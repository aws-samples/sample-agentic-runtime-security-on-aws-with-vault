"""Per-request activity events for the streamed /query.

When a caller asks /query for `text/event-stream`, every step the agent takes
is sent as one event from the contract in
applications/banking-app/ui/src/lib/agent-events.ts: the Vault sign-in, each
tool call, the short-lived credentials Vault issues, the answer.

Where events come from
----------------------
The agent runs in a worker thread (asyncio.to_thread), and Strands fires its
hooks and runs its tools in further threads. So an event can be emitted from
any thread, while the HTTP response that carries it lives on the event loop.

Each streamed request binds one Turn in the _TURN ContextVar before its worker
starts. asyncio.to_thread copies the context into the worker, and Strands
copies it again into its own threads, so every emit() finds THIS request's
Turn — never another visitor's. emit() hands the event to the loop with
call_soon_threadsafe; the queue is unbounded, so a visitor who disconnects can
never leave the worker blocked on a full queue.

Outside a streamed request (the JSON path, startup, a kubectl-exec'd script)
nothing is bound and emit() does nothing.

Credentials
-----------
The workshop shows every credential issued during a turn in full: the
service-account JWT the agent signs in to Vault with, its Vault token, the AWS
keys and database login Vault issues. They travel ONLY as `agent:credential`
events on this queue (credential() below). Never in narration text, never in a
log line (pod logs are shipped off-cluster), never in a tool's return value
(that goes to Bedrock, and the model can repeat it).
"""

from __future__ import annotations

import asyncio
import base64
import json
import time
from contextvars import ContextVar
from dataclasses import dataclass, field
from typing import Any

# Narration glyphs, exactly as the contract's NARRATION_GLYPHS spells them.
STEP = "▶"  # ▶ an agent step
OUTPUT = "⚡"  # ⚡ what a tool or the response returned


@dataclass
class Turn:
    """One streamed /query: its correlation id and where its events go."""

    request_id: str
    loop: asyncio.AbstractEventLoop
    queue: asyncio.Queue
    # Knowledge-base sources recorded by retrieve_from_knowledge_base, keyed by
    # toolUseId: Strands runs one turn's tool calls concurrently, so the order
    # they finish in says nothing about which call a result belongs to.
    sources: dict[str, list[dict[str, Any]]] = field(default_factory=dict)


# Marks the end of a Turn's events. Only close() sends it.
END = object()

_TURN: ContextVar[Turn | None] = ContextVar("uc1_turn", default=None)


def bind(turn: Turn) -> None:
    """Bind `turn` in the CURRENT context. Call it inside a copied context."""
    _TURN.set(turn)


def current() -> Turn | None:
    """The Turn bound to this request, or None outside a streamed request."""
    return _TURN.get()


def _put(turn: Turn, item: Any) -> None:
    try:
        turn.loop.call_soon_threadsafe(turn.queue.put_nowait, item)
    except RuntimeError:
        # The event loop is closed (process shutdown). Nobody is listening.
        pass


def emit(event: dict[str, Any]) -> None:
    """Send one contract event for the current request, stamped with requestId and ts."""
    turn = _TURN.get()
    if turn is None:
        return
    _put(turn, {**event, "requestId": turn.request_id, "ts": int(time.time() * 1000)})


def narrate(text: str, *, output: bool = False) -> None:
    """One Agent Log line. `output=True` marks a line that reports what something returned."""
    event: dict[str, Any] = {"type": "agent:narration", "glyph": OUTPUT if output else STEP, "text": text}
    if output:
        event["accent"] = "tool_output"
    emit(event)


def jwt_claims(token: str) -> dict[str, Any] | None:
    """The payload of a compact JWT, decoded but NOT verified; None if it is not one."""
    try:
        payload = token.split(".")[1]
        claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
    except (IndexError, ValueError):
        return None
    return claims if isinstance(claims, dict) else None


def credential(
    kind: str,
    label: str,
    issuer: str,
    *,
    value: str | None = None,
    fields: dict[str, Any] | None = None,
    claims: dict[str, Any] | None = None,
    vault_path: str | None = None,
    lease_id: str | None = None,
    ttl_seconds: int | None = None,
    expires_at: int | None = None,
) -> None:
    """Send one issued credential, in full, as an `agent:credential` event.

    `value` for a single token, `fields` for a multi-part credential — never
    both. Only the fields that exist for the credential are sent.
    """
    if _TURN.get() is None:
        return
    event: dict[str, Any] = {"type": "agent:credential", "kind": kind, "label": label, "issuer": issuer}
    if value is not None:
        event["value"] = value
    elif fields is not None:
        event["fields"] = fields
    optional = {
        "claims": claims,
        "vaultPath": vault_path,
        "leaseId": lease_id,
        "ttlSeconds": ttl_seconds,
        "expiresAt": expires_at,
    }
    event.update({key: val for key, val in optional.items() if val is not None})
    emit(event)


def record_sources(tool_use_id: str, sources: list[dict[str, Any]]) -> None:
    """Keep one retrieve call's sources until its tool_call success event is sent."""
    turn = _TURN.get()
    if turn is not None:
        turn.sources[tool_use_id] = sources


def close() -> None:
    """Tell the response there are no more events from the worker."""
    turn = _TURN.get()
    if turn is not None:
        _put(turn, END)
