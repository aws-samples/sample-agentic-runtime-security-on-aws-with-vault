"""mmfa.py — IBM Verify mobile-push (MMFA) helpers for UC3 CIBA approval.

uc3-agent owns the push + identity end-to-end (OBJ-3): it fires the MMFA push to
the AUTHENTICATED user's IBM Verify device itself (identity from the verified
session, never a parameter), then reads that user's OWN SCIM MMFA transaction
status to decide approval. The IVIA `checkstatus` mapping rule polls
/api/ciba/status on this service, which calls read_txn_status() here.

Two operations, both against the AAC runtime (iviaruntime:9443):

  fire_push(username) -> transaction_id
    Unauthenticated authsvc policy `mmfa_initiate_simple_login`:
      GET  ?username=<user>                 -> device-select page
      POST ?StateId=<sid>&operation=verify  -> fires the push
    Returns the data-mmfa-transaction-id of the fired transaction.

  read_txn_status(username, transaction_id) -> "approved" | "denied" | "pending"
    Admin SCIM read (HTTP Basic easuser): GET /scim/Users filtered to the user,
    requesting only the MMFA Transaction attribute. Matches the EXACT fired
    transaction_id (never "any SUCCESS for the user" — the user accumulates
    stale SUCCESS/FAIL history) and maps txnStatus SUCCESS->approved,
    FAIL->denied; not-yet-resolved (pending list or absent) -> pending.

TLS: iviaruntime:9443 serves a self-signed cert CN=isam with no SAN. We PIN that
exact cert as the CA (IVIA_RUNTIME_CA_BUNDLE) and disable hostname matching only
(check_hostname=False, verify_mode stays CERT_REQUIRED) — certificate-pinning,
NOT verify=False. This authenticates the runtime and protects the easuser SCIM
credential against in-cluster MITM despite the CN!=DNS mismatch, mirroring the
repo's existing captured-serving-cert convention (iviaop.pem, iviawrprp1.pem).
"""

import logging
import os
import re
import ssl

import httpx

logger = logging.getLogger(__name__)

IVIA_RUNTIME_URL = os.getenv(
    "IVIA_RUNTIME_URL",
    "https://iviaruntime.verify-access.svc.cluster.local:9443",
).rstrip("/")
IVIA_RUNTIME_CA_BUNDLE = os.getenv("IVIA_RUNTIME_CA_BUNDLE", "/etc/ssl/ivia/iviaruntime.pem")

MMFA_POLICY = "/sps/authsvc/policy/mmfa_initiate_simple_login"
SCIM_USERS = "/scim/Users"
_MMFA_TXN_SCHEMA = "urn:ietf:params:scim:schemas:extension:isam:1.0:MMFA:Transaction"

# Markers in the authsvc HTML (verified live 2026-06-01).
_RE_DEVICE = re.compile(r'name="mmfa\.user\.device\.id"[^>]*value="([^"]+)"')
_RE_STATEID = re.compile(r'action="[^"]*StateId=([^"&]+)')
_RE_TXN_ID = re.compile(r'data-mmfa-transaction-id="([^"]+)"')


def _require(name: str) -> str:
    """Fail-loud fetch of an identity-bearing env var (no defaults allowed)."""
    val = os.environ.get(name)
    if not val:
        raise RuntimeError(f"{name} is required but not set")
    return val


def _runtime_ssl_context() -> ssl.SSLContext:
    """Pinned-CA TLS context: validate the captured runtime cert, skip hostname
    match (cert CN=isam, no SAN, != iviaruntime DNS). Cert-pinning, never off."""
    ctx = ssl.create_default_context(cafile=IVIA_RUNTIME_CA_BUNDLE)
    ctx.check_hostname = False  # chain is still verified against the pinned cert
    return ctx


def fire_push(username: str) -> str:
    """Fire an MMFA push to `username`'s IBM Verify device; return the txn id.

    `username` is the authenticated session sub passed by the caller — never a
    default. Raises RuntimeError if the push cannot be fired (no device,
    unexpected page) so the refund flow fails loud rather than silently.
    """
    if not username:
        raise RuntimeError("fire_push requires an authenticated username")

    ctx = _runtime_ssl_context()
    with httpx.Client(verify=ctx, timeout=30.0, follow_redirects=True) as client:
        r1 = client.get(f"{IVIA_RUNTIME_URL}{MMFA_POLICY}", params={"username": username})
        if r1.status_code != 200:
            raise RuntimeError(f"MMFA initiate GET failed: HTTP {r1.status_code}")
        dev_m = _RE_DEVICE.search(r1.text)
        sid_m = _RE_STATEID.search(r1.text)
        if not dev_m or not sid_m:
            raise RuntimeError(
                f"MMFA device-select page missing device/StateId for user={username} "
                "(no registered IBM Verify device?)"
            )
        device_id = dev_m.group(1)
        state_id = sid_m.group(1)

        r2 = client.post(
            f"{IVIA_RUNTIME_URL}{MMFA_POLICY}",
            params={"StateId": state_id, "operation": "verify"},
            data={"mmfa.user.device.id": device_id, "Submit": "Submit"},
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        if r2.status_code != 200:
            raise RuntimeError(f"MMFA fire POST failed: HTTP {r2.status_code}")
        txn_m = _RE_TXN_ID.search(r2.text)
        if not txn_m:
            raise RuntimeError("MMFA fire page missing data-mmfa-transaction-id (push not created)")
        transaction_id = txn_m.group(1)

    logger.info(
        "mmfa_push_fired",
        extra={"username": username, "device_id": device_id, "transaction_id": transaction_id},
    )
    return transaction_id


def read_txn_status(username: str, transaction_id: str) -> str:
    """Return approved|denied|pending for the EXACT fired MMFA transaction.

    Admin SCIM read of the user's MMFA Transaction attribute. Matches on the
    lowercase `transactionId` of the fired push; maps `txnStatus`
    SUCCESS->approved, FAIL->denied. Anything else (still pending, not found
    yet) -> pending. Never matches "any SUCCESS for the user".
    """
    if not username or not transaction_id:
        return "pending"

    ctx = _runtime_ssl_context()
    attrs = f"{_MMFA_TXN_SCHEMA}:transactionsResolved,{_MMFA_TXN_SCHEMA}:transactionsPending"
    params = {"filter": f'userName eq "{username}"', "attributes": attrs}
    with httpx.Client(verify=ctx, timeout=15.0) as client:
        resp = client.get(
            f"{IVIA_RUNTIME_URL}{SCIM_USERS}",
            params=params,
            auth=(_require("IVIA_SCIM_USER"), _require("IVIA_SCIM_PASSWORD")),
            headers={"Accept": "application/scim+json"},
        )
    if resp.status_code != 200:
        logger.warning("mmfa_scim_read_http_%s user=%s", resp.status_code, username)
        return "pending"

    try:
        data = resp.json()
        resources = data.get("Resources") or []
        if not resources:
            return "pending"
        txn = resources[0].get(_MMFA_TXN_SCHEMA) or {}
        resolved = txn.get("transactionsResolved") or []
        pending = txn.get("transactionsPending") or []
    except Exception as exc:  # noqa: BLE001 — malformed SCIM => treat as pending
        logger.warning("mmfa_scim_parse_error user=%s err=%s", username, exc)
        return "pending"

    for entry in resolved:
        if entry.get("transactionId") == transaction_id:
            status = (entry.get("txnStatus") or "").upper()
            if status == "SUCCESS":
                return "approved"
            if status == "FAIL":
                return "denied"
            return "pending"
    for entry in pending:
        if entry.get("transactionId") == transaction_id:
            return "pending"
    return "pending"
