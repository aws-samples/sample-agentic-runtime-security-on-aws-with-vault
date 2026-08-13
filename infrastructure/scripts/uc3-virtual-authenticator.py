#!/usr/bin/env python3
"""uc3-virtual-authenticator.py — headless MMFA device for `verify-uc3.sh --no-phone`.

ADMIN / VERIFICATION TOOL. Not part of the attendee path and not referenced by any
workshop content: the workshop's Use Case 3 approval is a real tap on the IBM Verify
app. This exists so an admin WITHOUT an enrolled phone can still prove the whole
CIBA chain end-to-end before a delivery.

What it is: the IBM Verify app is an HTTP client of documented IVIA endpoints. This
enrolls a throwaway "device" over those SAME endpoints (OAuth authorization_code for
the AuthenticatorClient, then SCIM for the response key), and answers the real
user-presence challenge with a real RSA signature. Nothing is stubbed, mocked, or
bypassed — IVIA resolves the transaction on its own evidence, and the agent still
reads the result through its own `mmfa.read_txn_status()`. The unforgeability
property the workshop teaches is untouched: approval is bound to the exact MMFA
transaction the agent fired, so a stale or foreign approval cannot complete a refund.

Runs INSIDE the uc3-agent pod (which has httpx + cryptography and can reach both the
WRP ALB and the agent's own /chat):

    kubectl exec -i -n <ns> <pod> -- python3 - <args> < uc3-virtual-authenticator.py

Subcommands:
  run <wrp> <user> <password> <agent_client> <client_secret> <redirect_uri> <op_url>
      Enroll a virtual device, drive the real /chat refund turns, sign the approval,
      and report each step as KEY=value lines. Always deletes its own device.
  cleanup <wrp> <user> <password>
      Delete any device this tool enrolled (matched by key handle). Never touches a
      device it did not create.

Exit codes: 0 = every step succeeded, 2 = refused (a device this tool did NOT enroll
is already registered — see PREFLIGHT_OTHER), 1 = any other failure.

Output is a KEY=value protocol for verify-uc3.sh. Tokens are NEVER printed.
"""

import base64
import json
import os
import re
import sys
import time
import urllib.parse

import httpx
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa

# Key handle stamped on every response key this tool registers. It is the ONLY
# marker distinguishing our throwaway device from a real enrolled phone, so
# preflight/cleanup key off it and nothing else.
KEY_HANDLE = "uc3-no-phone-verify"

# The MMFA enrollment client shipped by IVIA (public client, scope mmfaAuthn) —
# the same one the IBM Verify app uses when it scans the enrolment QR code.
ENROLL_CLIENT_ID = "AuthenticatorClient"

TXN_SCHEMA = "urn:ietf:params:scim:schemas:extension:isam:1.0:MMFA:Transaction"
AUTH_SCHEMA = "urn:ietf:params:scim:schemas:extension:isam:1.0:MMFA:Authenticator"

MGMT_AUTHNS = "/mga/sps/mmfa/user/mgmt/authenticators"


def emit(key, value):
    """Emit one KEY=value line for verify-uc3.sh (single line, never a secret)."""
    text = " ".join(str(value).split())
    print(f"{key}={text}", flush=True)


def die(message, code=1):
    emit("ERR", message)
    sys.exit(code)


def one_line(text, limit=700):
    collapsed = " ".join(str(text).split())
    return collapsed[:limit]


def login(web, wrp, user, password):
    """Authenticate the WebSEAL session the enrolment legs run under."""
    resp = web.post(
        f"{wrp}/pkmslogin.form",
        data={
            "username": user,
            "password": password,
            "login-form-type": "pwd",
            "login-response-type": "original_url",
        },
    )
    if resp.status_code not in (200, 302):
        die(f"WebSEAL login failed for {user}: HTTP {resp.status_code}")


# Set by run()/cleanup() to re-authenticate the WebSEAL session. A no-phone run
# spans several minutes, so the session can lapse (and the junction can throw a
# transient 502) between the preflight listing and the final sweep — one retry
# behind a fresh login keeps the sweep from leaving a device enrolled.
_RELOGIN = None


def list_devices(web, wrp):
    last = ""
    for attempt in (1, 2):
        resp = web.get(f"{wrp}{MGMT_AUTHNS}", headers={"Accept": "application/json"})
        if resp.status_code == 200:
            try:
                return resp.json()
            except ValueError:
                last = f"response was not JSON: {one_line(resp.text, 200)}"
        else:
            last = f"HTTP {resp.status_code} {one_line(resp.text, 200)}"
        if attempt == 1 and _RELOGIN is not None:
            _RELOGIN()
            continue
        die(f"could not list authenticators: {last}")


def is_ours(device):
    return any(
        (method or {}).get("key_handle") == KEY_HANDLE
        for method in device.get("auth_methods") or []
    )


def delete_ours(web, wrp):
    """Delete only devices this tool enrolled. Returns (deleted, foreign_remaining)."""
    deleted = 0
    foreign = 0
    for device in list_devices(web, wrp):
        if not is_ours(device):
            foreign += 1
            continue
        resp = web.delete(f"{wrp}{MGMT_AUTHNS}/{device['id']}")
        if resp.status_code not in (200, 204) and _RELOGIN is not None:
            _RELOGIN()
            resp = web.delete(f"{wrp}{MGMT_AUTHNS}/{device['id']}")
        if resp.status_code not in (200, 204):
            die(f"could not delete virtual device {device['id']}: HTTP {resp.status_code}")
        deleted += 1
    return deleted, foreign


def mint_id_token(web, wrp, op_url, user, password, agent_client, client_secret, redirect_uri):
    """Mint the persona's id_token over the production PKCE path (same recipe as
    verify-uc3.sh:_mint_uc3_tokens). The agent's /chat requires a real IVIA
    id_token — this never fabricates one."""
    verifier = base64.urlsafe_b64encode(os.urandom(48)).rstrip(b"=").decode()
    digest = hashes.Hash(hashes.SHA256())
    digest.update(verifier.encode())
    challenge = base64.urlsafe_b64encode(digest.finalize()).rstrip(b"=").decode()
    state = base64.urlsafe_b64encode(os.urandom(12)).rstrip(b"=").decode()

    authorize = (
        f"{wrp}/isvaop/oauth2/authorize?response_type=code"
        f"&client_id={urllib.parse.quote(agent_client)}"
        f"&redirect_uri={urllib.parse.quote(redirect_uri, safe='')}"
        f"&code_challenge={challenge}&code_challenge_method=S256"
        f"&state={state}&scope=openid+profile+email"
    )
    location = web.get(authorize).headers.get("location", "")
    match = re.search(r"[?&]code=([^&]+)", location)
    if not match:
        # Session not established yet (or expired mid-run) — log in and retry once.
        login(web, wrp, user, password)
        location = web.get(authorize).headers.get("location", "")
        match = re.search(r"[?&]code=([^&]+)", location)
    if not match:
        die(f"no authorization code returned for {user} (WebSEAL login rejected?)")
    code = urllib.parse.unquote(match.group(1))

    # The OIDC provider is in-cluster with its own PKI — verified separately from
    # the public WRP leg, so this client (and only this client) skips CA checks.
    with httpx.Client(verify=False, timeout=45.0) as op:
        resp = op.post(
            f"{op_url}/oauth2/token",
            auth=(agent_client, client_secret),
            data={
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": redirect_uri,
                "code_verifier": verifier,
            },
        )
    if resp.status_code != 200:
        die(f"authorization_code exchange failed: HTTP {resp.status_code} {one_line(resp.text, 200)}")
    id_token = resp.json().get("id_token")
    if not id_token:
        die("token response carried no id_token (scope openid not granted?)")
    return id_token


def enroll_device(web, wrp):
    """Enroll over the same OAuth flow the IBM Verify app runs after a QR scan."""
    resp = web.get(
        f"{wrp}/mga/sps/oauth/oauth20/authorize?response_type=code"
        f"&client_id={ENROLL_CLIENT_ID}&scope=mmfaAuthn",
        follow_redirects=True,
    )
    match = re.search(r"[?&]code=([^&]+)", str(resp.url))
    if not match:
        die(f"no enrolment code returned (HTTP {resp.status_code}) — is the MMFA authenticator client configured?")
    code = urllib.parse.unquote(match.group(1))

    # Cookieless on purpose: with the WebSEAL session cookie attached, the OAuth EAS
    # treats the logged-in user as the client id and rejects the call (FBTOAU220E).
    with httpx.Client(verify=True, timeout=45.0) as anon:
        resp = anon.post(
            f"{wrp}/mga/sps/oauth/oauth20/token",
            data={
                "grant_type": "authorization_code",
                "client_id": ENROLL_CLIENT_ID,
                "code": code,
            },
            headers={"Accept": "application/json"},
        )
    if resp.status_code != 200:
        die(f"enrolment token exchange failed: HTTP {resp.status_code} {one_line(resp.text, 200)}")
    body = resp.json()
    if not body.get("access_token") or not body.get("authenticator_id"):
        die("enrolment response carried no access_token/authenticator_id")
    return body["access_token"], body["authenticator_id"]


def register_user_presence_key(device, wrp, bearer):
    """Register the response key IVIA will verify the approval signature against."""
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    public_der = key.public_key().public_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PublicFormat.SubjectPublicKeyInfo,
    )
    patch = {
        "schemas": ["urn:ietf:params:scim:api:messages:2.0:PatchOp"],
        "Operations": [
            {
                "op": "add",
                "path": f"{AUTH_SCHEMA}:userPresenceMethods",
                "value": [
                    {
                        "keyHandle": KEY_HANDLE,
                        "algorithm": "SHA256withRSA",
                        "publicKey": base64.b64encode(public_der).decode(),
                        "enabled": True,
                    }
                ],
            }
        ],
    }
    resp = device.patch(
        f"{wrp}/scim/Me",
        content=json.dumps(patch),
        headers={
            "Authorization": f"Bearer {bearer}",
            "Content-Type": "application/scim+json",
            "Accept": "application/scim+json",
        },
    )
    if resp.status_code not in (200, 204):
        die(f"could not register the user-presence key: HTTP {resp.status_code} {one_line(resp.text, 200)}")
    return key


def scim_transactions(device, wrp, bearer, attribute):
    resp = device.get(
        f"{wrp}/scim/Me?attributes={urllib.parse.quote(f'{TXN_SCHEMA}:{attribute}', safe=':,')}",
        headers={"Authorization": f"Bearer {bearer}", "Accept": "application/scim+json"},
    )
    if resp.status_code != 200:
        return []
    try:
        return (resp.json().get(TXN_SCHEMA) or {}).get(attribute) or []
    except ValueError:
        return []


def wait_for_pending(device, wrp, bearer, timeout):
    """Wait for the MMFA transaction the agent fired at initiate_refund."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        pending = [
            txn
            for txn in scim_transactions(device, wrp, bearer, "transactionsPending")
            if (txn.get("txnStatus") or "").upper() == "PENDING"
        ]
        if pending:
            # Newest last if the runtime orders them; approve the most recent so a
            # stale pending transaction can never stand in for this run's push.
            return pending[-1], len(pending)
        time.sleep(3)
    return None, 0


def approve(device, wrp, bearer, key, txn):
    """POST the transaction's requestUrl for a challenge, then PUT the signature.

    Both legs share one cookie jar: the apiauthsvc POST->PUT pair is stateful and
    the PUT lands on a fresh HttpSession without the JSESSIONID from the POST.
    """
    resp = device.post(
        txn["requestUrl"],
        content="{}",
        headers={
            "Authorization": f"Bearer {bearer}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
    )
    emit("CHALLENGE_STATUS", resp.status_code)
    if resp.status_code != 200:
        die(f"challenge request failed: HTTP {resp.status_code} {one_line(resp.text, 200)}")
    challenge = resp.json()
    if not challenge.get("serverChallenge") or not challenge.get("state"):
        die(f"challenge response missing serverChallenge/state: {one_line(json.dumps(challenge), 200)}")

    signature = key.sign(
        challenge["serverChallenge"].encode(), padding.PKCS1v15(), hashes.SHA256()
    )
    resp = device.put(
        f"{wrp}/mga/sps/apiauthsvc?StateId={urllib.parse.quote(challenge['state'])}",
        content=json.dumps(
            {
                "signedChallenge": base64.b64encode(signature).decode(),
                "keyHandle": KEY_HANDLE,
            }
        ),
        headers={
            "Authorization": f"Bearer {bearer}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
    )
    emit("APPROVE_STATUS", resp.status_code)
    if resp.status_code not in (200, 204):
        die(f"IVIA rejected the signed challenge: HTTP {resp.status_code} {one_line(resp.text, 200)}")


def wait_for_resolution(device, wrp, bearer, transaction_id, timeout=40):
    """Read the outcome back through the SAME surface the agent reads."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        for txn in scim_transactions(device, wrp, bearer, "transactionsResolved"):
            if txn.get("transactionId") == transaction_id:
                return (txn.get("txnStatus") or "").upper()
        time.sleep(2)
    return ""


def chat(message, session_id, id_token, timeout):
    resp = httpx.post(
        "http://127.0.0.1:8080/chat",
        json={"message": message, "sessionId": session_id},
        headers={"Authorization": f"Bearer {id_token}"},
        timeout=timeout,
    )
    return resp.status_code, one_line(resp.text)


def run(wrp, user, password, agent_client, client_secret, redirect_uri, op_url):
    session_id = f"no-phone-{int(time.time())}"
    emit("PERSONA", user)
    emit("SESSION", session_id)

    web = httpx.Client(verify=True, follow_redirects=False, timeout=45.0)
    device = httpx.Client(verify=True, follow_redirects=False, timeout=60.0)
    global _RELOGIN
    _RELOGIN = lambda: login(web, wrp, user, password)  # noqa: E731
    try:
        login(web, wrp, user, password)

        # --- Preflight: never race a device this tool did not enrol -------------
        devices = list_devices(web, wrp)
        stale = [d for d in devices if is_ours(d)]
        foreign = [d for d in devices if not is_ours(d)]
        emit("PREFLIGHT_STALE", len(stale))
        emit("PREFLIGHT_OTHER", len(foreign))
        if foreign:
            die(
                f"{user} already has {len(foreign)} enrolled device(s) this tool did not create "
                f"(ids: {','.join(d['id'] for d in foreign)}). The agent's mmfa.fire_push() targets the "
                f"first device listed, so --no-phone would race a real phone. Use the phone, or unenrol it first.",
                code=2,
            )
        if stale:
            deleted, _ = delete_ours(web, wrp)
            emit("PREFLIGHT_CLEANED", deleted)

        # --- Enrol + mint -------------------------------------------------------
        id_token = mint_id_token(
            web, wrp, op_url, user, password, agent_client, client_secret, redirect_uri
        )
        emit("ID_TOKEN_MINTED", 1)
        bearer, authenticator_id = enroll_device(web, wrp)
        emit("AUTHENTICATOR", authenticator_id)
        key = register_user_presence_key(device, wrp, bearer)
        emit("KEY_REGISTERED", 1)

        # --- Turn 1: the agent lists the persona's transactions ------------------
        status, body = chat("I need a refund", session_id, id_token, 120)
        emit("CHAT1_STATUS", status)
        emit("CHAT1", body)

        # --- Turn 2: pick one and authorize it; the agent fires the MMFA push ----
        status, body = chat("Refund transaction 1", session_id, id_token, 180)
        emit("CHAT2_STATUS", status)
        emit("CHAT2", body)

        txn, pending_count = wait_for_pending(device, wrp, bearer, 25)
        if txn is None:
            # The agent usually confirms before initiating — confirm, then wait again.
            status, body = chat(
                "Yes, send it now — I authorize this refund.", session_id, id_token, 180
            )
            emit("CHAT2B_STATUS", status)
            emit("CHAT2B", body)
            txn, pending_count = wait_for_pending(device, wrp, bearer, 90)
        if txn is None:
            die("the agent never fired an MMFA push — no pending transaction appeared (initiate_refund not reached)")
        emit("PENDING_COUNT", pending_count)
        emit("TXN_ID", txn["transactionId"])

        # --- The tap: sign the real user-presence challenge ---------------------
        approve(device, wrp, bearer, key, txn)
        resolved = wait_for_resolution(device, wrp, bearer, txn["transactionId"])
        emit("TXN_STATUS", resolved or "UNRESOLVED")
        if resolved != "SUCCESS":
            die(f"transaction {txn['transactionId']} did not resolve SUCCESS (got '{resolved or 'nothing'}')")

        # --- Turn 3: the agent polls CIBA, exchanges, and writes the refund -----
        status, body = chat("I approved the request on my device", session_id, id_token, 300)
        emit("CHAT3_STATUS", status)
        emit("CHAT3", body)
        emit("RUN_COMPLETE", 1)
    finally:
        try:
            deleted, foreign_left = delete_ours(web, wrp)
            emit("CLEANUP_DELETED", deleted)
            emit("CLEANUP_FOREIGN_LEFT", foreign_left)
        except SystemExit:
            emit("CLEANUP_DELETED", "FAILED")
        web.close()
        device.close()


def cleanup(wrp, user, password):
    global _RELOGIN
    with httpx.Client(verify=True, follow_redirects=False, timeout=45.0) as web:
        _RELOGIN = lambda: login(web, wrp, user, password)  # noqa: E731
        login(web, wrp, user, password)
        deleted, foreign_left = delete_ours(web, wrp)
        emit("CLEANUP_DELETED", deleted)
        emit("CLEANUP_FOREIGN_LEFT", foreign_left)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        die("usage: uc3-virtual-authenticator.py run|cleanup <args>")
    command = sys.argv[1]
    if command == "run":
        if len(sys.argv) != 9:
            die("usage: run <wrp> <user> <password> <agent_client> <client_secret> <redirect_uri> <op_url>")
        run(*sys.argv[2:9])
    elif command == "cleanup":
        if len(sys.argv) != 5:
            die("usage: cleanup <wrp> <user> <password>")
        cleanup(*sys.argv[2:5])
    else:
        die(f"unknown subcommand '{command}'")
