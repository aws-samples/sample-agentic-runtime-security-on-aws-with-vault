---
title: 'Obtain IVIA Licenses'
weight: 22
---

IBM Verify Identity Access (IVIA) 11.0.2 runs self-hosted on EKS as the OIDC provider and CIBA authorization server for all three use cases. It needs two licensing artifacts before you deploy: an **IBM Container Registry entitlement key** to pull the IVIA container image, and a **90-day trial activation certificate** to unlock the IVIA server.

The entitlement key is collected by the deploy script — `deploy-workshop.sh` prompts you for it (input hidden) on its first run and writes it to the gitignored `infrastructure/services/terraform.tfvars`, so it never enters version control. You don't place it in any file; just obtain it from your IBM Cloud account and have it ready to paste at the Deploy step. The trial activation certificate below is the one artifact you stage by hand.

## IVIA Trial Activation Certificate

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

## Verify the Trial Certificate Is in Place

The entitlement key is supplied later, at the deploy prompt — nothing to verify for it here. Before continuing to the Deploy Foundation module, confirm the trial certificate file exists:

```bash
[ -f infrastructure/modules/verify_access/base_layer/ISAM-Trial-HashiCorp.cer ] \
  && echo "Trial cert: PRESENT" \
  || echo "Trial cert: MISSING"
```

`Trial cert: PRESENT` must print before you proceed to [Deploy Foundation](../../30-deploy-foundation/).
