---
title: 'Cleanup'
weight: 80
---

Run the teardown script to destroy all workshop resources and verify no chargeable resources remain.

## 1. Run the teardown script

From the repo root, run:

```bash
bash infrastructure/scripts/teardown.sh
```

This single command performs the full teardown in order:

1. **Terraform destroy — three roots in reverse dependency order:** `workloads` (the Use Case agent pods), then `services` (Vault + IVIA), then `infrastructure` (VPC, EKS, RDS, KB). Downstream first, because each root reads the one below it.
2. **Phase-9 native Vault resources** — run between the `workloads` and `services` destroys, while Vault is still up. Deletes the Agent Registry registrations (`uc1-agent`, `agent-uc2`, `uc3-actor`), the identity entities and aliases (those three plus `oscar` and `jaime`), the `oauth-resource-server` profile `ivia`, and **the `vault-ent-license` secret**. These are Enterprise objects inside Vault, so they cannot be reclaimed once the Vault StatefulSet is gone.
3. **Kubernetes drain** — deletes workshop namespaces (`vault`, `verify-access`, `uc1`, `banking-app`) and any NLB/ALB services managed by the AWS Load Balancer Controller
4. **AWS sweep** — tag-scoped and name-prefix-scoped sweep of every resource the workshop provisioned:
   - EKS pod-identity associations, managed add-ons, node groups, cluster, OIDC provider
   - Vault PVCs, EBS volumes, EC2 launch templates
   - ECR repositories (`workshop/uc1-agent`, `workshop/uc3-agent`, `workshop-banking-app`)
   - RDS instance, subnet groups, parameter groups, Secrets Manager secrets
   - Bedrock Knowledge Base and data sources (us-east-1)
   - OpenSearch Serverless collection and policies (us-east-1)
   - Kinesis Firehose delivery streams, CloudWatch subscription filters and log groups
   - S3 buckets (corpus, multimodal, Athena results, logs)
   - Glue catalog database, Athena workgroup
   - CloudFormation stacks
   - KMS aliases and keys (scheduled for 7-day deletion — AWS minimum)
   - IAM roles, policies, and instance profiles tagged `Workshop=agentic-runtime-security`
   - VPC: load balancers, target groups, VPC endpoints, ENIs, security groups, NAT gateways, EIPs, subnets, route tables, VPC itself
5. **Zero-residual verification** — confirms each resource class is gone before exiting
6. **Local state cleanup** — removes `infrastructure/.acme-state` and `.acme-rerun-marker`, then archives the three roots' `terraform.tfstate` files. This only runs once the verification above has passed, so a partial teardown leaves your state intact and re-runnable.

The script exits non-zero if verification finds residuals; review the output for `FAIL` lines.

## 2. Available flags

| Flag | What it does |
|---|---|
| `--dry-run` | Print what would be deleted without executing |
| `--post-destroy-only` | Skip `terraform destroy`; run sweep + verify only (useful if state is already gone) |
| `--aws-only` | K8s drain + AWS sweep only (skip Terraform) |

To preview the full sweep without making changes:

```bash
bash infrastructure/scripts/teardown.sh --dry-run
```

## 3. Spot-check after teardown

The script runs a built-in audit, but you can run these spot-checks manually to confirm nothing chargeable remains.

**EKS cluster gone:**
```bash
aws eks describe-cluster --name ars-workshop
```
Expected: `ResourceNotFoundException`

**RDS instance gone:**
```bash
aws rds describe-db-instances \
  --query "DBInstances[?starts_with(DBInstanceIdentifier,'ars-workshop')].DBInstanceIdentifier" \
  --output text
```
Expected: empty output

**S3 buckets gone:**
```bash
aws s3api list-buckets \
  --query "Buckets[?starts_with(Name,'workshop-kb') || starts_with(Name,'workshop-athena')].Name" \
  --output text
```
Expected: empty output

**No workshop-tagged IAM roles:**
```bash
aws iam list-roles \
  --query "Roles[].RoleName" --output text | tr '\t' '\n' | while read r; do
    tag=$(aws iam list-role-tags --role-name "$r" \
      --query "Tags[?Key=='Workshop' && Value=='agentic-runtime-security'].Value" \
      --output text 2>/dev/null)
    [ -n "$tag" ] && echo "$r"
  done
```
Expected: no output

**KMS keys note:** Customer-managed KMS keys are scheduled for deletion with a 7-day pending window — the minimum AWS allows. The keys will appear as `PendingDeletion` immediately after teardown; they are fully deleted after the window expires and incur no charges during that period.
