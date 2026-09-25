"""activity.py — the per-request activity stream of the UC3 refund agent.

Every step the refund agent takes — each tool call, the account-owner check, the
CIBA approval request and its outcome, the token exchange, the Vault credential,
the database write and the audit anchor — is reported to the browser as it
happens, as one Server-Sent Event per step. The event shapes are the banking UI's
contract, applications/banking-app/ui/src/lib/agent-events.ts.

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

The turn's requestId
--------------------
Every event in a turn carries the same requestId (the contract). In a refund
turn that is the refund's request_id — the id the CIBA binding_message, Vault's
X-Correlation-Id, the pgaudit statement comment and banking.refunds.request_id
carry. initiate_refund mints it and complete_refund takes it from the approval
it redeems, once its checks prove the approval is the caller's; neither id
exists when the refund tool's call starts. So the sink holds every event until
the turn's requestId is known and then sends them, stamped, in the order they
were reported. A turn that binds no refund — a non-refund tool runs, a refund
tool ends without binding, or the turn ends — uses the id main.py minted for
it. From then on every event is sent at once.

Credentials
-----------
Every credential the turn uses is shown IN FULL, in exactly one place: an
`agent:credential` event built by credential() (Bear's decision, 2026-09-24 —
the workshop shows in real time what happens behind each use case). The value
goes only onto this request's queue: never into a tool's return value (that
reaches Bedrock and the on-disk session history) and never into a log line.
OAuth client secrets and the SCIM password are configuration, not issued
credentials, and are never passed to credential().

Every OTHER event (narration, tool calls, approvals, the audit seed) is sent
with every key and value the agent gave it — no key named like a secret is
removed and no JWT or Vault token is replaced (Bear, 2026-09-25: the workshop
shows attendees everything as it happens). Payload fields are only copied into
plain JSON values (_json_safe), which leaves out prototype keys, nesting deeper
than 32 levels, numbers JSON cannot carry, and null values.

An emit never raises into the tool that called it, and a tool-call hook never
raises into the tool call it reports: reporting a step must not be able to
break the step.
"""

import asyncio
import base64
import hashlib
import json
import logging
import math
import threading
import time
from contextvars import ContextVar, Token
from typing import Any

from strands.hooks import AfterToolCallEvent, BeforeToolCallEvent, HookProvider, HookRegistry

logger = logging.getLogger(__name__)

# Placed on the queue after the agent's worker has finished; never sent.
END = object()

# Event fields that carry arbitrary data and are copied into plain JSON values.
_PAYLOAD_FIELDS = frozenset({"args", "result", "details", "leases", "claims"})

_PROTOTYPE_KEYS = frozenset({"__proto__", "constructor", "prototype"})
_MAX_DEPTH = 32

# The delegated-token claims worth showing. Everything else is left out.
_CLAIMS_SHOWN = ("sub", "scope", "jti", "iss", "aud", "exp", "act", "may_act")


# ---------------------------------------------------------------------------
# Events as plain JSON
# ---------------------------------------------------------------------------


def _json_safe(value: Any, depth: int = 0) -> Any:
    """A plain-JSON copy of value with every key and value kept, or None if it is left out.

    Nothing is removed or replaced for being secret. Left out: prototype keys,
    nesting deeper than _MAX_DEPTH, numbers JSON cannot carry, and null values.
    """
    if isinstance(value, str):
        return value
    if isinstance(value, bool) or value is None:
        return value
    if isinstance(value, (int, float)):
        return value if math.isfinite(value) else None
    if depth >= _MAX_DEPTH:
        return None
    if isinstance(value, (list, tuple)):
        out = []
        for item in value:
            copied = _json_safe(item, depth + 1)
            if copied is not None:
                out.append(copied)
        return out
    if isinstance(value, dict):
        out = {}
        for key, item in value.items():
            key = str(key)
            if key in _PROTOTYPE_KEYS:
                continue
            copied = _json_safe(item, depth + 1)
            if copied is not None:
                out[key] = copied
        return out
    # Anything else (Decimal, datetime, ...) is reported as its text.
    return str(value)


# ---------------------------------------------------------------------------
# The per-request sink
# ---------------------------------------------------------------------------


class EventSink:
    """One /chat request's event queue, safe to push to from any thread.

    `request_id` is the id this turn uses if it binds no refund (see "The turn's
    requestId" above).
    """

    def __init__(self, loop: asyncio.AbstractEventLoop, request_id: str) -> None:
        self._loop = loop
        self.queue: asyncio.Queue = asyncio.Queue()  # unbounded: a push never blocks
        self._closed = False
        self._lock = threading.Lock()
        self._request_by_tool_call: dict[str, str] = {}
        self._tool_call_by_request: dict[str, str] = {}
        self._own_request_id = request_id
        # The turn's requestId once it is known; until then every event is held.
        self._request_id: str | None = None
        self._held: list[dict] = []
        self._credentials_sent: set[str] = set()  # sha256 of kind+value, per turn

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

    def publish(self, event: dict) -> None:
        """Send one event stamped with the turn's requestId, or hold it until that is known.

        An event that already names a requestId keeps it.
        """
        with self._lock:
            if self._closed:
                return
            if self._request_id is None:
                self._held.append(event)
                return
            event.setdefault("requestId", self._request_id)
            self.push(event)

    def _settle_locked(self, request_id: str, send) -> None:
        """Fix the turn's requestId and send what was held, in order, through `send`."""
        if self._request_id is not None:
            return
        self._request_id = request_id
        for event in self._held:
            event.setdefault("requestId", request_id)
            send(event)
        self._held = []

    def bind_request(self, tool_call_id: str, request_id: str) -> None:
        """A refund tool call has its request_id: the turn's requestId, if not already fixed."""
        with self._lock:
            self._request_by_tool_call[tool_call_id] = request_id
            self._tool_call_by_request[request_id] = tool_call_id
            self._settle_locked(request_id, self.push)

    def settle_without_refund(self) -> None:
        """No refund bound its request_id before this point: the turn uses its own id."""
        with self._lock:
            self._settle_locked(self._own_request_id, self.push)

    @property
    def request_id(self) -> str:
        """The turn's requestId: the refund's, or the turn's own when no refund bound one."""
        return self._request_id or self._own_request_id

    def offer_credential(self, event: dict, request_id: str | None, digest: str) -> None:
        """Send a credential event once per turn."""
        with self._lock:
            if self._closed or digest in self._credentials_sent:
                return
            self._credentials_sent.add(digest)
        if request_id:
            event["requestId"] = request_id
        event["ts"] = int(time.time() * 1000)
        self.publish(event)

    def finish(self) -> None:
        """On the request's loop, after the agent task is done: flush, then END.

        Everything the worker pushed is already queued (call_soon_threadsafe ran
        ahead of the task's completion). Events still held — the turn bound no
        refund — are stamped with the turn's own id and queued directly, ahead
        of END. Once the stream has closed nothing is queued: nobody reads it.
        """
        with self._lock:
            if self._closed:
                self._held = []
                return
            self._settle_locked(self._own_request_id, self.queue.put_nowait)
        self.queue.put_nowait(END)

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

    Fields set to None are left out. Payload fields are copied into plain JSON
    values; every other field is sent as given. Never raises.
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
                value = _json_safe(value)
                if value is None:
                    continue
            event[name] = value
        event["ts"] = int(time.time() * 1000)
        sink.publish(event)
    except Exception:  # noqa: BLE001 — reporting a step must never break it
        logger.warning("uc3_activity_emit_failed", extra={"event_type": event_type}, exc_info=True)


def bind_request(tool_context: Any, request_id: str) -> None:
    """Tie a refund's request_id to the tool call that is running it.

    From here on the tool call's own events (tool_call success/error, HITL)
    carry that request_id, and so does every event the turn held until now.
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


def decode_jwt_payload(token: str) -> dict | None:
    """A JWT's payload, decoded but NOT verified (display only), or None.

    None when the value is not a readable three-part JWT — an opaque token is
    shown without claims rather than guessed at.
    """
    try:
        parts = token.split(".")
        if len(parts) != 3 or not token.startswith("eyJ"):
            return None
        payload_b64 = parts[1] + "=" * (-len(parts[1]) % 4)
        payload = json.loads(base64.urlsafe_b64decode(payload_b64))
    except Exception:  # noqa: BLE001 — unreadable: show nothing rather than guess
        return None
    return payload if isinstance(payload, dict) else None


def delegated_token_claims(token: str) -> dict:
    """Decode a JWT's payload and keep the claims the narration and audit seed show.

    The signature is NOT checked here — Vault verifies the token against IVIA's
    JWKS when the agent presents it. This is display only, and the token itself
    is never returned. Returns {} when the value is not a readable JWT.
    """
    payload = decode_jwt_payload(token)
    if payload is None:
        return {}
    claims = {name: payload[name] for name in _CLAIMS_SHOWN if name in payload}
    details = payload.get("authorization_details")
    if isinstance(details, list):
        claims["authorization_details"] = [
            {"type": entry["type"]} for entry in details if isinstance(entry, dict) and "type" in entry
        ]
    return _json_safe(claims)


# ---------------------------------------------------------------------------
# Issued credentials, shown in full
# ---------------------------------------------------------------------------


def credential(
    kind: str,
    label: str,
    issuer: str,
    *,
    value: str | None = None,
    fields: dict | None = None,
    vault_path: str | None = None,
    lease_id: str | None = None,
    ttl_seconds: int | float | None = None,
    expires_at: int | None = None,
    request_id: str | None = None,
) -> None:
    """Show one issued credential IN FULL on the current request's stream.

    The workshop's UI shows every credential a turn uses (Bear's decision,
    2026-09-24). Hard rules this function exists to keep:
      - the value goes ONLY onto this request's event queue — never into a
        tool's return value (that reaches Bedrock and the on-disk session
        history) and never into a log line (pod logs are shipped off-cluster);
      - configuration secrets (OAuth client secrets, the SCIM password) are
        never passed here.
    `value` (a single token) or `fields` (a multi-part credential), never both.
    A JWT value also carries its decoded, unverified payload as `claims`.
    Each distinct credential is sent once per turn. Never raises; a failure is
    logged without the value.
    """
    sink = _EVENT_SINK.get()
    if sink is None or sink.closed:
        return
    try:
        event: dict[str, Any] = {"type": "agent:credential", "kind": kind, "label": label, "issuer": issuer}
        if value is not None:
            event["value"] = value
            claims = decode_jwt_payload(value)
            if claims is not None:
                event["claims"] = claims
        elif fields is not None:
            event["fields"] = dict(fields)
        for name, item in (
            ("vaultPath", vault_path),
            ("leaseId", lease_id),
            ("ttlSeconds", ttl_seconds),
            ("expiresAt", expires_at),
        ):
            if item is not None:
                event[name] = item
        identity = value if value is not None else json.dumps(fields, sort_keys=True, default=str)
        digest = hashlib.sha256(f"{kind}\0{identity}".encode()).hexdigest()
        sink.offer_credential(event, request_id, digest)
    except Exception as exc:  # noqa: BLE001 — never raise; never log the value
        logger.warning("uc3_activity_credential_failed", extra={"kind": kind, "error_type": type(exc).__name__})


def expires_at_ms(ttl_seconds: Any, issued_at: float | None = None) -> int | None:
    """Absolute expiry (ms since the epoch) from a TTL in seconds, or None."""
    try:
        return int(((issued_at if issued_at is not None else time.time()) + float(ttl_seconds)) * 1000)
    except (TypeError, ValueError):
        return None


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
    """Reports every tool call's start and finish as `tool_call` events.

    `refund_tools` names the tools that bind a refund's request_id. When any
    other tool starts, or a refund tool finishes without binding one, the turn
    has no refund in play: it takes its own requestId and what it held is sent.

    A hook only reports; it must never change what the tool call does. Strands
    hands an exception raised in a hook to the tool call itself: from the
    Before hook it fails the whole turn, and from the After hook it replaces a
    tool's real result with an error, so a refund that WAS written would be
    reported to the model, and so to the user, as a failure. Each hook
    therefore swallows its own failure and logs it without any value.
    """

    def __init__(self, refund_tools: frozenset[str] = frozenset()) -> None:
        self._refund_tools = refund_tools

    def register_hooks(self, registry: HookRegistry, **kwargs: Any) -> None:
        registry.add_callback(BeforeToolCallEvent, self._before_tool)
        registry.add_callback(AfterToolCallEvent, self._after_tool)

    @staticmethod
    def _request_id(tool_call_id: str) -> str | None:
        sink = _EVENT_SINK.get()
        return sink.request_id_for(tool_call_id) if sink is not None else None

    def _before_tool(self, event: BeforeToolCallEvent) -> None:
        try:
            self._report_start(event)
        except Exception as exc:  # noqa: BLE001 — reporting a tool call must never break it
            logger.warning("uc3_activity_hook_failed", extra={"hook": "before_tool_call", "error_type": type(exc).__name__})

    def _after_tool(self, event: AfterToolCallEvent) -> None:
        try:
            self._report_finish(event)
        except Exception as exc:  # noqa: BLE001 — reporting a tool call must never break it
            logger.warning("uc3_activity_hook_failed", extra={"hook": "after_tool_call", "error_type": type(exc).__name__})

    def _report_start(self, event: BeforeToolCallEvent) -> None:
        tool_use = event.tool_use
        tool_call_id = str(tool_use.get("toolUseId", ""))
        sink = _EVENT_SINK.get()
        if sink is not None and tool_use.get("name") not in self._refund_tools:
            sink.settle_without_refund()
        emit(
            "tool_call",
            toolCallId=tool_call_id,
            name=str(tool_use.get("name", "")),
            status="in_progress",
            args=tool_use.get("input"),
            requestId=self._request_id(tool_call_id),
        )

    def _report_finish(self, event: AfterToolCallEvent) -> None:
        tool_use = event.tool_use
        tool_call_id = str(tool_use.get("toolUseId", ""))
        result = event.result or {}
        failed = (
            event.exception is not None
            or event.cancel_message is not None
            or result.get("status") == "error"
        )
        sink = _EVENT_SINK.get()
        if sink is not None:
            # A refund tool that refused before binding a request_id: no refund
            # this turn, so its held events go out now rather than at turn end.
            sink.settle_without_refund()
        emit(
            "tool_call",
            toolCallId=tool_call_id,
            name=str(tool_use.get("name", "")),
            status="error" if failed else "success",
            result=_tool_result_payload(result),
            durationMs=round(event.duration * 1000) if event.duration is not None else None,
            requestId=self._request_id(tool_call_id),
        )
