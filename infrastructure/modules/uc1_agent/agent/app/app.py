"""FastAPI HTTP wrapper for the UC1 Strands agent.

Exposes three endpoints:
  POST /query   — invoke the agent with a natural-language question
  GET  /health  — liveness/readiness probe (includes Vault token validity)
  GET  /        — welcome message describing the agent's role

Credential metadata (Vault lease_id, ttl) is returned in /query responses so
attendees can correlate agent actions back to the Vault audit log (OBJ-5).
"""

import logging
import logging.config
import os
from contextlib import asynccontextmanager
from typing import Any

import uvicorn
from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from strands import Agent

from .agent import build_uc1_agent, _vault

# ---------------------------------------------------------------------------
# Structured JSON logging — matches Vault audit log timestamp format.
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format='{"time": "%(asctime)s", "level": "%(levelname)s", "logger": "%(name)s", "message": %(message)s}',
)
logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Application lifespan — build agent once at startup.
# ---------------------------------------------------------------------------
_agent: Agent | None = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    global _agent
    logger.info('"uc1_agent_startup_begin"')
    _agent = build_uc1_agent()
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


class CredentialMetadata(BaseModel):
    vault_authenticated: bool
    vault_role: str


class QueryResponse(BaseModel):
    answer: str
    sources: list[str]
    credential_metadata: CredentialMetadata


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------


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
    """
    authenticated = _vault.is_authenticated() if _vault else False
    status = "healthy" if authenticated else "degraded"
    return {
        "status": status,
        "vault_authenticated": authenticated,
        "vault_addr": os.getenv("VAULT_ADDR", ""),
        "vault_role": os.getenv("VAULT_ROLE", "uc1-agent"),
    }


@app.post("/query", response_model=QueryResponse)
async def query(request: QueryRequest) -> QueryResponse:
    """Invoke the UC1 Strands agent with a natural-language question.

    The agent may call query_database and/or retrieve_from_knowledge_base
    depending on the question. Each tool call fetches fresh JIT credentials
    from Vault (OBJ-2). The response includes credential_metadata for OBJ-5
    audit correlation exercises.

    Args:
        request: JSON body with a ``query`` string field.

    Returns:
        QueryResponse with answer text, KB source passages, and credential metadata.
    """
    if _agent is None:
        raise HTTPException(status_code=503, detail="Agent not initialized")

    vault_role = os.getenv("VAULT_ROLE", "uc1-agent")

    logger.info(
        f'"query_received" query_preview="{request.query[:80]}"',
    )

    try:
        result = _agent(request.query)
        answer = str(result)
    except Exception as exc:
        logger.error(f'"query_error" error="{exc}"')
        raise HTTPException(status_code=500, detail=f"Agent error: {exc}") from exc

    # Extract KB source passages from tool results if available.
    sources: list[str] = []
    if hasattr(result, "tool_results"):
        for tr in result.tool_results:
            if isinstance(tr, list):
                sources.extend([str(s) for s in tr])

    logger.info(f'"query_complete" source_count={len(sources)}')

    return QueryResponse(
        answer=answer,
        sources=sources,
        credential_metadata=CredentialMetadata(
            vault_authenticated=_vault.is_authenticated(),
            vault_role=vault_role,
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
