"""Vault Kubernetes auth + JIT credential fetch for UC1 agent.

Demonstrates OBJ-1 (verifiable identity) and OBJ-2 (no standing privileges).

The VaultClient authenticates once using the pod's Kubernetes Service Account JWT
and then issues Just-In-Time database and AWS STS credentials on demand. Every
credential has a finite TTL and is auditable in the Vault audit log stream.
"""

import logging
import os

import boto3
import hvac

logger = logging.getLogger(__name__)


class VaultClient:
    """Authenticates to Vault via Kubernetes SA JWT and vends JIT credentials.

    Lifecycle:
      1. Construct with addr + role.
      2. Call login() once per pod startup (token cached for pod lifecycle).
      3. Call get_db_credentials() / get_bedrock_session() per request.
    """

    SA_JWT_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token"

    def __init__(self, vault_addr: str, vault_role: str) -> None:
        self._addr = vault_addr
        self._role = vault_role
        self.client = hvac.Client(url=vault_addr)

    def login(self) -> None:
        """Authenticate using the Kubernetes Service Account JWT (OBJ-1).

        Reads the projected SA token from the standard K8s mount path and
        presents it to the Vault Kubernetes auth method. The resulting Vault
        token is stored in self.client.token for subsequent API calls.
        """
        with open(self.SA_JWT_PATH, "r") as fh:
            jwt = fh.read().strip()

        response = self.client.auth.kubernetes.login(
            role=self._role,
            jwt=jwt,
        )
        ttl = response.get("auth", {}).get("lease_duration", "unknown")
        logger.info(
            "vault_auth_success",
            extra={
                "vault_role": self._role,
                "token_ttl_seconds": ttl,
                "auth_method": "kubernetes",
            },
        )

    def get_db_credentials(self, role_name: str = "uc1-readonly") -> dict:
        """Issue JIT Postgres credentials from the Vault database secrets engine (OBJ-2).

        Each call creates a new ephemeral database user with a TTL-bounded
        password. Lease ID is returned so callers can include it in audit logs.

        Args:
            role_name: Vault database role to generate credentials for.

        Returns:
            dict with keys: username, password, lease_id, lease_duration.
        """
        response = self.client.secrets.database.generate_credentials(name=role_name)
        creds = {
            "username": response["data"]["username"],
            "password": response["data"]["password"],
            "lease_id": response["lease_id"],
            "lease_duration": response["lease_duration"],
        }
        logger.info(
            "db_credentials_issued",
            extra={
                "vault_role": role_name,
                "lease_id": creds["lease_id"],
                "lease_duration_seconds": creds["lease_duration"],
            },
        )
        return creds

    def get_bedrock_session(self, kb_region: str) -> boto3.Session:
        """Obtain ephemeral AWS STS credentials from Vault aws secrets engine (OBJ-2).

        Vault generates a temporary IAM credential (access key + secret + session
        token) for the bedrock-reader role. A boto3.Session is constructed with
        those credentials scoped to kb_region so all Bedrock KB calls are bounded
        to a single short-lived credential set.

        Args:
            kb_region: AWS region where the Bedrock Knowledge Base resides.

        Returns:
            boto3.Session configured with the ephemeral STS credentials.
        """
        response = self.client.secrets.aws.generate_credentials(name="bedrock-reader")
        data = response["data"]
        session = boto3.Session(
            aws_access_key_id=data["access_key"],
            aws_secret_access_key=data["secret_key"],
            aws_session_token=data["security_token"],
            region_name=kb_region,
        )
        logger.info(
            "bedrock_sts_credentials_issued",
            extra={
                "vault_aws_role": "bedrock-reader",
                "lease_id": response.get("lease_id", "n/a"),
                "kb_region": kb_region,
            },
        )
        return session

    def is_authenticated(self) -> bool:
        """Return True if the cached Vault token is valid."""
        return self.client.is_authenticated()


def _build_default_client() -> VaultClient:
    """Build a VaultClient from environment variables.

    Expected env vars (set via ConfigMap in the Kubernetes deployment):
      VAULT_ADDR   — Vault cluster endpoint, e.g. http://vault.vault.svc:8200
      VAULT_ROLE   — Vault Kubernetes auth role, e.g. uc1-agent
    """
    vault_addr = os.getenv("VAULT_ADDR", "http://vault.vault.svc.cluster.local:8200")
    vault_role = os.getenv("VAULT_ROLE", "uc1-agent")
    return VaultClient(vault_addr=vault_addr, vault_role=vault_role)
