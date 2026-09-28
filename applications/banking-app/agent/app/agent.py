"""agent.py — UC2 Strands banking agent with OAuth identity layer.

This agent is the bridge between the SvelteKit UI and the MCP server:

  Browser (user JWT in cookie)
    → UI server → POST /chat with JWT in Authorization header
      → Agent: extracts JWT, passes to MCP tools
        → MCP server: Vault jwt auth with JWT → per-user DB creds → RDS (RLS)

Security architecture:
  - Agent extracts the user JWT from the Authorization header on every /chat call.
  - JWT is forwarded to MCP tool calls as a parameter — agent never stores it.
  - Agent's OWN identity is established via Kubernetes SA JWT + Vault K8s auth (OBJ-1).
  - Agent never calls Vault for database credentials — that is the MCP server's job.
  - This separation ensures OBJ-3: actions are tied to the user's JWT-encoded identity.

Banking operations:
  - get_accounts: list accounts belonging to the authenticated user
  - get_transactions: list recent transactions for the user's accounts
"""

import contextvars
import json
import logging
import os
import re
from decimal import Decimal, InvalidOperation

import httpx
from strands import Agent, ToolContext, tool
from strands.models import BedrockModel

from . import activity

logger = logging.getLogger(__name__)

MCP_URL = os.getenv("MCP_URL", "http://banking-mcp.banking-app.svc.cluster.local:3001")


def _call_mcp_tool(tool_name: str, jwt: str, **kwargs: object) -> dict:
    """Call an MCP server tool, presenting the user JWT on the Authorization header.

    The JWT travels in the header ONLY. It used to be duplicated into the tool
    arguments, and the MCP server acted on that copy — so the token it
    authenticated and the token it used were different values and the header
    constrained nothing. The tools no longer accept a jwt argument at all, so
    there is no ignored field left for a caller to believe is honoured.
    """
    activity.report_mcp_call(tool_name, MCP_URL, jwt)

    payload = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": {
            "name": tool_name,
            "arguments": {**kwargs},
        },
    }

    with httpx.Client(timeout=30.0) as client:
        response = client.post(
            f"{MCP_URL}/mcp",
            json=payload,
            headers={
                "Content-Type": "application/json",
                "Accept": "application/json, text/event-stream",
                "Authorization": f"Bearer {jwt}",
            },
        )
        response.raise_for_status()
        return response.json()


# Request-scoped JWT store. A ContextVar — NOT a module global — so each
# concurrent /chat request (and the worker thread asyncio.to_thread copies the
# context into) sees ONLY its own caller's JWT. main.py sets it per request and
# resets it in a finally. Mirrors uc3-agent's _AUTHENTICATED_SUB ContextVar.
# A module global here let one caller's identity bleed into another's request
# under concurrency — half of the cross-user data leak this replaces.
_REQUEST_JWT: contextvars.ContextVar[str] = contextvars.ContextVar(
    "uc2_request_jwt", default=""
)


@tool
def get_accounts() -> list[dict]:
    """Retrieve bank accounts for the authenticated user.

    Calls the MCP server with the user's JWT. The MCP server authenticates
    to Vault using the JWT, receives per-user-scoped DB credentials, and
    queries PostgreSQL with RLS activated for this user's sub claim.

    Returns:
        List of account dicts with balance, account_type, currency.
    """
    jwt = _REQUEST_JWT.get()
    if not jwt:
        raise ValueError("No user JWT in request context — _REQUEST_JWT not set")

    result = _call_mcp_tool("get_accounts", jwt)

    mcp_result = result.get("result", {})
    content_blocks = mcp_result.get("content", [])

    if mcp_result.get("isError"):
        msg = content_blocks[0].get("text", "Unknown MCP error") if content_blocks else "Unknown MCP error"
        raise RuntimeError(msg)

    if content_blocks and content_blocks[0].get("type") == "text":
        parsed = json.loads(content_blocks[0]["text"])
        # The issued DB credential, the MCP server's own Vault token and the
        # service-account token its Vault login presented go to the turn's event
        # stream ONLY. They are taken out here so they can never reach the model
        # or a log line.
        issued = parsed.pop("issued_db_credentials", None)
        mcp_token = parsed.pop("mcp_vault_token", None)
        mcp_sa_token = parsed.pop("mcp_service_account_token", None)
        accounts = parsed.get("accounts", [])
        meta = parsed.get("credential_metadata", {})
        activity.report_credential_metadata("get_accounts", meta, issued)
        activity.report_mcp_service_account_token("get_accounts", mcp_sa_token)
        activity.report_mcp_vault_token("get_accounts", mcp_token)
        logger.info(
            "get_accounts_success",
            extra={
                "account_count": len(accounts),
                "vault_lease_id": meta.get("lease_id", "unknown"),
                "user_sub": meta.get("user_sub", "unknown"),
            },
        )
        return accounts

    return []


@tool(context=True)
def get_transactions(tool_context: ToolContext, account_id: str = "") -> list[dict]:
    """Retrieve recent transactions for the authenticated user.

    Calls the MCP server with the user's JWT. Optionally filters to
    a specific account_id. The MCP server applies Vault JWT auth and
    PostgreSQL RLS — only this user's transactions are returned.

    Args:
        account_id: Optional account ID to filter. Empty string = all accounts.

    Returns:
        List of transaction dicts (amount, description, transaction_type, created_at).
    """
    jwt = _REQUEST_JWT.get()
    if not jwt:
        raise ValueError("No user JWT in request context — _REQUEST_JWT not set")

    kwargs = {}
    if account_id:
        kwargs["account_id"] = account_id

    result = _call_mcp_tool("get_transactions", jwt, **kwargs)

    mcp_result = result.get("result", {})
    content_blocks = mcp_result.get("content", [])

    if mcp_result.get("isError"):
        msg = content_blocks[0].get("text", "Unknown MCP error") if content_blocks else "Unknown MCP error"
        raise RuntimeError(msg)

    if content_blocks and content_blocks[0].get("type") == "text":
        parsed = json.loads(content_blocks[0]["text"])
        # The issued DB credential, the MCP server's own Vault token and the
        # service-account token its Vault login presented go to the turn's event
        # stream ONLY. They are taken out here so they can never reach the model
        # or a log line.
        issued = parsed.pop("issued_db_credentials", None)
        mcp_token = parsed.pop("mcp_vault_token", None)
        mcp_sa_token = parsed.pop("mcp_service_account_token", None)
        transactions = parsed.get("transactions", [])
        meta = parsed.get("credential_metadata", {})
        activity.report_credential_metadata("get_transactions", meta, issued)
        activity.report_mcp_service_account_token("get_transactions", mcp_sa_token)
        activity.report_mcp_vault_token("get_transactions", mcp_token)
        logger.info(
            "get_transactions_success",
            extra={
                "transaction_count": len(transactions),
                "vault_lease_id": meta.get("lease_id", "unknown"),
                "user_sub": meta.get("user_sub", "unknown"),
                "account_filter": account_id or "all",
            },
        )
        _record_transactions(tool_context, transactions, account_filtered=bool(account_id))
        return transactions

    return []


# ---------------------------------------------------------------------------
# The reply under the transactions card, checked by code
#
# The chat shows get_transactions' rows as a card. The model writes the reply,
# so a specific question ("How much did I spend at Equinox?") still gets its
# answer. After the turn, checked_reply() compares that reply with the rows
# this turn's get_transactions calls returned. A reply that lists them again —
# a list or table whose items name those rows, or prose naming three or more
# of them — is replaced by a line built from the rows themselves ("Here are
# your 9 recent transactions from September 25, 2026."). get_accounts is not
# checked: an answer may name the accounts.
# ---------------------------------------------------------------------------

# invocation_state key: toolUseId -> what that get_transactions call returned.
# main.py passes each turn its own invocation_state and reads it back.
_TRANSACTIONS_SEEN = "uc2_transactions_seen"

_MONTHS = (
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December",
)
_DATE = re.compile(r"(\d{4})-(\d{2})-(\d{2})")


def _utc_date(created_at) -> str | None:
    """The date part of created_at ("2026-09-25T12:48:43.836Z" -> "2026-09-25"), as the card shows it."""
    match = _DATE.match(created_at) if isinstance(created_at, str) else None
    if match is None or not 1 <= int(match.group(2)) <= 12:
        return None
    return match.group(0)


def _plain_amount(value) -> str | None:
    """An amount as unsigned two-decimal text ("-88.30" -> "88.30"), or None when it is not a number."""
    try:
        amount = Decimal(str(value))
    except (InvalidOperation, ValueError):
        return None
    return str(abs(amount).quantize(Decimal("0.01"))) if amount.is_finite() else None


def _record_transactions(tool_context: ToolContext, transactions: list, account_filtered: bool) -> None:
    """Record, for this call only, the rows it returned: count, first and last date, and what names each row."""
    dates = [_utc_date(row.get("created_at")) if isinstance(row, dict) else None for row in transactions]
    known = all(dates) and bool(dates)
    tool_context.invocation_state.setdefault(_TRANSACTIONS_SEEN, {})[tool_context.tool_use["toolUseId"]] = {
        "count": len(transactions),
        "first_date": min(dates) if known else None,
        "last_date": max(dates) if known else None,
        "account_filtered": account_filtered,
        "rows": [
            {"description": row.get("description"), "amount": _plain_amount(row.get("amount"))}
            for row in transactions
            if isinstance(row, dict)
        ],
    }


def _long_date(iso_date: str, with_year: bool = True) -> str:
    year, month, day = iso_date.split("-")
    text = f"{_MONTHS[int(month) - 1]} {int(day)}"
    return f"{text}, {year}" if with_year else text


def _date_range(first: str, last: str) -> str:
    """The dates as text: "September 25, 2026", "September 20 to September 25, 2026", or both years."""
    if first == last:
        return _long_date(first)
    if first[:4] == last[:4]:
        return f"{_long_date(first, with_year=False)} to {_long_date(last)}"
    return f"{_long_date(first)} to {_long_date(last)}"


def transactions_reply(seen: dict) -> str:
    """The line under the transactions card, from one get_transactions call's record."""
    count = seen["count"]
    where = " on that account" if seen.get("account_filtered") else ""
    if count == 0:
        return f"You have no recent transactions{where}."
    text = f"Here is your 1 recent transaction{where}" if count == 1 else f"Here are your {count} recent transactions{where}"
    if seen.get("first_date") and seen.get("last_date"):
        text += " from " + _date_range(seen["first_date"], seen["last_date"])
    return text + "."


# A line that is a markdown list item or table row: "- x", "* x", "• x", "1. x", "2) x", "| x |".
_LIST_LINE = re.compile(r"^[ \t]*(?:[-*•+]|\d{1,3}[.)]|\|)[ \t]*\S.*$", re.MULTILINE)
# A money figure in a line: "$4,200.00" -> "4,200.00".
_MONEY = re.compile(r"\d[\d,]*\.\d{2}(?!\d)")


def _mentions(text: str, phrase) -> bool:
    """True when `phrase` appears in `text` as whole words, ignoring case."""
    if not isinstance(phrase, str) or not phrase.strip():
        return False
    return re.search(r"(?<!\w)" + re.escape(phrase.strip()) + r"(?!\w)", text, re.IGNORECASE) is not None


def _line_names_row(line: str, row: dict) -> bool:
    """True when a list line names a transaction row, by its description or its amount."""
    if _mentions(line, row.get("description")):
        return True
    amounts = {_plain_amount(figure.replace(",", "")) for figure in _MONEY.findall(line)}
    return row.get("amount") is not None and row["amount"] in amounts


def reply_problem(text: str, invocation_state: dict) -> str | None:
    """Why the reply repeats this turn's transaction rows ("list" or "names_rows"), or None."""
    rows = [row for seen in invocation_state.get(_TRANSACTIONS_SEEN, {}).values() for row in seen["rows"]]
    if not rows:
        return None
    for line in _LIST_LINE.findall(text):
        if any(_line_names_row(line, row) for row in rows):
            return "list"
    named = {row["description"].strip().lower() for row in rows if _mentions(text, row.get("description"))}
    return "names_rows" if len(named) >= 3 else None


def _all_calls(seen: list) -> dict:
    """One record for every get_transactions call of the turn, for the replacement line."""
    if len(seen) == 1:
        return seen[0]
    dates = [date for record in seen for date in (record["first_date"], record["last_date"])]
    known = all(dates)
    return {
        "count": sum(record["count"] for record in seen),
        "first_date": min(dates) if known else None,
        "last_date": max(dates) if known else None,
        "account_filtered": False,
    }


def checked_reply(text: str, invocation_state: dict) -> str:
    """The model's reply, or — when it repeats this turn's transaction rows — the line built from them.

    main.py calls this on the text it sends as the answer, so the answer frames
    keep their shape and order. Never raises: on a failure the model's reply
    stands and the failure is logged without any value.
    """
    try:
        problem = reply_problem(text, invocation_state)
        if problem is None:
            return text
        seen = list(invocation_state[_TRANSACTIONS_SEEN].values())
        replacement = transactions_reply(_all_calls(seen))
        logger.info(
            "uc2_reply_replaced",
            extra={"reason": problem, "transaction_calls": len(seen), "transaction_count": sum(s["count"] for s in seen)},
        )
        return replacement
    except Exception as exc:  # noqa: BLE001 — the model's reply stands
        logger.warning("uc2_reply_check_failed", extra={"error_type": type(exc).__name__})
        return text


def build_uc2_model(vault_client=None) -> BedrockModel:
    """Build the shared Bedrock model — called ONCE at startup, never per user.

    Uses Amazon Nova Pro via CRIS profile (us.amazon.nova-pro-v1:0). Bedrock
    credentials come from Vault AWS STS (OBJ-2) — not the node IAM role — and
    botocore re-mints them via RefreshableCredentials as they near expiry. The
    model carries NO per-user state, so it is safe to share across every
    request: the per-request isolation boundary is the Agent (build_uc2_agent),
    not the model.

    Returns:
        Configured strands.models.BedrockModel for build_uc2_agent to wrap.
    """
    region = os.getenv("AWS_REGION") or os.getenv("AWS_DEFAULT_REGION")
    if not region:
        raise RuntimeError("AWS_REGION (or AWS_DEFAULT_REGION) must be set")
    model_id = os.getenv("BEDROCK_MODEL_ID", "us.amazon.nova-pro-v1:0")

    boto_session = None
    if vault_client:
        boto_session = vault_client.get_bedrock_session(region)

    model_kwargs = {"model_id": model_id}
    if boto_session:
        model_kwargs["boto_session"] = boto_session
    else:
        model_kwargs["region_name"] = region

    bedrock_model = BedrockModel(**model_kwargs)

    logger.info(
        "uc2_model_built",
        extra={"model_id": model_id, "region": region},
    )
    return bedrock_model


def build_uc2_agent(model: BedrockModel) -> Agent:
    """Construct a FRESH UC2 banking Strands Agent — called PER /chat request.

    A new Agent (empty conversation history) is the cross-user isolation
    boundary: because it holds no prior turns, it can never serve one user's
    banking data to the next user — the leak a single long-lived shared Agent
    caused. Identity for each tool call flows from the request-scoped
    _REQUEST_JWT ContextVar, never a shared global. Mirrors uc3-agent's
    per-request build_uc3_agent.

    Tools: get_accounts + get_transactions — both forward the user JWT to the
    MCP server, which performs Vault JWT auth → per-user DB creds → RDS (RLS).

    Returns:
        Configured strands.Agent ready to handle one user's banking queries.
    """
    system_prompt = (
        "You are the OscarVault International (OVI) AI Assistant for the Agentic Runtime Security workshop. "
        "You help authenticated users (Oscar and Jaime) with their banking queries. "
        "\n\n"
        "SECURITY MODEL:\n"
        "- Your identity is established via Kubernetes Service Account JWT + Vault (OBJ-1).\n"
        "- Every tool call is made with the user's JWT — Vault authenticates each request "
        "and issues per-user-scoped credentials (OBJ-2, OBJ-3).\n"
        "- PostgreSQL Row-Level Security ensures you can ONLY retrieve this user's data.\n"
        "- You have READ-ONLY access — no account modifications are possible (this is UC2).\n"
        "\n"
        "AVAILABLE TOOLS:\n"
        "- get_accounts: List the user's bank accounts with balances.\n"
        "- get_transactions: Show recent transactions. Optionally pass account_id to filter.\n"
        "\n"
        "RESPONSE STYLE:\n"
        "- Present financial data clearly (format amounts with currency symbol).\n"
        "- After get_transactions, reply in one or two sentences and answer the user's question; "
        "do not list the transactions.\n"
        "- Never state an amount, count, date or transaction that a tool did not return in this "
        "turn. To answer anything about accounts or transactions, call the tool first.\n"
        "- Do NOT include JWT tokens, Vault lease IDs, or credential metadata in your response.\n"
        "- If a tool call fails, explain what the user can check (session validity, account access).\n"
        "- This is a read-only banking app — if asked to transfer funds or modify data, "
        "politely explain that UC2 is read-only and refer to UC3 for write operations."
    )

    # ActivityHooks reports each tool call and follow-up model call into the
    # current turn's event queue (activity._TURN_ACTIVITY), never into a shared one.
    agent = Agent(
        model=model,
        tools=[get_accounts, get_transactions],
        system_prompt=system_prompt,
        hooks=[activity.ActivityHooks()],
    )

    logger.info(
        "uc2_agent_built",
        extra={"tools": ["get_accounts", "get_transactions"]},
    )
    return agent
