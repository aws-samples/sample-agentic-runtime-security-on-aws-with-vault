"""vault_client.py — Vault Kubernetes auth for the UC2 banking agent pod.

The agent pod uses Kubernetes Service Account JWT auth (OBJ-1 — workload
identity) to obtain its own Vault token at startup. This token is used
exclusively for the pod's workload identity — NOT for user data access.

The user's DB credential path is handled entirely by the MCP server:
  Agent → MCP server (with user JWT) → Vault jwt auth → per-user DB creds

The agent never calls Vault for database credentials. This separation is
intentional and pedagogically important for the UC2 workshop demo.

The workshop shows every credential in full (Bear, 2026-09-24), including the
agent's own: the service-account JWT its Kubernetes login presented, the Vault
token that login returned, and the Bedrock keys Vault issued with it. This
client keeps them in memory and hands a turn the keys that signed its model
calls (on_keys_used), together with the login they were issued under. They are
never logged here; the caller sends them only on the turn's own event queue.
"""

import logging
import os
import threading
import time
from collections import OrderedDict
from collections.abc import Callable
from datetime import datetime, timedelta, timezone

import boto3
import hvac
from botocore.credentials import RefreshableCredentials
from botocore.session import get_session as _get_botocore_session

logger = logging.getLogger(__name__)

# How many Bedrock key issuances to remember. botocore holds one set at a time,
# so this only needs to cover a refresh landing while an older set is still
# signing a request.
_ISSUANCES_KEPT = 8


class _ReportingCredentials(RefreshableCredentials):
    """RefreshableCredentials that say which keys signed each AWS request.

    botocore freezes the credentials once per request it signs
    (botocore/signers.py, RequestSigner.get_auth_instance); a refresh, when the
    keys near expiry, happens inside that same call. After it, the access key id
    of the keys that actually sign the request is passed to on_use.
    """

    on_use: Callable[[str], None] | None = None

    def get_frozen_credentials(self):
        frozen = super().get_frozen_credentials()
        on_use = self.on_use
        if on_use is not None:
            try:
                on_use(frozen.access_key)
            except Exception as exc:  # noqa: BLE001 — reporting must never fail request signing
                logger.warning("bedrock_key_use_report_failed: %s", type(exc).__name__)
        return frozen


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

    def __init__(
        self,
        vault_addr: str,
        vault_role: str,
        on_keys_used: Callable[[dict], None] | None = None,
    ) -> None:
        self._addr = vault_addr
        self._role = vault_role
        self.client = hvac.Client(url=vault_addr)
        # Called with an issuance record (see _fetch_bedrock_sts) each time a set
        # of Bedrock keys signs a request. Values go to the event queue only.
        self._on_keys_used = on_keys_used
        # The current login's credentials, in memory only (login_details()).
        self._login: dict | None = None
        # Bedrock key issuances by access key id, newest last, bounded.
        self._issuances: OrderedDict[str, dict] = OrderedDict()
        self._issuances_lock = threading.Lock()

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
        auth = response.get("auth", {})
        ttl = auth.get("lease_duration", "unknown")
        metadata = auth.get("metadata") or {}
        self._login = {
            "sa_jwt": jwt,
            "vault_token": auth.get("client_token") or self.client.token,
            "ttl_seconds": ttl if isinstance(ttl, int) else None,
            "issued_at": time.time(),
            "role": metadata.get("role") or self._role,
            "service_account_name": metadata.get("service_account_name"),
            "policies": list(auth.get("policies") or []),
        }
        logger.info(
            "vault_k8s_auth_success",
            extra={
                "vault_role": self._role,
                "token_ttl_seconds": ttl,
                "auth_method": "kubernetes",
                "note": "agent workload identity only; user DB creds via MCP server",
            },
        )

    def login_details(self) -> dict | None:
        """The current login's credentials, for a streamed turn's events only.

        Returns {"sa_jwt", "vault_token", "ttl_seconds", "issued_at", "role",
        "service_account_name", "policies"} — the service-account JWT the login
        presented, the Vault token it returned, the TTL Vault granted, the login
        time (epoch seconds), the Kubernetes auth role and service account Vault
        reported, and the token's policies — or None before the first login.
        Never log these; send them only on the turn's event queue.
        """
        return dict(self._login) if self._login else None

    def ensure_authenticated(self) -> None:
        """Re-login if the pod's Vault token has expired.

        The projected SA token on disk is auto-rotated by Kubernetes, so a fresh
        login always succeeds. Called on every credential fetch, and by /health
        so the probe reports what a real request would find rather than the
        staleness of a token cached at pod startup.
        """
        if not self.client.is_authenticated():
            logger.info("vault_token_expired_relogin")
            self.login()

    def _fetch_bedrock_sts(self) -> dict:
        """Read fresh ephemeral STS credentials from Vault's aws secrets engine.

        Re-authenticates to Vault first if the pod's Vault token has expired.
        This is the refresh callback for RefreshableCredentials, so it is invoked
        transparently by botocore whenever the cached STS credentials approach
        their lease expiry.

        Returns the metadata dict botocore expects (access_key/secret_key/token/
        expiry_time), NOT a boto3.Session.
        """
        self.ensure_authenticated()

        response = self.client.read("aws/sts/bedrock-reader")
        data = response["data"]
        # Refresh slightly before the lease actually ends; botocore's advisory
        # window keeps creds valid across the swap.
        lease_seconds = int(response.get("lease_duration") or 900)
        expiry = datetime.now(timezone.utc) + timedelta(seconds=lease_seconds)
        issued = {
            "vault_path": "aws/sts/bedrock-reader",
            "lease_id": response.get("lease_id"),
            "ttl_seconds": lease_seconds,
            "issued_at": time.time(),
            "access_key_id": data["access_key"],
            "secret_access_key": data["secret_key"],
            "session_token": data["security_token"],
            # The login these keys were issued under, so a turn can show the chain.
            "login": self.login_details(),
        }
        with self._issuances_lock:
            self._issuances[data["access_key"]] = issued
            while len(self._issuances) > _ISSUANCES_KEPT:
                self._issuances.popitem(last=False)
        logger.info(
            "bedrock_sts_credentials_issued",
            extra={
                "vault_aws_role": "bedrock-reader",
                "lease_id": response.get("lease_id", "n/a"),
                "lease_seconds": lease_seconds,
                "region": "n/a",
            },
        )
        return {
            "access_key": data["access_key"],
            "secret_key": data["secret_key"],
            "token": data["security_token"],
            "expiry_time": expiry.isoformat(),
        }

    def get_bedrock_session(self, region: str) -> boto3.Session:
        """Obtain a boto3.Session with auto-refreshing Vault STS creds (OBJ-2).

        The returned session is backed by botocore RefreshableCredentials: when
        the short-lived bedrock-reader STS credentials near expiry, botocore
        calls _fetch_bedrock_sts() to mint a new lease (re-logging into Vault if
        needed). This lets the agent be built once at startup and run for the
        pod's full lifetime without the credentials going stale — fixing the
        ExpiredTokenException that previously surfaced after the lease TTL.
        """
        creds = _ReportingCredentials.create_from_metadata(
            metadata=self._fetch_bedrock_sts(),
            refresh_using=self._fetch_bedrock_sts,
            method="vault-aws-sts",
        )
        creds.on_use = self._keys_used
        botocore_session = _get_botocore_session()
        botocore_session._credentials = creds
        botocore_session.set_config_variable("region", region)
        return boto3.Session(botocore_session=botocore_session, region_name=region)

    def _keys_used(self, access_key_id: str) -> None:
        """Hand on_keys_used the issuance record of the keys that just signed a request."""
        if self._on_keys_used is None:
            return
        with self._issuances_lock:
            issued = self._issuances.get(access_key_id)
        if issued is not None:
            self._on_keys_used(dict(issued))

    def is_authenticated(self) -> bool:
        """Return True if the cached Vault token is still valid."""
        return self.client.is_authenticated()


def build_agent_vault_client(on_keys_used: Callable[[dict], None] | None = None) -> AgentVaultClient:
    """Build an AgentVaultClient from environment variables.

    Expected env vars (set via ConfigMap in the Kubernetes deployment):
      VAULT_ADDR   — Vault cluster endpoint, e.g. http://vault.vault.svc:8200
      VAULT_ROLE   — Vault Kubernetes auth role for the agent pod workload identity

    on_keys_used: see AgentVaultClient — main.py passes the turn reporter.
    """
    vault_addr = os.getenv("VAULT_ADDR", "http://vault.vault.svc.cluster.local:8200")
    vault_role = os.getenv("VAULT_ROLE", "uc2-agent")
    return AgentVaultClient(vault_addr=vault_addr, vault_role=vault_role, on_keys_used=on_keys_used)
