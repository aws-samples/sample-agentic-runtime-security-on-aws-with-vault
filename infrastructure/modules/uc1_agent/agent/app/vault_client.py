"""Vault Kubernetes auth + JIT credential fetch for UC1 agent.

Demonstrates OBJ-1 (verifiable identity) and OBJ-2 (no standing privileges).

The VaultClient authenticates once using the pod's Kubernetes Service Account JWT
and then issues Just-In-Time database and AWS STS credentials on demand. Every
credential has a finite TTL and is auditable in the Vault audit log stream.
"""

import logging
import os
from datetime import datetime, timedelta, timezone

import boto3
import hvac
from botocore.credentials import RefreshableCredentials
from botocore.session import get_session as _get_botocore_session

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

    def ensure_authenticated(self) -> None:
        """Re-login if the pod's Vault token has expired.

        The agent logs in once at startup, but the Vault token has a finite TTL.
        Without this guard the token silently expires and every subsequent JIT
        credential request fails with hvac.exceptions.Forbidden — which the model
        then narrates as "I couldn't find it" instead of a real error. The
        projected SA JWT on disk is auto-rotated by Kubernetes, so a fresh login
        always succeeds. Mirrors the banking-app agent's proven re-auth pattern.

        Public because /health calls it too: a probe that only inspects the
        cached token reports "degraded" on a perfectly serviceable agent as soon
        as the TTL elapses, while the very next /query silently re-logs in.
        """
        if not self.client.is_authenticated():
            logger.info("vault_token_expired_relogin")
            self.login()

    def get_db_credentials(self, role_name: str = "uc1-readonly") -> dict:
        """Issue JIT Postgres credentials from the Vault database secrets engine (OBJ-2).

        Each call creates a new ephemeral database user with a TTL-bounded
        password. Lease ID is returned so callers can include it in audit logs.

        Args:
            role_name: Vault database role to generate credentials for.

        Returns:
            dict with keys: username, password, lease_id, lease_duration.
        """
        self.ensure_authenticated()
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
        """Obtain a boto3.Session with auto-refreshing Vault STS creds (OBJ-2).

        The returned session is backed by botocore RefreshableCredentials: when
        the short-lived bedrock-reader STS credentials near expiry, botocore
        transparently calls the refresh closure to mint a new lease (re-logging
        into Vault if needed). This lets the agent be built once at startup and
        run for the pod's full lifetime without the credentials going stale —
        fixing the ExpiredTokenException that previously surfaced after the
        lease TTL elapsed.

        Args:
            kb_region: AWS region where the Bedrock Knowledge Base resides.
        """

        def _refresh() -> dict:
            self.ensure_authenticated()
            response = self.client.read("aws/sts/bedrock-reader")
            data = response["data"]
            lease_seconds = int(response.get("lease_duration") or 900)
            expiry = datetime.now(timezone.utc) + timedelta(seconds=lease_seconds)
            logger.info(
                "bedrock_sts_credentials_issued",
                extra={
                    "vault_aws_role": "bedrock-reader",
                    "lease_id": response.get("lease_id", "n/a"),
                    "lease_seconds": lease_seconds,
                    "kb_region": kb_region,
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
        botocore_session.set_config_variable("region", kb_region)
        return boto3.Session(botocore_session=botocore_session, region_name=kb_region)

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
