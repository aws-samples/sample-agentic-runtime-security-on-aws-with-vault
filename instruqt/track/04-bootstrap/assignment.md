---
slug: bootstrap
type: challenge
title: Bootstrap Terraform Roots
teaser: Seed the three terraform.tfvars files and run terraform init in all three roots.
tabs:
  - title: Terminal
    type: terminal
    hostname: cloud-client
---

The workshop is split into three local-state Terraform roots, applied in
dependency order. Each downstream root reads the upstream root's state, so
Terraform enforces the order for you:

- **Tier 1** — `infrastructure/` — VPC, EKS, add-ons, RDS, Bedrock KB, ECR, IAM
- **Tier 2** — `infrastructure/services/` — Vault server + IBM Verify Access
- **Tier 3** — `infrastructure/workloads/` — the Use Case 1, 2, and 3 agent pods

`bootstrap.sh` seeds all three `terraform.tfvars` files from their templates,
stamps the tier-1 `admin_principal_arn` from your STS identity, and runs
`terraform init` in all three roots.

The track-play setup already ran `bootstrap.sh --skip-prereq-gate` for you, and
the three values that the Workshop Studio path prompts for at deploy time
(`acme_email`, `icr_entitlement_key`, `ivia_mmfa_push_client_secret`) were
injected by setup-cloud-client from the Instruqt runtime_parameter and org secrets.
This challenge just verifies the result.

## Verify the bootstrap

Confirm the three tfvars files exist and carry the seeded values:

```bash
cd /root/workshop
ls -la infrastructure/terraform.tfvars \
       infrastructure/services/terraform.tfvars \
       infrastructure/workloads/terraform.tfvars
```

Confirm the `admin_principal_arn` was stamped from your STS identity:

```bash
grep -E '^admin_principal_arn\s*=' /root/workshop/infrastructure/terraform.tfvars
```

Confirm tier-1, tier-2, and tier-3 are all `terraform init`-ed (each `.terraform/`
directory should exist):

```bash
for d in /root/workshop/infrastructure \
         /root/workshop/infrastructure/services \
         /root/workshop/infrastructure/workloads; do
    [ -d "$d/.terraform" ] && echo "OK $d" || echo "MISSING $d"
done
```

All three should print `OK`.
