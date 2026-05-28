"""auth.py — IVIA id_token verification + authenticated-sub ContextVar for UC3.

Single import surface for both `main.py` (the FastAPI `/chat` boundary) and
`agent.py` (the Strands tools). The boundary handler verifies the inbound
`Authorization: Bearer <id_token>` cryptographically, extracts the verified
`sub` claim, and sets `_AUTHENTICATED_SUB` BEFORE invoking the agent. Tool
callbacks read `_AUTHENTICATED_SUB.get()` to learn who the authenticated user
is — identity NEVER flows in as an LLM-controllable parameter (OBJ-3, the
security-critical invariant this whole phase exists to enforce).

Security posture:
  - Algorithm allowlist: RS256 only — never trust `token.alg` from the header.
  - Required claims: sig + iss + aud + exp. Any failure surfaces as
    `AuthenticationError`, which `main.py` translates to HTTP 401.
  - `_AUTHENTICATED_SUB` is declared with NO default, so `.get()` raises
    `LookupError` if a future refactor accidentally bypasses the verify call —
    a server-side bug surfaces as HTTP 500, not as a silent identity-spoof.
  - TLS verify=False on the IVIA JWKS / discovery fetch matches the existing
    in-cluster CIBA/token-exchange posture (CONTEXT.md "Deferred Idea 1").

Required environment (read via `os.environ[...]` — fail loud at module import):
  - IVIA_BASE_URL: in-cluster IVIA OIDC endpoint, e.g.
    `https://iviaop.verify-access.svc.cluster.local:8436`
  - IVIA_ID_TOKEN_AUDIENCE: OAuth client_id whose code-flow minted the id_token
    forwarded by banking-ui (= `agent-uc2`, NOT `agent-uc3`).
"""

import logging
import os
import ssl
from contextvars import ContextVar
from typing import Optional

import httpx
import jwt
from jwt import PyJWKClient
from jwt.exceptions import (
    ExpiredSignatureError,
    InvalidAudienceError,
    InvalidIssuerError,
    InvalidSignatureError,
    InvalidTokenError,
    MissingRequiredClaimError,
    PyJWKClientError,
)

logger = logging.getLogger(__name__)


# Fail-loud env-var reads: subscript form raises KeyError on miss, which we
# re-raise as a RuntimeError so the pod's liveness fails on a config bug
# instead of silently defaulting to a wrong audience/issuer (CLAUDE.md global
# rule, 2026-05-28 — no defaultable identity-relevant values).
try:
    IVIA_BASE_URL = os.environ["IVIA_BASE_URL"]
    IVIA_ID_TOKEN_AUDIENCE = os.environ["IVIA_ID_TOKEN_AUDIENCE"]
except KeyError as exc:
    raise RuntimeError(
        "auth.py: IVIA_BASE_URL and IVIA_ID_TOKEN_AUDIENCE env vars are required"
    ) from exc


# Single canonical source for the authenticated subject. NO default — `.get()`
# raises LookupError when unset, which surfaces as HTTP 500 (server-side bug)
# rather than a silent identity-spoof.
_AUTHENTICATED_SUB: ContextVar[str] = ContextVar("authenticated_sub")


class AuthenticationError(Exception):
    """Raised on any id_token verification failure. Caller maps to HTTP 401."""

    pass


# Preserve the existing in-cluster IVIA TLS posture (verify=False) used by the
# CIBA and token-exchange helpers in agent.py — out of scope to tighten here.
_INSECURE_SSL = ssl.create_default_context()
_INSECURE_SSL.check_hostname = False
_INSECURE_SSL.verify_mode = ssl.CERT_NONE


# Lazy-init caches — populated on first verify_id_token() call. Module-level so
# the JWKS client + discovered issuer survive across requests; Optional[...] so
# the file imports cleanly on Python 3.9 (no PEP 604 `X | None` union syntax).
_JWKS_CLIENT: Optional[PyJWKClient] = None
_OIDC_ISSUER: Optional[str] = None


def _init_jwks_client() -> None:
    """Fetch IVIA OIDC discovery doc once and cache PyJWKClient + issuer.

    Lazy-init: called on first verify_id_token() invocation. On failure the
    caller maps the exception to HTTP 401 (CONTEXT line 27); we never crash
    the process at import time. Safe to retry on subsequent calls because we
    only mutate the module globals on success.
    """
    global _JWKS_CLIENT, _OIDC_ISSUER
    disc_url = f"{IVIA_BASE_URL}/oauth2/.well-known/openid-configuration"
    resp = httpx.get(disc_url, verify=False, timeout=10.0)
    resp.raise_for_status()
    disc = resp.json()
    _JWKS_CLIENT = PyJWKClient(disc["jwks_uri"], ssl_context=_INSECURE_SSL)
    _OIDC_ISSUER = disc["issuer"]


def verify_id_token(token: str) -> str:
    """Verify an IVIA RS256 id_token and return its `sub` claim.

    Validates: signature (RS256 via JWKS) + iss (from discovery doc) +
    aud (= IVIA_ID_TOKEN_AUDIENCE = banking-ui's client_id `agent-uc2`) +
    exp (not in past). Algorithm is ALLOWLISTED — never read from token.alg.

    Lazy-fetches the JWKS client + issuer on first call so a transient IVIA
    outage at pod boot maps to HTTP 401 (caller's responsibility), not a pod
    import crash.

    Raises:
        AuthenticationError: on ANY verification failure. The caller in
        main.py MUST translate to HTTP 401. The structured log line carries
        the failure category in `reason` — the token bytes are NEVER logged.
    """
    global _JWKS_CLIENT, _OIDC_ISSUER
    try:
        if _JWKS_CLIENT is None or _OIDC_ISSUER is None:
            _init_jwks_client()

        signing_key = _JWKS_CLIENT.get_signing_key_from_jwt(token)
        claims = jwt.decode(
            token,
            signing_key,
            algorithms=["RS256"],
            audience=IVIA_ID_TOKEN_AUDIENCE,
            issuer=_OIDC_ISSUER,
            options={"require": ["sub", "iss", "aud", "exp"]},
        )
    except PyJWKClientError as exc:
        logger.warning("id_token_verify_failed", extra={"reason": "jwks_fetch_failed"})
        # Reset cache so next request retries discovery (transient IVIA outage).
        _JWKS_CLIENT = None
        _OIDC_ISSUER = None
        raise AuthenticationError("jwks_fetch_failed") from exc
    except ExpiredSignatureError as exc:
        logger.warning("id_token_verify_failed", extra={"reason": "token_expired"})
        raise AuthenticationError("token_expired") from exc
    except InvalidIssuerError as exc:
        logger.warning("id_token_verify_failed", extra={"reason": "issuer_mismatch"})
        raise AuthenticationError("issuer_mismatch") from exc
    except InvalidAudienceError as exc:
        logger.warning("id_token_verify_failed", extra={"reason": "audience_mismatch"})
        raise AuthenticationError("audience_mismatch") from exc
    except InvalidSignatureError as exc:
        logger.warning("id_token_verify_failed", extra={"reason": "signature_invalid"})
        raise AuthenticationError("signature_invalid") from exc
    except MissingRequiredClaimError as exc:
        logger.warning("id_token_verify_failed", extra={"reason": "claim_missing"})
        raise AuthenticationError("claim_missing") from exc
    except InvalidTokenError as exc:
        logger.warning("id_token_verify_failed", extra={"reason": "token_invalid"})
        raise AuthenticationError("token_invalid") from exc

    sub = claims.get("sub")
    if not isinstance(sub, str) or not sub:
        logger.warning("id_token_verify_failed", extra={"reason": "sub_empty"})
        raise AuthenticationError("sub_empty")
    return sub
