---
slug: ivia-licensing
id: cakzx4esvxyp
type: challenge
title: IVIA Licensing
teaser: Confirm the IBM Container Registry entitlement key and the IVIA trial certificate
  are in place.
tabs:
- id: csw2y85tczac
  title: Terminal
  type: terminal
  hostname: cloud-client
difficulty: ""
enhanced_loading: null
---

IBM Verify Access (IVIA) 11.0.2 runs self-hosted on EKS as the OIDC provider
and CIBA authorization server for all three use cases. It needs two licensing
artifacts before you can deploy:

1. **IBM Container Registry entitlement key** to pull the IVIA container image
2. **IVIA trial activation certificate** to unlock the OIDC + CIBA features
   (90-day trial tied to an IBM account — no purchase required)

In the Workshop Studio distribution, the attendee pastes the entitlement key
into a deploy-script prompt and downloads the trial cert manually. In the
Instruqt sandbox, both artifacts are **already provisioned for you** at the
Instruqt org level:

- `ICR_ENTITLEMENT_KEY` is an Instruqt org secret. Setup-shell injected it
  into `/root/workshop/infrastructure/services/terraform.tfvars` as
  `icr_entitlement_key = "..."` so `deploy-workshop.sh` sees it as already-set
  on first run.
- `IVIA_MMFA_PUSH_SECRET` is also an Instruqt org secret, injected the same
  way as `ivia_mmfa_push_client_secret`. Use Case 3 (CIBA mobile-push) needs it.
- The trial activation certificate ships in the repo at
  `infrastructure/modules/verify_access/base_layer/ISAM-Trial-HashiCorp.cer`
  and Terraform reads it during the IVIA module apply. The current cert is
  valid until **2026-08-07**.

{% hint style="info" %}
You never see the org secrets in plaintext — Instruqt injects them as env
vars at sandbox start, setup-cloud-client writes them to the gitignored
`infrastructure/services/terraform.tfvars`, and they are never echoed.
{% endhint %}

## Verify what was provisioned

Confirm the two services tfvars values are non-empty:

```bash
cd /root/workshop
grep -E '^(icr_entitlement_key|ivia_mmfa_push_client_secret)\s*=' \
  infrastructure/services/terraform.tfvars \
  | sed -E 's/(=.*").{8}/\1<redacted>/'
```

Expected: two lines, each showing the variable name and the first 8 characters
of the value (the rest redacted). The presence of both lines is sufficient.

Confirm the trial activation certificate file is present and not expired:

```bash
cd /root/workshop
[ -f infrastructure/modules/verify_access/base_layer/ISAM-Trial-HashiCorp.cer ] \
  && openssl x509 \
       -in infrastructure/modules/verify_access/base_layer/ISAM-Trial-HashiCorp.cer \
       -noout -dates \
  || echo "Trial cert MISSING — request a fresh one from https://isva-trial.verify.ibm.com/"
```

The `notAfter=` date must be in the future. If the cert has expired, request a
fresh one at `https://isva-trial.verify.ibm.com/` and Instruqt org-secret-rotate
the repo's deploy key with a branch that updates the file (out of scope for
this play).
