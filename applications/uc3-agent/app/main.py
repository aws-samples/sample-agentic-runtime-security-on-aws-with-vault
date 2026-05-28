"""main.py — FastAPI application for the UC3 privileged-action agent.

Exposes:
  POST /chat    — Accept user message + sessionId, invoke agent, return SSE response
  GET  /health  — Liveness probe for Kubernetes

Session management:
  Each request builds a fresh Agent with fresh Vault STS creds (no expiry).
  Conversation history is persisted/loaded automatically via Strands
  FileSessionManager keyed on sessionId.

Env vars consumed (set via Kubernetes ConfigMap):
  VAULT_ADDR           — Vault endpoint
  VAULT_ROLE           — Vault K8s auth role (default: uc3)
  IVIA_BASE_URL        — IVIA base URL for OAuth/CIBA endpoints
  IVIA_CLIENT_ID       — OAuth client ID registered in IVIA
  IVIA_CLIENT_SECRET   — OAuth client secret
  DB_HOST              — PostgreSQL host
  DB_PORT              — PostgreSQL port (default: 5432)
  DB_NAME              — PostgreSQL database name (default: workshop)
  BEDROCK_MODEL_ID     — Bedrock model ID (default: us.amazon.nova-pro-v1:0)
  REGION               — AWS region (default: us-west-2)
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

from . import ciba_store
from .agent import build_uc3_agent
from .vault_client import UC3VaultClient
from .auth import verify_id_token, _AUTHENTICATED_SUB, AuthenticationError

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logger = logging.getLogger(__name__)

_vault_client = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    """FastAPI lifespan — authenticate agent workload identity at startup."""
    global _vault_client

    vault_addr = os.getenv("VAULT_ADDR", "http://vault.vault.svc.cluster.local:8200")
    vault_role = os.getenv("VAULT_ROLE", "uc3")

    _vault_client = UC3VaultClient(vault_addr=vault_addr, vault_role=vault_role)

    try:
        _vault_client.login()
        logger.info("uc3_vault_k8s_auth_success")
    except Exception as exc:
        logger.warning("uc3_vault_k8s_auth_skipped: %s", str(exc))

    yield

    logger.info("uc3_agent_shutdown")


app = FastAPI(
    title="OscarVault Agent — UC3",
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
    sessionId: str = "default"


@app.post("/chat")
async def chat(request: Request, body: ChatRequest):
    """Accept a user message and return an SSE agent response.

    Identity boundary: extracts the IVIA-issued id_token from
    `Authorization: Bearer <id_token>`, verifies it cryptographically (sig +
    iss + aud + exp, RS256 allowlist) via `auth.verify_id_token`, and sets the
    request-scoped `_AUTHENTICATED_SUB` ContextVar to the verified `sub` claim
    BEFORE invoking the Strands agent. The to_thread worker propagates the
    contextvars Context to the worker thread, so downstream refund tools can
    read `_AUTHENTICATED_SUB.get()` to learn the authenticated user — identity
    NEVER flows in as an LLM-controllable parameter (OBJ-3).

    Failure modes:
      - 503: vault client not initialized / re-auth failed (infra fault).
      - 401: Authorization header missing / malformed / empty token / id_token
        verification failed. Response body is GENERIC — the structured warning
        in `auth.py` records the actual failure category.

    Builds a fresh Agent per request with:
      - Fresh Vault STS creds (never expired)
      - FileSessionManager loads/saves conversation history by sessionId
    """
    if _vault_client is None:
        raise HTTPException(status_code=503, detail="UC3 agent not initialized")

    if not _vault_client.is_authenticated():
        try:
            _vault_client.login()
            logger.info("uc3_vault_k8s_reauth_success")
        except Exception as exc:
            raise HTTPException(status_code=503, detail=f"Vault re-auth failed: {exc}")

    # Identity boundary — extract + verify the IVIA id_token BEFORE building
    # the agent. 401 responses are kept generic to avoid info leak about which
    # claim failed; the structured log in auth.py carries the failure reason.
    auth_header = request.headers.get("Authorization", "")
    if not auth_header.lower().startswith("bearer "):
        raise HTTPException(
            status_code=401,
            detail="Authorization: Bearer <id_token> header required",
        )
    id_token = auth_header[7:].strip()
    if not id_token:
        raise HTTPException(status_code=401, detail="Empty id_token in Authorization header")

    try:
        verified_sub = verify_id_token(id_token)
    except AuthenticationError as exc:
        raise HTTPException(status_code=401, detail="id_token verification failed") from exc

    agent = build_uc3_agent(vault_client=_vault_client, session_id=body.sessionId)
    message = body.message

    async def generate():
        # Bind the verified sub for the entire SSE stream lifetime. The set
        # MUST happen before the to_thread(agent, message) call below —
        # to_thread uses contextvars.copy_context() so the worker thread (and the Strands
        # tool callbacks running in it) inherit this value. Reset in finally
        # so the ContextVar is unbound before the request task is reused for
        # another caller on the same uvicorn worker (defense in depth).
        ctx_token = _AUTHENTICATED_SUB.set(verified_sub)
        try:
            yield f"data: {json.dumps({'role': 'ai', 'content': 'Processing your request...', 'type': 'tool_planning'})}\n\n"
            try:
                response = await asyncio.to_thread(agent, message)
                content = re.sub(r'<thinking>.*?</thinking>\s*', '', str(response), flags=re.DOTALL)

                yield f"data: {json.dumps({'role': 'ai', 'content': content, 'type': 'delta'})}\n\n"
                yield f"data: {json.dumps({'type': 'end'})}\n\n"

            except Exception as exc:
                logger.error("uc3_agent_error: %s | user_message: %s", str(exc), message)
                yield f"data: {json.dumps({'type': 'error', 'content': str(exc)})}\n\n"
                yield f"data: {json.dumps({'type': 'end'})}\n\n"
        finally:
            _AUTHENTICATED_SUB.reset(ctx_token)

    return StreamingResponse(
        generate(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )


@app.post("/api/ciba/pending")
async def ciba_pending_push(request: Request):
    """Receive the CIBA consent URL pushed by the IVIA notifyuser mapping rule.

    notifyuser fires during bc-authorize and POSTs {auth_req_id, consent_url}.
    We stash it so initiate_refund (and the banking UI) can hand the user the
    real consent link without needing kubectl/log access to the internal txid.
    """
    try:
        data = await request.json()
    except Exception:
        data = {}
    auth_req_id = (data or {}).get("auth_req_id")
    consent_url = (data or {}).get("consent_url")
    if auth_req_id and consent_url:
        ciba_store.put(auth_req_id, consent_url)
        logger.info("ciba_consent_pushed", extra={"auth_req_id": auth_req_id})
        return {"stored": True}
    logger.warning("ciba_consent_push_incomplete: %s", data)
    return {"stored": False}


@app.get("/api/ciba/pending/{auth_req_id}")
async def ciba_pending_get(auth_req_id: str):
    """Return the consent URL notifyuser pushed for this auth_req_id (or null)."""
    return {"auth_req_id": auth_req_id, "consent_url": ciba_store.get(auth_req_id)}


@app.get("/health")
async def health():
    """Liveness probe — confirms Vault client is authenticated."""
    return {
        "status": "ok",
        "service": "uc3-agent",
        "vault_authenticated": _vault_client.is_authenticated() if _vault_client else False,
    }
