"""UC1 Strands agent — non-personalized read-only retrieval.

Demonstrates workload-identity-only access to Postgres + Bedrock KB.

This module defines two @tool-decorated functions that the Strands Agent calls:
  - query_database: issues JIT Postgres creds per request, runs SELECT, closes connection.
  - retrieve_from_knowledge_base: obtains ephemeral STS creds, calls Bedrock KB retrieve().

Both tools obtain credentials from Vault on each invocation so no standing
credentials exist in the pod's environment (OBJ-2). The module-level VaultClient
authenticates once at startup (pod lifecycle token cache) and renews via the K8s
SA JWT rotation projected by the Kubernetes token controller (OBJ-1).
"""

import json
import logging
import os
import threading
from contextvars import ContextVar
from typing import Any

import psycopg2
import psycopg2.extras
from strands import Agent, tool
from strands.agent import AgentResult
from strands.hooks import AfterToolCallEvent, BeforeToolCallEvent, HookProvider, HookRegistry
from strands.models import BedrockModel
from strands.types.tools import ToolContext

from . import activity
from .vault_client import VaultClient, _build_default_client

logger = logging.getLogger(__name__)

# Request-scoped record of the Vault credentials issued while serving one
# /query. A ContextVar — NOT a module global — so concurrent requests never read
# each other's leases; app.py binds a fresh list per request and resets it in a
# finally. Mirrors uc3-agent's _AUTHENTICATED_SUB ContextVar.
#
# The default None means "no request scope bound". The tools are also reachable
# outside an HTTP request — Use Case 1's "Verify Credentials and Enforcement"
# page drives _vault directly via kubectl exec — and recording must no-op there
# rather than raise.
_ISSUED_CREDENTIALS: ContextVar[list[dict] | None] = ContextVar(
    "uc1_issued_credentials", default=None
)


def _record_issuance(vault_path: str, creds: dict) -> None:
    """Record one Vault credential issuance for the in-flight request.

    Captures only audit-correlatable metadata: the lease id exactly as Vault
    spelled it, and its TTL. NEVER the username or password — this record is
    serialized into the /query response body and the streamed events.
    """
    lease = {
        "vault_path": vault_path,
        "lease_id": creds["lease_id"],
        "ttl_seconds": creds["lease_duration"],
    }
    activity.narrate(
        f"Vault issued a short-lived database credential for this question "
        f"({vault_path}, lease {lease['lease_id']}, {lease['ttl_seconds']}s)."
    )
    sink = _ISSUED_CREDENTIALS.get()
    if sink is None:
        return
    sink.append(lease)


def _describe_identity(identity: dict) -> str:
    """'my Kubernetes service account X (Vault role Y)', from Vault's own login metadata."""
    account = identity.get("service_account_name")
    role = identity.get("role") or os.getenv("VAULT_ROLE", "uc1-agent")
    if account:
        return f"my Kubernetes service account {account} (Vault role {role})"
    return f"my Kubernetes service account (Vault role {role})"


def _narrate_vault_login(identity: dict) -> None:
    """Called by VaultClient after every successful login; silent outside a streamed request."""
    activity.narrate(
        f"No user is signed in. I authenticate to Vault as myself, using {_describe_identity(identity)}."
    )


def _narrate_kb_credentials(issued: dict) -> None:
    activity.narrate(
        "Vault issued short-lived AWS credentials for reading the knowledge base "
        f"({issued['vault_path']}, {issued['ttl_seconds']}s)."
    )


# Module-level VaultClient: authenticated once at startup.
# login() is called in init_uc1_model(), which runs during FastAPI startup.
_vault: VaultClient = _build_default_client(on_login=_narrate_vault_login)


@tool
def query_database(query: str) -> list[dict]:
    """Execute a read-only SQL query against the workshop Postgres database.

    Fetches JIT credentials from Vault for each call — no standing DB passwords.
    The Vault lease (and ephemeral DB user) expires when the connection closes.

    Args:
        query: SQL SELECT statement to execute.

    Returns:
        List of row dicts (column-name → value). Empty list on no results.
    """
    creds = _vault.get_db_credentials(role_name="uc1-readonly")
    _record_issuance("database/creds/uc1-readonly", creds)
    db_host = os.getenv("DB_HOST", "")
    db_port = int(os.getenv("DB_PORT", "5432"))
    db_name = os.getenv("DB_NAME", "workshop")

    logger.info(
        "db_query_start",
        extra={
            "vault_username": creds["username"],
            "lease_id": creds["lease_id"],
            "query_preview": query[:120],
        },
    )

    conn = psycopg2.connect(
        host=db_host,
        port=db_port,
        dbname=db_name,
        user=creds["username"],
        password=creds["password"],
    )
    try:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(query)
            rows = [dict(row) for row in cur.fetchall()]
    finally:
        conn.close()

    logger.info(
        "db_query_complete",
        extra={"row_count": len(rows), "lease_id": creds["lease_id"]},
    )
    return rows


@tool(context=True)
def retrieve_from_knowledge_base(query: str, tool_context: ToolContext) -> list[str]:
    """Retrieve relevant passages from the Bedrock Knowledge Base.

    Obtains ephemeral STS credentials from Vault on each call. The Bedrock
    bedrock-agent-runtime retrieve() API performs semantic search against the
    AOSS vector index and returns ranked text chunks.

    Args:
        query: Natural-language question or keyword string.

    Returns:
        List of text passages from the Knowledge Base, ordered by relevance.
    """
    # tool_context is injected by Strands and is not part of the tool spec the
    # model sees; it identifies this call so its sources reach the right
    # tool_call event when the model runs several calls at once.
    kb_region = os.getenv("KB_REGION", "")
    knowledge_base_id = os.getenv("KNOWLEDGE_BASE_ID", "")

    bedrock_session = _vault.get_bedrock_session(kb_region=kb_region, on_issued=_narrate_kb_credentials)
    client = bedrock_session.client("bedrock-agent-runtime", region_name=kb_region)

    logger.info(
        "kb_retrieve_start",
        extra={"knowledge_base_id": knowledge_base_id, "kb_region": kb_region},
    )

    response = client.retrieve(
        knowledgeBaseId=knowledge_base_id,
        retrievalQuery={"text": query},
        retrievalConfiguration={
            "vectorSearchConfiguration": {
                "numberOfResults": int(os.getenv("KB_MAX_RESULTS", "5")),
            }
        },
    )

    items = [item for item in response.get("retrievalResults", []) if item.get("content", {}).get("text")]
    results = [item["content"]["text"] for item in items]

    # The same passages, with the document each came from and its relevance
    # score, for the Sources card. The model still receives only `results`.
    activity.record_sources(
        tool_context.tool_use["toolUseId"],
        [
            {
                "document": ((item.get("location") or {}).get("s3Location") or {}).get("uri"),
                "score": item.get("score"),
                "text": item["content"]["text"],
            }
            for item in items
        ],
    )

    logger.info(
        "kb_retrieve_complete",
        extra={"result_count": len(results), "knowledge_base_id": knowledge_base_id},
    )
    return results


# The Bedrock model, built once at startup by init_uc1_model() and shared by
# every request's Agent. Sharing it is safe: BedrockModel.stream keeps its
# queue and worker thread local to each call, and the boto3 client it wraps is
# backed by thread-safe RefreshableCredentials.
_model: BedrockModel | None = None


def init_uc1_model() -> None:
    """Sign in to Vault once and build the shared Bedrock model (pod startup).

    Performs one-time Vault Kubernetes auth (OBJ-1) and builds a BedrockModel
    using Amazon Nova Pro via CRIS profile (us.amazon.nova-pro-v1:0), backed by
    a Vault-issued STS session for the model invocation plane (primary region,
    from the REGION env var). That session is for model invocations only; each
    tool call independently fetches its own ephemeral credentials from Vault.
    """
    global _model

    # Authenticate once at startup; token is cached for the pod's lifetime.
    _vault.login()

    region = os.getenv("REGION", "")
    model_id = os.getenv("BEDROCK_MODEL_ID", "us.amazon.nova-pro-v1:0")

    # Obtain an STS session for the model invocation plane (primary region).
    bedrock_session = _vault.get_bedrock_session(kb_region=region)

    _model = BedrockModel(
        model_id=model_id,
        boto_session=bedrock_session,
    )
    logger.info(
        "uc1_model_ready",
        extra={"model_id": model_id, "region": region, "kb_region": os.getenv("KB_REGION", "")},
    )


# A query_database result can be any number of rows; the event that reports it
# carries at most this many, so one frame never outgrows what the UI's filter
# accepts. row_count still reports the full number.
_MAX_ROWS_IN_EVENT = 50


def _tool_output_text(result: dict | None) -> str:
    """The text a tool handed back to the model (Strands wraps it in content blocks)."""
    blocks = (result or {}).get("content") or []
    return "\n".join(b["text"] for b in blocks if isinstance(b, dict) and isinstance(b.get("text"), str))


class _ActivityHooks(HookProvider):
    """Reports every tool call as a tool_call event: once when it starts, once when it ends.

    Stateless and shared: the request an event belongs to is looked up through
    the activity ContextVar at the moment the callback fires (in a Strands
    worker thread), never held on this object.
    """

    def register_hooks(self, registry: HookRegistry, **kwargs: Any) -> None:
        registry.add_callback(BeforeToolCallEvent, self._started)
        registry.add_callback(AfterToolCallEvent, self._finished)

    @staticmethod
    def _started(event: BeforeToolCallEvent) -> None:
        tool_use = event.tool_use
        activity.emit(
            {
                "type": "tool_call",
                "toolCallId": tool_use["toolUseId"],
                "name": tool_use["name"],
                "status": "in_progress",
                "args": tool_use.get("input"),
            }
        )

    @staticmethod
    def _finished(event: AfterToolCallEvent) -> None:
        turn = activity.current()
        if turn is None:
            return
        tool_use = event.tool_use
        tool_use_id = tool_use["toolUseId"]
        sources = turn.sources.pop(tool_use_id, None)
        text = _tool_output_text(event.result)
        failed = (
            event.exception is not None
            or event.cancel_message is not None
            or (event.result or {}).get("status") == "error"
        )

        result: Any
        if failed:
            result = {"error": (event.cancel_message or text)[:1000]}
        elif sources is not None:
            result = {"sources": sources}
        else:
            try:
                output = json.loads(text)
            except ValueError:
                output = text[:4000]
            if tool_use["name"] == "query_database" and isinstance(output, list):
                result = {"row_count": len(output), "rows": output[:_MAX_ROWS_IN_EVENT]}
            else:
                result = {"output": output}

        payload: dict[str, Any] = {
            "type": "tool_call",
            "toolCallId": tool_use_id,
            "name": tool_use["name"],
            "status": "error" if failed else "success",
            "result": result,
        }
        if event.duration is not None:
            payload["durationMs"] = round(event.duration * 1000)
        activity.emit(payload)


_ACTIVITY_HOOKS = _ActivityHooks()


def build_uc1_agent() -> Agent:
    """Construct a fresh UC1 Strands Agent for ONE request.

    A new Agent per request, never one shared Agent, because Strands 1.57.0:
      - raises ConcurrencyException when a second request invokes an Agent that
        is still answering the first (Agent.__init__ defaults
        concurrent_invocation_mode to THROW; stream_async refuses the lock), and
      - appends every turn to agent.messages, so a shared Agent sends each
        visitor's question to the model together with the previous visitors'
        questions, tool output and answers.
    The Agent is cheap to build; the Vault login and the Bedrock model are
    shared (see init_uc1_model).

    Returns:
        Configured strands.Agent with query_database + retrieve_from_knowledge_base.
    """
    if _model is None:
        raise RuntimeError("init_uc1_model() has not run")

    system_prompt = (
        "You are a workshop demonstration agent for the Agentic Runtime Security on AWS workshop. "
        "You operate in Use Case 1 (non-personalized read-only mode): you have NO user identity context — "
        "all database and knowledge base access uses workload-identity-only (Kubernetes Service Account) credentials. "
        "Your capabilities: "
        "(1) query_database — run read-only SQL against the workshop Postgres database using Just-In-Time Vault credentials; "
        "(2) retrieve_from_knowledge_base — semantic search against the Bedrock Knowledge Base using ephemeral STS credentials. "
        "Never state, invent or restate credential identifiers — lease IDs, TTLs, usernames or passwords — in your "
        "answer. You are never given them, and an invented one reads as authoritative. The runtime attaches the real "
        "Vault lease metadata to the response's credential_metadata field, which is what OBJ-5 audit correlation uses. "
        "Never request, store, or disclose user-identifying information — this use case is intentionally non-personalized."
    )

    return Agent(
        model=_model,
        tools=[query_database, retrieve_from_knowledge_base],
        system_prompt=system_prompt,
        hooks=[_ACTIVITY_HOOKS],
    )


def run_uc1_turn(query: str, cancel_signal: threading.Event | None = None) -> AgentResult:
    """Answer one /query. Blocking — the caller runs it in asyncio.to_thread.

    First confirms the agent's own Vault login, so a streamed request can say
    truthfully whether it signed in again or reused its login, then runs a
    fresh Agent. `cancel_signal` stops the Agent at its next checkpoint (set
    when a streaming visitor disconnects).
    """
    try:
        if not _vault.ensure_authenticated():
            activity.narrate(
                "No user is signed in. I am already authenticated to Vault as myself, using "
                f"{_describe_identity(_vault.identity)}, so I reuse that login."
            )
    except Exception as exc:  # noqa: BLE001 — each tool checks the login again itself
        logger.warning("turn_vault_check_failed", exc_info=True)
        activity.narrate(f"I could not confirm my Vault login ({type(exc).__name__}); each tool will try again.")
    return build_uc1_agent()(query, cancel_signal=cancel_signal)
