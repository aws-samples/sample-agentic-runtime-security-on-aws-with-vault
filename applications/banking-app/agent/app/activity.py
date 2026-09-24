"""activity.py — what the UC2 banking agent reports about each step, as it happens.

Every /chat turn gets one TurnActivity: a per-turn event queue plus the facts
the turn has observed (the credential leases the MCP server reported, and the
decoded claims of the caller's token). main.py drains the queue into the SSE
stream while the agent runs, so the browser sees each step before the answer.

Events follow the UI's contract, applications/banking-app/ui/src/lib/agent-events.ts:
agent:thinking, agent:narration, tool_call, agent:audit_seed, agent:text_delta,
agent:error and agent:done. None of them carries a `content` field, so today's
dashboard (which makes a chat bubble from any frame with `content`) ignores them.

Threading
---------
The agent runs inside asyncio.to_thread, and Strands runs it on yet another
thread with its own event loop (strands/_async.py run_async). Hooks and tools
therefore fire on worker threads. They find this turn's TurnActivity through the
_TURN_ACTIVITY ContextVar — set before the worker starts and copied into it by
to_thread and run_async — and push onto the SERVER loop captured at request
start, via loop.call_soon_threadsafe. The queue is unbounded, so a client that
disconnects never blocks the worker; the worker always finishes.

Credentials
-----------
The workshop shows every credential issued during a turn IN FULL (Bear,
2026-09-24): the caller's access token as the MCP server presents it to Vault,
and the database credential Vault issues for each tool call. Those go out ONLY
as `agent:credential` events, built field by field in TurnActivity.credential()
and sent only on this per-request queue — never in a tool's return value (which
reaches the model) and never in a log line.

The agent's OWN credentials are shown the same way (report_model_credentials):
the Kubernetes service-account JWT and Vault token of its login, and the
Bedrock keys Vault issued under that login, which sign the turn's model calls.
So is the MCP server's own Vault token, which it revokes each lease with
(report_mcp_vault_token), and the Kubernetes service-account token its Vault
login presented (report_mcp_service_account_token). Unlike the caller's token
and database credential,
these are standing: every turn that runs while they are current shows the
same values.

Every OTHER event is scrubbed with the UI filter's rules before it is queued:
keys named like a secret are removed, and JWTs and Vault tokens in any string are
replaced. So narration, tool calls and the audit seed never carry a credential;
the one place a credential appears is the event whose job is to show it.
"""

from __future__ import annotations

import asyncio
import base64
import contextvars
import hashlib
import json
import logging
import re
import threading
import time
from datetime import datetime
from typing import Any, AsyncIterator
from urllib.parse import urlsplit

from strands.hooks import (
    AfterToolCallEvent,
    BeforeModelCallEvent,
    BeforeToolCallEvent,
    HookProvider,
    HookRegistry,
)

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Scrubbing — the same rules as the UI's activity-filter.ts
# ---------------------------------------------------------------------------

REDACTED_TOKEN = "[token redacted]"

# A key is secret-named when, lowercased with non-alphanumerics removed, it
# CONTAINS one of these, or equals one of the credential header names.
_SECRET_KEY_SUBSTRINGS = ("password", "passwd", "passphrase", "secret", "token", "privatekey", "apikey")
_SECRET_KEY_NAMES = frozenset({"authorization", "proxyauthorization", "cookie", "setcookie"})

# Correlation keys the audit story depends on: always kept, values still scrubbed.
_CORRELATION_KEYS = frozenset(
    {
        "lease_id",
        "lease_duration_seconds",
        "ttl_seconds",
        "vault_path",
        "vault_role",
        "db_role",
        "user_sub",
        "sub",
        "scope",
        "jti",
        "request_id",
        "iss",
        "aud",
        "exp",
        "act",
    }
)

# Runs of the characters a compact JWT is made of. Tokens are found run by run
# rather than with one backtracking regex over the whole string.
_TOKEN_CHAR_RUN = re.compile(r"[A-Za-z0-9_.-]+")
# Vault tokens (1.10+): hvs. service, hvb. batch, hvr. recovery.
_VAULT_TOKEN = re.compile(r"hv[sbr]\.[A-Za-z0-9_-]{24,}")


def _is_secret_key(key: str) -> bool:
    normalized = re.sub(r"[^a-z0-9]", "", key.lower())
    if normalized in _SECRET_KEY_NAMES:
        return True
    return any(term in normalized for term in _SECRET_KEY_SUBSTRINGS)


def _redact_run(match: re.Match[str]) -> str:
    run = match.group(0)
    start = run.find("eyJ")
    # A JWT starts at "eyJ" and has at least two more dot-separated parts.
    if start != -1 and run[start:].count(".") >= 2:
        run = run[:start] + REDACTED_TOKEN
    if "hv" in run:
        run = _VAULT_TOKEN.sub(REDACTED_TOKEN, run)
    return run


def scrub_text(value: str) -> str:
    """Replace every JWT and Vault token in `value` with REDACTED_TOKEN."""
    if "eyJ" not in value and "hv" not in value:
        return value
    return _TOKEN_CHAR_RUN.sub(_redact_run, value)


def scrub(value: Any) -> Any:
    """Return a copy of `value` with secret-named keys removed and tokens redacted."""
    if isinstance(value, str):
        return scrub_text(value)
    if isinstance(value, dict):
        out = {}
        for key, item in value.items():
            key = str(key)
            if key not in _CORRELATION_KEYS and (_is_secret_key(key) or scrub_text(key) != key):
                continue
            out[key] = scrub(item)
        return out
    if isinstance(value, (list, tuple)):
        return [scrub(item) for item in value]
    if value is None or isinstance(value, (bool, int, float)):
        return value
    return scrub_text(str(value))


def decode_payload(jwt: str) -> dict[str, Any]:
    """The whole decoded payload of a JWT, for display only.

    The signature is NOT verified here: Vault verifies the token when the MCP
    server presents it. What this returns labels the turn; it authorizes nothing.
    """
    try:
        payload = jwt.split(".")[1]
        data = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
    except (IndexError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


# The claims agent:audit_seed carries, as the UI contract lists them
# (ui/src/lib/agent-events.ts, AgentAuditSeedEvent.claims). jti is how Vault
# names the caller's token (lookup-self display_name "JWT Token with JTI: <jti>"),
# and act.sub is the agent Vault resolves the request's ceiling from.
_AUDIT_CLAIMS = ("sub", "scope", "jti", "iss", "aud", "exp", "act")


def decode_claims(jwt: str) -> dict[str, Any]:
    """The non-secret claims of the caller's token that label the turn (unverified)."""
    data = decode_payload(jwt)
    return {key: data[key] for key in _AUDIT_CLAIMS if key in data}


# ---------------------------------------------------------------------------
# The per-turn event queue
# ---------------------------------------------------------------------------

_END = object()  # sentinel: the agent worker has finished


class TurnActivity:
    """One chat turn's event queue and the facts it has observed so far."""

    def __init__(self, loop: asyncio.AbstractEventLoop, request_id: str, claims: dict[str, Any]):
        self._loop = loop
        self._queue: asyncio.Queue[Any] = asyncio.Queue()  # unbounded: the worker never blocks
        self._lock = threading.Lock()
        self._model_calls = 0
        # Digests of the credentials already shown this turn (first_showing).
        self._shown: set[str] = set()
        self._tool_started_at: dict[str, float] = {}
        # Epoch seconds: a credential issued at or after this was issued during the turn.
        self.started_at = time.time()
        self.request_id = request_id
        self.claims = claims
        self.db_role: str | None = None
        self.leases: list[dict[str, Any]] = []

    def build(self, event: dict[str, Any]) -> dict[str, Any]:
        """Stamp an event with this turn's requestId and the time, then scrub it."""
        return scrub({**event, "requestId": self.request_id, "ts": int(time.time() * 1000)})

    def emit(self, event: dict[str, Any]) -> None:
        """Queue an event for the SSE stream. Safe to call from any thread."""
        self._push(self.build(event))

    def narrate(self, text: str, glyph: str = "▶", accent: str | None = None) -> None:
        event: dict[str, Any] = {"type": "agent:narration", "glyph": glyph, "text": text}
        if accent:
            event["accent"] = accent
        self.emit(event)

    def credential(
        self,
        *,
        kind: str,
        label: str,
        issuer: str,
        value: str | None = None,
        fields: dict[str, str] | None = None,
        claims: dict[str, Any] | None = None,
        vault_path: str | None = None,
        lease_id: str | None = None,
        ttl_seconds: int | float | None = None,
        expires_at: int | None = None,
    ) -> None:
        """Queue an agent:credential event carrying a credential IN FULL.

        Built from these named fields only, and deliberately NOT scrubbed: showing
        the credential is the event's purpose. Only credentials issued during the
        turn come through here — never a client secret or other configuration.
        """
        event: dict[str, Any] = {"type": "agent:credential", "kind": kind, "label": label, "issuer": issuer}
        if value is not None:
            event["value"] = value
        elif fields is not None:
            event["fields"] = dict(fields)
        optional = {
            "claims": claims,
            "vaultPath": vault_path,
            "leaseId": lease_id,
            "ttlSeconds": ttl_seconds,
            "expiresAt": expires_at,
        }
        event.update({key: item for key, item in optional.items() if item is not None})
        event["requestId"] = self.request_id
        event["ts"] = int(time.time() * 1000)
        self._push(event)

    def first_showing(self, kind: str, value: str) -> bool:
        """True the first time this credential is shown in this turn, False after.

        Only a digest is kept, so the turn holds no second copy of the value.
        """
        digest = hashlib.sha256(f"{kind}\0{value}".encode()).hexdigest()
        with self._lock:
            if digest in self._shown:
                return False
            self._shown.add(digest)
            return True

    def close(self) -> None:
        """Mark the agent worker finished. Called from the worker's finally."""
        self._push(_END)

    def _push(self, item: Any) -> None:
        try:
            self._loop.call_soon_threadsafe(self._queue.put_nowait, item)
        except RuntimeError:
            # The server loop is closed (shutdown). Nobody is left to read it.
            logger.debug("turn_activity_event_dropped request_id=%s", self.request_id)

    async def events(self) -> AsyncIterator[dict[str, Any]]:
        """Yield queued events, in order, until the agent worker finishes."""
        while True:
            item = await self._queue.get()
            if item is _END:
                return
            yield item

    def next_model_call(self) -> int:
        with self._lock:
            self._model_calls += 1
            return self._model_calls

    def tool_started(self, tool_call_id: str) -> None:
        with self._lock:
            self._tool_started_at[tool_call_id] = time.monotonic()

    def tool_elapsed_ms(self, tool_call_id: str) -> int | None:
        with self._lock:
            started = self._tool_started_at.pop(tool_call_id, None)
        return None if started is None else round((time.monotonic() - started) * 1000)

    def record_lease(self, db_role: Any, lease_id: Any, ttl_seconds: Any, vault_path: Any = None) -> None:
        with self._lock:
            if self.db_role is None and isinstance(db_role, str):
                self.db_role = db_role
            if isinstance(lease_id, str) and lease_id and lease_id != "unknown":
                lease: dict[str, Any] = {"lease_id": lease_id}
                if isinstance(vault_path, str) and vault_path:
                    lease["vault_path"] = vault_path
                if isinstance(ttl_seconds, (int, float)):
                    lease["ttl_seconds"] = ttl_seconds
                self.leases.append(lease)

    def audit_seed(self) -> dict[str, Any]:
        """The agent:audit_seed event for everything this turn has observed."""
        with self._lock:
            # No vaultRole: the caller's access token reaches Vault directly as
            # X-Vault-Token, so no Vault auth role is involved (see
            # _CREDENTIAL_METADATA_KEYS for why the MCP server's label is not used).
            event: dict[str, Any] = {"type": "agent:audit_seed", "leases": list(self.leases)}
            if self.db_role:
                event["dbRole"] = self.db_role
        if self.claims:
            event["claims"] = self.claims
        return self.build(event)


_TURN_ACTIVITY: contextvars.ContextVar[TurnActivity | None] = contextvars.ContextVar(
    "uc2_turn_activity", default=None
)


def bind(turn: TurnActivity) -> contextvars.Token[TurnActivity | None]:
    return _TURN_ACTIVITY.set(turn)


def unbind(token: contextvars.Token[TurnActivity | None]) -> None:
    _TURN_ACTIVITY.reset(token)


def current() -> TurnActivity | None:
    return _TURN_ACTIVITY.get()


# ---------------------------------------------------------------------------
# What the tools report about the MCP call
# ---------------------------------------------------------------------------

# The credential_metadata keys the MCP server returns (mcp-server/src/tools.ts).
# Narration text is built from THESE keys only, never by dumping the dict, because
# free text is not key-scrubbed by the UI filter.
#
# vault_role is deliberately NOT read. The MCP server labels every credential
# "uc2-jwt", a JWT auth role that was retired with the native cutover
# (infrastructure/modules/vault_config/main.tf); the caller's access token is
# presented to Vault directly as X-Vault-Token and no Vault role is involved.
# Repeating the label would tell the attendee something false.
_CREDENTIAL_METADATA_KEYS = (
    "vault_authenticated",
    "vault_auth_header",
    "db_role",
    "vault_path",
    "lease_id",
    "lease_duration_seconds",
    "lease_expires_at",
    "lease_revoked",
    "user_sub",
    "vault_policies",
    "vault_identity_policies",
)


def _utc_text(epoch_seconds: float) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch_seconds))


def _iso_epoch(value: Any) -> float | None:
    """Epoch seconds for an ISO 8601 timestamp the MCP server reported, or None."""
    if not isinstance(value, str) or not value:
        return None
    try:
        return datetime.fromisoformat(value).timestamp()
    except ValueError:
        return None


def _policy_names(value: Any) -> str | None:
    """A reported policy list as text, or None when it was not reported."""
    if not isinstance(value, list):
        return None
    names = [name for name in value if isinstance(name, str)]
    return ", ".join(names) if names else "none"


def report_mcp_call(tool_name: str, mcp_url: str, jwt: str) -> None:
    """Narrate the MCP call a tool is about to make, and show the token it presents.

    The MCP server presents exactly the token it receives on the Authorization
    header to Vault as X-Vault-Token (mcp-server/src/index.ts, vault-client.ts),
    so `jwt` here is the credential Vault sees. It is shown once per turn.
    """
    turn = current()
    if turn is None:
        return
    # The sub is what the token CLAIMS, unverified here; Vault verifies the token.
    sub = turn.claims.get("sub")
    whose = f" (sub {sub})" if isinstance(sub, str) and sub else ""
    host = urlsplit(mcp_url).netloc or mcp_url
    turn.narrate(
        f"Calling {tool_name} on the MCP server ({host}), presenting the caller's access token{whose} "
        "on the Authorization header."
    )
    if jwt and turn.first_showing("access_token", jwt):
        claims = decode_payload(jwt)
        exp = claims.get("exp")
        turn.credential(
            kind="access_token",
            label=f"The caller's access token{whose}, which the MCP server presents to Vault as X-Vault-Token",
            issuer="IBM Verify Identity Access",
            value=jwt,
            claims=claims or None,
            expires_at=int(exp * 1000) if isinstance(exp, (int, float)) else None,
        )


def report_credential_metadata(tool_name: str, meta: Any, issued: Any = None) -> None:
    """Narrate — and show — the credential the MCP server says Vault issued for this call.

    `meta` is the MCP server's credential_metadata; `issued` is its
    issued_db_credentials ({username, password}), which the tool has already
    taken out of the response so the model never sees it. An MCP server older
    than lease_revoked / issued_db_credentials still works: the credential is
    then not shown and the revoke is narrated as not observed. Likewise the
    auth-path and policy lines appear only when the server reports
    vault_auth_header and vault_policies / vault_identity_policies. When the
    revoke failed, the credential is still shown, labelled as still live until
    lease_expires_at (or, from a server that does not report it, until its
    lease duration runs out).
    """
    turn = current()
    if turn is None or not isinstance(meta, dict) or not meta:
        return
    reported = {key: meta[key] for key in _CREDENTIAL_METADATA_KEYS if key in meta}
    if not reported:
        return
    db_role = reported.get("db_role")
    vault_path = reported.get("vault_path")
    lease_id = reported.get("lease_id")
    ttl = reported.get("lease_duration_seconds")
    revoked = reported.get("lease_revoked")
    # When the lease ends unless revoked: the MCP server's receipt time plus the
    # lease duration Vault returned (tools.ts, lease_expires_at).
    lease_ends = _iso_epoch(reported.get("lease_expires_at"))
    if lease_ends is not None:
        still_live = f"still live until {_utc_text(lease_ends)}"
    elif isinstance(ttl, (int, float)):
        still_live = f"still live until its lease ends, {ttl}s after it was issued"
    else:
        still_live = "still live until its lease ends"
    turn.record_lease(db_role, lease_id, ttl, vault_path)

    # Tools can run concurrently, so every line names the tool it belongs to.
    turn.narrate(
        f'Tool "{tool_name}" response credential_metadata: {json.dumps(reported)}',
        glyph="⚡",
        accent="tool_output",
    )

    # Only the credential READ uses the caller's token; the MCP server revokes with
    # its own Kubernetes-auth identity, so "no Vault login" is scoped to the read.
    if reported.get("vault_auth_header") == "X-Vault-Token":
        where = f" {vault_path}" if isinstance(vault_path, str) and vault_path else ""
        turn.narrate(
            f"The MCP server reports it read{where} for {tool_name} by presenting the caller's access token "
            "to Vault as X-Vault-Token — no Vault login for the credential read."
        )

    # "lease duration", not "valid for": the MCP server has already tried to
    # revoke the lease by the time it returns, so nothing may imply it is live.
    parts = []
    if db_role:
        parts.append(f"database role {db_role}")
    if isinstance(ttl, (int, float)):
        parts.append(f"lease duration {ttl}s")
    if lease_id:
        parts.append(f"lease {lease_id}")
    shown = (
        isinstance(issued, dict)
        and isinstance(issued.get("username"), str)
        and isinstance(issued.get("password"), str)
    )
    if parts:
        tail = (
            " It handed the credential back for display only; the model never sees it."
            if shown
            else " The agent never receives the credential."
        )
        turn.narrate(
            f"The MCP server reports Vault issued it a database credential for {tool_name} — "
            + ", ".join(parts)
            + "."
            + tail
        )

    if shown:
        if revoked is True:
            state = "revoked before the MCP server replied"
        elif revoked is False:
            # Bear, 2026-09-24: show it anyway, and say plainly that it still works.
            state = f"revoke FAILED — this credential is {still_live}"
        else:
            state = "revoke not observed in this flow"
        turn.credential(
            kind="db_credentials",
            label=f"Database credential Vault issued for {tool_name}"
            + (f" (role {db_role})" if db_role else "")
            + f", {state}",
            issuer="Vault",
            fields={"username": issued["username"], "password": issued["password"]},
            vault_path=vault_path if isinstance(vault_path, str) else None,
            lease_id=lease_id if isinstance(lease_id, str) else None,
            ttl_seconds=ttl if isinstance(ttl, (int, float)) else None,
            # An expiry only for a credential that may still work; a revoked one has none.
            expires_at=int(lease_ends * 1000) if revoked is False and lease_ends is not None else None,
        )

    if lease_id and lease_id != "unknown":
        if revoked is True:
            turn.narrate(f"The MCP server reports Vault revoked the {tool_name} lease {lease_id} before it replied.")
        elif revoked is False:
            turn.narrate(
                f"The MCP server reports its revoke of the {tool_name} lease {lease_id} FAILED — "
                f"the credential is {still_live}."
            )
        else:
            turn.narrate(
                f"Credential revoked: not observed in this flow. The MCP server revokes the {tool_name} lease "
                f"{lease_id} itself and does not report the outcome to the agent."
            )

    # Exactly as Vault labels them on the caller's token (auth/token/lookup-self).
    # Not called "what the agent may do": Vault also bounds the request by the
    # agent's ceiling, which lookup-self does not list.
    token_policies = _policy_names(reported.get("vault_policies"))
    identity_policies = _policy_names(reported.get("vault_identity_policies"))
    if token_policies is not None or identity_policies is not None:
        listed = []
        if token_policies is not None:
            listed.append(f"token policies {token_policies}")
        if identity_policies is not None:
            listed.append(f"identity policies {identity_policies}")
        turn.narrate(
            f"The MCP server reports Vault's lookup-self for the caller's token during {tool_name} lists "
            + "; ".join(listed)
            + "."
        )


# ---------------------------------------------------------------------------
# The agent's own credentials behind the turn's model calls
# ---------------------------------------------------------------------------


def _at(epoch_seconds: Any) -> str:
    """'at <UTC time>' for an epoch-seconds value, or 'earlier' when there is none."""
    if not isinstance(epoch_seconds, (int, float)):
        return "earlier"
    return "at " + _utc_text(epoch_seconds)


def _expires_ms(start: Any, ttl: Any) -> int | None:
    if isinstance(start, (int, float)) and isinstance(ttl, (int, float)):
        return int((start + ttl) * 1000)
    return None


def report_model_credentials(issued: Any) -> None:
    """Show, in full, the agent's own credentials behind this turn's model calls.

    AgentVaultClient calls this each time a set of Bedrock keys signs a request
    (vault_client._ReportingCredentials). The first time a set signs a request
    in this turn, the turn is shown the login those keys were issued under — the
    Kubernetes service-account JWT it presented and the Vault token it got back
    — and then the keys. Labels say whether each was issued during this turn or
    earlier and reused. These are the agent's standing credentials, so every turn
    that runs while they are current shows the same values. Outside a turn
    (startup, /health) nothing is sent.
    """
    turn = current()
    if turn is None or not isinstance(issued, dict):
        return
    key_id = issued.get("access_key_id")
    if not isinstance(key_id, str) or not key_id or not turn.first_showing("aws_sts_credentials", key_id):
        return

    login = issued.get("login") if isinstance(issued.get("login"), dict) else {}
    account = login.get("service_account_name") or "my service account"
    role = login.get("role") or "unknown"
    login_at = login.get("issued_at")
    login_this_turn = isinstance(login_at, (int, float)) and login_at >= turn.started_at
    issued_at = issued.get("issued_at")
    keys_this_turn = isinstance(issued_at, (int, float)) and issued_at >= turn.started_at
    ttl = issued.get("ttl_seconds")
    vault_path = issued.get("vault_path")
    lease_id = issued.get("lease_id")

    details = ", ".join(
        str(part)
        for part in (
            vault_path,
            f"lease {lease_id}" if lease_id else None,
            f"{ttl}s" if isinstance(ttl, (int, float)) else None,
        )
        if part
    )
    when = "during this turn" if keys_this_turn else _at(issued_at)
    turn.narrate(
        f"My model calls to Bedrock are signed with short-lived AWS keys Vault issued me {when} ({details}), "
        f"under my own Kubernetes login (role {role}) — not the caller's token."
    )

    sa_jwt = login.get("sa_jwt")
    if isinstance(sa_jwt, str) and sa_jwt and turn.first_showing("k8s_sa_token", sa_jwt):
        claims = decode_payload(sa_jwt)
        exp = claims.get("exp")
        turn.credential(
            kind="k8s_sa_token",
            label=(
                f"My Kubernetes service-account token ({account}), presented to Vault to sign in during this turn"
                if login_this_turn
                else f"The Kubernetes service-account token ({account}) I presented to Vault to sign in {_at(login_at)}"
            ),
            issuer="Kubernetes",
            value=sa_jwt,
            claims=claims or None,
            expires_at=int(exp * 1000) if isinstance(exp, (int, float)) else None,
        )

    vault_token = login.get("vault_token")
    if isinstance(vault_token, str) and vault_token and turn.first_showing("vault_token", vault_token):
        token_ttl = login.get("ttl_seconds")
        turn.credential(
            kind="vault_token",
            label=(
                f"My Vault token from this turn's Kubernetes login (role {role})"
                if login_this_turn
                else f"My Vault token from my Kubernetes login {_at(login_at)} (role {role})"
            ),
            issuer="Vault",
            value=vault_token,
            ttl_seconds=token_ttl if isinstance(token_ttl, (int, float)) else None,
            expires_at=_expires_ms(login_at, token_ttl),
        )

    access = issued.get("secret_access_key"), issued.get("session_token")
    if all(isinstance(part, str) and part for part in access):
        turn.credential(
            kind="aws_sts_credentials",
            label=(
                "Short-lived AWS keys Vault issued me for calling Bedrock during this turn — "
                "they sign this turn's model calls"
                if keys_this_turn
                else f"Short-lived AWS keys Vault issued me for calling Bedrock {_at(issued_at)} — "
                "reused to sign this turn's model calls"
            ),
            issuer="AWS STS (via Vault)",
            fields={
                "access_key_id": key_id,
                "secret_access_key": access[0],
                "session_token": access[1],
            },
            vault_path=vault_path if isinstance(vault_path, str) else None,
            lease_id=lease_id if isinstance(lease_id, str) else None,
            ttl_seconds=ttl if isinstance(ttl, (int, float)) else None,
            expires_at=_expires_ms(issued_at, ttl),
        )


# ---------------------------------------------------------------------------
# The MCP server's own credentials: its Kubernetes login and its Vault token
# ---------------------------------------------------------------------------


def report_mcp_service_account_token(tool_name: str, sa_token: Any) -> None:
    """Show, in full, the Kubernetes service-account token the MCP server signed in to Vault with.

    `sa_token` is the MCP server's mcp_service_account_token (tools.ts), which the
    tool has already taken out of the response so the model never sees it. It is
    the server's projected ServiceAccount token, presented to auth/kubernetes/login
    for the Vault token that revokes the lease (report_mcp_vault_token). It is
    standing, like that token, so each distinct value is shown once per turn. An
    MCP server that does not report it, or whose login failed, leaves this silent.
    """
    turn = current()
    if turn is None or not isinstance(sa_token, dict):
        return
    jwt = sa_token.get("jwt")
    if not isinstance(jwt, str) or not jwt or not turn.first_showing("mcp_k8s_sa_token", jwt):
        return
    account = sa_token.get("service_account") or "its service account"
    role = sa_token.get("role") or "unknown"
    when = (
        f"during this {tool_name} call"
        if sa_token.get("logged_in_for_this_call") is True
        else "for the Vault token it is still reusing"
    )
    claims = decode_payload(jwt)
    exp = claims.get("exp")
    turn.credential(
        kind="k8s_sa_token",
        label=f"The MCP server's own Kubernetes service-account token ({account}), "
        f"presented to Vault to sign in (role {role}) {when}",
        issuer="Kubernetes",
        value=jwt,
        claims=claims or None,
        expires_at=int(exp * 1000) if isinstance(exp, (int, float)) else None,
    )


def report_mcp_vault_token(tool_name: str, login: Any) -> None:
    """Show, in full, the MCP server's own Vault token that revoked this call's lease.

    `login` is the MCP server's mcp_vault_token (tools.ts), which the tool has
    already taken out of the response so the model never sees it. The token is
    the server's, from its Kubernetes login (role uc2) — not the caller's. It is
    standing: the server reuses it across calls and callers until it nears
    expiry, so each distinct token is shown once per turn. An MCP server that
    does not report it leaves this silent.
    """
    turn = current()
    if turn is None or not isinstance(login, dict):
        return
    token = login.get("token")
    if not isinstance(token, str) or not token or not turn.first_showing("mcp_vault_token", token):
        return
    role = login.get("role") or "unknown"
    policies = _policy_names(login.get("policies")) or "not reported"
    ttl = login.get("ttl_seconds")
    issued_at = _iso_epoch(login.get("issued_at"))
    fresh = login.get("logged_in_for_this_call") is True
    when = f"made during this {tool_name} call" if fresh else f"made {_at(issued_at)} and reused"
    turn.narrate(
        f"The MCP server presented its own Vault token to revoke the {tool_name} lease — not the caller's token. "
        f"It comes from the server's Kubernetes login (role {role}, policies {policies}), {when}."
    )
    turn.credential(
        kind="vault_token",
        label=f"The MCP server's own Vault token (Kubernetes login, role {role}, policies {policies}, {when}), "
        f"presented to revoke the {tool_name} lease",
        issuer="Vault",
        value=token,
        ttl_seconds=ttl if isinstance(ttl, (int, float)) else None,
        expires_at=_expires_ms(issued_at, ttl),
    )


# ---------------------------------------------------------------------------
# Strands hooks: tool start / finish and model calls
# ---------------------------------------------------------------------------


def _tool_result_payload(result: Any) -> Any:
    """The tool's output as JSON, from the ToolResult Strands produced."""
    if not isinstance(result, dict):
        return None
    texts = [block["text"] for block in result.get("content", []) if isinstance(block, dict) and "text" in block]
    if len(texts) != 1:
        return texts or None
    try:
        return json.loads(texts[0])
    except ValueError:
        return texts[0]


class ActivityHooks(HookProvider):
    """Reports each tool call and each follow-up model call of the current turn.

    Holds no state of its own: every callback looks the turn up through the
    ContextVar when it fires, so one agent can never report into another turn.
    """

    def register_hooks(self, registry: HookRegistry, **kwargs: Any) -> None:
        registry.add_callback(BeforeModelCallEvent, self._before_model_call)
        registry.add_callback(BeforeToolCallEvent, self._before_tool_call)
        registry.add_callback(AfterToolCallEvent, self._after_tool_call)

    @staticmethod
    def _before_model_call(event: BeforeModelCallEvent) -> None:
        turn = current()
        if turn is None:
            return
        # main.py reports the first model call as the turn starts; every later
        # call is the model reading what the tools returned.
        if turn.next_model_call() > 1:
            turn.emit({"type": "agent:thinking", "text": "Reasoning over the tool results"})

    @staticmethod
    def _before_tool_call(event: BeforeToolCallEvent) -> None:
        turn = current()
        if turn is None:
            return
        tool_call_id = str(event.tool_use.get("toolUseId", ""))
        name = str(event.tool_use.get("name", ""))
        turn.tool_started(tool_call_id)
        turn.narrate(f"I need to call the tool — {name}")
        turn.emit(
            {
                "type": "tool_call",
                "toolCallId": tool_call_id,
                "name": name,
                "status": "in_progress",
                "args": event.tool_use.get("input", {}),
            }
        )

    @staticmethod
    def _after_tool_call(event: AfterToolCallEvent) -> None:
        turn = current()
        if turn is None:
            return
        tool_call_id = str(event.tool_use.get("toolUseId", ""))
        elapsed = turn.tool_elapsed_ms(tool_call_id)
        failed = (
            event.exception is not None
            or event.cancel_message is not None
            or (isinstance(event.result, dict) and event.result.get("status") == "error")
        )
        payload = _tool_result_payload(event.result)
        tool_event: dict[str, Any] = {
            "type": "tool_call",
            "toolCallId": tool_call_id,
            "name": str(event.tool_use.get("name", "")),
            "status": "error" if failed else "success",
        }
        if payload is not None:
            tool_event["result"] = {"error": payload} if failed else payload
        duration = getattr(event, "duration", None)
        if isinstance(duration, (int, float)):
            tool_event["durationMs"] = round(duration * 1000)
        elif elapsed is not None:
            tool_event["durationMs"] = elapsed
        turn.emit(tool_event)
