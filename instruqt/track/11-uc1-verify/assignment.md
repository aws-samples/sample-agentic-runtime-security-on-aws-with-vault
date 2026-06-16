---
slug: uc1-verify
type: challenge
title: Use Case 1 — Verify Credentials
teaser: Run verify-uc1.sh — issue, observe, prove enforcement.
tabs:
  - title: Terminal
    type: terminal
    hostname: shell
---

Use Case 1 ships with an end-to-end verifier that exercises the JIT credential
flow and proves Use Case 1's identity cannot obtain Use Case 3 credentials
(the ENFC-01 enforcement boundary).

```bash
cd /root/workshop
bash infrastructure/scripts/verify-uc1.sh
```

The script:

1. Issues a JIT Postgres credential against `database/creds/uc1-readonly` and
   confirms it can `SELECT` but not `INSERT`.
2. Issues a scoped Bedrock STS credential against `aws/sts/bedrock-reader`
   and confirms it can `bedrock:Retrieve` but not `bedrock:CreateKnowledgeBase`.
3. Attempts to authenticate the `uc1-retriever-sa` JWT against the `uc3` role
   — Vault returns `403 permission denied`, proving the SA-to-policy binding
   is enforced (ENFC-01).
4. Reads the Vault audit log entry that recorded the credential issuance and
   confirms the `display_name` field ties back to `uc1-retriever-sa`.

Expected output ends with:

```
verify-uc1.sh: ALL CHECKS PASSED
```

If a check fails, the script prints the failing assertion with a `Fix:` hint
— follow it, then re-run the script (idempotent).
