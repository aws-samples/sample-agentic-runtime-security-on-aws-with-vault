"""main.py — FastAPI application for the UC2 banking agent.

Exposes:
  POST /chat    — Accept user message + JWT, stream agent response via SSE
  GET  /health  — Liveness probe for Kubernetes

Security flow per request:
  1. Extract JWT from Authorization: Bearer header.
  2. Build a FRESH Strands agent (empty history) from the shared model.
  3. Bind the JWT to the request via the _REQUEST_JWT ContextVar.
  4. Invoke the agent in a worker thread — it calls get_accounts/get_transactions.
  5. Each tool forwards the JWT to the MCP server.
  6. MCP server authenticates to Vault with the JWT and fetches per-user DB creds.
  7. Stream agent response back as Server-Sent Events; reset the ContextVar.

The agent pod's workload identity (Vault K8s auth) and the shared Bedrock model
are established once at startup. The user's identity (JWT) and the agent itself
are per-request — never shared across users — so one caller's banking data can
never reach another caller.
"""

import asyncio
import json
import logging
import os
import re
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

from .agent import build_uc2_agent, build_uc2_model, _REQUEST_JWT
from .vault_client import build_agent_vault_client

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logger = logging.getLogger(__name__)

_model = None
_vault_client = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    """FastAPI lifespan — authenticate agent workload identity at startup."""
    global _model, _vault_client

    # Establish agent workload identity via Vault Kubernetes auth (OBJ-1)
    _vault_client = build_agent_vault_client()
    try:
        _vault_client.login()
        logger.info("agent_vault_auth_success", extra={"auth_method": "kubernetes"})
    except Exception as exc:
        # Non-fatal in development (no K8s SA token mount outside cluster)
        logger.warning("agent_vault_auth_skipped", extra={"reason": str(exc)})

    # Build the SHARED Bedrock model with Vault-issued STS credentials (OBJ-2).
    # The model carries no per-user state; each /chat builds a fresh Agent on top
    # of it (the per-user isolation boundary).
    _model = build_uc2_model(vault_client=_vault_client if _vault_client and _vault_client.is_authenticated() else None)

    yield

    logger.info("agent_shutdown")


app = FastAPI(
    title="OscarVault Agent — UC2",
    description="Personalized banking agent with OAuth + Vault JWT auth",
    version="1.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


class ChatRequest(BaseModel):
    message: str
    sessionId: str = "default"


@app.post("/chat")
async def chat(request: Request, body: ChatRequest):
    """Accept a user message and return an SSE stream of agent responses.

    Extracts the user JWT from Authorization: Bearer header, builds a FRESH
    agent for this request, and binds the JWT to the request-scoped _REQUEST_JWT
    ContextVar before invoking the agent in a worker thread. A per-request agent
    (empty conversation history) plus a request-scoped JWT mean one caller's
    banking data can never reach another caller. The JWT is forwarded to MCP
    tool calls — the agent never persists or discloses it.
    """
    global _model
    if _model is None:
        raise HTTPException(status_code=503, detail="Agent not initialized")

    # Extract user JWT from Authorization header
    auth_header = request.headers.get("Authorization", "")
    if not auth_header.lower().startswith("bearer "):
        raise HTTPException(
            status_code=401,
            detail="Authorization: Bearer <jwt> header required",
        )

    jwt = auth_header[7:].strip()
    if not jwt:
        raise HTTPException(status_code=401, detail="Empty JWT in Authorization header")

    # Build a FRESH agent for THIS request on top of the shared model. The
    # agent's (empty) conversation history is the cross-user isolation boundary:
    # a per-request agent can never serve a prior user's banking data to this
    # caller. The shared _model carries no user state — its Bedrock session uses
    # RefreshableCredentials, so botocore transparently re-mints the Vault STS
    # lease as it nears expiry (OBJ-2).
    agent = build_uc2_agent(_model)
    message = body.message

    async def generate():
        # Bind the user JWT for THIS request only. A ContextVar (not a module
        # global) keeps concurrent callers isolated; asyncio.to_thread copies the
        # context into the worker thread so the Strands tool callbacks read THIS
        # caller's JWT. Reset in finally so it never bleeds into the next request.
        ctx_token = _REQUEST_JWT.set(jwt)
        try:
            # Yield a planning message
            yield f"data: {json.dumps({'role': 'ai', 'content': 'Processing your request...', 'type': 'tool_planning'})}\n\n"

            # Invoke the Strands agent off the event loop; to_thread copies the
            # current context, so _REQUEST_JWT is visible to the tools it calls.
            response = await asyncio.to_thread(agent, message)

            # Stream the response. Strip any <thinking>...</thinking> chain-of-thought
            # the model emits so it never leaks into the chat UI (mirrors uc3-agent).
            content = re.sub(r'<thinking>.*?</thinking>\s*', '', str(response), flags=re.DOTALL)
            yield f"data: {json.dumps({'role': 'ai', 'content': content, 'type': 'delta'})}\n\n"
            yield f"data: {json.dumps({'type': 'end'})}\n\n"

        except Exception as exc:
            logger.error("agent_error: %s | user_message: %s", str(exc), message)
            yield f"data: {json.dumps({'type': 'error', 'content': str(exc)})}\n\n"
            yield f"data: {json.dumps({'type': 'end'})}\n\n"
        finally:
            # Unbind the JWT so the next request on this worker starts clean.
            _REQUEST_JWT.reset(ctx_token)

    return StreamingResponse(
        generate(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )


@app.get("/health")
async def health():
    """Liveness probe — confirms agent and Vault client are initialized.

    vault_authenticated re-authenticates the same way a real request does.
    Reading only the token cached at startup reported False once its finite TTL
    elapsed, on an agent that was serving normally — every credential fetch calls
    ensure_authenticated() and silently re-logs in.

    Never raises: this is the liveness probe, and failing it would restart-loop
    the pod whenever Vault was briefly unreachable.
    """
    vault_authenticated = False
    if _vault_client:
        try:
            _vault_client.ensure_authenticated()
            vault_authenticated = _vault_client.is_authenticated()
        except Exception:  # noqa: BLE001 — probe must never raise; see docstring
            logger.warning("health_vault_reauth_failed", exc_info=True)

    return {
        "status": "ok",
        "service": "banking-agent",
        "agent_ready": _model is not None,
        "vault_authenticated": vault_authenticated,
    }
