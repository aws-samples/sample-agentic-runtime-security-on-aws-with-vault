---
title: 'The Bypass Test'
weight: 73
---

## What Would Happen Without `may_act` Enforcement?

If Vault's `uc3-jwt` role had no `bound_claims` on `may_act`, any agent that could obtain a CIBA-issued user token could independently perform a refund write — without the user knowing which agent acted. The delegation proof would be meaningless.

The bypass test proves enforcement is working by attempting to present forged tokens and confirming Vault rejects them at the auth layer — before any credential is issued.

## Run the Bypass Test

```bash
cd infrastructure/scripts
./verify-uc3.sh --bypass
```

The script generates two forged JWTs using PyJWT (running in a temporary Kubernetes pod) and presents each to Vault's `auth/jwt/login` endpoint.

**Expected output:**

```
ℹ  Use Case 3 — CIBA Privileged verification — BYPASS TEST MODE

ℹ  Bypass Check 12: Forge JWT with wrong may_act.sub
✓  Bypass Check 12 PASSED: Vault rejected forged may_act.sub — HS256 token not
   trusted by JWKS (signature validation + may_act.sub bound_claim enforcement)

ℹ  Bypass Check 13: Forge JWT with wrong authorization_details type
✓  Bypass Check 13 PASSED: Vault rejected wrong authorization_details type —
   HS256 token not trusted by JWKS (even if may_act.sub matched,
   authorization_details.type must equal refund_approval)

All checks passed.
```

## Two Layers of Rejection

The forged tokens are rejected by Vault for two independent reasons, either of which would be sufficient:

| Layer | Mechanism | What It Enforces |
|---|---|---|
| JWT signature | JWKS validation against IVIA's RS256 public keys | Only IVIA-signed tokens are accepted — HS256 self-signed tokens are always rejected |
| `bound_claims` | `/may_act/sub = "*"` (glob) — any `may_act.sub` value in the JWT satisfies this check; the key constraint is that `may_act` must be present and the token must be IVIA-signed | Only properly delegated RFC 8693 tokens carry `may_act`; a raw CIBA token without delegation is rejected |

The signature layer and the claim layer are both enforced. A real attacker would need to compromise IVIA's RS256 private signing key in order to produce a token that passes JWKS validation — the bound_claim on `/may_act/sub` is an additional structural check that a raw (non-delegated) CIBA token lacks the `may_act` object entirely.

### Threat Model

**What this protects against:** A rogue agent pod that obtains a user's CIBA access token (via network interception or a compromised secret) cannot use it to issue a refund. A raw CIBA access token has no `may_act` object, so the `/may_act/sub` bound_claim check fails — but more fundamentally, the forged HS256 token the bypass test generates is rejected first by JWKS signature validation: Vault trusts only tokens signed by IVIA's RS256 key pair. No DB credentials are ever issued.

**What this does NOT protect against:** A compromised agent-uc3 pod with its service account JWT intact could initiate a CIBA flow and present the resulting delegated token to Vault. Mitigations for pod compromise (e.g., falco runtime rules, IRSA session policy restrictions) are out of scope for this workshop but represent the next layer of defense.
