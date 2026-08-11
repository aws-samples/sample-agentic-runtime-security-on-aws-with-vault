---
title: 'Verify Deployment'
weight: 33
---

Everything is deployed. This section is where you confirm it — you run commands and read what comes back, working up the stack from the AWS foundation to the identity layer the Use Cases depend on.

Nothing here deploys or changes infrastructure. Each page is a set of read-only checks with the expected output printed alongside, so you can compare what your account returns against what it should return.

| Page | What you confirm |
|---|---|
| [Verify Infrastructure](./33-verify-infrastructure/) | EKS, RDS, the Bedrock Knowledge Base, the audit log groups, OpenLDAP, and the Vault native surface — one script, one summary |
| [Ingest Knowledge Base](./34-ingest-knowledge-base/) | All three Knowledge Base data sources finished ingesting (the deploy already ran this — here you confirm it, and re-trigger if needed) |
| [Validate Vault](./35-verify-vault/) | Vault is initialized, unsealed, running as a 3-node Raft cluster on an Enterprise build, with the Agent Registry populated |
| [Validate Identity Access](./36-verify-identity-access/) | The IBM Verify Identity Access stack is up, its autoconf Job completed, and the ALB is serving the trusted `nip.io` certificate |
| [The OIDC Seam](./37-oidc-seam/) | Vault's OAuth resource server profile trusts IVIA — the join where an IVIA-issued JWT becomes a Vault-vended credential |
| [Platform Health Check](./38-platform-health-check/) | One script re-checks the whole platform layer, including that the retired `jwt` auth backend is still absent |

Work through them in order. If a check does not match, each page prints a `Fix:` hint next to the failure — and at an event, a Tier-2 check that fails is worth raising with your organizer rather than trying to redeploy yourself.

Once **Platform Health Check** passes, the foundation is sound and you can start [Use Case 1](../../50-use-case-1/).
