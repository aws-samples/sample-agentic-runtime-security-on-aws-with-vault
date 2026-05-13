"""main.py — FastAPI application for the UC3 privileged-action agent.

Exposes:
  POST /chat    — Accept user message + session_id, invoke agent, return JSON response
  GET  /health  — Liveness probe for Kubernetes

Security flow per request:
  1. Receive user message.
  2. Agent generates request_id UUID for the refund flow.
  3. Agent executes CIBA backchannel auth → user consent → CIBA token poll.
  4. Agent performs RFC 8693 token exchange → delegated JWT.
  5. Agent presents delegated JWT to Vault jwt auth → uc3-refund-writer DB creds.
  6. Agent INSERTs into banking.refunds with request_id threaded through.

The agent pod's workload identity (Vault K8s auth, role "uc3") is established
at startup. Per-refund Vault jwt auth uses the delegated JWT with may_act claim.

Env vars consumed (set via Kubernetes ConfigMap):
  VAULT_ADDR           — Vault endpoint (e.g. http://vault.vault.svc.cluster.local:8200)
  VAULT_ROLE           — Vault K8s auth role for agent workload identity (default: uc3)
  IVIA_BASE_URL        — IVIA base URL for OAuth/CIBA endpoints
  IVIA_CLIENT_ID       — OAuth client ID registered in IVIA
  IVIA_CLIENT_SECRET   — OAuth client secret
  DB_HOST              — PostgreSQL host
  DB_PORT              — PostgreSQL port (default: 5432)
  DB_NAME              — PostgreSQL database name (default: workshop)
  BEDROCK_MODEL_ID     — Bedrock model ID (default: us.amazon.nova-pro-v1:0)
  REGION               — AWS region (default: us-west-2)
"""

import json
import logging
import os
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

from .agent import build_uc3_agent
from .vault_client import UC3VaultClient

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

    vault_addr = os.getenv("VAULT_ADDR", "http://vault.vault.svc.cluster.local:8200")
    vault_role = os.getenv("VAULT_ROLE", "uc3")

    _vault_client = UC3VaultClient(vault_addr=vault_addr, vault_role=vault_role)

    try:
        _vault_client.login()
        logger.info("uc3_vault_k8s_auth_success")
    except Exception as exc:
        # Non-fatal outside cluster (no SA token mount in local dev)
        logger.warning("uc3_vault_k8s_auth_skipped: %s", str(exc))

    _agent = build_uc3_agent(vault_client=_vault_client)

    yield

    logger.info("uc3_agent_shutdown")


app = FastAPI(
    title="CDL Bank Agent — UC3",
    description="Privileged-action agent with CIBA + RFC 8693 token exchange + Vault jwt auth",
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
    session_id: str = "default"


@app.post("/chat")
async def chat(body: ChatRequest):
    """Accept a user message and return a JSON agent response.

    The agent handles CIBA consent flow, token exchange, and privileged DB write
    internally. The response includes the agent output and the request_id for
    audit correlation.
    """
    global _agent
    if _agent is None:
        raise HTTPException(status_code=503, detail="UC3 agent not initialized")

    message = body.message

    async def generate():
        try:
            yield f"data: {json.dumps({'role': 'ai', 'content': 'Processing your request...', 'type': 'tool_planning'})}\n\n"

            response = _agent(message)
            content = str(response)

            yield f"data: {json.dumps({'role': 'ai', 'content': content, 'type': 'delta'})}\n\n"
            yield f"data: {json.dumps({'type': 'end'})}\n\n"

        except Exception as exc:
            logger.error("uc3_agent_error: %s | user_message: %s", str(exc), message)
            yield f"data: {json.dumps({'type': 'error', 'content': str(exc)})}\n\n"
            yield f"data: {json.dumps({'type': 'end'})}\n\n"

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
    """Liveness probe — confirms UC3 agent and Vault client are initialized."""
    return {
        "status": "ok",
        "service": "uc3-agent",
        "agent_ready": _agent is not None,
        "vault_authenticated": _vault_client.is_authenticated() if _vault_client else False,
    }
