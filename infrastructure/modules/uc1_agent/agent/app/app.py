"""FastAPI HTTP wrapper for the UC1 Strands agent.

Exposes three endpoints:
  POST /query   — invoke the agent with a natural-language question
  GET  /health  — liveness/readiness probe (includes Vault token validity)
  GET  /        — welcome message describing the agent's role

Credential metadata is returned in /query responses: `credential_metadata.leases`
carries the lease_id and TTL of every JIT Vault credential issued while serving
the request, spelled exactly as Vault spells it, so attendees can find the same
lease in the Vault audit log (OBJ-5). A question the model answers from the
Knowledge Base alone issues no database credential, and the list is then empty.
"""

import asyncio
import contextvars
import json
import logging
import logging.config
import os
import re
import threading
import time
import uuid
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from typing import Any

import uvicorn
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel, Field

from . import activity
from .agent import init_uc1_model, run_uc1_turn, _vault, _ISSUED_CREDENTIALS

# ---------------------------------------------------------------------------
# Structured JSON logging — matches Vault audit log timestamp format.
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format='{"time": "%(asctime)s", "level": "%(levelname)s", "logger": "%(name)s", "message": %(message)s}',
)
logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Application lifespan — sign in to Vault and build the model once at startup.
# Each /query builds its own Agent around that model (see build_uc1_agent).
# ---------------------------------------------------------------------------
_ready = False


@asynccontextmanager
async def lifespan(app: FastAPI):
    global _ready
    logger.info('"uc1_agent_startup_begin"')
    init_uc1_model()
    _ready = True
    logger.info('"uc1_agent_startup_complete"')
    yield
    logger.info('"uc1_agent_shutdown"')


app = FastAPI(
    title="UC1 Agent — Non-Personalized Read-Only",
    description=(
        "Workshop demonstration agent for Use Case 1. "
        "Authenticates via Kubernetes workload identity, obtains JIT credentials "
        "from HashiCorp Vault, and queries Postgres + Bedrock Knowledge Base."
    ),
    version="1.0.0",
    lifespan=lifespan,
)


# ---------------------------------------------------------------------------
# Request / Response models
# ---------------------------------------------------------------------------


class QueryRequest(BaseModel):
    query: str


class VaultLease(BaseModel):
    """One JIT credential Vault issued while serving this request.

    `lease_id` is Vault's own spelling, byte for byte, so it matches the
    `database/creds/...` lease recorded in the Vault audit log exactly — that
    identity is what makes the OBJ-5 correlation exercise work.
    """

    vault_path: str
    lease_id: str
    ttl_seconds: int


class CredentialMetadata(BaseModel):
    vault_authenticated: bool
    vault_role: str
    leases: list[VaultLease] = Field(default_factory=list)


class QueryResponse(BaseModel):
    answer: str
    sources: list[str]
    credential_metadata: CredentialMetadata


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------


def _clean_answer(result: Any) -> str:
    # Strip any <thinking>...</thinking> chain-of-thought the model emits so it
    # never leaks into the answer (mirrors uc3-agent + banking-app agent).
    return re.sub(r'<thinking>.*?</thinking>\s*', '', str(result), flags=re.DOTALL)


def _sse(event: dict) -> str:
    return f"data: {json.dumps(event, ensure_ascii=False)}\n\n"


def _wants_event_stream(http_request: Request) -> bool:
    """True only when the caller explicitly accepts text/event-stream.

    Everything else — curl's default `*/*`, no Accept header at all (the urllib
    call in verify-uc1.sh), `application/json` — gets the JSON reply.
    """
    return "text/event-stream" in http_request.headers.get("accept", "").lower()


def _run_turn_in_worker(query: str, cancel: threading.Event) -> Any:
    """Worker-thread body for a streamed turn: run it, then close its event queue."""
    try:
        return run_uc1_turn(query, cancel_signal=cancel)
    finally:
        activity.close()


async def _stream_turn(query: str, request_id: str, vault_role: str) -> AsyncIterator[str]:
    """One streamed /query: every agent step as an event, then the answer.

    Frame order:
      tool_planning (legacy) → agent:thinking → the worker's events (Vault
      sign-in, tool_call in_progress/success/error, credential issuance) →
      agent:audit_seed → credential_metadata line → agent:text_delta +
      delta (legacy) → end (legacy) → agent:done.
    On failure: … → agent:error → error (legacy) → end (legacy) → agent:done.
    The legacy frames are the ones the other two agent chats send today.
    """
    loop = asyncio.get_running_loop()
    turn = activity.Turn(request_id=request_id, loop=loop, queue=asyncio.Queue())
    sink: list[dict] = []
    cancel = threading.Event()

    # The worker's context is a copy with this request's Turn and lease sink
    # bound. asyncio.to_thread copies it again into the worker thread, and
    # Strands copies it into its own threads, so the tools and hooks of this
    # request — and only this request — find them. Nothing is set on the
    # generator's own context, so nothing needs resetting when it is closed.
    ctx = contextvars.copy_context()
    ctx.run(activity.bind, turn)
    ctx.run(_ISSUED_CREDENTIALS.set, sink)

    def stamped(event: dict) -> dict:
        return {**event, "requestId": request_id, "ts": int(time.time() * 1000)}

    yield _sse({"type": "tool_planning", "role": "ai", "content": "Processing your request..."})
    yield _sse(stamped({"type": "agent:thinking", "text": "Reasoning about your request…"}))

    worker = asyncio.create_task(asyncio.to_thread(_run_turn_in_worker, query, cancel), context=ctx)
    try:
        while (event := await turn.queue.get()) is not activity.END:
            yield _sse(event)
        try:
            outcome = await worker
        except Exception as exc:
            logger.error(f'"query_error" request_id="{request_id}" error="{exc}"')
            message = f"Agent error: {exc}"
            yield _sse(stamped({"type": "agent:error", "message": message}))
            yield _sse({"type": "error", "content": message})
            yield _sse({"type": "end"})
            yield _sse(stamped({"type": "agent:done"}))
            return

        answer = _clean_answer(outcome.result)
        try:
            vault_authenticated = await asyncio.to_thread(_vault.is_authenticated)
        except Exception:  # noqa: BLE001 — the answer is already written; report the login as unconfirmed
            logger.warning("stream_vault_status_failed", exc_info=True)
            vault_authenticated = False
        credential_metadata = {"vault_authenticated": vault_authenticated, "vault_role": vault_role, "leases": sink}
        yield _sse(stamped({"type": "agent:audit_seed", "vaultRole": vault_role, "leases": sink}))
        note = "" if sink else " — no database credential was needed for this question"
        yield _sse(
            stamped(
                {
                    "type": "agent:narration",
                    "glyph": activity.OUTPUT,
                    "accent": "tool_output",
                    "text": f"Response credential_metadata: {json.dumps(credential_metadata)}{note}",
                }
            )
        )
        yield _sse(stamped({"type": "agent:narration", "glyph": activity.STEP, "text": "Writing the answer."}))
        yield _sse(stamped({"type": "agent:text_delta", "text": answer}))
        yield _sse({"type": "delta", "role": "ai", "content": answer})
        yield _sse({"type": "end"})
        yield _sse(stamped({"type": "agent:done"}))
        logger.info(f'"query_complete" request_id="{request_id}" stream=true lease_count={len(sink)}')
    finally:
        if not worker.done():
            # The visitor went away mid-answer: stop the agent at its next
            # checkpoint. The worker thread still finishes on its own; the
            # queue is unbounded, so it never blocks on events nobody reads.
            cancel.set()
            logger.info(f'"query_stream_closed_early" request_id="{request_id}"')


@app.get("/")
async def root() -> dict[str, str]:
    """Welcome message describing Use Case 1."""
    return {
        "agent": "UC1 — Non-Personalized Read-Only",
        "description": (
            "Workload-identity-only Strands agent. "
            "No user context — all access via Kubernetes SA JWT + Vault JIT credentials."
        ),
        "endpoints": "POST /query, GET /health",
        "bedrock_model": os.getenv("BEDROCK_MODEL_ID", "us.amazon.nova-pro-v1:0"),
    }


@app.get("/health")
async def health() -> dict[str, Any]:
    """Liveness and readiness probe.

    Returns Vault authentication status so Kubernetes can surface auth failures
    in pod readiness without requiring a full query round-trip.

    The probe re-authenticates the same way a real request does. Inspecting only
    the cached token reported "degraded" once its finite TTL elapsed — on an
    agent that was fully serviceable, because /query calls ensure_authenticated()
    and silently re-logs in. So the probe now exercises that same path: a merely
    stale token re-logs in and reports healthy, while a Vault that is genuinely
    unreachable or a broken role fails the login and reports degraded.

    Always answers HTTP 200 — the status field carries the verdict. Raising here
    would fail the liveness probe and restart-loop the pod whenever Vault is
    briefly unavailable, which fixes nothing.
    """
    authenticated = False
    if _vault:
        try:
            _vault.ensure_authenticated()
            authenticated = _vault.is_authenticated()
        except Exception:  # noqa: BLE001 — probe must never raise; see docstring
            logger.warning("health_vault_reauth_failed", exc_info=True)
    status = "healthy" if authenticated else "degraded"
    return {
        "status": status,
        "vault_authenticated": authenticated,
        "vault_addr": os.getenv("VAULT_ADDR", ""),
        "vault_role": os.getenv("VAULT_ROLE", "uc1-agent"),
    }


@app.post("/query", response_model=QueryResponse)
async def query(request: QueryRequest, http_request: Request) -> Any:
    """Invoke the UC1 Strands agent with a natural-language question.

    The agent may call query_database and/or retrieve_from_knowledge_base
    depending on the question. Each tool call fetches fresh JIT credentials
    from Vault (OBJ-2). The response includes credential_metadata for OBJ-5
    audit correlation exercises.

    Two reply formats, chosen by the Accept header:
      - `Accept: text/event-stream` — Server-Sent Events: each step the agent
        takes, as it happens, then the answer (see _stream_turn).
      - anything else — the QueryResponse JSON below, unchanged.

    Args:
        request: JSON body with a ``query`` string field.

    Returns:
        QueryResponse with answer text, KB source passages, and credential metadata.
    """
    if not _ready:
        raise HTTPException(status_code=503, detail="Agent not initialized")

    vault_role = os.getenv("VAULT_ROLE", "uc1-agent")
    # Correlation id of this turn: in every streamed event and in these log lines.
    request_id = str(uuid.uuid4())

    logger.info(
        f'"query_received" request_id="{request_id}" query_preview="{request.query[:80]}"',
    )

    if _wants_event_stream(http_request):
        return StreamingResponse(
            _stream_turn(request.query, request_id, vault_role),
            media_type="text/event-stream",
            headers={
                "Cache-Control": "no-cache",
                "Connection": "keep-alive",
                "X-Accel-Buffering": "no",
            },
        )

    # Bind a fresh per-request sink BEFORE invoking the agent: query_database
    # appends the lease of every JIT credential it issues. Reset in the finally
    # so the binding never outlives the request on a reused uvicorn task.
    # asyncio.to_thread copies this context into the worker thread, so the
    # tools append to THIS request's list.
    ctx_token = _ISSUED_CREDENTIALS.set([])
    try:
        # Off the event loop: a blocking call here held every other request —
        # including /health — until this answer was finished.
        outcome = await asyncio.to_thread(run_uc1_turn, request.query)
        answer = _clean_answer(outcome.result)
        # The knowledge-base passages the answer was written from (see kb_passages).
        sources = outcome.sources
        leases = [VaultLease(**issued) for issued in (_ISSUED_CREDENTIALS.get() or [])]
    except Exception as exc:
        logger.error(f'"query_error" error="{exc}"')
        raise HTTPException(status_code=500, detail=f"Agent error: {exc}") from exc
    finally:
        _ISSUED_CREDENTIALS.reset(ctx_token)

    logger.info(
        f'"query_complete" request_id="{request_id}" source_count={len(sources)} lease_count={len(leases)}'
    )

    return QueryResponse(
        answer=answer,
        sources=sources,
        credential_metadata=CredentialMetadata(
            vault_authenticated=await asyncio.to_thread(_vault.is_authenticated),
            vault_role=vault_role,
            leases=leases,
        ),
    )


# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    uvicorn.run(
        app,
        host="0.0.0.0",  # noqa: S104 — intentional; pod network only
        port=int(os.getenv("PORT", "8080")),
        log_level="info",
    )
