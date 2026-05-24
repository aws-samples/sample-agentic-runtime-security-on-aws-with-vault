"""agent.py — UC3 Strands agent with CIBA + RFC 8693 token exchange + privileged write.

Security architecture (OBJ-1 through OBJ-5):

  OBJ-1: Agent workload identity via Vault Kubernetes auth (K8s SA JWT, role "uc3").
  OBJ-2: No standing DB write credentials — write creds fetched per-refund via
          Vault jwt auth after CIBA consent + token exchange. TTL = 5 minutes.
  OBJ-3: Privileged write is gated on user's CIBA consent (may_act claim in JWT).
          Agent identity present as actor_token in RFC 8693 exchange.
  OBJ-4: Vault policy enforces uc3-refund-writer access ONLY with delegated JWT.
          Read-only creds (uc3-readonly) cannot INSERT into banking.refunds.
  OBJ-5: request_id UUID threaded through IVIA binding_message, RDS refunds,
          and structured agent logs for three-plane audit correlation.

Tools:
  list_transactions    — read-only SELECT recent transactions (K8s auth creds)
  process_refund       — full CIBA + exchange + write flow (delegated jwt auth creds)
  check_refund_status  — read-only SELECT from banking.refunds by refund_id
"""

import logging
import os
import secrets
import time
import uuid
from datetime import datetime, timezone

import httpx
import psycopg2
import psycopg2.extras
from strands import Agent, tool
from strands.models import BedrockModel
from strands.session import FileSessionManager

from . import ciba_store

logger = logging.getLogger(__name__)

# Module-level vault client reference (set by build_uc3_agent)
_vault_client = None

# IVIA configuration from env vars
IVIA_BASE_URL = os.getenv("IVIA_BASE_URL", "https://iviaop.verify-access.svc.cluster.local:8436")
IVIA_CLIENT_ID = os.getenv("IVIA_CLIENT_ID", "uc3-agent")
IVIA_CLIENT_SECRET = os.getenv("IVIA_CLIENT_SECRET", "")
IVIA_EXTERNAL_URL = os.getenv("IVIA_EXTERNAL_URL", "")
IVIA_ACTOR_CLIENT_ID = os.getenv("IVIA_ACTOR_CLIENT_ID", "uc3-actor")
IVIA_ACTOR_CLIENT_SECRET = os.getenv("IVIA_ACTOR_CLIENT_SECRET", IVIA_CLIENT_SECRET)

# CIBA polling config
CIBA_POLL_INTERVAL_SECONDS = 5
CIBA_TIMEOUT_SECONDS = 120


# ---------------------------------------------------------------------------
# CIBA helper functions
# ---------------------------------------------------------------------------


def _initiate_ciba(login_hint: str, authorization_details: list, request_id: str) -> dict:
    """Initiate CIBA backchannel authentication at IVIA.

    Sends bc-authorize request with:
      - login_hint: the account owner's username/email (to target the right user)
      - binding_message: request_id UUID (visible in IVIA consent UI; audit anchor)
      - authorization_details: RAR payload describing the refund approval scope
      - user_code: a short code the user re-enters at /oauth2/user_authorization to
        bind the browser consent session to this pending request.

    user_code mechanic (unverified between two readings — handled defensively):
      (A) device-flow style: provider GENERATES and returns user_code in the
          response. (B) standard CIBA: client SENDS user_code and the provider
          echoes/accepts it. We send a generated code AND prefer any value the
          provider returns, logging both so the first live test reveals the truth.

    Args:
        login_hint: Username or email to target for CIBA consent.
        authorization_details: Rich Authorization Request details (type, amount, etc.).
        request_id: UUID threaded through the flow for audit correlation.

    Returns:
        Dict with auth_req_id (for polling) and user_code (for the consent page).

    Raises:
        RuntimeError: If IVIA bc-authorize returns an error.
    """
    import json as _json

    bc_authorize_url = f"{IVIA_BASE_URL}/oauth2/ciba"

    # Short, user-typable code. The user enters this at the consent page to bind
    # their authenticated browser session to this CIBA request.
    sent_user_code = secrets.token_hex(3).upper()  # e.g. "A3F9C1"

    # Client creds go in the HTTP Basic Authorization header (the client is
    # registered token_endpoint_auth_method=client_secret_basic), NOT the body.
    payload = {
        "login_hint": login_hint,
        "binding_message": request_id,
        "authorization_details": _json.dumps(authorization_details),
        "scope": "openid",
        "user_code": sent_user_code,
    }

    logger.info(
        "ciba_bc_authorize_initiated",
        extra={
            "request_id": request_id,
            "login_hint": login_hint,
            "binding_message": request_id,
            "ivia_url": bc_authorize_url,
            "sent_user_code": sent_user_code,
        },
    )

    with httpx.Client(verify=False, timeout=30.0) as client:
        resp = client.post(
            bc_authorize_url,
            data=payload,
            auth=(IVIA_CLIENT_ID, IVIA_CLIENT_SECRET),
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )

    if resp.status_code != 200:
        raise RuntimeError(
            f"CIBA bc-authorize failed: HTTP {resp.status_code} — {resp.text}"
        )

    data = resp.json()
    auth_req_id = data.get("auth_req_id") or data.get("request_id")
    if not auth_req_id:
        raise RuntimeError(f"CIBA bc-authorize response missing auth_req_id: {data}")

    # Prefer a provider-returned user_code (interpretation A); fall back to the
    # code we sent (interpretation B). The log line below disambiguates on first
    # live test — whichever the user must actually type is the authoritative one.
    returned_user_code = data.get("user_code")
    user_code = returned_user_code or sent_user_code

    logger.info(
        "ciba_bc_authorize_success",
        extra={
            "request_id": request_id,
            "auth_req_id": auth_req_id,
            "expires_in": data.get("expires_in", "unknown"),
            "interval": data.get("interval", CIBA_POLL_INTERVAL_SECONDS),
            "sent_user_code": sent_user_code,
            "returned_user_code": returned_user_code,
            "user_code_source": "response" if returned_user_code else "sent",
        },
    )
    return {"auth_req_id": auth_req_id, "user_code": user_code}


def _poll_ciba(auth_req_id: str, request_id: str) -> str:
    """Poll the IVIA token endpoint until CIBA consent is granted or timeout.

    Polls every CIBA_POLL_INTERVAL_SECONDS seconds up to CIBA_TIMEOUT_SECONDS.
    Returns the access_token once the user approves the CIBA request in the
    IVIA consent UI (or the IVIA mobile push notification).

    Args:
        auth_req_id: The auth_req_id returned by bc-authorize.
        request_id: UUID for log correlation.

    Returns:
        CIBA access_token string.

    Raises:
        TimeoutError: If user does not consent within CIBA_TIMEOUT_SECONDS.
        RuntimeError: If IVIA returns an unexpected error.
    """
    token_url = f"{IVIA_BASE_URL}/oauth2/token"
    grant_type = "urn:openid:params:grant-type:ciba"

    deadline = time.monotonic() + CIBA_TIMEOUT_SECONDS
    attempt = 0

    while time.monotonic() < deadline:
        attempt += 1
        payload = {
            "grant_type": grant_type,
            "auth_req_id": auth_req_id,
        }

        with httpx.Client(verify=False, timeout=30.0) as client:
            resp = client.post(
                token_url,
                data=payload,
                auth=(IVIA_CLIENT_ID, IVIA_CLIENT_SECRET),
                headers={"Content-Type": "application/x-www-form-urlencoded"},
            )

        if resp.status_code == 200:
            data = resp.json()
            access_token = data.get("access_token")
            if access_token:
                logger.info(
                    "ciba_poll_success",
                    extra={
                        "request_id": request_id,
                        "auth_req_id": auth_req_id,
                        "poll_attempt": attempt,
                        "token_type": data.get("token_type", "unknown"),
                    },
                )
                return access_token

        # authorization_pending — keep polling
        if resp.status_code == 400:
            error_data = resp.json()
            error = error_data.get("error", "")
            if error == "authorization_pending":
                logger.debug(
                    "ciba_poll_pending",
                    extra={
                        "request_id": request_id,
                        "auth_req_id": auth_req_id,
                        "attempt": attempt,
                    },
                )
                time.sleep(CIBA_POLL_INTERVAL_SECONDS)
                continue
            elif error == "slow_down":
                time.sleep(CIBA_POLL_INTERVAL_SECONDS * 2)
                continue
            elif error == "access_denied":
                raise RuntimeError(
                    f"CIBA access denied by user (request_id={request_id})"
                )
            else:
                raise RuntimeError(
                    f"CIBA poll unexpected error: {error_data} (request_id={request_id})"
                )

        raise RuntimeError(
            f"CIBA poll HTTP {resp.status_code}: {resp.text} (request_id={request_id})"
        )

    raise TimeoutError(
        f"CIBA consent not received within {CIBA_TIMEOUT_SECONDS}s "
        f"(auth_req_id={auth_req_id}, request_id={request_id})"
    )


def _token_exchange(ciba_token: str, actor_token: str, request_id: str) -> str:
    """RFC 8693 token exchange: produce delegated JWT with may_act claim.

    Presents:
      - subject_token: CIBA access token (user's identity + consent)
      - actor_token: K8s SA JWT (agent workload identity as actor)

    IVIA issues a delegated JWT containing:
      - sub: the user (subject)
      - act / may_act: the agent SA (actor)
      - authorization_details: the RAR refund_approval scope

    This delegated JWT is then presented to Vault jwt auth (uc3-jwt role)
    which validates may_act and issues uc3-refund-writer DB credentials.

    Args:
        ciba_token: The CIBA access_token (user consent proof).
        actor_token: The agent's IVIA-issued client_credentials token (actor identity).
        request_id: UUID for log correlation.

    Returns:
        Delegated JWT string.

    Raises:
        RuntimeError: If IVIA token exchange fails.
    """
    token_url = f"{IVIA_BASE_URL}/oauth2/token"

    payload = {
        "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
        "subject_token": ciba_token,
        "subject_token_type": "urn:ietf:params:oauth:token-type:access_token",
        "actor_token": actor_token,
        "actor_token_type": "urn:ietf:params:oauth:token-type:access_token",
        "requested_token_type": "urn:ietf:params:oauth:token-type:access_token",
    }

    logger.info(
        "token_exchange_initiated",
        extra={
            "request_id": request_id,
            "grant_type": "token-exchange",
            "subject_token_type": "ciba_access_token",
            "actor_token_type": "k8s_sa_jwt",
        },
    )

    with httpx.Client(verify=False, timeout=30.0) as client:
        resp = client.post(
            token_url,
            data=payload,
            auth=(IVIA_ACTOR_CLIENT_ID, IVIA_ACTOR_CLIENT_SECRET),
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )

    if resp.status_code != 200:
        raise RuntimeError(
            f"Token exchange failed: HTTP {resp.status_code} — {resp.text} "
            f"(request_id={request_id})"
        )

    data = resp.json()
    delegated_jwt = data.get("access_token")
    if not delegated_jwt:
        raise RuntimeError(
            f"Token exchange response missing access_token: {data} "
            f"(request_id={request_id})"
        )

    logger.info(
        "token_exchange_success",
        extra={
            "request_id": request_id,
            "token_type": data.get("token_type", "unknown"),
            "issued_token_type": data.get("issued_token_type", "unknown"),
            "expires_in": data.get("expires_in", "unknown"),
        },
    )
    return delegated_jwt


def _get_actor_token() -> str:
    """Get an IVIA-issued client_credentials token for use as actor_token.

    The agent authenticates to IVIA with its own client_id/secret.
    IVIA trusts its own tokens, so token exchange validation succeeds.
    The delegated JWT carries the agent's client_id in the act/may_act claim.

    Returns:
        IVIA-issued access_token string.
    """
    token_url = f"{IVIA_BASE_URL}/oauth2/token"
    with httpx.Client(verify=False, timeout=30.0) as client:
        resp = client.post(
            token_url,
            data={
                "grant_type": "client_credentials",
                "scope": "openid",
            },
            auth=(IVIA_ACTOR_CLIENT_ID, IVIA_ACTOR_CLIENT_SECRET),
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
    resp.raise_for_status()
    return resp.json()["access_token"]


# ---------------------------------------------------------------------------
# Strands tools
# ---------------------------------------------------------------------------


@tool
def list_transactions() -> list:
    """List recent transactions across all accounts (read-only).

    Uses Vault K8s auth credentials to SELECT from banking.transactions.
    Returns the most recent transactions so the user can select one for a refund.

    Returns:
        List of dicts with transaction details: id, account_id, amount,
        description, transaction_type, merchant, category, created_at, account_type.
    """
    global _vault_client
    if _vault_client is None:
        raise RuntimeError("UC3 vault client not initialized")

    creds = _vault_client.get_readonly_credentials()

    logger.info(
        "list_transactions_called",
        extra={"vault_role": "uc3-readonly"},
    )

    try:
        with psycopg2.connect(
            host=creds["host"],
            port=creds["port"],
            dbname=creds["dbname"],
            user=creds["username"],
            password=creds["password"],
            cursor_factory=psycopg2.extras.RealDictCursor,
        ) as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    SELECT t.id, t.account_id, t.amount::float,
                           t.description, t.transaction_type, t.merchant,
                           t.category,
                           t.created_at AT TIME ZONE 'UTC' AS created_at,
                           a.account_type
                    FROM banking.transactions t
                    JOIN banking.accounts a ON a.id = t.account_id
                    ORDER BY t.created_at DESC
                    LIMIT 20
                    """
                )
                rows = cur.fetchall()
    except Exception as exc:
        logger.error("list_transactions_db_error: %s", str(exc))
        raise

    results = []
    for row in rows:
        r = dict(row)
        r["created_at"] = str(r.get("created_at", ""))
        results.append(r)
    return results


@tool
def initiate_refund(
    account_id: str,
    transaction_id: str,
    amount: float,
    currency: str,
    login_hint: str = "oscar",
) -> dict:
    """Initiate a CIBA consent request for a privileged refund (step 1 of 2).

    Sends bc-authorize to IVIA with Rich Authorization Request (RFC 9396)
    details. Returns immediately with auth_req_id and consent marker so the
    banking UI can show the Approve/Deny button to the user.

    After the user approves, call complete_refund with the same parameters
    plus auth_req_id and request_id to finish the flow.

    Args:
        account_id: Account to credit the refund to.
        transaction_id: Original transaction being refunded.
        amount: Refund amount (positive float).
        currency: ISO 4217 currency code (e.g. "USD").
        login_hint: Username/email for CIBA targeting (default: "oscar").

    Returns:
        Dict with auth_req_id, request_id, and consent status.
    """
    request_id = str(uuid.uuid4())

    logger.info(
        "initiate_refund_started",
        extra={
            "request_id": request_id,
            "account_id": account_id,
            "transaction_id": transaction_id,
            "amount": amount,
            "currency": currency,
        },
    )

    authorization_details = [
        {
            "type": "refund_approval",
            "transaction_id": transaction_id,
            "account_id": account_id,
            "amount": amount,
            "currency": currency,
            "request_id": request_id,
        }
    ]

    ciba = _initiate_ciba(login_hint, authorization_details, request_id)
    auth_req_id = ciba["auth_req_id"]
    user_code = ciba["user_code"]

    rar_desc = f"refund_approval ${amount} {currency} for transaction {transaction_id}"

    # The real CIBA consent page is /isvaop/oauth2/ciba_user_authorize/{transactionID},
    # where transactionID is an internal id the client never sees. The IVIA notifyuser
    # mapping rule fires during bc-authorize and POSTs that full browser-reachable URL
    # to our /api/ciba/pending endpoint. Poll the store briefly for it (notifyuser runs
    # server-side before bc-authorize returns, so it is normally present immediately).
    consent_url = ""
    for _ in range(20):  # up to ~5s
        consent_url = ciba_store.get(auth_req_id) or ""
        if consent_url:
            break
        time.sleep(0.25)

    if not consent_url:
        logger.warning(
            "ciba_consent_url_not_pushed",
            extra={"request_id": request_id, "auth_req_id": auth_req_id},
        )

    logger.info(
        "ciba_consent_requested",
        extra={
            "request_id": request_id,
            "auth_req_id": auth_req_id,
            "user_code": user_code,
            "authorization_details": authorization_details,
        },
    )

    return {
        "status": "consent_required",
        "auth_req_id": auth_req_id,
        "request_id": request_id,
        "account_id": account_id,
        "transaction_id": transaction_id,
        "amount": amount,
        "currency": currency,
        "login_hint": login_hint,
        "user_code": user_code,
        "consent_url": consent_url,
        "consent_marker": f"CIBA_CONSENT:auth_req_id={auth_req_id}|request_id={request_id}|user_code={user_code}|details={rar_desc}|consent_url={consent_url}",
    }


@tool
def complete_refund(
    auth_req_id: str,
    request_id: str,
    account_id: str,
    transaction_id: str,
    amount: float,
    currency: str,
    login_hint: str = "oscar",
) -> dict:
    """Complete a refund after CIBA consent is granted (step 2 of 2).

    Polls IVIA for consent approval, then executes:
      1. CIBA token poll (user already approved via banking UI)
      2. RFC 8693 token exchange → delegated JWT with may_act claim
      3. Vault jwt auth (uc3-jwt) → uc3-refund-writer DB credentials
      4. INSERT into banking.refunds

    Args:
        auth_req_id: CIBA auth_req_id from initiate_refund.
        request_id: Audit correlation UUID from initiate_refund.
        account_id: Account to credit the refund to.
        transaction_id: Original transaction being refunded.
        amount: Refund amount (positive float).
        currency: ISO 4217 currency code (e.g. "USD").
        login_hint: Username/email who approved (default: "oscar").

    Returns:
        Dict with refund_id, request_id, status, and audit fields.
    """
    global _vault_client
    if _vault_client is None:
        raise RuntimeError("UC3 vault client not initialized")

    logger.info(
        "complete_refund_started",
        extra={"request_id": request_id, "auth_req_id": auth_req_id},
    )

    ciba_token = _poll_ciba(auth_req_id, request_id)
    actor_token = _get_actor_token()
    delegated_jwt = _token_exchange(ciba_token, actor_token, request_id)
    write_creds = _vault_client.get_refund_credentials(delegated_jwt, request_id)

    refund_id = str(uuid.uuid4())
    approved_by = login_hint
    created_at = datetime.now(timezone.utc)

    logger.info(
        "process_refund_db_write",
        extra={
            "request_id": request_id,
            "refund_id": refund_id,
            "account_id": account_id,
            "vault_db_role": "uc3-refund-writer",
            "approved_by": approved_by,
        },
    )

    with psycopg2.connect(
        host=write_creds["host"],
        port=write_creds["port"],
        dbname=write_creds["dbname"],
        user=write_creds["username"],
        password=write_creds["password"],
    ) as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO banking.refunds
                    (refund_id, account_id, transaction_id, amount, currency,
                     approved_by, request_id, created_at)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
                """,
                (
                    refund_id,
                    account_id,
                    transaction_id,
                    amount,
                    currency,
                    approved_by,
                    request_id,
                    created_at,
                ),
            )
        conn.commit()

    logger.info(
        "process_refund_success",
        extra={
            "request_id": request_id,
            "refund_id": refund_id,
            "account_id": account_id,
            "amount": amount,
            "currency": currency,
            "approved_by": approved_by,
        },
    )

    return {
        "refund_id": refund_id,
        "request_id": request_id,
        "account_id": account_id,
        "transaction_id": transaction_id,
        "amount": amount,
        "currency": currency,
        "approved_by": approved_by,
        "status": "approved",
        "created_at": created_at.isoformat(),
    }


@tool
def check_refund_status(refund_id: str) -> dict:
    """Check the status of an existing refund by refund_id.

    Uses Vault K8s auth credentials (uc3-readonly role) to SELECT from
    banking.refunds. No CIBA required — this is a read-only status check.

    Args:
        refund_id: UUID of the refund to look up.

    Returns:
        Dict with refund details: refund_id, account_id, amount, currency,
        approved_by, request_id, status, created_at.
    """
    global _vault_client
    if _vault_client is None:
        raise RuntimeError("UC3 vault client not initialized")

    creds = _vault_client.get_readonly_credentials()

    logger.info(
        "check_refund_status_called",
        extra={"refund_id": refund_id, "vault_role": "uc3-readonly"},
    )

    with psycopg2.connect(
        host=creds["host"],
        port=creds["port"],
        dbname=creds["dbname"],
        user=creds["username"],
        password=creds["password"],
        cursor_factory=psycopg2.extras.RealDictCursor,
    ) as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT refund_id, account_id, transaction_id,
                       amount::float, currency, approved_by, request_id,
                       created_at AT TIME ZONE 'UTC' AS created_at
                FROM banking.refunds
                WHERE refund_id = %s
                LIMIT 1
                """,
                (refund_id,),
            )
            row = cur.fetchone()

    if row is None:
        return {"error": f"Refund {refund_id} not found"}

    result = dict(row)
    result["created_at"] = str(result.get("created_at", ""))
    result["status"] = "approved"
    return result


def build_uc3_agent(vault_client=None, session_id: str = "default") -> Agent:
    """Construct a fresh UC3 Strands Agent with new STS creds and session history.

    Called on every /chat request. Fresh BedrockModel gets unexpired Vault STS
    creds; FileSessionManager loads/saves conversation history by session_id.
    """
    global _vault_client
    _vault_client = vault_client

    region = os.getenv("REGION", "us-west-2")
    model_id = os.getenv("BEDROCK_MODEL_ID", "us.amazon.nova-pro-v1:0")

    boto_session = None
    if vault_client and vault_client.is_authenticated():
        try:
            boto_session = vault_client.get_bedrock_credentials()
        except Exception as exc:
            logger.warning("uc3_bedrock_sts_skipped: %s", str(exc))

    model_kwargs = {"model_id": model_id}
    if boto_session:
        model_kwargs["boto_session"] = boto_session
    else:
        model_kwargs["region_name"] = region

    bedrock_model = BedrockModel(**model_kwargs)
    session_manager = FileSessionManager(session_id=session_id, storage_dir="/tmp/uc3-sessions")

    system_prompt = (
        "You are the CDL Bank Refund Assistant.\n\n"
        "WORKFLOW — follow these steps exactly:\n"
        "1. When the user asks for a refund, call the list_transactions tool.\n"
        "2. Present results as a numbered list: description, amount, merchant, date.\n"
        "3. Ask the user which number they want to refund.\n"
        "4. When the user selects a number, confirm the transaction details and ask 'Shall I proceed?'\n"
        "5. When the user confirms, call the initiate_refund tool with:\n"
        "   - account_id: the account_id from the selected transaction\n"
        "   - transaction_id: the id from the selected transaction\n"
        "   - amount: the absolute value of the amount (positive number)\n"
        "   - currency: 'USD'\n"
        "6. initiate_refund returns a consent_marker string. You MUST include it EXACTLY as-is in your response.\n"
        "   Tell the user: 'CIBA consent is required. Click Approve in the consent banner below,\n"
        "   sign in if prompted, and approve the refund.'\n"
        "7. When the user says they approved (or sends any follow-up), call complete_refund with:\n"
        "   auth_req_id, request_id, account_id, transaction_id, amount, currency from the initiate_refund result.\n"
        "8. Report exactly what the complete_refund tool returns to the user.\n\n"
        "CRITICAL RULES:\n"
        "- NEVER generate URLs, consent links, request_ids, or refund_ids yourself.\n"
        "- NEVER simulate or role-play what a tool would do. ALWAYS call the actual tool.\n"
        "- ALL data must come from tool calls, never from your own knowledge.\n"
        "- Present financial amounts with $ symbol.\n"
        "- Do NOT include JWT tokens, Vault credentials, or internal secrets in responses."
    )

    agent = Agent(
        model=bedrock_model,
        tools=[list_transactions, initiate_refund, complete_refund, check_refund_status],
        system_prompt=system_prompt,
        session_manager=session_manager,
    )

    logger.info(
        "uc3_agent_built",
        extra={
            "model_id": model_id,
            "region": region,
            "tools": ["list_transactions", "process_refund", "check_refund_status"],
        },
    )
    return agent
