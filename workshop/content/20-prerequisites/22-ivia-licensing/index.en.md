---
title: 'Obtain IVIA Licenses'
weight: 22
---

IBM Verify Identity Access (IVIA) 11.0.2 runs self-hosted on EKS as the OIDC provider and CIBA authorization server for all three use cases. Before you deploy in the Deploy Foundation module, you need two licensing artifacts: an IBM Container Registry entitlement key that allows Kubernetes to pull the IVIA container image, and a 90-day trial activation certificate that unlocks the IVIA server.

Obtain both secrets before running `terraform -chdir=infrastructure apply` — deploying without them causes the IVIA pod to fail at `ImagePullBackOff` or at license validation.

## Secret 1 — IBM Container Registry Entitlement Key

The IVIA container image is hosted in the IBM Container Registry (`icr.io`). Kubernetes must authenticate to pull it. The entitlement key is a long-lived token tied to your IBM Cloud account.

<!-- TODO(ICR-KEY-URL): user to supply canonical IBM Cloud URL + steps -->

**Where to obtain:** _TBD — see workshop maintainer_

**Where to place it:** Add the key to `infrastructure/terraform.tfvars`:

```hcl
icr_entitlement_key = "<your-entitlement-key>"
```

The key has no expiry. Keep it out of version control — `infrastructure/terraform.tfvars` is already listed in `.gitignore`.

**ImagePullBackOff symptom** — If the IVIA pod shows `ImagePullBackOff` after deploy, the entitlement key is missing or incorrect. Update `icr_entitlement_key` in `infrastructure/terraform.tfvars` and re-run `terraform -chdir=infrastructure apply`.

## Secret 2 — IVIA Trial Activation Certificate

IVIA requires a signed trial certificate to activate its OIDC and CIBA features. The certificate is a 90-day trial tied to your IBM account — no purchase required.

**Where to obtain:** Request the trial at `https://isva-trial.verify.ibm.com/`

You will receive a file named `ISAM-Trial-HashiCorp.cer`. The certificate in the repository is valid until **2026-08-07**. If you are running the workshop after that date, request a fresh certificate from the URL above.

**Where to place it:** Copy the file to:

```
infrastructure/modules/verify_access/base_layer/ISAM-Trial-HashiCorp.cer
```

Terraform reads this file during `verify_access` module apply. The IVIA autoconf job imports it automatically — no manual LMI interaction is required.

:::alert{header="Trial certificate expiry" type="info"}
The trial certificate has a 90-day validity window. Check the `Not After` date before the workshop: `openssl x509 -in infrastructure/modules/verify_access/base_layer/ISAM-Trial-HashiCorp.cer -noout -dates`
:::

## Verify Both Secrets Are in Place

Before continuing to the Deploy Foundation module, confirm both artifacts exist:

```bash
# Entitlement key set in tfvars
grep -q 'icr_entitlement_key' infrastructure/terraform.tfvars && echo "ICR key: SET" || echo "ICR key: MISSING"

# Trial certificate present
[ -f infrastructure/modules/verify_access/base_layer/ISAM-Trial-HashiCorp.cer ] \
  && echo "Trial cert: PRESENT" \
  || echo "Trial cert: MISSING"
```

Both lines must print the positive result before you proceed to [Deploy Foundation](../../30-deploy-foundation/).
