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

import boto3
import hvac

logger = logging.getLogger(__name__)


class UC3VaultClient:
    """Vault client for the UC3 privileged-action agent.

    Lifecycle:
      1. Construct with addr + vault_role.
      2. Call login() at pod startup — establishes workload identity token.
      3. Call get_readonly_credentials() for lookup_transaction tool.
      4. Call get_refund_credentials(delegated_jwt, request_id) for process_refund tool.
      5. Call get_bedrock_credentials() for Bedrock STS creds.
      6. Call refresh_sts_if_needed() before each Bedrock call.
    """

    SA_JWT_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token"

    def __init__(self, vault_addr: str, vault_role: str) -> None:
        self._addr = vault_addr
        self._role = vault_role
        self._client = hvac.Client(url=vault_addr)
        self._sts_session: boto3.Session | None = None

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
        """Fetch read-only DB credentials from Vault (lookup_transaction tool).

        Uses the agent's K8s auth workload identity token.
        Role: uc3-readonly — scoped to SELECT on banking.transactions only.

        Returns:
            Dict with keys: username, password, host, port, dbname
        """
        vault_db_path = os.getenv("VAULT_DB_READONLY_PATH", "database/creds/uc3-readonly")
        response = self._client.read(vault_db_path)
        data = response["data"]

        logger.info(
            "uc3_readonly_creds_issued",
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
        response = self._client.auth.jwt.login(
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
        }

    def get_bedrock_credentials(self) -> boto3.Session:
        """Obtain ephemeral Bedrock STS credentials from Vault aws secrets engine (OBJ-2).

        Uses the agent's workload identity token to read aws/sts/bedrock-reader.

        Returns:
            boto3.Session with Vault-issued STS credentials.
        """
        region = os.getenv("REGION", "us-west-2")
        response = self._client.read("aws/sts/bedrock-reader")
        data = response["data"]
        session = boto3.Session(
            aws_access_key_id=data["access_key"],
            aws_secret_access_key=data["secret_key"],
            aws_session_token=data["security_token"],
            region_name=region,
        )
        self._sts_session = session
        logger.info(
            "uc3_bedrock_sts_credentials_issued",
            extra={
                "vault_aws_role": "bedrock-reader",
                "lease_id": response.get("lease_id", "n/a"),
                "region": region,
            },
        )
        return session

    def refresh_sts_if_needed(self) -> boto3.Session | None:
        """Refresh Bedrock STS credentials if authenticated.

        Returns a fresh boto3.Session or None if not authenticated.
        """
        if self.is_authenticated():
            return self.get_bedrock_credentials()
        return self._sts_session

    def is_authenticated(self) -> bool:
        """Return True if the cached Vault token is still valid."""
        return self._client.is_authenticated()
