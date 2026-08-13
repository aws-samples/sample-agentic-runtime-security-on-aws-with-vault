---
title: 'IVIA Licensing'
weight: 22
---

IBM Verify Identity Access (IVIA) 11.0.2 runs self-hosted on EKS as the OIDC provider and CIBA authorization server for all three use cases. Several IBM-supplied artifacts gate the IVIA deployment: an **entitlement key** to pull the container image, an **MMFA push client secret** for Use Case 3's mobile push, and a **trial activation certificate** to unlock the server. Separately, the Vault server (Tier 2) needs a **Vault Enterprise license** — covered at the end of this page.

::::alert{header="At an event: nothing on this page is yours to supply" type="info"}
Tier 2 was deployed for you during account setup. Your organizer supplied the entitlement key, the MMFA push secret and the Vault Enterprise license **once** at event setup; they were consumed inside the build and shredded, and your account holds no readable copy. **You will not be prompted for any of them.**

This page is background on what the deployment needs and why. The sections below marked *self-paced* apply only when you are deploying to your own AWS account.
::::

## IBM Container Registry entitlement key (self-paced: you supply this)

The entitlement key is collected by the deploy script — `deploy-workshop.sh` prompts you for it (input hidden) on its first run and writes it to the gitignored `infrastructure/services/terraform.tfvars`, so it never enters version control. You don't place it in any file; have it ready to paste at the Deploy step, or export it as `ICR_ENTITLEMENT_KEY` beforehand for a hands-off run.

At an event your organizer already supplied this key to the account-setup build — you are not prompted for it. For a self-paced run, obtain it from your IBM Cloud account (Container Software Library).

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

## Vault Enterprise license (self-paced: you supply this)

Vault runs in **Enterprise** mode — the native Agent Registry and OAuth resource server that back the on-behalf-of trust model are Enterprise features. The Tier-2 deploy therefore needs a Vault Enterprise license file (`.hclic`).

Unlike the IBM entitlement key, the license is **not** prompted — `deploy-workshop.sh` reads it from a **file** on every Tier-2 run and fails fast if it is missing. Place it before you deploy Tier 2:

- Save the license to the default path `~/Downloads/vault-ent.hclic`, **or**
- point `VAULT_ENTERPRISE_LICENSE_PATH` at wherever you saved it.

At an event your organizer already supplied the `.hclic` to the account-setup build — you do not place a license file. For a self-paced run, use your own HashiCorp Vault Enterprise license. The file is gitignored (`*.hclic`) and never committed.
