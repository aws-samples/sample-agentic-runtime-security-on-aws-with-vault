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
import time
from contextvars import ContextVar
from typing import Any, NamedTuple

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

    The lease record appended to the sink holds only audit-correlatable
    metadata: the lease id exactly as Vault spelled it, and its TTL. NEVER the
    username or password — that record is serialized into the /query JSON
    reply and the stream's agent:audit_seed. The login itself (username and
    password) goes only to a streamed request's own event queue, as one
    agent:credential event; it is never logged and never returned to the model.
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
    # The login itself, in full, for the streamed request only (queue, never a log).
    activity.credential(
        "db_credentials",
        "Short-lived database login Vault issued for this question",
        "Vault",
        fields={"username": creds["username"], "password": creds["password"]},
        vault_path=vault_path,
        lease_id=creds["lease_id"],
        ttl_seconds=creds["lease_duration"],
        expires_at=int((time.time() + creds["lease_duration"]) * 1000),
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


def _show_login_credentials(reused: bool) -> None:
    """Send the agent's own login credentials in full: the service-account JWT it
    presented to Vault and the Vault token it got back. Streamed requests only."""
    if activity.current() is None:
        return
    login = _vault.login_details()
    if login is None:
        return
    account = _vault.identity.get("service_account_name") or "my service account"
    role = _vault.identity.get("role") or os.getenv("VAULT_ROLE", "uc1-agent")
    claims = activity.jwt_claims(login["sa_jwt"])
    activity.credential(
        "k8s_sa_token",
        (
            f"The Kubernetes service-account token ({account}) my current Vault login was made with — "
            "reused this turn, not presented again"
            if reused
            else f"My Kubernetes service-account token ({account}), presented to Vault to sign in"
        ),
        "Kubernetes",
        value=login["sa_jwt"],
        claims=claims,
        expires_at=int(claims["exp"] * 1000) if claims and isinstance(claims.get("exp"), (int, float)) else None,
    )
    ttl = login["ttl_seconds"]
    activity.credential(
        "vault_token",
        (
            f"My Vault token from an earlier Kubernetes login (role {role}) — reused this turn"
            if reused
            else f"My Vault token from this Kubernetes login (role {role})"
        ),
        "Vault",
        value=login["vault_token"],
        ttl_seconds=ttl,
        expires_at=int((login["issued_at"] + ttl) * 1000) if ttl is not None and login["issued_at"] else None,
    )


def _narrate_vault_login(identity: dict) -> None:
    """Called by VaultClient after every successful login; silent outside a streamed request."""
    activity.narrate(
        f"No user is signed in. I authenticate to Vault as myself, using {_describe_identity(identity)}."
    )
    _show_login_credentials(reused=False)


def _show_sts_credentials(issued: dict, label: str) -> None:
    """The AWS keys themselves, in full, for the streamed request only (queue, never a log)."""
    activity.credential(
        "aws_sts_credentials",
        label,
        "AWS STS (via Vault)",
        fields={
            "access_key_id": issued["access_key_id"],
            "secret_access_key": issued["secret_access_key"],
            "session_token": issued["session_token"],
        },
        vault_path=issued["vault_path"],
        lease_id=issued.get("lease_id"),
        ttl_seconds=issued["ttl_seconds"],
        expires_at=int((time.time() + issued["ttl_seconds"]) * 1000),
    )


def _narrate_kb_credentials(issued: dict) -> None:
    activity.narrate(
        "Vault issued short-lived AWS credentials for reading the knowledge base "
        f"({issued['vault_path']}, {issued['ttl_seconds']}s)."
    )
    _show_sts_credentials(issued, "Short-lived AWS keys Vault issued for reading the knowledge base")


# Lease and timing of the latest issuance of the model's AWS keys, with the
# access key id they belong to, so a turn that reuses the keys can say which
# lease they came from. Never the secret key or the session token.
_model_keys_issuance: dict[str, Any] = {}
_model_keys_issuance_lock = threading.Lock()

# How many model-key issuances ran in the current context. A turn compares it
# before and after reading the keys to tell whether that read refreshed them.
_MODEL_KEYS_ISSUED_HERE: ContextVar[int] = ContextVar("uc1_model_keys_issued_here", default=0)


def _narrate_model_credentials(issued: dict) -> None:
    """The model's own AWS keys, issued at pod startup and refreshed by botocore
    when they near expiry. A refresh runs on the thread that reads the keys — a
    turn's first read of them (_show_model_keys) or the Bedrock call that signs
    with them — inside the turn that needed it, so it lands on that turn's
    stream. The startup issuance belongs to no request and stays silent."""
    with _model_keys_issuance_lock:
        _model_keys_issuance.clear()
        _model_keys_issuance.update(
            access_key_id=issued["access_key_id"],
            vault_path=issued["vault_path"],
            lease_id=issued.get("lease_id"),
            ttl_seconds=issued["ttl_seconds"],
            issued_at=time.time(),
        )
    _MODEL_KEYS_ISSUED_HERE.set(_MODEL_KEYS_ISSUED_HERE.get() + 1)
    activity.narrate(
        "Vault issued fresh short-lived AWS credentials for calling the model "
        f"({issued['vault_path']}, {issued['ttl_seconds']}s); my previous ones were about to expire."
    )
    _show_sts_credentials(
        issued, "Short-lived AWS keys Vault issued for calling the model, refreshed during this answer"
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

# The model's live AWS credentials: the botocore RefreshableCredentials its
# Bedrock client signs with (boto3 Session.get_credentials returns the session's
# own object, not a copy). Reading them always gives the keys in use right now.
_model_credentials: Any = None


def init_uc1_model() -> None:
    """Sign in to Vault once and build the shared Bedrock model (pod startup).

    Performs one-time Vault Kubernetes auth (OBJ-1) and builds a BedrockModel
    using Amazon Nova Pro via CRIS profile (us.amazon.nova-pro-v1:0), backed by
    a Vault-issued STS session for the model invocation plane (primary region,
    from the REGION env var). That session is for model invocations only; each
    tool call independently fetches its own ephemeral credentials from Vault.
    """
    global _model, _model_credentials

    # Authenticate once at startup; token is cached for the pod's lifetime.
    _vault.login()

    region = os.getenv("REGION", "")
    model_id = os.getenv("BEDROCK_MODEL_ID", "us.amazon.nova-pro-v1:0")

    # Obtain an STS session for the model invocation plane (primary region).
    # Its refreshes are shown on the stream of the turn that triggers them.
    bedrock_session = _vault.get_bedrock_session(kb_region=region, on_issued=_narrate_model_credentials)
    _model_credentials = bedrock_session.get_credentials()

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


def _show_model_keys() -> None:
    """Every streamed turn shows the AWS keys the model signs with, read live.

    get_frozen_credentials refreshes the keys first when they are near expiry
    (botocore credentials.py:663-698). If this read was that refresh, the keys
    have just been shown as "refreshed during this answer" and are not shown a
    second time as reused. The lease, TTL and expiry are sent only when the last
    recorded issuance belongs to these exact keys.
    """
    if activity.current() is None or _model_credentials is None:
        return
    issued_before = _MODEL_KEYS_ISSUED_HERE.get()
    keys = _model_credentials.get_frozen_credentials()
    if _MODEL_KEYS_ISSUED_HERE.get() != issued_before:
        return
    with _model_keys_issuance_lock:
        issuance = dict(_model_keys_issuance)
    same_keys = issuance.get("access_key_id") == keys.access_key
    ttl = issuance.get("ttl_seconds") if same_keys else None
    activity.narrate("I reuse the short-lived AWS keys Vault issued earlier for calling the model.")
    activity.credential(
        "aws_sts_credentials",
        "Short-lived AWS keys Vault issued for calling the model — reused this turn",
        "AWS STS (via Vault)",
        fields={
            "access_key_id": keys.access_key,
            "secret_access_key": keys.secret_key,
            "session_token": keys.token,
        },
        vault_path=issuance.get("vault_path") if same_keys else None,
        lease_id=issuance.get("lease_id") if same_keys else None,
        ttl_seconds=ttl,
        expires_at=int((issuance["issued_at"] + ttl) * 1000) if same_keys and ttl else None,
    )


_KB_TOOL = "retrieve_from_knowledge_base"


def kb_passages(messages: list[dict]) -> list[str]:
    """The passages the knowledge-base tool returned during one turn, in order.

    Read from the conversation the turn's Agent kept, because that is where
    Strands 1.57.0 puts tool results: AgentResult carries none
    (strands/agent/agent_result.py:36-42); each round's results become one user
    message of toolResult blocks (strands/event_loop/event_loop.py:918-921),
    appended to Agent.messages (event_loop.py:960); and a tool's list[str]
    return value is JSON-encoded into the block's content[0].text
    (strands/tools/decorator.py:703-715). Only successful calls to the
    knowledge-base tool count, matched to their toolUse by toolUseId, so
    query_database rows never land here.
    """
    kb_calls = {
        block["toolUse"]["toolUseId"]
        for message in messages
        if message.get("role") == "assistant"
        for block in message.get("content", [])
        if "toolUse" in block and block["toolUse"].get("name") == _KB_TOOL
    }
    passages: list[str] = []
    for message in messages:
        for block in message.get("content", []):
            tool_result = block.get("toolResult")
            if not tool_result or tool_result.get("toolUseId") not in kb_calls:
                continue
            if tool_result.get("status") != "success":
                continue
            for part in tool_result.get("content", []):
                text = part.get("text")
                if not isinstance(text, str):
                    continue
                try:
                    value = json.loads(text)
                except ValueError:
                    continue
                if isinstance(value, list):
                    passages.extend(item for item in value if isinstance(item, str))
    return passages


class TurnOutcome(NamedTuple):
    """One answered /query: what the Agent returned, and the knowledge-base
    passages it read to write the answer."""

    result: AgentResult
    sources: list[str]


def run_uc1_turn(query: str, cancel_signal: threading.Event | None = None) -> TurnOutcome:
    """Answer one /query. Blocking — the caller runs it in asyncio.to_thread.

    First confirms the agent's own Vault login, so a streamed request can say
    truthfully whether it signed in again or reused its login, and (streamed
    requests only) shows the model's AWS keys, then runs a fresh Agent.
    `cancel_signal` stops the Agent at its next checkpoint (set when a
    streaming visitor disconnects).
    """
    try:
        if not _vault.ensure_authenticated():
            activity.narrate(
                "No user is signed in. I am already authenticated to Vault as myself, using "
                f"{_describe_identity(_vault.identity)}, so I reuse that login."
            )
            _show_login_credentials(reused=True)
    except Exception as exc:  # noqa: BLE001 — each tool checks the login again itself
        logger.warning("turn_vault_check_failed", exc_info=True)
        activity.narrate(f"I could not confirm my Vault login ({type(exc).__name__}); each tool will try again.")
    try:
        _show_model_keys()
    except Exception as exc:  # noqa: BLE001 — the model call refreshes its keys again itself
        logger.warning("turn_model_keys_read_failed", extra={"error_type": type(exc).__name__})
        activity.narrate(
            f"I could not read my AWS keys for calling the model ({type(exc).__name__}); the model call will try again."
        )
    agent = build_uc1_agent()
    result = agent(query, cancel_signal=cancel_signal)
    return TurnOutcome(result=result, sources=kb_passages(agent.messages))
