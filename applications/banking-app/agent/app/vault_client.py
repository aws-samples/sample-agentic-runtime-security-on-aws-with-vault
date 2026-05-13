"""vault_client.py — Vault Kubernetes auth for the UC2 banking agent pod.

The agent pod uses Kubernetes Service Account JWT auth (OBJ-1 — workload
identity) to obtain its own Vault token at startup. This token is used
exclusively for the pod's workload identity — NOT for user data access.

The user's DB credential path is handled entirely by the MCP server:
  Agent → MCP server (with user JWT) → Vault jwt auth → per-user DB creds

The agent never calls Vault for database credentials. This separation is
intentional and pedagogically important for the UC2 workshop demo.
"""

import logging
import os

import boto3
import hvac

logger = logging.getLogger(__name__)


class AgentVaultClient:
    """Vault Kubernetes auth for the UC2 banking agent workload identity.

    Lifecycle:
      1. Construct with addr + k8s_role.
      2. Call login() once at pod startup (token cached for pod lifecycle).
      3. The token is available for any agent-level Vault operations
         (e.g., fetching agent configuration — not DB credentials).

    Note: This client does NOT issue database credentials.
          DB credentials are handled by the MCP server via Vault jwt auth
          using the user's IVIA JWT.
    """

    SA_JWT_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token"

    def __init__(self, vault_addr: str, vault_role: str) -> None:
        self._addr = vault_addr
        self._role = vault_role
        self.client = hvac.Client(url=vault_addr)

    def login(self) -> None:
        """Authenticate using the Kubernetes Service Account JWT (OBJ-1).

        Reads the projected SA token from the standard K8s mount path and
        presents it to the Vault Kubernetes auth method. This establishes
        the agent pod's workload identity.
        """
        with open(self.SA_JWT_PATH, "r") as fh:
            jwt = fh.read().strip()

        response = self.client.auth.kubernetes.login(
            role=self._role,
            jwt=jwt,
        )
        ttl = response.get("auth", {}).get("lease_duration", "unknown")
        logger.info(
            "vault_k8s_auth_success",
            extra={
                "vault_role": self._role,
                "token_ttl_seconds": ttl,
                "auth_method": "kubernetes",
                "note": "agent workload identity only; user DB creds via MCP server",
            },
        )

    def get_bedrock_session(self, region: str) -> boto3.Session:
        """Obtain ephemeral AWS STS credentials from Vault aws secrets engine (OBJ-2).

        Returns a boto3.Session with Vault-issued short-lived credentials
        scoped to the bedrock-reader IAM role.
        """
        response = self.client.read("aws/sts/bedrock-reader")
        data = response["data"]
        session = boto3.Session(
            aws_access_key_id=data["access_key"],
            aws_secret_access_key=data["secret_key"],
            aws_session_token=data["security_token"],
            region_name=region,
        )
        logger.info(
            "bedrock_sts_credentials_issued",
            extra={
                "vault_aws_role": "bedrock-reader",
                "lease_id": response.get("lease_id", "n/a"),
                "region": region,
            },
        )
        return session

    def is_authenticated(self) -> bool:
        """Return True if the cached Vault token is still valid."""
        return self.client.is_authenticated()


def build_agent_vault_client() -> AgentVaultClient:
    """Build an AgentVaultClient from environment variables.

    Expected env vars (set via ConfigMap in the Kubernetes deployment):
      VAULT_ADDR   — Vault cluster endpoint, e.g. http://vault.vault.svc:8200
      VAULT_ROLE   — Vault Kubernetes auth role for the agent pod workload identity
    """
    vault_addr = os.getenv("VAULT_ADDR", "http://vault.vault.svc.cluster.local:8200")
    vault_role = os.getenv("VAULT_ROLE", "uc2-agent")
    return AgentVaultClient(vault_addr=vault_addr, vault_role=vault_role)
