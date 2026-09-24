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

Never put a credential into an event: no Vault token, no JWT, no database
password, no AWS key. Credentials are described by path, lease id and TTL only.
"""

from __future__ import annotations

import asyncio
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
