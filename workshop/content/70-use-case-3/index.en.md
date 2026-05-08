---
title: 'Use Case 3 — CIBA Privileged'
weight: 70
---

:::alert{header="Content pending" type="info"}
Use Case 3 triggers a CIBA out-of-band approval flow for privileged actions. The resulting JWT carries `may_act` (RFC 8693 Token Exchange) and `authorization_details` (RFC 9396 RAR) claims, enforced by Vault `bound_claims`. A bypass test confirms that forged `may_act` claims are rejected. The module culminates in the three-plane audit correlation query — the workshop's pedagogical money shot. **Demonstrates all 5 Objectives.**
:::
