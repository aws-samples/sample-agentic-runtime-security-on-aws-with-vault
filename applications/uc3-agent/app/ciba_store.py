"""ciba_store.py — in-process store for CIBA consent URLs pushed by notifyuser.

The IVIA `notifyuser` mapping rule fires during bc-authorize and POSTs the
server-generated consent URL (which embeds an internal transactionID a workshop
user cannot otherwise discover) to /api/ciba/pending on this service. The agent's
initiate_refund tool then reads it back by auth_req_id to hand the user an Approve
link. Single-process, single-replica — a dict with a lock is sufficient.
"""

import threading
import time

_lock = threading.Lock()
_pending: dict[str, dict] = {}
_TTL_SECONDS = 900  # CIBA auth_req lifetime


def put(auth_req_id: str, consent_url: str) -> None:
    """Store the consent URL pushed by notifyuser, keyed by auth_req_id."""
    with _lock:
        _pending[auth_req_id] = {"consent_url": consent_url, "ts": time.time()}
        _gc_locked()


def get(auth_req_id: str) -> str | None:
    """Return the consent URL for an auth_req_id, or None if not yet pushed."""
    with _lock:
        entry = _pending.get(auth_req_id)
        return entry["consent_url"] if entry else None


def _gc_locked() -> None:
    cutoff = time.time() - _TTL_SECONDS
    for k in [k for k, v in _pending.items() if v["ts"] < cutoff]:
        _pending.pop(k, None)
