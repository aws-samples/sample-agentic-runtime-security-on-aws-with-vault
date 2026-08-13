---
title: 'Run Pre-flight Checks'
weight: 23
---

::::alert{header="At an event: you do not run the pre-flight script" type="info"}
Your account was provisioned with Tier 1 and Tier 2 already deployed, which means the service quotas below were **already consumed during account setup** — there is nothing to request. The deploy page deliberately passes `bootstrap.sh --skip-prereq-gate` for exactly this reason.

The one thing worth doing is confirming your CloudShell session has the CLI tools the later pages use — run the **Verify CLI tools** command below. Everything else on this page is *self-paced*.
::::

## Self-paced: CLI tools

The workshop expects these versions: kubectl 1.34.x, helm 3.12+, terraform 1.10+, vault 1.21.x, aws CLI v2, jq, and yq.

The pre-flight script installs them all and verifies your AWS account in one step. Manual install steps are intentionally omitted — running the script is the documented path. Windows users: use WSL2 (Linux subsystem).

## Self-paced: run the pre-flight script

The pre-flight script auto-installs all CLI tools, then verifies Bedrock model access, AWS service quotas, and IAM permissions in one shot. It continues past individual failures and emits a consolidated summary with copy-paste remediation for each failure.

```bash
bash infrastructure/scripts/check-prerequisites.sh
```

Available flags:
  - `--interactive` — prompt before each install AND before each check section
  - `--dry-run` — print install plan without executing
  - `--skip-iam-sim` — skip the IAM permission simulation (see the note below on at-an-event accounts)
  - `--skip-quotas` — skip the service-quota probe when the account blocks the `servicequotas` API
  - `--help` — usage

:::alert{header="At an AWS-led event: IAM permission checks will report failures, and that is expected" type="info"}
If you are running this in a Workshop Studio event account (your role is `WSParticipantRole`), the IAM permissions section will report `implicitDeny` failures for actions such as `iam:CreateRole`, `eks:CreateCluster`, and `rds:CreateDBInstance`. This is expected and does not mean anything is broken.

The check uses `iam:SimulatePrincipalPolicy`, which evaluates only the policies attached directly to your role. In an event account your permissions are granted through Service Control Policies and permission boundaries that the simulator cannot see, so it reports a denial for write actions you can actually perform. The read-only checks (for example `eks:DescribeCluster`) pass while the create/write actions appear to fail — that pattern is the signature of this simulator limitation, not a real permissions gap.

The authoritative permissions test is the deploy itself: `deploy-workshop.sh` runs a real `terraform apply`, and any genuine permission gap surfaces there as a specific `AccessDenied` on that resource. The simulation creates nothing, so skipping it leaves no setup incomplete. Re-run the pre-flight with the IAM simulation skipped (add `--skip-quotas` as well if the quota section also reports denials in your event account):

```bash
bash infrastructure/scripts/check-prerequisites.sh --skip-iam-sim --skip-quotas
```

Self-paced attendees using their own account with `AdministratorAccess` (or `PowerUserAccess` + `IAMFullAccess`) should not skip these checks — there the failures are real and tell you which policy to attach.
:::

## Verify CLI tools are installed

Confirm the key tools — self-paced, after the script completes; at an event, to check what your CloudShell session already has:

```bash
terraform version && kubectl version --client && helm version --short && vault version && aws --version
```

If any tool is missing at an event, tell your organizer before continuing — the later pages read Vault directly with the `vault` CLI.

## Self-paced: service quotas

The script also verifies these service quotas in your deploy Region. It resolves that Region exactly the way the deploy does — `AWS_REGION` if you have exported one, otherwise the `region` value in `infrastructure/terraform.tfvars` — and prints it in the banner:

```
===============================================================================
 Workshop Pre-Flight
===============================================================================
  Mode:   DEFAULT
  Region: us-east-1
```

Check that `Region:` line matches where you intend to deploy before you read any of the results below — quota and Bedrock access are Region-scoped, so a green run against the wrong Region tells you nothing about the one you are about to deploy into.

| Quota | Minimum | Quota code |
|-------|---------|------------|
| EC2 standard vCPUs | 32 | `L-1216C47A` |
| VPC Elastic IPs | 4 | `L-0263D0A3` |
| RDS DB instances | 1 | `L-7B6409FD` |
| AOSS indexing OCUs | 2 | `L-50FA809B` |
| AOSS search OCUs | 2 | `L-4E98D4EB` |

If any quota is insufficient, the script prints the exact `aws service-quotas request-service-quota-increase` command. You can also check manually:

```bash
aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A --query 'Quota.Value' --output text
```

:::alert{header="Workshop Studio quota auto-provisioning" type="info"}
AWS Workshop Studio auto-provisions these quotas before account hand-off when the workshop's publisher configures them in the Catalog Builder admin UI (Account Configuration -> Service Quotas tab). If you still encounter quota errors during deploy, run `check-prerequisites.sh` and follow the printed remediation to request increases manually.
:::

## All checks passed?

Once every check is green, continue to [Deploy Foundation](../../30-deploy-foundation/).

---

## Self-paced: container runtime (`--image-source ecr`)

The default self-paced deploy **builds the five Use Case images and pushes them to your own account's private ECR**, so a running container runtime (Docker or Podman) is **required** — install and start it before you deploy. (An optional no-build path that pulls pre-built images from your own GHCR namespace needs no container runtime; it is an advanced option documented in the repository README, not part of this walkthrough.)

**A container runtime is the one exception you install *and start* yourself — Docker *or* Podman.** The deploy builds and pushes the Use Case agent container images with whichever one you have; the pre-flight script auto-detects it but does not install it. What happens if the engine is not running depends on which one you installed:

- **Podman on macOS** — pre-flight tries to start it for you and passes if that works: `ℹ INFO Podman detected but its machine is not running — attempting 'podman machine start'` followed by `✓ PASS Container runtime: podman`. It only fails — `podman is installed but not responsive` — when the machine still will not come up.
- **Docker** — never auto-started. A stopped daemon fails with `docker is installed but the daemon is not running`.

Set up **one** of:

- **Docker** — install Docker Desktop (macOS/Windows) or Docker Engine (Linux), then **start it** and confirm `docker info` succeeds.
- **Podman** — `brew install podman` (macOS) then `podman machine init && podman machine start`; on Linux install Podman 4.0+ from [podman.io](https://podman.io/docs/installation). Confirm `podman info` succeeds.

When both are installed, the scripts prefer Podman — and because pre-flight will start a stopped Podman machine, Podman wins even if Docker is the one you had running. **On Apple Silicon that means the Rosetta requirement below applies to you even if you installed Docker**, unless you pin the runtime: force one with `WORKSHOP_CONTAINER_CLI=docker` (or `=podman`).

:::alert{header="Apple Silicon + Podman: Rosetta is required" type="warning"}
On Apple Silicon Macs (M1–M4), **Podman MUST have Rosetta enabled.** The Use Case images are built for `linux/amd64`; without Rosetta, Podman falls back to QEMU emulation, which crashes the banking-UI image build (the JavaScript bundler dies with a `fatal error: lfstack.push`). A known Podman bug ([containers/podman#28181](https://github.com/containers/podman/issues/28181)) reports `Rosetta: true` while Rosetta is actually inactive — so verify it.

```bash
# Rosetta active when this prints a 'rosetta' entry AND qemu-x86_64 is absent:
podman machine ssh ls /proc/sys/fs/binfmt_misc/ | grep -E 'rosetta|qemu-x86_64'
```

If `qemu-x86_64` is present (or `rosetta` is missing), enable Rosetta and restart the machine:

```bash
podman machine ssh 'sudo touch /etc/containers/enable-rosetta'
podman machine stop && podman machine start
```

Docker Desktop uses Rosetta automatically — this note is Podman-only. Native `amd64` Linux hosts are unaffected (no emulation).
:::

Confirm your container runtime is ready before running `deploy-workshop.sh`:

```bash
docker info --format '{{.ServerVersion}}' 2>/dev/null || podman info --format '{{.Version.Version}}'
```
