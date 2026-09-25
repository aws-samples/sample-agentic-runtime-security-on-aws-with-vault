"""agent.py — UC3 Strands agent with CIBA + RFC 8693 token exchange + privileged write.

Security architecture (OBJ-1 through OBJ-5):

  OBJ-1: Agent workload identity via Vault Kubernetes auth (K8s SA JWT, role "uc3").
  OBJ-2: No standing DB write credentials — write creds fetched per-refund by
          presenting the delegated OAuth JWT directly as the Vault token
          (X-Vault-Token) after CIBA consent + token exchange. TTL = 5 minutes.
  OBJ-3: Privileged write is gated on user's CIBA consent (may_act claim in JWT).
          Agent identity present as actor_token in RFC 8693 exchange.
  OBJ-4: Vault policy enforces uc3-refund-writer access ONLY with delegated JWT.
          Read-only creds use the least-privilege uc3-readonly Vault role, which
          carries SELECT-only grants on banking.transactions, banking.accounts, and
          banking.refunds — it genuinely cannot INSERT into banking.refunds.
  OBJ-5: request_id UUID threaded through IVIA binding_message, RDS refunds,
          and structured agent logs for three-plane audit correlation.

Tools:
  list_transactions    — read-only SELECT recent transactions (K8s auth creds)
  initiate_refund      — full CIBA + exchange + write flow (delegated OAuth JWT creds)
  complete_refund      — completes refund after CIBA consent received
  check_refund_status  — read-only SELECT from banking.refunds by refund_id
"""

import json
import logging
import os
import secrets
import time
import uuid
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation

import httpx
import psycopg2
import psycopg2.extensions
import psycopg2.extras
from strands import Agent, ToolContext, tool
from strands.models import BedrockModel
from strands.session import FileSessionManager

from . import activity
from . import ciba_store
from . import mmfa
from .auth import _AUTHENTICATED_SUB

logger = logging.getLogger(__name__)

# Module-level vault client reference (set by build_uc3_agent)
_vault_client = None


class RefundAuthorizationError(Exception):
    """Raised when a refund may not proceed on authorization grounds.

    Covers the account-ownership check that fires INDEPENDENTLY inside both
    initiate_refund and complete_refund, and the approval-binding checks in
    complete_refund (issue #31): no approval record for this auth_req_id, a
    request_id naming a different approval, an approval granted by a different
    human, and an approval already redeemed.

    Must be raised (not returned) so the LLM cannot observe the failure as a
    normal tool result and act on it.
    """


class RefundRefusedError(Exception):
    """Raised when the refund terms do not fit the real charge (issue #73).

    initiate_refund raises it before any approval is requested: the transaction
    is not a charge on the signed-in user's account, it is not on the account
    named, it is not a debit, or the amount is not more than zero and at most
    what is still refundable. complete_refund raises it when, inside the write
    transaction, the approved amount no longer fits what is still refundable.

    The message is a plain-English reason the model can relay to the user as it
    stands. It names only the signed-in user's own figures.
    """


def _open_readonly_connection():
    """A connection on a fresh short-lived uc3-readonly credential from Vault."""
    global _vault_client
    if _vault_client is None:
        raise RuntimeError("UC3 vault client not initialized")

    creds = _vault_client.get_readonly_credentials()
    return psycopg2.connect(
        host=creds["host"],
        port=creds["port"],
        dbname=creds["dbname"],
        user=creds["username"],
        password=creds["password"],
        cursor_factory=psycopg2.extras.RealDictCursor,
    )


def _check_account_owner(
    account_id: str, authenticated_sub: str, request_id: str, tool_name: str
) -> None:
    """Verify the authenticated user owns the targeted account.

    Issues a fresh short-lived Vault uc3-readonly DB credential and runs a
    single SELECT against banking.accounts. Mismatch (or missing account) →
    RefundAuthorizationError with refund_authz_denied structured log.

    Args:
        account_id: The account_id the LLM/caller wants to act on.
        authenticated_sub: The verified IVIA id_token `sub` from ContextVar.
        request_id: Audit-correlation UUID for the current refund flow.
        tool_name: "initiate_refund" or "complete_refund" — log field.

    Raises:
        RefundAuthorizationError: on mismatch OR missing-account (no info
            leak between the two cases).
    """
    with _open_readonly_connection() as conn:
        with conn.cursor() as cur:
            _owner_check(cur, account_id, authenticated_sub, request_id, tool_name)


def _owner_check(
    cur, account_id: str, authenticated_sub: str, request_id: str, tool_name: str
) -> None:
    """The account-owner check on an open read-only cursor (see _check_account_owner).

    Sets app.current_user_sub on the connection, so a caller reading more rows
    on the same cursor afterwards reads them under the signed-in user's RLS
    scope.
    """
    cur.execute(
        "SELECT set_config('app.current_user_sub', %s, false)",
        (authenticated_sub,),
    )
    cur.execute(
        """
        SELECT user_sub
        FROM banking.accounts
        WHERE id = %s
        LIMIT 1
        """,
        (account_id,),
    )
    row = cur.fetchone()

    if row is None or row["user_sub"] != authenticated_sub:
        logger.warning(
            "refund_authz_denied tool=%s authenticated_sub=%s requested_account_id=%s requested_account_owner_sub=%s request_id=%s",
            tool_name,
            authenticated_sub,
            account_id,
            row["user_sub"] if row else None,
            request_id,
            extra={
                "request_id": request_id,
                "authenticated_sub": authenticated_sub,
                "requested_account_id": account_id,
                "requested_account_owner_sub": row["user_sub"] if row else None,
                "tool": tool_name,
            },
        )
        # The owner's identity is logged above and never reported to the browser.
        activity.narrate(
            f"Account owner check refused: {account_id} does not belong to the signed-in user. "
            + _OWNER_CHECK_REFUSED_CONSEQUENCE.get(tool_name, ""),
            request_id,
        )
        raise RefundAuthorizationError("refund_authz_denied")

    activity.narrate(
        f"Account owner check passed: {account_id} belongs to the signed-in user "
        "(checked with a short-lived read-only database credential from Vault).",
        request_id,
    )


# What did NOT happen when the owner check refuses, per tool — both tools run the
# check before anything else touches IVIA, Vault's write path or the database.
_OWNER_CHECK_REFUSED_CONSEQUENCE = {
    "initiate_refund": "No approval was requested.",
    "complete_refund": "Nothing was written.",
}


# ---------------------------------------------------------------------------
# Refund terms, checked against the real charge (issue #73)
#
# The model proposes a transaction and an amount; nothing it says is trusted as a
# figure. initiate_refund reads the charge itself and refuses before any approval
# is requested unless the transaction is a debit on the signed-in user's account,
# on the account named, the currency asked for is the account's currency, and the
# amount is more than zero and at most the charge minus what is already refunded.
# The approval then carries the database's merchant, charge, amount and currency.
# complete_refund re-checks the remaining amount
# inside its write transaction, serialised per transaction, so two approvals for
# one charge can never together refund more than the charge.
#
# Money is Decimal to the cent throughout; no float is ever compared.
# ---------------------------------------------------------------------------

_CENT = Decimal("0.01")
_MAX_AMOUNT = Decimal("9999999999.99")  # the largest DECIMAL(12,2)


def _money(value: Decimal) -> str:
    """A Decimal as a two-decimal string, e.g. Decimal('88.3') -> '88.30'."""
    return str(value.quantize(_CENT))


def _refuse_terms(reason_code: str, reason: str, request_id: str, **log_fields) -> None:
    """Log, report and raise one initiate_refund refusal. Nothing has been sent yet."""
    logger.warning(
        "refund_terms_refused",
        extra={"request_id": request_id, "reason_code": reason_code, "tool": "initiate_refund", **log_fields},
    )
    reason = f"Refund refused: {reason} No approval was requested."
    activity.narrate(reason, request_id)
    raise RefundRefusedError(reason)


def _requested_amount(amount, request_id: str) -> Decimal:
    """The model's amount as a Decimal to the cent, or a refusal (not a number, <= 0, sub-cent)."""
    try:
        value = Decimal(str(amount))
    except (InvalidOperation, ValueError, TypeError):
        value = None
    if value is None or not value.is_finite():
        _refuse_terms("amount_not_a_number", f"the amount {amount!r} is not a number.", request_id)
    if value <= 0:
        _refuse_terms("amount_not_positive", f"the amount must be more than zero, not {value}.", request_id)
    # banking.refunds.amount is DECIMAL(12,2); anything larger is no charge's
    # amount, and quantizing a huge value would raise instead of refusing.
    if value > _MAX_AMOUNT:
        _refuse_terms("amount_too_large", f"the amount {value} is larger than any charge can be.", request_id)
    if value != value.quantize(_CENT):
        _refuse_terms(
            "amount_sub_cent", f"the amount {value} has fractions of a cent.", request_id, requested_amount=str(value)
        )
    return value.quantize(_CENT)


def _check_refund_terms(
    account_id: str,
    transaction_id: str,
    amount,
    currency,
    authenticated_sub: str,
    request_id: str,
) -> dict:
    """Check the model's refund against the real charge; return the database's terms.

    Runs the account-owner check and the charge read on ONE short-lived
    uc3-readonly credential, RLS-scoped to the signed-in user exactly as
    list_transactions is. Raises RefundAuthorizationError (owner check) or
    RefundRefusedError (everything else) before anything is sent to IVIA or the
    phone.

    Returns:
        {transaction_id, account_id, merchant, charge_amount, already_refunded,
         refundable, amount, currency} — every figure from the database except
        `amount`, which is the model's request after it has been checked.
    """
    requested = _requested_amount(amount, request_id)
    try:
        txn_uuid = uuid.UUID(str(transaction_id))
    except ValueError:
        _refuse_terms(
            "transaction_id_invalid",
            f"{transaction_id!r} is not a transaction ID.",
            request_id,
            transaction_id=str(transaction_id),
        )

    with _open_readonly_connection() as conn:
        with conn.cursor() as cur:
            _owner_check(cur, account_id, authenticated_sub, request_id, "initiate_refund")
            # RLS already limits both tables to the signed-in user's rows; the
            # explicit user_sub predicate says the same thing in the query itself.
            cur.execute(
                """
                SELECT t.id::text AS transaction_id,
                       t.account_id::text AS account_id,
                       t.transaction_type,
                       t.amount,
                       t.merchant,
                       t.description,
                       a.currency,
                       (SELECT COALESCE(sum(r.amount), 0)
                          FROM banking.refunds r
                         WHERE r.transaction_id = t.id) AS already_refunded
                FROM banking.transactions t
                JOIN banking.accounts a ON a.id = t.account_id
                WHERE t.id = %s
                  AND a.user_sub = %s
                """,
                (str(txn_uuid), authenticated_sub),
            )
            row = cur.fetchone()

    log_fields = {"transaction_id": str(txn_uuid), "account_id": account_id, "requested_amount": _money(requested)}
    if row is None:
        # Same answer for "does not exist" and "belongs to someone else".
        _refuse_terms(
            "transaction_not_found",
            f"transaction {txn_uuid} is not a charge on your accounts.",
            request_id,
            **log_fields,
        )

    merchant = row["merchant"] or row["description"] or "unnamed"
    requested_currency = str(currency or "").strip().upper()
    currency = row["currency"]
    if uuid.UUID(row["account_id"]) != uuid.UUID(str(account_id)):
        _refuse_terms(
            "account_mismatch",
            f"the {merchant} charge is on account {row['account_id']}, not on {account_id}.",
            request_id,
            **log_fields,
        )
    # A refund is paid in the account's own currency. A request in any other
    # currency is refused, not re-labelled, so an approval never names a
    # different currency from the one the user asked for.
    if requested_currency != currency:
        _refuse_terms(
            "currency_mismatch",
            f"the refund was asked for in {requested_currency or 'no currency'}, but account "
            f"{row['account_id']} holds {currency}. A refund is paid in the account's currency.",
            request_id,
            requested_currency=requested_currency,
            account_currency=currency,
            **log_fields,
        )
    if row["transaction_type"] != "debit":
        _refuse_terms(
            "not_a_debit",
            f"the {merchant} transaction is a {row['transaction_type']} of {_money(row['amount'])} {currency}, "
            "not a charge. Only a debit can be refunded.",
            request_id,
            **log_fields,
        )

    charge = abs(row["amount"])
    already = row["already_refunded"]
    refundable = charge - already
    log_fields.update(charge_amount=_money(charge), already_refunded=_money(already), refundable=_money(refundable))
    if requested > refundable:
        if refundable <= 0:
            reason = f"the {merchant} charge of {_money(charge)} {currency} has already been refunded in full."
        else:
            reason = (
                f"{_money(requested)} {currency} is more than the {_money(refundable)} {currency} still refundable "
                f"on the {merchant} charge of {_money(charge)} {currency} ({_money(already)} {currency} already refunded)."
            )
        _refuse_terms("exceeds_refundable", reason, request_id, **log_fields)

    activity.narrate(
        f"Refund check passed: the {merchant} charge of {_money(charge)} {currency} on {row['account_id']} is a "
        f"debit, {_money(already)} {currency} is already refunded, so up to {_money(refundable)} {currency} can be "
        f"refunded; {_money(requested)} {currency} was requested (read from the database with the same "
        "read-only credential).",
        request_id,
    )
    return {
        "transaction_id": row["transaction_id"],
        "account_id": row["account_id"],
        "merchant": merchant,
        "charge_amount": charge,
        "already_refunded": already,
        "refundable": refundable,
        "amount": requested,
        "currency": currency,
    }

# IVIA configuration from env vars
IVIA_BASE_URL = os.getenv("IVIA_BASE_URL", "https://iviaop.verify-access.svc.cluster.local:8436")
IVIA_CLIENT_ID = os.getenv("IVIA_CLIENT_ID", "uc3-agent")
IVIA_CLIENT_SECRET = os.getenv("IVIA_CLIENT_SECRET", "")
IVIA_ACTOR_CLIENT_ID = os.getenv("IVIA_ACTOR_CLIENT_ID", "uc3-actor")
# uc3-actor is a SEPARATE client with its OWN secret, and it must stay that way:
# uc3-actor is the only client allowed to perform the RFC 8693 exchange that mints
# the delegated refund token, so falling back to agent-uc3's secret here would
# hand every holder of agent-uc3's credential the ability to act as uc3-actor.
# No default — an unset value fails the exchange loudly instead of silently
# authenticating as the wrong client.
IVIA_ACTOR_CLIENT_SECRET = os.getenv("IVIA_ACTOR_CLIENT_SECRET", "")
# Path to the iviaop self-signed CA PEM mounted at /etc/ssl/ivia/iviaop.pem.
# All outbound IVIA TLS calls (CIBA bc-authorize, token poll, token exchange)
# verify against this file — TLS verification is never disabled in this module.
IVIA_CA_BUNDLE = os.getenv("IVIA_CA_BUNDLE", "/etc/ssl/ivia/iviaop.pem")

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

    with httpx.Client(verify=IVIA_CA_BUNDLE, timeout=30.0) as client:
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

        with httpx.Client(verify=IVIA_CA_BUNDLE, timeout=30.0) as client:
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
                activity.hitl(
                    "approved",
                    "Approved: the user approved on their phone, and IBM Verify Identity Access "
                    "returned the CIBA access token.",
                    request_id,
                    details={"auth_req_id": auth_req_id, "poll_attempts": attempt},
                )
                activity.credential(
                    "ciba_token",
                    f"{_sub_for_label()}'s CIBA token, issued by IBM Verify Identity Access "
                    "after the phone approval",
                    "IBM Verify Identity Access",
                    value=access_token,
                    ttl_seconds=data.get("expires_in"),
                    expires_at=activity.expires_at_ms(data.get("expires_in")),
                    request_id=request_id,
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
                activity.hitl(
                    "denied",
                    "Denied: the user declined the approval. No token was exchanged and "
                    "nothing was written.",
                    request_id,
                    details={"auth_req_id": auth_req_id},
                )
                raise RuntimeError(
                    f"CIBA access denied by user (request_id={request_id})"
                )
            else:
                if error == "expired_token":
                    # CIBA token error "expired_token": the auth_req_id has expired.
                    # Same exception as any other unexpected error; reported to the
                    # browser as the approval timing out.
                    activity.hitl(
                        "timeout",
                        "Timed out: IBM Verify Identity Access reports the approval request "
                        "expired. No token was exchanged and nothing was written.",
                        request_id,
                        details={"auth_req_id": auth_req_id},
                    )
                raise RuntimeError(
                    f"CIBA poll unexpected error: {error_data} (request_id={request_id})"
                )

        raise RuntimeError(
            f"CIBA poll HTTP {resp.status_code}: {resp.text} (request_id={request_id})"
        )

    activity.hitl(
        "timeout",
        f"Timed out: no approval arrived within {CIBA_TIMEOUT_SECONDS} s. No token was "
        "exchanged and nothing was written.",
        request_id,
        details={"auth_req_id": auth_req_id, "poll_attempts": attempt},
    )
    raise TimeoutError(
        f"CIBA consent not received within {CIBA_TIMEOUT_SECONDS}s "
        f"(auth_req_id={auth_req_id}, request_id={request_id})"
    )


def _token_exchange(ciba_token: str, request_id: str) -> str:
    """RFC 8693 token exchange: produce delegated JWT with may_act claim.

    The exchange is authenticated as uc3-actor (a DIFFERENT client than
    agent-uc3, which owns the CIBA subject_token) — IVIA rejects a client
    exchanging its own token (FBTAQ5207E). No actor_token is sent: the
    may_act delegation claim is injected by the isvaop_pretoken mapping rule
    on the token-exchange grant, which is what Vault's uc3-jwt role validates.

    Presents:
      - subject_token: CIBA access token (user's identity + consent)

    IVIA issues a delegated JWT containing:
      - sub: the user (subject)
      - act / may_act: the agent SA (actor)
      - jti: unique token id (Vault OAuth resource server schema-validates it)
      - authorization_details: the RAR refund_approval scope plus the
        vault:path_access entry scoping database/creds/uc3-refund-writer

    This delegated JWT is then presented DIRECTLY as the Vault token
    (X-Vault-Token); Vault's OAuth resource server validates it and issues
    uc3-refund-writer DB credentials scoped by the vault:path_access RAR.

    Args:
        ciba_token: The CIBA access_token (user consent proof).
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
        "requested_token_type": "urn:ietf:params:oauth:token-type:access_token",
    }

    logger.info(
        "token_exchange_initiated",
        extra={
            "request_id": request_id,
            "grant_type": "token-exchange",
            "subject_token_type": "ciba_access_token",
        },
    )

    with httpx.Client(verify=IVIA_CA_BUNDLE, timeout=30.0) as client:
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


def _sub_for_label() -> str:
    """The signed-in user's sub, for a credential's plain-English label."""
    try:
        return _AUTHENTICATED_SUB.get()
    except LookupError:
        return "The user"


def _describe_token_exchange(claims: dict) -> str:
    """One Agent Log line for the RFC 8693 exchange, from decoded claims only.

    Names only what the delegated token actually carries; a claim that is
    missing is left out rather than guessed.
    """
    parts = []
    if claims.get("sub"):
        parts.append(f"subject {claims['sub']}")
    # IVIA's pretoken rule stamps both act and may_act; name may_act only when it
    # says something act does not.
    act, may_act = claims.get("act"), claims.get("may_act")
    act_sub = act.get("sub") if isinstance(act, dict) else None
    may_act_sub = may_act.get("sub") if isinstance(may_act, dict) else None
    if act_sub:
        parts.append(f"acting party (act.sub) {act_sub}")
    if may_act_sub and may_act_sub != act_sub:
        parts.append(f"may_act.sub {may_act_sub}")
    if claims.get("scope"):
        parts.append(f"scope {claims['scope']}")
    detail_types = [d["type"] for d in claims.get("authorization_details") or [] if d.get("type")]
    if detail_types:
        parts.append("authorization_details " + " + ".join(detail_types))
    if isinstance(claims.get("exp"), (int, float)):
        expires = datetime.fromtimestamp(claims["exp"], tz=timezone.utc)
        parts.append(f"expires {expires.strftime('%H:%M:%S')} UTC")
    line = "Token exchanged (RFC 8693): IBM Verify Identity Access issued a delegated token"
    return f"{line}: {', '.join(parts)}." if parts else f"{line}."


# ---------------------------------------------------------------------------
# Strands tools
# ---------------------------------------------------------------------------


@tool
def list_transactions() -> list:
    """List the authenticated user's recent transactions (read-only).

    Scoped to the verified id_token `sub` via JOIN on banking.accounts.user_sub.
    The LLM has no input into the user-filter — identity flows from the
    _AUTHENTICATED_SUB ContextVar set by main.py /chat.

    Returns:
        List of dicts with transaction details: id, account_id, amount,
        description, transaction_type, merchant, category, created_at, account_type.
    """
    global _vault_client
    if _vault_client is None:
        raise RuntimeError("UC3 vault client not initialized")

    authenticated_sub = _AUTHENTICATED_SUB.get()

    creds = _vault_client.get_readonly_credentials()

    logger.info(
        "list_transactions_called vault_role=uc3-readonly authenticated_sub=%s",
        authenticated_sub,
        extra={"vault_role": "uc3-readonly", "authenticated_sub": authenticated_sub},
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
                    "SELECT set_config('app.current_user_sub', %s, false)",
                    (authenticated_sub,),
                )
                cur.execute(
                    """
                    SELECT t.id, t.account_id, t.amount::float,
                           t.description, t.transaction_type, t.merchant,
                           t.category,
                           t.created_at AT TIME ZONE 'UTC' AS created_at,
                           a.account_type
                    FROM banking.transactions t
                    JOIN banking.accounts a ON a.id = t.account_id
                    WHERE a.user_sub = %s
                    ORDER BY t.created_at DESC
                    LIMIT 20
                    """,
                    (authenticated_sub,),
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


@tool(context=True)
def initiate_refund(
    account_id: str,
    transaction_id: str,
    amount: float,
    currency: str,
    tool_context: ToolContext,
) -> dict:
    """Initiate a CIBA consent request for a privileged refund (step 1 of 2).

    Identity is sourced from the verified id_token's `sub` claim (set by
    main.py via _AUTHENTICATED_SUB ContextVar). The LLM has no input here.

    Sends bc-authorize to IVIA with Rich Authorization Request (RFC 9396)
    details. Returns immediately with auth_req_id and consent marker so the
    banking UI can show the Approve/Deny button to the user.

    After the user approves, call complete_refund with the auth_req_id and
    request_id returned here. It takes no other arguments — the refund terms are
    bound to the approval at this point and read back from the store, never
    re-supplied by the model.

    Nothing the model passes is trusted as a figure (issue #73). Before any
    approval is requested the transaction is read from the database and the
    refund is refused, with a plain reason, unless the transaction is a debit on
    the signed-in user's account, on the account named, the currency is the
    account's own currency, and the amount is more than zero and at most the
    charge minus what is already refunded. The approval then carries the
    database's merchant, charge, amount and currency.

    Args:
        account_id: Account to credit the refund to.
        transaction_id: Original transaction being refunded.
        amount: Refund amount in the currency's main unit, not in cents
            (e.g. 34.99 for $34.99). Positive, at most two decimal places.
        currency: ISO 4217 currency code (e.g. "USD"). Must be the account's
            own currency; any other is refused.

    Returns:
        Dict with auth_req_id, request_id, and consent status.
    """
    request_id = str(uuid.uuid4())
    # tool_context is injected by Strands and is not a model input. It ties this
    # tool call to the refund's request_id, so every event it reports from here on
    # carries the SAME id as the CIBA binding_message, Vault's X-Correlation-Id,
    # the pgaudit statement comment and banking.refunds.request_id.
    activity.bind_request(tool_context, request_id)
    authenticated_sub = _AUTHENTICATED_SUB.get()
    # The owner check and the charge check, on one read-only credential. Either
    # refusal raises here, before IVIA or the phone hears anything.
    checked = _check_refund_terms(
        account_id, transaction_id, amount, currency, authenticated_sub, request_id
    )
    # From here on every figure is the database's, never the model's.
    account_id = checked["account_id"]
    transaction_id = checked["transaction_id"]
    merchant = checked["merchant"]
    charge_text = _money(checked["charge_amount"])
    amount_text = _money(checked["amount"])
    currency = checked["currency"]
    # Local — sent on the CIBA wire to IVIA; NOT exposed to LLM.
    login_hint = authenticated_sub

    logger.info(
        "initiate_refund_started",
        extra={
            "request_id": request_id,
            "account_id": account_id,
            "transaction_id": transaction_id,
            "merchant": merchant,
            "charge_amount": charge_text,
            "already_refunded": _money(checked["already_refunded"]),
            "amount": amount_text,
            "currency": currency,
        },
    )

    authorization_details = [
        {
            "type": "refund_approval",
            "transaction_id": transaction_id,
            "account_id": account_id,
            # JSON numbers, the shape IVIA has accepted for `amount` since the
            # flow was built; both come from Decimals already checked to the cent.
            "amount": float(checked["amount"]),
            "currency": currency,
            "request_id": request_id,
            "merchant": merchant,
            "charge_amount": float(checked["charge_amount"]),
        }
    ]

    ciba = _initiate_ciba(login_hint, authorization_details, request_id)
    auth_req_id = ciba["auth_req_id"]
    activity.narrate(
        "Backchannel sign-in request (CIBA) sent to IBM Verify Identity Access. It carries "
        f"the refund terms as authorization details (RFC 9396): {amount_text} {currency} to "
        f"{account_id} for the {merchant} charge of {charge_text} {currency} "
        f"(transaction {transaction_id}).",
        request_id,
    )

    rar_desc = (
        f"refund_approval {amount_text} {currency} of the {merchant} charge of "
        f"{charge_text} {currency}, transaction {transaction_id}"
    )

    # Mobile-push consent: fire an MMFA push to the AUTHENTICATED user's IBM Verify
    # device (identity straight from the verified session — never a parameter) and
    # record auth_req_id -> {username, txn_id}. The IVIA checkstatus rule later polls
    # /api/ciba/status, which reads this user's OWN SCIM transaction (the EXACT one
    # fired here) to decide approval. complete_refund's CIBA token poll drives that.
    txn_id = mmfa.fire_push(authenticated_sub)
    # Bind the terms to the approval (issue #31). These are the values the human
    # is being asked to approve; complete_refund reads them back from here rather
    # than taking them from its own tool arguments, so the model cannot substitute
    # a different figure once the approval has been granted. Every value is the
    # database's (issue #73); amount and charge_amount are Decimal.
    ciba_store.put_txn(
        auth_req_id,
        authenticated_sub,
        txn_id,
        {
            "request_id": request_id,
            "account_id": account_id,
            "transaction_id": transaction_id,
            "merchant": merchant,
            "charge_amount": checked["charge_amount"],
            "amount": checked["amount"],
            "currency": currency,
            "approver_sub": authenticated_sub,
        },
    )

    logger.info(
        "ciba_mobile_push_sent",
        extra={
            "request_id": request_id,
            "auth_req_id": auth_req_id,
            "mmfa_transaction_id": txn_id,
            "authorization_details": authorization_details,
        },
    )

    # The push itself is a generic IBM Verify approval; the refund terms travel
    # on the CIBA request above and are bound to auth_req_id in ciba_store.
    activity.hitl(
        "required",
        "Approval push sent to the user's IBM Verify app. Waiting for the user to approve "
        "before anything is written.",
        request_id,
        details={
            "amount": amount_text,
            "currency": currency,
            "merchant": merchant,
            "charge_amount": charge_text,
            "account_id": account_id,
            "transaction_id": transaction_id,
            "auth_req_id": auth_req_id,
            "channel": "mobile_push",
        },
    )

    return {
        "status": "consent_required",
        "auth_req_id": auth_req_id,
        "request_id": request_id,
        "account_id": account_id,
        "transaction_id": transaction_id,
        "merchant": merchant,
        "charge_amount": charge_text,
        "amount": amount_text,
        "currency": currency,
        "channel": "mobile_push",
        "details": rar_desc,
        "message": "An approval request was pushed to the user's IBM Verify app.",
    }


@tool(context=True)
def complete_refund(auth_req_id: str, request_id: str, tool_context: ToolContext) -> dict:
    """Complete a refund after CIBA consent is granted (step 2 of 2).

    Identity is sourced from the verified id_token's `sub` claim (ContextVar).
    The LLM has no input here.

    The refund TERMS are not arguments either (issue #31). account_id,
    transaction_id, amount and currency are read back from the approval record
    initiate_refund wrote when it fired the push — the values the human actually
    approved. Passing them in would let a non-deterministic model have $88.30
    approved on the phone and write $8,830.00 to the ledger; the only things this
    tool accepts are the two identifiers naming WHICH approval to redeem.

    Polls IVIA for consent approval, then executes:
      1. CIBA token poll (user already approved via banking UI)
      2. RFC 8693 token exchange → delegated JWT with may_act claim
      3. Present the delegated OAuth JWT directly as the Vault token
         (X-Vault-Token) → uc3-refund-writer DB credentials
      4. INSERT into banking.refunds

    Args:
        auth_req_id: CIBA auth_req_id from initiate_refund.
        request_id: Audit correlation UUID from initiate_refund.

    Returns:
        Dict with refund_id, request_id, status, and audit fields.
    """
    global _vault_client
    if _vault_client is None:
        raise RuntimeError("UC3 vault client not initialized")

    authenticated_sub = _AUTHENTICATED_SUB.get()

    # The approved terms, recovered from the approval this auth_req_id names.
    # Fail closed: no record means this process never fired that push (or it has
    # aged out of the store), and there is no safe value to fall back on.
    # The three refusals below never report the request_id argument: until all
    # three checks pass it is unverified model input. They carry the turn's own
    # requestId instead (activity.py, "The turn's requestId").
    terms = ciba_store.get_terms(auth_req_id)
    if terms is None:
        logger.warning(
            "complete_refund_no_approval_record",
            extra={"request_id": request_id, "auth_req_id": auth_req_id},
        )
        activity.narrate("Refused: there is no approval on record for this request. Nothing was written.")
        raise RefundAuthorizationError("refund_approval_not_found")

    # request_id identifies the flow for audit correlation; it must name the SAME
    # approval, otherwise the caller is redeeming one approval under another's id.
    if terms.get("request_id") != request_id:
        logger.warning(
            "complete_refund_request_id_mismatch",
            extra={
                "request_id": request_id,
                "auth_req_id": auth_req_id,
                "approved_request_id": terms.get("request_id"),
            },
        )
        activity.narrate(
            "Refused: the request ID does not match the approval it names. Nothing was written."
        )
        raise RefundAuthorizationError("refund_request_id_mismatch")

    # An approval belongs to the human who granted it — a different authenticated
    # session must not be able to redeem it.
    if terms.get("approver_sub") != authenticated_sub:
        logger.warning(
            "complete_refund_approver_mismatch",
            extra={"request_id": request_id, "auth_req_id": auth_req_id},
        )
        activity.narrate(
            "Refused: this approval belongs to a different user. Nothing was written."
        )
        raise RefundAuthorizationError("refund_approver_mismatch")

    # request_id is now proven to be the approval's own id (terms were written by
    # initiate_refund): from here on every event carries it.
    activity.bind_request(tool_context, request_id)

    account_id = terms["account_id"]
    transaction_id = terms["transaction_id"]
    # Decimal, checked to the cent against the charge by initiate_refund.
    amount = terms["amount"]
    currency = terms["currency"]
    merchant = terms.get("merchant") or "unnamed"

    _check_account_owner(
        account_id, authenticated_sub, request_id, "complete_refund"
    )

    logger.info(
        "complete_refund_started",
        extra={
            "request_id": request_id,
            "auth_req_id": auth_req_id,
            "approved_amount": amount,
            "approved_currency": currency,
            "approved_account_id": account_id,
        },
    )

    activity.narrate(
        "Checking IBM Verify Identity Access for the user's approval "
        f"(every {CIBA_POLL_INTERVAL_SECONDS} s, for up to {CIBA_TIMEOUT_SECONDS} s).",
        request_id,
    )
    ciba_token = _poll_ciba(auth_req_id, request_id)
    delegated_jwt = _token_exchange(ciba_token, request_id)
    # The narration and the audit seed carry the token's decoded claims; the
    # token itself is shown once, as a credential event, and is never part of
    # this tool's return value.
    delegated_claims = activity.delegated_token_claims(delegated_jwt)
    activity.narrate(_describe_token_exchange(delegated_claims), request_id)
    activity.credential(
        "delegated_token",
        f"{_sub_for_label()}'s delegated token from the RFC 8693 exchange",
        "IBM Verify Identity Access",
        value=delegated_jwt,
        expires_at=int(delegated_claims["exp"] * 1000)
        if isinstance(delegated_claims.get("exp"), (int, float))
        else None,
        request_id=request_id,
    )

    write_creds = _vault_client.get_refund_credentials(delegated_jwt, request_id)
    writer_lease = {
        "vault_path": "database/creds/uc3-refund-writer",
        "lease_id": write_creds.get("lease_id"),
        "ttl_seconds": write_creds.get("lease_duration"),
        # The same identifier vault_client logs: this lease was issued to the
        # delegated token presented as X-Vault-Token, not to the agent's own role.
        "auth_method": "oauth_resource_server_x_vault_token",
    }
    activity.narrate(
        "Vault issued a uc3-refund-writer database credential to the delegated token: "
        f"lease {writer_lease['lease_id']}, time-to-live {writer_lease['ttl_seconds']} s.",
        request_id,
    )

    refund_id = str(uuid.uuid4())
    approved_by = authenticated_sub
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

    # refunds_request_id_key (applications/banking-app/db/seed.sql) makes one
    # approval redeemable exactly once. Catch the violation and say WHY, rather
    # than letting a raw psycopg2 error surface as a 500 nobody can interpret.
    try:
        with psycopg2.connect(
            host=write_creds["host"],
            port=write_creds["port"],
            dbname=write_creds["dbname"],
            user=write_creds["username"],
            password=write_creds["password"],
        ) as conn:
            # The re-check below relies on READ COMMITTED: each statement sees
            # everything committed before it started, so the SELECT after the lock
            # sees a refund another approval committed while this one waited.
            # Pinned here rather than inherited from the server default.
            conn.isolation_level = psycopg2.extensions.ISOLATION_LEVEL_READ_COMMITTED
            with conn.cursor() as cur:
                # RLS WITH CHECK gate: banking.refunds is FORCE ROW LEVEL SECURITY and the
                # refund_insert_own policy verifies account_id belongs to
                # current_setting('app.current_user_sub'). Set it transaction-local (SET
                # LOCAL semantics — third arg true) BEFORE the INSERT so the check can
                # confirm ownership. authenticated_sub is the verified id_token sub and
                # _check_account_owner already proved it owns account_id; the GUC is RLS
                # request-context, not the security boundary (defense-in-depth).
                cur.execute(
                    "SELECT set_config('app.current_user_sub', %s, true)",
                    (authenticated_sub,),
                )
                # Issue #73: two approvals for one charge must never together refund
                # more than the charge. Serialise every write for this transaction
                # on a transaction-scoped advisory lock (the writer role may not row-
                # lock banking.transactions: it has no UPDATE there, and a charge with
                # no refunds yet has no refunds row to lock). The key is the uuid in
                # canonical text form, so any spelling of the same id takes the same
                # lock. Held until COMMIT or ROLLBACK.
                cur.execute(
                    "SELECT pg_advisory_xact_lock(hashtextextended(%s::uuid::text, 0))",
                    (transaction_id,),
                )
                cur.execute(
                    """
                    SELECT abs(t.amount) AS charge,
                           (SELECT COALESCE(sum(r.amount), 0)
                              FROM banking.refunds r
                             WHERE r.transaction_id = t.id) AS already_refunded
                    FROM banking.transactions t
                    WHERE t.id = %s
                      AND t.account_id = %s
                      AND t.transaction_type = 'debit'
                    """,
                    (transaction_id, account_id),
                )
                charge_row = cur.fetchone()
                refundable = charge_row[0] - charge_row[1] if charge_row else Decimal("0")
                if charge_row is None or amount > refundable:
                    logger.warning(
                        "refund_terms_refused",
                        extra={
                            "request_id": request_id,
                            "reason_code": "exceeds_refundable_at_write",
                            "tool": "complete_refund",
                            "transaction_id": transaction_id,
                            "account_id": account_id,
                            "approved_amount": _money(amount),
                            "refundable": _money(refundable),
                        },
                    )
                    reason = (
                        f"Refund refused: only {_money(refundable)} {currency} is still refundable on the "
                        f"{merchant} charge, less than the {_money(amount)} {currency} that was approved. "
                        "Another refund of this charge was written after this approval was requested. "
                        "Nothing was written."
                    )
                    activity.narrate(reason, request_id)
                    raise RefundRefusedError(reason)
                activity.narrate(
                    f"Refundable amount re-checked inside the write transaction, locked for this "
                    f"charge: {_money(charge_row[1])} {currency} of the {merchant} charge of "
                    f"{_money(charge_row[0])} {currency} is already refunded, {_money(refundable)} "
                    f"{currency} is still refundable; writing {_money(amount)} {currency}.",
                    request_id,
                )
                # OBJ-5 PLANE-A: thread request_id into the pgaudit STATEMENT field via
                # an inline SQL comment. pgaudit (log='write') captures the full statement
                # text verbatim, so the audit_correlation VIEW can regexp-extract this
                # request_id (token form uc3_request_id=<uuid>) and LEFT JOIN pgaudit_logs
                # to the ivia_decisions anchor. Zero semantics impact: comment only — the
                # 8-column INSERT tuple and placeholders are unchanged. The token value is
                # an agent-generated uuid4 (T-071-04 accept: a tampered value simply fails
                # to join, it does not escalate).
                cur.execute(
                    f"""
                    /* uc3_request_id={request_id} */
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
    except psycopg2.errors.UniqueViolation:
        logger.warning(
            "refund_already_redeemed",
            extra={"request_id": request_id, "auth_req_id": auth_req_id},
        )
        activity.narrate(
            "Refused: this approval was already redeemed. The database rejected a second "
            "refund with the same request ID.",
            request_id,
        )
        raise RefundAuthorizationError("refund_already_redeemed") from None

    activity.narrate(
        f"Refund written: INSERT into banking.refunds (refund {refund_id}, {amount} {currency} "
        f"to {account_id}) with the uc3-refund-writer credential. The statement carries "
        f"uc3_request_id={request_id} for pgaudit.",
        request_id,
    )

    # OBJ-5 Branch B: emit the ivia_decisions ANCHOR record for the three-plane
    # audit_correlation VIEW. The VIEW INNER-JOINs on ivia_decisions, so without
    # this row the whole 16-column capstone returns zero rows. This is the agent's
    # OBSERVED view of IVIA's decision (a workshop-pedagogy log), NOT IVIA's own
    # AUDIT record — the authoritative IVIA AUDIT log remains source of truth
    # (threat T-071-01, disposition accept). The agent holds NO standing AWS
    # identity (OBJ-2): CloudWatch creds come from the Vault-STS uc3-logs-writer
    # role, fetched short-lived exactly like bedrock-reader (CONTEXT Delta-6).
    # Purely additive + best-effort: a failure here must NOT break the working
    # refund flow (PR #24 chain stays GREEN), so it is wrapped and swallowed.
    try:
        logs_session = _vault_client.get_logs_credentials()
        cw_logs = logs_session.client("logs")
        log_group = "/workshop/ivia-decision"
        log_stream = f"uc3-agent/{created_at.date().isoformat()}"
        try:
            cw_logs.create_log_stream(
                logGroupName=log_group, logStreamName=log_stream
            )
        except cw_logs.exceptions.ResourceAlreadyExistsException:
            pass
        decision_record = {
            "timestamp": created_at.isoformat(),
            "request_id": request_id,
            "user_identity": approved_by,
            "decision": "approved",
            "client_id": "agent-uc3",
            "grant_type": "urn:openid:params:grant-type:ciba",
            "authorization_details": [
                {
                    "type": "refund_approval",
                    "actions": ["process_refund"],
                    "amount": _money(amount),
                    "currency": currency,
                }
            ],
            "binding_message": request_id,
            # OBJ-2 (no standing privileges): the REAL numeric lease TTL in seconds
            # (e.g. 300 = 5 min) the agent observed when Vault issued the per-refund
            # uc3-refund-writer credential. Sourced from write_creds["lease_duration"]
            # which get_refund_credentials() captured from db_response.lease_duration.
            # The Vault audit log does NOT carry this numeric value, so the agent
            # anchors it here, request_id-keyed, for the audit_correlation VIEW.
            "db_credential_ttl": write_creds.get("lease_duration"),
        }
        cw_logs.put_log_events(
            logGroupName=log_group,
            logStreamName=log_stream,
            logEvents=[
                {
                    "timestamp": int(time.time() * 1000),
                    "message": json.dumps(decision_record),
                }
            ],
        )
        logger.info(
            "ivia_decision_anchor_emitted",
            extra={"request_id": request_id, "log_group": log_group},
        )
        activity.narrate(
            f"Audit anchor written to CloudWatch Logs ({log_group}) for request {request_id}.",
            request_id,
        )
    except Exception as exc:  # noqa: BLE001 — best-effort audit emission
        logger.warning(
            "ivia_decision_anchor_emit_failed",
            extra={"request_id": request_id, "error": str(exc)},
        )
        activity.narrate(
            "The audit anchor could not be written to CloudWatch Logs. The refund itself is "
            "recorded in banking.refunds.",
            request_id,
        )

    activity.audit_seed(
        request_id=request_id,
        vault_role=_vault_client.role,
        db_role="uc3-refund-writer",
        leases=[writer_lease],
        claims=delegated_claims,
    )

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
        "merchant": merchant,
        # A two-decimal string: the tool result is JSON, and Decimal is not.
        "amount": _money(amount),
        "currency": currency,
        "approved_by": approved_by,
        "status": "approved",
        "created_at": created_at.isoformat(),
    }


@tool
def check_refund_status(refund_id: str) -> dict:
    """Check the status of a refund owned by the authenticated user.

    Uses Vault K8s auth credentials (uc3-readonly role) to SELECT from
    banking.refunds JOIN banking.accounts. No CIBA required — read-only.
    Identity comes from _AUTHENTICATED_SUB ContextVar; refund_id is the only
    LLM-controllable argument.  A refund belonging to another user returns the
    same not-found shape — no cross-user information disclosure.

    Args:
        refund_id: UUID of the refund to look up.

    Returns:
        Dict with refund details: refund_id, account_id, amount, currency,
        approved_by, request_id, status, created_at.
        {"error": "Refund <id> not found"} if not found or owned by another user.
    """
    global _vault_client
    if _vault_client is None:
        raise RuntimeError("UC3 vault client not initialized")

    authenticated_sub = _AUTHENTICATED_SUB.get()

    creds = _vault_client.get_readonly_credentials()

    logger.info(
        "check_refund_status_called",
        extra={
            "refund_id": refund_id,
            "vault_role": "uc3-readonly",
            "authenticated_sub": authenticated_sub,
        },
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
                "SELECT set_config('app.current_user_sub', %s, false)",
                (authenticated_sub,),
            )
            cur.execute(
                """
                SELECT r.refund_id, r.account_id, r.transaction_id,
                       r.amount::float, r.currency, r.approved_by, r.request_id,
                       r.created_at AT TIME ZONE 'UTC' AS created_at
                FROM banking.refunds r
                JOIN banking.accounts a ON a.id = r.account_id
                WHERE r.refund_id = %s
                  AND a.user_sub = %s
                LIMIT 1
                """,
                (refund_id, authenticated_sub),
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

    region = os.getenv("AWS_REGION") or os.getenv("AWS_DEFAULT_REGION")
    if not region:
        raise RuntimeError("AWS_REGION (or AWS_DEFAULT_REGION) must be set")
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
        "You are the OscarVault Refund Assistant.\n\n"
        "WORKFLOW — follow these steps exactly:\n"
        "1. When the user asks for a refund, call the list_transactions tool.\n"
        "2. Present results as a numbered list: description, amount, merchant, date.\n"
        "3. Ask the user which number they want to refund.\n"
        "4. When the user selects a number, confirm the transaction details and ask 'Shall I proceed?'\n"
        "5. When the user confirms, call the initiate_refund tool with:\n"
        "   - account_id: the account_id from the selected transaction\n"
        "   - transaction_id: the id from the selected transaction\n"
        "   - amount: the amount the user asked to refund, as a positive number; only if they\n"
        "     named no amount, the absolute value of the transaction's amount\n"
        "   - currency: the three-letter currency code the user named; if they named none, 'USD'\n"
        "6. initiate_refund pushes an approval request to the user's IBM Verify mobile app.\n"
        "   Tell the user EXACTLY: 'I've sent an approval request to your IBM Verify app. Open the\n"
        "   app and tap Approve, then reply here and I'll finish the refund.' Do NOT print any\n"
        "   internal IDs, tokens, or URLs.\n"
        "7. When the user says they approved (or sends any follow-up), call complete_refund with\n"
        "   ONLY the auth_req_id and request_id from the initiate_refund result (they are in the\n"
        "   tool result; never invent them). It takes no other arguments — the amount, currency,\n"
        "   account and transaction are the ones the user approved on their phone and are read\n"
        "   from the approval itself.\n"
        "8. Report exactly what the complete_refund tool returns to the user.\n\n"
        "CRITICAL RULES:\n"
        "- NEVER generate URLs, consent links, request_ids, or refund_ids yourself.\n"
        "- NEVER simulate or role-play what a tool would do. ALWAYS call the actual tool.\n"
        "- ALL data must come from tool calls, never from your own knowledge.\n"
        "- If initiate_refund refuses a refund, tell the user the reason it gave. Do NOT call\n"
        "  initiate_refund again with a different amount, transaction or currency unless the\n"
        "  user asks for it.\n"
        "- Present financial amounts with $ symbol.\n"
        "- Do NOT include JWT tokens, Vault credentials, or internal secrets in responses."
    )

    agent = Agent(
        model=bedrock_model,
        tools=[list_transactions, initiate_refund, complete_refund, check_refund_status],
        system_prompt=system_prompt,
        session_manager=session_manager,
        # Reports every tool call's start and finish to this request's activity
        # stream (see activity.py); the tools add the steps inside each call.
        hooks=[activity.ToolActivityHooks(refund_tools=frozenset({"initiate_refund", "complete_refund"}))],
    )

    logger.info(
        "uc3_agent_built",
        extra={
            "model_id": model_id,
            "region": region,
            "tools": ["list_transactions", "initiate_refund", "complete_refund", "check_refund_status"],
        },
    )
    return agent
