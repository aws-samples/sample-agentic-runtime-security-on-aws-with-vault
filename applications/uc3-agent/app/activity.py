"""activity.py — the per-request activity stream of the UC3 refund agent.

Every step the refund agent takes — each tool call, the account-owner check, the
CIBA approval request and its outcome, the token exchange, the Vault credential,
the database write and the audit anchor — is reported to the browser as it
happens, as one Server-Sent Event per step. The event shapes are the banking UI's
contract, applications/banking-app/ui/src/lib/agent-events.ts; nothing outside it
is emitted.

Isolation
---------
Each /chat request gets its own EventSink, held in the `_EVENT_SINK` ContextVar
exactly like `_AUTHENTICATED_SUB`: main.py sets it before the agent starts, and
asyncio.to_thread / Strands' own thread and tool hops copy the context, so a
tool or hook always finds the sink of the request it is running for — never a
shared object. With no sink bound (a tool called outside a request) every emit
is a no-op.

Threads
-------
The agent runs in a worker thread and Strands runs its hooks and tools in
threads of its own, none of them on the request's event loop. An EventSink
therefore captures the request's loop when it is created and every push goes
through loop.call_soon_threadsafe onto an unbounded asyncio.Queue. The queue is
never full and a push never blocks, so a browser that disconnects cannot stall
the worker: the refund still runs to completion, and pushes after close() are
dropped.

Secrets
-------
No event may carry a raw JWT, Vault token, password or other credential. The
banking UI's activity filter enforces that at the edge; this module enforces the
same rules at the source, so the agent's own stream is already clean:
  - payload keys named like a secret (password, secret, token, private key,
    api key, credential headers) are removed at any depth, except the
    correlation keys the audit story needs (lease_id, request_id, sub, ...);
  - every string has JWTs and Vault tokens replaced by "[token redacted]".
Tokens are only ever reported as decoded, non-secret claims
(delegated_token_claims).

An emit never raises into the tool that called it: reporting a step must not be
able to break the step.
"""

import asyncio
import base64
import json
import logging
import math
import re
import threading
import time
from contextvars import ContextVar, Token
from typing import Any

from strands.hooks import AfterToolCallEvent, BeforeToolCallEvent, HookProvider, HookRegistry

logger = logging.getLogger(__name__)

# Placed on the queue after the agent's worker has finished; never sent.
END = object()

REDACTED_TOKEN = "[token redacted]"

# Event fields that carry arbitrary data and are deep-scrubbed.
_PAYLOAD_FIELDS = frozenset({"args", "result", "details", "leases", "claims"})

# Same rules as applications/banking-app/ui/src/lib/server/activity-filter.ts.
_SECRET_KEY_SUBSTRINGS = ("password", "passwd", "passphrase", "secret", "token", "privatekey", "apikey")
_SECRET_KEY_NAMES = frozenset({"authorization", "proxyauthorization", "cookie", "setcookie"})
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
_PROTOTYPE_KEYS = frozenset({"__proto__", "constructor", "prototype"})
_MAX_DEPTH = 32

_TOKEN_CHAR_RUN = re.compile(r"[A-Za-z0-9_.-]+")
_VAULT_TOKEN = re.compile(r"hv[sbr]\.[A-Za-z0-9_-]{24,}")

# The delegated-token claims worth showing. Everything else is left out.
_CLAIMS_SHOWN = ("sub", "scope", "jti", "iss", "aud", "exp", "act", "may_act")


# ---------------------------------------------------------------------------
# Scrubbing
# ---------------------------------------------------------------------------


def _is_secret_key(key: str) -> bool:
    normalized = re.sub(r"[^a-z0-9]", "", key.lower())
    if normalized in _SECRET_KEY_NAMES:
        return True
    return any(term in normalized for term in _SECRET_KEY_SUBSTRINGS)


def _redact_run(match: re.Match) -> str:
    run = match.group(0)
    start = run.find("eyJ")
    if start != -1 and run[start:].count(".") >= 2:
        run = run[:start] + REDACTED_TOKEN
    if "hv" in run:
        run = _VAULT_TOKEN.sub(REDACTED_TOKEN, run)
    return run


def scrub_text(value: str) -> str:
    """Replace JWTs and Vault tokens inside a string with REDACTED_TOKEN."""
    if "eyJ" not in value and "hv" not in value:
        return value
    return _TOKEN_CHAR_RUN.sub(_redact_run, value)


def _scrub(value: Any, depth: int = 0) -> Any:
    """Return a JSON-safe, scrubbed copy of value (None when nothing may pass)."""
    if isinstance(value, str):
        return scrub_text(value)
    if isinstance(value, bool) or value is None:
        return value
    if isinstance(value, (int, float)):
        return value if math.isfinite(value) else None
    if depth >= _MAX_DEPTH:
        return None
    if isinstance(value, (list, tuple)):
        out = []
        for item in value:
            scrubbed = _scrub(item, depth + 1)
            if scrubbed is not None:
                out.append(scrubbed)
        return out
    if isinstance(value, dict):
        out = {}
        for key, item in value.items():
            key = str(key)
            if key in _PROTOTYPE_KEYS:
                continue
            if key not in _CORRELATION_KEYS and (_is_secret_key(key) or scrub_text(key) != key):
                continue
            scrubbed = _scrub(item, depth + 1)
            if scrubbed is not None:
                out[key] = scrubbed
        return out
    # Anything else (Decimal, datetime, ...) is reported as its text.
    return scrub_text(str(value))


# ---------------------------------------------------------------------------
# The per-request sink
# ---------------------------------------------------------------------------


class EventSink:
    """One /chat request's event queue, safe to push to from any thread."""

    def __init__(self, loop: asyncio.AbstractEventLoop) -> None:
        self._loop = loop
        self.queue: asyncio.Queue = asyncio.Queue()  # unbounded: a push never blocks
        self._closed = False
        self._lock = threading.Lock()
        self._request_by_tool_call: dict[str, str] = {}
        self._tool_call_by_request: dict[str, str] = {}

    @property
    def closed(self) -> bool:
        return self._closed

    def push(self, event: Any) -> None:
        """Queue an event for the SSE stream. Dropped once the stream has closed."""
        if self._closed:
            return
        try:
            self._loop.call_soon_threadsafe(self.queue.put_nowait, event)
        except RuntimeError:
            # The request's loop is gone; nobody is listening any more.
            self._closed = True

    def close(self) -> None:
        """Stop accepting events: the browser has gone or the stream has ended."""
        self._closed = True

    def bind_request(self, tool_call_id: str, request_id: str) -> None:
        with self._lock:
            self._request_by_tool_call[tool_call_id] = request_id
            self._tool_call_by_request[request_id] = tool_call_id

    def request_id_for(self, tool_call_id: str) -> str | None:
        with self._lock:
            return self._request_by_tool_call.get(tool_call_id)

    def tool_call_for(self, request_id: str) -> str | None:
        with self._lock:
            return self._tool_call_by_request.get(request_id)


_EVENT_SINK: ContextVar["EventSink | None"] = ContextVar("uc3_event_sink", default=None)


def bind_sink(sink: EventSink) -> Token:
    """Make `sink` the current request's sink. Pair with reset_sink()."""
    return _EVENT_SINK.set(sink)


def reset_sink(token: Token) -> None:
    _EVENT_SINK.reset(token)


# ---------------------------------------------------------------------------
# Emitting
# ---------------------------------------------------------------------------


def emit(event_type: str, **fields: Any) -> None:
    """Send one contract event on the current request's stream.

    Fields set to None are left out. Payload fields are deep-scrubbed and every
    other string field is token-scrubbed. Never raises.
    """
    sink = _EVENT_SINK.get()
    if sink is None or sink.closed:
        return
    try:
        event: dict[str, Any] = {"type": event_type}
        for name, value in fields.items():
            if value is None:
                continue
            if name in _PAYLOAD_FIELDS:
                value = _scrub(value)
                if value is None:
                    continue
            elif isinstance(value, str):
                value = scrub_text(value)
            event[name] = value
        event["ts"] = int(time.time() * 1000)
        sink.push(event)
    except Exception:  # noqa: BLE001 — reporting a step must never break it
        logger.warning("uc3_activity_emit_failed", extra={"event_type": event_type}, exc_info=True)


def bind_request(tool_context: Any, request_id: str) -> None:
    """Tie a refund's request_id to the tool call that is running it.

    From here on the tool call's own events (tool_call success/error, HITL)
    carry that request_id.
    """
    sink = _EVENT_SINK.get()
    if sink is None:
        return
    try:
        tool_call_id = tool_context.tool_use["toolUseId"]
    except Exception:  # noqa: BLE001
        return
    sink.bind_request(tool_call_id, request_id)


def narrate(text: str, request_id: str | None = None) -> None:
    """One Agent Log line for an agent step (glyph ▶)."""
    emit("agent:narration", glyph="▶", text=text, requestId=request_id)


_HITL_TYPES = {
    "required": "agent:hitl_required",
    "approved": "agent:hitl_approved",
    "denied": "agent:hitl_denied",
    "timeout": "agent:hitl_timeout",
}


def hitl(state: str, text: str, request_id: str, details: dict | None = None) -> None:
    """A human-in-the-loop approval event: required, approved, denied or timeout."""
    sink = _EVENT_SINK.get()
    tool_call_id = sink.tool_call_for(request_id) if sink is not None else None
    emit(
        _HITL_TYPES[state],
        toolCallId=tool_call_id,
        text=text,
        details=details,
        requestId=request_id,
    )


def audit_seed(
    request_id: str,
    vault_role: str | None,
    db_role: str | None,
    leases: list[dict],
    claims: dict | None,
) -> None:
    """The live correlation fields for the Audit Trace card."""
    emit(
        "agent:audit_seed",
        requestId=request_id,
        vaultRole=vault_role,
        dbRole=db_role,
        leases=leases,
        claims=claims,
    )


def delegated_token_claims(token: str) -> dict:
    """Decode a JWT's payload and keep only the non-secret claims worth showing.

    The signature is NOT checked here — Vault verifies the token against IVIA's
    JWKS when the agent presents it. This is display only, and the token itself
    is never returned. Returns {} when the value is not a readable JWT.
    """
    try:
        payload_b64 = token.split(".")[1]
        payload_b64 += "=" * (-len(payload_b64) % 4)
        payload = json.loads(base64.urlsafe_b64decode(payload_b64))
    except Exception:  # noqa: BLE001 — unreadable: show nothing rather than guess
        return {}
    if not isinstance(payload, dict):
        return {}
    claims = {name: payload[name] for name in _CLAIMS_SHOWN if name in payload}
    details = payload.get("authorization_details")
    if isinstance(details, list):
        claims["authorization_details"] = [
            {"type": entry["type"]} for entry in details if isinstance(entry, dict) and "type" in entry
        ]
    return _scrub(claims) or {}


# ---------------------------------------------------------------------------
# Tool-call hooks
# ---------------------------------------------------------------------------


def _tool_result_payload(result: Any) -> Any:
    """The tool's return value as the model saw it: parsed JSON, else the text."""
    try:
        text = result["content"][0]["text"]
    except Exception:  # noqa: BLE001
        return None
    try:
        return json.loads(text)
    except (TypeError, ValueError):
        return text


class ToolActivityHooks(HookProvider):
    """Reports every tool call's start and finish as `tool_call` events."""

    def register_hooks(self, registry: HookRegistry, **kwargs: Any) -> None:
        registry.add_callback(BeforeToolCallEvent, self._before_tool)
        registry.add_callback(AfterToolCallEvent, self._after_tool)

    @staticmethod
    def _request_id(tool_call_id: str) -> str | None:
        sink = _EVENT_SINK.get()
        return sink.request_id_for(tool_call_id) if sink is not None else None

    def _before_tool(self, event: BeforeToolCallEvent) -> None:
        tool_use = event.tool_use
        tool_call_id = str(tool_use.get("toolUseId", ""))
        emit(
            "tool_call",
            toolCallId=tool_call_id,
            name=str(tool_use.get("name", "")),
            status="in_progress",
            args=tool_use.get("input"),
            requestId=self._request_id(tool_call_id),
        )

    def _after_tool(self, event: AfterToolCallEvent) -> None:
        tool_use = event.tool_use
        tool_call_id = str(tool_use.get("toolUseId", ""))
        result = event.result or {}
        failed = (
            event.exception is not None
            or event.cancel_message is not None
            or result.get("status") == "error"
        )
        emit(
            "tool_call",
            toolCallId=tool_call_id,
            name=str(tool_use.get("name", "")),
            status="error" if failed else "success",
            result=_tool_result_payload(result),
            durationMs=round(event.duration * 1000) if event.duration is not None else None,
            requestId=self._request_id(tool_call_id),
        )
