---
slug: uc2-jwt-rls
id: smrxwjchdy7i
type: challenge
title: Use Case 2 — JWT + Row-Level Security
teaser: Per-user Vault credentials; PostgreSQL RLS enforces data isolation.
tabs:
- id: tntwwvqexfmy
  title: Terminal
  type: terminal
  hostname: cloud-client
difficulty: ""
enhanced_loading: null
---

Use Case 2 issues per-user Postgres credentials via Vault's `database/creds/uc2-personal-readonly`
role. The PostgreSQL Row-Level Security policy on `banking.accounts` filters
rows by the `app.current_user_sub` session variable. The MCP Server sets that
variable to the user's `sub` claim from the IVIA JWT on every connection,
so each user sees only their own rows.

## Run the end-to-end verifier

```bash
cd /root/workshop
bash infrastructure/scripts/verify-uc2.sh
```

The script:

1. Logs in to Vault via the `uc2-jwt` role with a forged-but-properly-signed
   JWT carrying `sub=oscar` (the test fixture lives in the script).
2. Issues a JIT Postgres credential from `database/creds/uc2-personal-readonly`.
3. Connects to RDS, sets `app.current_user_sub = 'oscar'`, runs
   `SELECT * FROM banking.accounts` — gets only Oscar's rows.
4. Sets `app.current_user_sub = 'jaime'` — gets only Jaime's rows.
5. Attempts an `INSERT` — the DB GRANT rejects it (Layer 2 enforcement).
6. Attempts an egress to an unapproved host from the MCP Server pod — the
   NetworkPolicy blocks it (Layer 3 enforcement).

Expected: `verify-uc2.sh: ALL CHECKS PASSED`.

## What you just proved

| Layer            | Mechanism                                         |
| ---------------- | ------------------------------------------------- |
| Identity (OBJ-3) | IVIA JWT `sub` claim flows through Vault to RDS   |
| Authz (OBJ-2)    | Vault JIT cred TTL = 15 min, no standing privilege |
| RLS              | `app.current_user_sub` filters rows per user      |
| DB GRANT         | INSERT/UPDATE/DELETE rejected by role grants       |
| NetworkPolicy    | Egress restricted to Vault + RDS + DNS only        |
