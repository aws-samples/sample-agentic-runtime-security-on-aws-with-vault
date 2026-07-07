"""vault_client.py — Vault client for the UC3 privileged-action agent.

Two-phase Vault authentication pattern for UC3:

  Phase 1 (workload identity at startup):
    K8s SA JWT → Vault kubernetes auth (role "uc3") → agent Vault token
    Used for: lookup_transaction (read-only DB creds), Bedrock STS creds

  Phase 2 (per-refund delegated auth):
    Delegated JWT (RFC 8693 subject_token with may_act claim)
    → Vault jwt auth (role "uc3-jwt")
    → uc3-refund-writer DB creds (TTL 5m)
    Used for: process_refund write path only

This dual-path ensures OBJ-2 (no standing privileges) and OBJ-3 (privileged
write is gated on user consent via CIBA + token exchange — never just the
agent's own workload identity).
"""

import logging
import os
from datetime import datetime, timedelta, timezone

import boto3
import hvac
from botocore.credentials import RefreshableCredentials
from botocore.session import get_session as _get_botocore_session

logger = logging.getLogger(__name__)


class UC3VaultClient:
    """Vault client for the UC3 privileged-action agent.

    Lifecycle:
      1. Construct with addr + vault_role.
      2. Call login() at pod startup — establishes workload identity token.
      3. Call get_readonly_credentials() for lookup_transaction tool.
      4. Call get_refund_credentials(delegated_jwt, request_id) for process_refund tool.
      5. Call get_bedrock_credentials() / get_logs_credentials() — both return
         boto3.Session backed by RefreshableCredentials, so no per-call refresh
         dance is needed: botocore re-issues the Vault lease transparently as
         the previous one approaches expiry.
    """

    SA_JWT_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token"

    def __init__(self, vault_addr: str, vault_role: str) -> None:
        self._addr = vault_addr
        self._role = vault_role
        self._client = hvac.Client(url=vault_addr)

    def login(self) -> None:
        """Authenticate using the Kubernetes Service Account JWT (OBJ-1).

        Presents the projected SA token to Vault Kubernetes auth method.
        Role "uc3" is bound to the uc3-agent service account; policy grants
        read-only DB creds + aws/sts/bedrock-reader + kv reads.
        """
        with open(self.SA_JWT_PATH, "r") as fh:
            jwt = fh.read().strip()

        response = self._client.auth.kubernetes.login(
            role=self._role,
            jwt=jwt,
        )
        ttl = response.get("auth", {}).get("lease_duration", "unknown")
        logger.info(
            "uc3_vault_k8s_auth_success",
            extra={
                "vault_role": self._role,
                "token_ttl_seconds": ttl,
                "auth_method": "kubernetes",
            },
        )

    def get_readonly_credentials(self) -> dict:
        """Fetch DB credentials from Vault for transaction/refund-status lookups.

        Uses the agent's K8s auth workload identity token.
        Role: uc3-readonly — least-privilege role with SELECT-only grants on
        banking.transactions, banking.accounts, banking.refunds.  Cannot INSERT
        or UPDATE any table.  Write credentials are fetched separately via
        get_refund_credentials() only after CIBA consent + token exchange.

        Returns:
            Dict with keys: username, password, host, port, dbname
        """
        vault_db_path = os.getenv("VAULT_DB_READONLY_PATH", "database/creds/uc3-readonly")
        response = self._client.read(vault_db_path)
        data = response["data"]

        logger.info(
            "uc3_db_creds_issued",
            extra={
                "vault_db_path": vault_db_path,
                "lease_id": response.get("lease_id", "n/a"),
                "lease_duration": response.get("lease_duration", "unknown"),
                "username": data.get("username", "n/a"),
            },
        )
        return {
            "username": data["username"],
            "password": data["password"],
            "host": os.getenv("DB_HOST", "localhost"),
            "port": int(os.getenv("DB_PORT", "5432")),
            "dbname": os.getenv("DB_NAME", "workshop"),
        }

    def get_refund_credentials(self, delegated_jwt: str, request_id: str) -> dict:
        """Fetch uc3-refund-writer DB credentials via Vault jwt auth (OBJ-2, OBJ-3).

        Presents the RFC 8693 delegated JWT (with may_act claim) to Vault's
        jwt auth method under role "uc3-jwt". Vault validates:
          - JWT signature via IVIA JWKS endpoint
          - may_act claim is present (delegation proof)
          - bound_claims enforced per vault_config module

        TTL is 5 minutes — credential lifetime scoped to a single refund operation.

        Args:
            delegated_jwt: RFC 8693 delegated access token with may_act claim.
            request_id: UUID threaded through the refund flow for audit correlation.

        Returns:
            Dict with keys: username, password, host, port, dbname
        """
        response = self._client.auth.jwt.jwt_login(
            role="uc3-jwt",
            jwt=delegated_jwt,
            path="jwt",
        )
        # Switch to the delegated token for the DB creds fetch
        delegated_client = hvac.Client(
            url=self._addr,
            token=response["auth"]["client_token"],
        )

        vault_db_path = "database/creds/uc3-refund-writer"
        db_response = delegated_client.read(vault_db_path)
        data = db_response["data"]

        logger.info(
            "uc3_refund_writer_creds_issued",
            extra={
                "vault_db_path": vault_db_path,
                "vault_role": "uc3-jwt",
                "lease_id": db_response.get("lease_id", "n/a"),
                "lease_duration": db_response.get("lease_duration", "unknown"),
                "username": data.get("username", "n/a"),
                "request_id": request_id,
                "auth_method": "jwt",
                "delegation": "rfc8693_may_act",
            },
        )
        return {
            "username": data["username"],
            "password": data["password"],
            "host": os.getenv("DB_HOST", "localhost"),
            "port": int(os.getenv("DB_PORT", "5432")),
            "dbname": os.getenv("DB_NAME", "workshop"),
            # Real numeric lease TTL (seconds, e.g. 300) the agent OBSERVED when
            # Vault issued the credential. The Vault AUDIT-logged response does NOT
            # carry this numeric value (only a lease-id identifier), so the agent
            # threads it forward here to populate db_credential_ttl in the
            # three-plane audit_correlation VIEW (proof of OBJ-2: no standing creds).
            "lease_duration": db_response.get("lease_duration"),
        }

    def _build_refreshing_session(self, vault_aws_role: str, log_event: str) -> boto3.Session:
        """Build a boto3.Session backed by RefreshableCredentials over a Vault STS role.

        Shared between get_bedrock_credentials() and get_logs_credentials() — both
        read short-lived `aws/sts/<role>` leases and want botocore to re-mint them
        transparently as the previous lease approaches expiry. Without this, every
        STS lease silently expires after its TTL and downstream AWS calls return
        ExpiredTokenException (OBJ-2 — no standing privileges, but no breakage either).

        Args:
            vault_aws_role: The Vault aws/sts/<role> path suffix (e.g., "bedrock-reader").
            log_event: Structured log event name to emit on each lease issuance.
        """
        region = os.getenv("AWS_REGION") or os.getenv("AWS_DEFAULT_REGION")
        if not region:
            raise RuntimeError("AWS_REGION (or AWS_DEFAULT_REGION) must be set")
        vault_path = f"aws/sts/{vault_aws_role}"

        def _refresh() -> dict:
            if not self._client.is_authenticated():
                logger.info("uc3_vault_token_expired_relogin")
                self.login()
            response = self._client.read(vault_path)
            data = response["data"]
            lease_seconds = int(response.get("lease_duration") or 900)
            expiry = datetime.now(timezone.utc) + timedelta(seconds=lease_seconds)
            logger.info(
                log_event,
                extra={
                    "vault_aws_role": vault_aws_role,
                    "lease_id": response.get("lease_id", "n/a"),
                    "lease_seconds": lease_seconds,
                    "region": region,
                },
            )
            return {
                "access_key": data["access_key"],
                "secret_key": data["secret_key"],
                "token": data["security_token"],
                "expiry_time": expiry.isoformat(),
            }

        creds = RefreshableCredentials.create_from_metadata(
            metadata=_refresh(),
            refresh_using=_refresh,
            method="vault-aws-sts",
        )
        botocore_session = _get_botocore_session()
        botocore_session._credentials = creds
        botocore_session.set_config_variable("region", region)
        return boto3.Session(botocore_session=botocore_session, region_name=region)

    def get_bedrock_credentials(self) -> boto3.Session:
        """Obtain a boto3.Session with auto-refreshing Bedrock STS creds (OBJ-2).

        Returns a session backed by botocore RefreshableCredentials over Vault's
        aws/sts/bedrock-reader role — botocore re-issues the lease transparently
        as the previous one approaches expiry, so the agent can run for the pod's
        full lifetime without hitting ExpiredTokenException.
        """
        return self._build_refreshing_session(
            vault_aws_role="bedrock-reader",
            log_event="uc3_bedrock_sts_credentials_issued",
        )

    def get_logs_credentials(self) -> boto3.Session:
        """Obtain a boto3.Session with auto-refreshing CloudWatch Logs STS creds (OBJ-2).

        Used by the Branch-B ivia_decisions anchor emission (CONTEXT Delta-6).
        Session is server-side-scoped to logs:PutLogEvents + logs:CreateLogStream
        on the single /workshop/ivia-decision log group. The agent holds NO
        standing AWS identity — leases are short-lived and rotated transparently.
        """
        return self._build_refreshing_session(
            vault_aws_role="uc3-logs-writer",
            log_event="uc3_logs_sts_credentials_issued",
        )

    def is_authenticated(self) -> bool:
        """Return True if the cached Vault token is still valid."""
        return self._client.is_authenticated()
