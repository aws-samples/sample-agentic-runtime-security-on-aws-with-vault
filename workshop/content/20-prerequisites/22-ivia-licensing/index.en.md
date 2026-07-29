---
title: 'IVIA Licensing'
weight: 22
---

IBM Verify Identity Access (IVIA) 11.0.2 runs self-hosted on EKS as the OIDC provider and CIBA authorization server for all three use cases. Several IBM-supplied artifacts gate the IVIA deployment: an **entitlement key** to pull the container image, an **MMFA push client secret** for Use Case 3's mobile push, and a **trial activation certificate** to unlock the server. The first two you supply at deploy time (prompt or env var); the certificate is **already included** with the workshop.

## IBM Container Registry entitlement key (you supply this)

The entitlement key is collected by the deploy script — `deploy-workshop.sh` prompts you for it (input hidden) on its first run and writes it to the gitignored `infrastructure/services/terraform.tfvars`, so it never enters version control. You don't place it in any file; have it ready to paste at the Deploy step, or export it as `ICR_ENTITLEMENT_KEY` beforehand for a hands-off run.

At an event, your organizer provides this key. For a self-paced run, obtain it from your IBM Cloud account (Container Software Library).

## IVIA Trial Activation Certificate (included — no action needed)

IVIA requires a signed trial certificate to activate its OIDC and CIBA features. **This certificate is bundled with the workshop** at:

```
infrastructure/modules/verify_access/base_layer/ISAM-Trial-HashiCorp.cer
```

Terraform reads this file during `verify_access` module apply, and the IVIA autoconf job imports it automatically — no manual LMI interaction and no attendee action are required. You do **not** request, download, or place this file; cloning the repository is all you need.

:::alert{header="Trial certificate expiry" type="info"}
The bundled certificate is a time-limited trial, and the deploy tooling validates it is still in date, so you normally don't need to think about it. If you want to confirm the window yourself, read the `Not After` date directly from the bundled file:

```bash
openssl x509 -in infrastructure/modules/verify_access/base_layer/ISAM-Trial-HashiCorp.cer -noout -dates
```

If the bundled certificate has expired (or expires before your workshop date), it is refreshed by the workshop maintainer — at an event, notify your organizer; for a self-paced run from a public release, check for an updated version of the repository. You do not replace it yourself.
:::
