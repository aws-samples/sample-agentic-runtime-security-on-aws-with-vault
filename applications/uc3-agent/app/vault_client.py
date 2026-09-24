"""vault_client.py — Vault client for the UC3 privileged-action agent.

Two-phase Vault authentication pattern for UC3:

  Phase 1 (workload identity at startup):
    K8s SA JWT → Vault kubernetes auth (role "uc3") → agent Vault token
    Used for: lookup_transaction (read-only DB creds), Bedrock STS creds

  Phase 2 (per-refund delegated auth):
    Delegated IVIA OAuth JWT (RFC 8693 subject_token with may_act claim,
    a jti claim, and a vault:path_access authorization_details RAR)
    → presented DIRECTLY as the Vault token via the X-Vault-Token header
      (Vault OAuth resource server validates the JWT and scopes it per the RAR)
    → uc3-refund-writer DB creds (TTL 5m)
    Used for: process_refund write path only.
    There is NO Vault login round-trip and NO intermediate Vault token — the
    OAuth JWT IS the credential (Phase 9 native cutover, locked decision (a);
    no fallback path remains).

This dual-path ensures OBJ-2 (no standing privileges) and OBJ-3 (privileged
write is gated on user consent via CIBA + token exchange — never just the
agent's own workload identity).
"""

import logging
import os
import time
from datetime import datetime, timedelta, timezone

import boto3
import hvac
from botocore.credentials import RefreshableCredentials
from botocore.session import get_session as _get_botocore_session

from . import activity

logger = logging.getLogger(__name__)

# What each Vault aws/sts role's keys are used for, in the credential label.
_STS_PURPOSE = {
    "bedrock-reader": "the model calls to Amazon Bedrock",
    "uc3-logs-writer": "the audit anchor in CloudWatch Logs",
}


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
        # When the current Vault token was issued and its TTL, for the UI's
        # credential view (report_vault_token).
        self._login_at: float | None = None
        self._login_ttl: int | None = None

    @property
    def role(self) -> str:
        """The Vault Kubernetes auth role this agent logs in as (VAULT_ROLE)."""
        return self._role

    def login(self) -> None:
        """Authenticate using the Kubernetes Service Account JWT (OBJ-1).

        Presents the projected SA token to Vault Kubernetes auth method.
        Role "uc3" is bound to the uc3-privileged-actor-sa service account in
        banking-app and to the uc3-agent policy: database/creds/uc3-readonly,
        aws/sts/bedrock-reader, aws/sts/uc3-logs-writer, own-token lookup and
        lease renewal. It grants no refund-writer credentials; those come only
        from an approved refund's delegated token (get_refund_credentials).

        A login during a chat request (re-login after the token expired) shows
        the service-account JWT and the new Vault token on that request's
        activity stream; the one at pod startup has no request to show them on.
        """
        with open(self.SA_JWT_PATH, "r") as fh:
            jwt = fh.read().strip()

        response = self._client.auth.kubernetes.login(
            role=self._role,
            jwt=jwt,
        )
        ttl = response.get("auth", {}).get("lease_duration", "unknown")
        self._login_at = time.time()
        self._login_ttl = ttl if isinstance(ttl, int) else None
        logger.info(
            "uc3_vault_k8s_auth_success",
            extra={
                "vault_role": self._role,
                "token_ttl_seconds": ttl,
                "auth_method": "kubernetes",
            },
        )
        sa_claims = activity.decode_jwt_payload(jwt) or {}
        activity.credential(
            "k8s_sa_token",
            "The uc3 agent's Kubernetes service-account token, presented to Vault to log in",
            "Kubernetes",
            value=jwt,
            expires_at=int(sa_claims["exp"] * 1000) if isinstance(sa_claims.get("exp"), (int, float)) else None,
        )
        self.report_vault_token()

    def report_vault_token(self) -> None:
        """Show the agent's current Vault token (from its Kubernetes login) on
        the current request's activity stream. Sent once per request."""
        token = self._client.token
        if not token:
            return
        activity.credential(
            "vault_token",
            f"The uc3 agent's Vault token from its Kubernetes login (role {self._role})",
            "Vault",
            value=token,
            vault_path="auth/kubernetes/login",
            ttl_seconds=self._login_ttl,
            expires_at=activity.expires_at_ms(self._login_ttl, self._login_at) if self._login_at else None,
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
        activity.credential(
            "db_credentials",
            f"Read-only database credentials Vault issued to the agent's own Vault token ({vault_db_path})",
            "Vault",
            fields={"username": data["username"], "password": data["password"]},
            vault_path=vault_db_path,
            lease_id=response.get("lease_id"),
            ttl_seconds=response.get("lease_duration"),
            expires_at=activity.expires_at_ms(response.get("lease_duration")),
        )
        return {
            "username": data["username"],
            "password": data["password"],
            "host": os.getenv("DB_HOST", "localhost"),
            "port": int(os.getenv("DB_PORT", "5432")),
            "dbname": os.getenv("DB_NAME", "workshop"),
        }

    def get_refund_credentials(self, oauth_jwt: str, request_id: str) -> dict:
        """Fetch uc3-refund-writer DB credentials by presenting the delegated
        IVIA OAuth JWT directly as the Vault token (OBJ-2, OBJ-3).

        Phase 9 native cutover (locked decision (a)): the delegated OAuth JWT
        IS the Vault credential. It is presented directly via the X-Vault-Token
        header (hvac sets it from the token= kwarg) — there is NO Vault login
        round-trip and NO intermediate Vault token. Vault's OAuth resource
        server validates the JWT and authorizes the request:
          - JWT signature via IVIA JWKS endpoint
          - jti claim present (schema validation; missing → rejected)
          - a vault:path_access authorization_details (RAR) entry scoping the
            request to database/creds/uc3-refund-writer (mandatory for UC3;
            profile optional_authorization_details=false)

        This is the ONLY credential path for the refund write. On any error the
        exception SURFACES — there is no fallback to a Vault login or K8s auth
        (no such path remains). The token is never sent as an Authorization
        header (that silently resolves to no identity). Runtime assertion of jti
        on the real token is Plan 08's live done-gate.

        TTL is 5 minutes — credential lifetime scoped to a single refund operation.

        Args:
            oauth_jwt: Delegated IVIA OAuth JWT (RFC 8693 access token carrying
                may_act, jti, and the vault:path_access RAR).
            request_id: UUID threaded through the refund flow for audit correlation.

        Returns:
            Dict with keys: username, password, host, port, dbname
        """
        # Present the OAuth JWT directly as the Vault token (X-Vault-Token).
        oauth_client = hvac.Client(url=self._addr, token=oauth_jwt)

        # Stamp the flow's request_id onto the Vault request so the Vault audit
        # plane carries the SAME id as the IVIA approval and the Postgres write.
        # Vault records this header because vault_audit_request_header
        # "correlation_id" allowlists it (hmac=false, so the value is verbatim);
        # without the allowlist Vault drops it silently. This is the join key the
        # audit_correlation VIEW uses — before it existed the VIEW had to guess,
        # matching the Vault record to the approval by credential path and a 30s
        # time window, which is ambiguous the moment two refunds overlap.
        oauth_client.session.headers["X-Correlation-Id"] = request_id

        vault_db_path = "database/creds/uc3-refund-writer"
        db_response = oauth_client.read(vault_db_path)
        data = db_response["data"]

        logger.info(
            "uc3_refund_writer_creds_issued",
            extra={
                "vault_db_path": vault_db_path,
                "lease_id": db_response.get("lease_id", "n/a"),
                "lease_duration": db_response.get("lease_duration", "unknown"),
                "username": data.get("username", "n/a"),
                "request_id": request_id,
                "auth_method": "oauth_resource_server_x_vault_token",
                "delegation": "rfc8693_may_act",
            },
        )
        activity.credential(
            "db_credentials",
            "Refund-writer database credentials Vault issued to the delegated token "
            f"({vault_db_path})",
            "Vault",
            fields={"username": data["username"], "password": data["password"]},
            vault_path=vault_db_path,
            lease_id=db_response.get("lease_id"),
            ttl_seconds=db_response.get("lease_duration"),
            expires_at=activity.expires_at_ms(db_response.get("lease_duration")),
            request_id=request_id,
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
            # The lease identifier (database/creds/uc3-refund-writer/<id>) — an
            # identifier, not the credential. The refund flow reports it to the
            # browser so the Audit Trace can name the exact lease Vault issued.
            "lease_id": db_response.get("lease_id"),
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
            self.ensure_authenticated()
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
            # Every lease botocore asks for (the first, and each refresh) is shown
            # on the activity stream of the request that caused it.
            activity.credential(
                "aws_sts_credentials",
                f"AWS STS keys Vault issued for {_STS_PURPOSE.get(vault_aws_role, vault_aws_role)} ({vault_path})",
                "AWS STS (via Vault)",
                fields={
                    "access_key_id": data["access_key"],
                    "secret_access_key": data["secret_key"],
                    "session_token": data["security_token"],
                },
                vault_path=vault_path,
                lease_id=response.get("lease_id"),
                ttl_seconds=lease_seconds,
                expires_at=int(expiry.timestamp() * 1000),
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

    def ensure_authenticated(self) -> None:
        """Re-login if the pod's Vault token has expired.

        The projected SA token on disk is auto-rotated by Kubernetes, so a fresh
        login always succeeds. Called on every credential refresh, and by /health
        so the probe reports what a real request would find rather than the
        staleness of a token cached at pod startup.
        """
        if not self._client.is_authenticated():
            logger.info("uc3_vault_token_expired_relogin")
            self.login()

    def is_authenticated(self) -> bool:
        """Return True if the cached Vault token is still valid."""
        return self._client.is_authenticated()
