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

Secrets
-------
The UI's activity filter is the second line of defence, not the first. Every
event built here is scrubbed with the same rules before it is queued: keys named
like a secret are removed, and JWTs and Vault tokens in any string are replaced.
The caller's token appears only as its decoded non-secret claims.
"""

from __future__ import annotations

import asyncio
import base64
import contextvars
import json
import logging
import re
import threading
import time
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


def decode_claims(jwt: str) -> dict[str, Any]:
    """The non-secret claims of the caller's token, for display only.

    The signature is NOT verified here: Vault verifies the token when the MCP
    server presents it. These claims only label the turn; they authorize nothing.
    """
    try:
        payload = jwt.split(".")[1]
        data = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
    except (IndexError, ValueError):
        return {}
    if not isinstance(data, dict):
        return {}
    return {key: data[key] for key in ("sub", "scope", "iss", "aud", "exp") if key in data}


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
        self._tool_started_at: dict[str, float] = {}
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

    def record_lease(self, db_role: Any, lease_id: Any, ttl_seconds: Any) -> None:
        with self._lock:
            if self.db_role is None and isinstance(db_role, str):
                self.db_role = db_role
            if isinstance(lease_id, str) and lease_id and lease_id != "unknown":
                lease: dict[str, Any] = {"lease_id": lease_id}
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
    "db_role",
    "lease_id",
    "lease_duration_seconds",
    "user_sub",
)


def report_mcp_call(tool_name: str, mcp_url: str) -> None:
    """Narrate the MCP call a tool is about to make."""
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


def report_credential_metadata(tool_name: str, meta: Any) -> None:
    """Narrate the credential the MCP server says Vault issued for this call.

    Everything here is what the MCP server REPORTED in credential_metadata; the
    agent never sees Vault or the credential itself. The lease is revoked inside
    the MCP server, which does not report the outcome, so the revoke is narrated
    as not observed.
    """
    turn = current()
    if turn is None or not isinstance(meta, dict) or not meta:
        return
    reported = {key: meta[key] for key in _CREDENTIAL_METADATA_KEYS if key in meta}
    if not reported:
        return
    db_role = reported.get("db_role")
    lease_id = reported.get("lease_id")
    ttl = reported.get("lease_duration_seconds")
    turn.record_lease(db_role, lease_id, ttl)

    turn.narrate(
        f"Response credential_metadata: {json.dumps(reported)}",
        glyph="⚡",
        accent="tool_output",
    )

    # "lease duration", not "valid for": the MCP server has already revoked the
    # lease by the time it returns, so nothing here may imply it is still live.
    parts = []
    if db_role:
        parts.append(f"database role {db_role}")
    if isinstance(ttl, (int, float)):
        parts.append(f"lease duration {ttl}s")
    if lease_id:
        parts.append(f"lease {lease_id}")
    if parts:
        turn.narrate(
            f"The MCP server reports Vault issued it a database credential for {tool_name} — "
            + ", ".join(parts)
            + ". The agent never receives the credential."
        )
    if lease_id and lease_id != "unknown":
        turn.narrate(
            f"Credential revoked: not observed in this flow. The MCP server revokes lease {lease_id} itself "
            "and does not report the outcome to the agent."
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
