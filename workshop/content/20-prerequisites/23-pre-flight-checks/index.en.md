---
title: 'Run Pre-flight Checks'
weight: 23
---

## CLI tools

The workshop expects these versions: kubectl 1.34.x, helm 3.12+, terraform 1.10+, vault 1.21.x, aws CLI v2, jq, and yq.

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
terraform version && kubectl version --client && helm version --short && vault version && aws --version
```

## Service quotas

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
