"""ciba_store.py — in-process CIBA state for UC3 mobile-push approval.

Single-process, single-replica — plain dicts under one lock are sufficient.

Two stores:
  _txns    — the live mobile-push flow. initiate_refund fires the MMFA push and
             records auth_req_id -> {username, txn_id, bearer, terms}. The IVIA
             checkstatus rule (via /api/ciba/status) reads it back to learn WHICH
             user + WHICH fired transaction to check in SCIM, and first-seen-pins
             the CIBA bearer to authenticate the poll (defense-in-depth on top of
             the SCIM transaction-truth gate).

             `terms` is the APPROVED refund — request_id, account_id,
             transaction_id, amount, currency — recorded at the moment the push is
             fired, i.e. the terms the human is being asked to approve.
             complete_refund reads the amount from here rather than from its own
             tool arguments, so a non-deterministic model cannot substitute a
             different value after the human has approved (issue #31).

             This is deliberately in-process rather than a database row: the agent
             holds NO standing write credential — the refund-writer credential is
             issued by Vault only AFTER the approval — so there is nothing to
             write a pending-approval row with at initiate time. The durable half
             of the guarantee is the unique constraint on
             banking.refunds.request_id, which stops one approval being redeemed
             twice regardless of what this store remembers.
  _pending — legacy browser-consent path. The old notifyuser rule POSTed a
             server-generated consent_url to /api/ciba/pending; kept for
             back-compat so nothing 500s if an old rule build is still live.
"""

import threading
import time

_lock = threading.Lock()
_pending: dict[str, dict] = {}
_txns: dict[str, dict] = {}
_TTL_SECONDS = 900  # CIBA auth_req lifetime


def put(auth_req_id: str, consent_url: str) -> None:
    """Legacy: store a consent URL pushed by the old notifyuser rule."""
    with _lock:
        _pending[auth_req_id] = {"consent_url": consent_url, "ts": time.time()}
        _gc_locked()


def get(auth_req_id: str) -> str | None:
    """Legacy: return the consent URL for an auth_req_id, or None."""
    with _lock:
        entry = _pending.get(auth_req_id)
        return entry["consent_url"] if entry else None


def put_txn(auth_req_id: str, username: str, txn_id: str, terms: dict) -> None:
    """Record the MMFA push uc3-agent fired for a CIBA auth_req_id.

    `terms` is the refund the human is being asked to approve. It is stored
    verbatim and read back by complete_refund; nothing downstream may widen it.
    """
    with _lock:
        _txns[auth_req_id] = {
            "username": username,
            "txn_id": txn_id,
            "bearer": None,
            "terms": dict(terms),
            "ts": time.time(),
        }
        _gc_locked()


def get_terms(auth_req_id: str) -> dict | None:
    """Return a COPY of the approved refund terms for an auth_req_id, or None.

    None means this process has no record of the approval — complete_refund must
    fail closed rather than fall back to caller-supplied values.
    """
    with _lock:
        entry = _txns.get(auth_req_id)
        if entry is None:
            return None
        terms = entry.get("terms")
        return dict(terms) if terms else None


def get_txn(auth_req_id: str) -> dict | None:
    """Return a COPY of the {username, txn_id, bearer, terms} mapping, or None."""
    with _lock:
        entry = _txns.get(auth_req_id)
        return dict(entry) if entry else None


def match_or_set_bearer(auth_req_id: str, bearer: str | None) -> bool:
    """First-seen-pin the checkstatus bearer for an auth_req_id.

    Returns True if the poll is authenticated: the auth_req_id is known AND
    (no bearer pinned yet -> pin this one) OR (presented bearer == pinned).
    Returns False on unknown auth_req_id or bearer mismatch. Defense-in-depth;
    the real gate is the SCIM transaction-truth in mmfa.read_txn_status.
    """
    with _lock:
        entry = _txns.get(auth_req_id)
        if entry is None:
            return False
        pinned = entry.get("bearer")
        if pinned is None:
            entry["bearer"] = bearer
            return True
        return pinned == bearer


def _gc_locked() -> None:
    cutoff = time.time() - _TTL_SECONDS
    for k in [k for k, v in _pending.items() if v["ts"] < cutoff]:
        _pending.pop(k, None)
    for k in [k for k, v in _txns.items() if v["ts"] < cutoff]:
        _txns.pop(k, None)
