---
title: 'Run Pre-flight Checks'
weight: 23
---

## CLI tools

The workshop expects these versions: kubectl 1.33.x, helm 3.12+, terraform 1.10+, vault 1.21.x, aws CLI v2, jq, and yq.

The pre-flight script installs them all and verifies your AWS account in one step. Manual install steps are intentionally omitted — running the script is the documented path. Windows users: use WSL2 (Linux subsystem).

## Run the pre-flight script

The pre-flight script auto-installs all CLI tools, then verifies Bedrock model access, AWS service quotas, and IAM permissions in one shot. It continues past individual failures and emits a consolidated summary with copy-paste remediation for each failure.

```bash
bash infrastructure/scripts/check-prerequisites.sh
```

Available flags:
  - `--interactive` — prompt before each install AND before each check section
  - `--dry-run` — print install plan without executing
  - `--help` — usage

## Verify CLI tools are installed

After the script completes, confirm the key tools:

```bash
terraform version
kubectl version --client
helm version --short
vault version
aws --version
```

## Service quotas

The script also verifies these service quotas in `us-west-2`:

| Quota | Minimum | Quota code |
|-------|---------|------------|
| EC2 standard vCPUs | 32 | `L-1216C47A` |
| VPC Elastic IPs | 4 | `L-0263D0A3` |
| RDS DB instances | 1 | `L-7B6409FD` |
| AOSS indexing OCUs | 2 | `L-50FA809B` |
| AOSS search OCUs | 2 | `L-4E98D4EB` |

If any quota is insufficient, the script prints the exact `aws service-quotas request-service-quota-increase` command. You can also check manually:

```bash
aws service-quotas get-service-quota \
  --service-code ec2 \
  --quota-code L-1216C47A \
  --region us-west-2 \
  --query 'Quota.Value' \
  --output text
```

:::alert{header="Workshop Studio quota auto-provisioning" type="info"}
AWS Workshop Studio auto-provisions these quotas before account hand-off when the workshop's publisher configures them in the Catalog Builder admin UI (Account Configuration -> Service Quotas tab). If you still encounter quota errors during deploy, run `check-prerequisites.sh` and follow the printed remediation to request increases manually.
:::

## All checks passed?

Once every check is green, continue to [Deploy Foundation](../../30-deploy-foundation/).
