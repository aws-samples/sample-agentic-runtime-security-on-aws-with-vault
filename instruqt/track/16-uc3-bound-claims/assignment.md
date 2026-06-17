---
slug: uc3-bound-claims
id: ts9eexvmdevj
type: challenge
title: Use Case 3 — Vault bound_claims Enforcement
teaser: Inspect the may_act delegation claim and the RFC 9396 authorization_details.type
  that gate the write credential.
tabs:
- id: chqsnydsh7dh
  title: Terminal
  type: terminal
  hostname: cloud-client
difficulty: ""
enhanced_loading: null
---

The refund credential is gated by **three cryptographic enforcement points**
at the token-exchange step, all encoded as Vault `bound_claims` on the
`auth/jwt/role/uc3-refund-writer` role:

| Enforced                                       | Standard                       | Claim                                |
| ---------------------------------------------- | ------------------------------ | ------------------------------------ |
| User identity (the human who approved)         | OpenID Connect CIBA            | `sub`                                |
| Which agent may act on the user's behalf       | RFC 8693 Token Exchange        | `may_act.sub = uc3-actor`            |
| Class of action authorized                     | RFC 9396 Rich Authorization Request | `authorization_details[0].type = refund_approval` |

## Inspect the bound_claims

```bash
export VAULT_ROOT_TOKEN=$(jq -r '.root_token' ~/vault-init.json)
kubectl exec -n vault vault-0 -- \
  sh -c "VAULT_TOKEN='${VAULT_ROOT_TOKEN}' vault read -format=json auth/jwt/role/uc3-refund-writer" \
  | jq '.data.bound_claims'
```

Expected: a JSON object with `may_act.sub` pinned to `uc3-actor` and
`authorization_details[0].type` pinned to `refund_approval`.

## Bypass test — forge a token without may_act

Use Case 3 ships a bypass test that constructs a JWT with `sub=jaime` but
without the `may_act` claim, then attempts to exchange it for a Vault token.
Vault MUST reject it with `permission denied`.

```bash
cd /root/workshop
bash infrastructure/scripts/verify-uc3.sh
```

The script:

1. Inspects the `uc3-refund-writer` role's `bound_claims`.
2. Constructs the bypass token and confirms Vault rejects it.
3. Re-issues a legitimate CIBA-bound token and confirms Vault accepts it.
4. Reads the Postgres role created by the legitimate exchange and verifies
   it can `INSERT INTO banking.refunds` but not `DROP TABLE`.

Expected: `verify-uc3.sh: ALL CHECKS PASSED`.
