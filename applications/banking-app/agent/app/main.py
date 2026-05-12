"""main.py — FastAPI application for the UC2 banking agent.

Exposes:
  POST /chat    — Accept user message + JWT, stream agent response via SSE
  GET  /health  — Liveness probe for Kubernetes

Security flow per request:
  1. Extract JWT from Authorization: Bearer header.
  2. Set the JWT in the request context (agent.set_request_jwt).
  3. Invoke the Strands agent — it calls get_accounts/get_transactions tools.
  4. Each tool forwards the JWT to the MCP server.
  5. MCP server authenticates to Vault with the JWT and fetches per-user DB creds.
  6. Stream agent response back as Server-Sent Events.

The agent pod's workload identity (Vault K8s auth) is established at startup.
The user's identity (JWT) is established per-request and never stored.
"""

import json
import logging
import os
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

from .agent import build_uc2_agent, set_request_jwt
from .vault_client import build_agent_vault_client

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logger = logging.getLogger(__name__)

_agent = None
_vault_client = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    """FastAPI lifespan — authenticate agent workload identity at startup."""
    global _agent, _vault_client

    # Establish agent workload identity via Vault Kubernetes auth (OBJ-1)
    _vault_client = build_agent_vault_client()
    try:
        _vault_client.login()
        logger.info("agent_vault_auth_success", extra={"auth_method": "kubernetes"})
    except Exception as exc:
        # Non-fatal in development (no K8s SA token mount outside cluster)
        logger.warning("agent_vault_auth_skipped", extra={"reason": str(exc)})

    # Build the Strands agent with Bedrock Nova Pro
    _agent = build_uc2_agent()

    yield

    logger.info("agent_shutdown")


app = FastAPI(
    title="CDL Bank Agent — UC2",
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

    Extracts the user JWT from Authorization: Bearer header and sets it
    in the request context before invoking the agent. The JWT is forwarded
    to MCP tool calls — the agent never stores or discloses it.
    """
    if _agent is None:
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

    # Set JWT in request context for tool calls
    set_request_jwt(jwt)

    message = body.message

    async def generate():
        try:
            # Yield a planning message
            yield f"data: {json.dumps({'role': 'ai', 'content': 'Processing your request...', 'type': 'tool_planning'})}\n\n"

            # Invoke the Strands agent
            response = _agent.invoke(message)

            # Stream the response
            content = str(response)
            yield f"data: {json.dumps({'role': 'ai', 'content': content, 'type': 'delta'})}\n\n"
            yield f"data: {json.dumps({'type': 'end'})}\n\n"

        except Exception as exc:
            logger.error("agent_error", extra={"error": str(exc), "message": message})
            yield f"data: {json.dumps({'type': 'error', 'content': str(exc)})}\n\n"
            yield f"data: {json.dumps({'type': 'end'})}\n\n"
        finally:
            # Clear JWT from request context
            set_request_jwt("")

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
    """Liveness probe — confirms agent and Vault client are initialized."""
    return {
        "status": "ok",
        "service": "banking-agent",
        "agent_ready": _agent is not None,
        "vault_authenticated": _vault_client.is_authenticated() if _vault_client else False,
    }
