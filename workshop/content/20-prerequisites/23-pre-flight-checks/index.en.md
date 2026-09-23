---
title: 'Run Pre-flight Checks'
weight: 23
---

## Step 1 — Choose where you will run the workshop

Every command in this workshop runs from one shell. Pick it now — your choice follows you down the page.

:::::tabs{groupId="workshop-env"}

::::tab{label="AWS CloudShell" id="cs"}

Open **CloudShell** from the AWS console toolbar, in the same Region you will deploy into. It runs with your console session's own credentials, so there is nothing to configure.

Two things about CloudShell that the rest of the workshop assumes you have done:

**CloudShell keeps only your home directory.** Tools installed outside `$HOME` are gone after an idle disconnect. If your session drops, re-run the pre-flight script in Step 2 — it reinstalls whatever is missing.

**Put the Vault Enterprise license in your home directory**, at the path the Deploy Foundation pages already use. Create the directory first:

```bash
mkdir -p ~/Downloads
```

Then **Actions → Upload file**, target `~/Downloads`, and confirm it landed:

```bash
ls -la ~/Downloads/vault-ent.hclic
```

:::alert{header="Self-paced: deploy from a local terminal, not CloudShell" type="warning"}
The self-paced deploy builds the five Use Case container images on the machine you run it from, and CloudShell has no container runtime. Run the self-paced path from a local terminal instead.

At an AWS-led event this does not apply — CodeBuild built and pushed those images during Tier 1, so you run only Tiers 2 and 3 and never build anything.
:::
::::

::::tab{label="Local terminal or IDE" id="local"}

Use your own terminal on macOS or Linux. On Windows, use **WSL2** — the scripts are bash and expect a Linux shell.

The pre-flight script in Step 2 installs every CLI tool for you, through Homebrew, apt or yum depending on your system.

Note where you saved the Vault Enterprise license — the Deploy Foundation pages ask for its path, and show `~/Downloads/vault-ent.hclic` as the default.

If you are self-paced, you also need a container runtime running before you deploy — see **the container runtime you install yourself** at the bottom of this page.
::::

:::::

## Step 2 — Run the pre-flight script

**Why:** One command installs every CLI tool, then checks the things that silently break a deploy two hours later — Bedrock model access, service quotas, IAM permissions. It continues past individual failures and ends with one summary carrying a copy-paste fix for each.

```bash
bash infrastructure/scripts/check-prerequisites.sh
```

The workshop expects kubectl 1.34.x, helm 3.12+, terraform 1.10+, vault 1.20.4+, aws CLI v2, jq and yq. The script installs them all — there are no manual install steps to follow.

Flags:

- `--interactive` — prompt before each install and each check section
- `--dry-run` — print the install plan without executing
- `--skip-iam-sim` — skip the IAM permission simulation (see the note below)
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

## Step 3 — Confirm the tools are installed

**Why:** The script reports its own success. This is the independent check, and it is the one command to re-run first if anything later says "command not found".

```bash
terraform version && kubectl version --client && helm version --short && vault version && aws --version
```

## All checks passed?

Once every check is green, continue to [Deploy Foundation](../../30-deploy-foundation/).

---

::::expand{header="Reference — the service quotas the script checks"}

The script verifies these quotas in your deploy Region:

| Quota | Minimum | Quota code |
|-------|---------|------------|
| EC2 standard vCPUs | 32 | `L-1216C47A` |
| VPC Elastic IPs | 4 | `L-0263D0A3` |
| RDS DB instances | 1 | `L-7B6409FD` |
| AOSS indexing OCUs | 2 | `L-50FA809B` |
| AOSS search OCUs | 2 | `L-4E98D4EB` |

If any quota is insufficient, the script prints the exact `aws service-quotas request-service-quota-increase` command. You can also check one manually:

```bash
aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A --query 'Quota.Value' --output text
```

:::alert{header="Workshop Studio quota auto-provisioning" type="info"}
AWS Workshop Studio auto-provisions these quotas before account hand-off when the workshop's publisher configures them in the Catalog Builder admin UI (Account Configuration -> Service Quotas tab). If you still encounter quota errors during deploy, run `check-prerequisites.sh` and follow the printed remediation to request increases manually.
:::
::::

::::expand{header="Self-paced only — the container runtime you install yourself"}

The default self-paced deploy **builds the five Use Case images and pushes them to your own account's private ECR**, so a running container runtime is **required**. This is the one tool the pre-flight script detects but does not install, and **CloudShell cannot provide it** — run the self-paced deploy from a local terminal.

At an AWS-led event none of this applies: CodeBuild built and pushed the images during Tier 1.

Installing a runtime is not enough — the engine must be **running** before you deploy, or the pre-flight check fails with "installed but not running". Set up **one** of:

- **Docker** — install Docker Desktop (macOS/Windows) or Docker Engine (Linux), then **start it** and confirm `docker info` succeeds.
- **Podman** — `brew install podman` (macOS) then `podman machine init && podman machine start`; on Linux install Podman 4.0+ from [podman.io](https://podman.io/docs/installation). Confirm `podman info` succeeds.

When both are installed, the scripts prefer Podman; force one with `WORKSHOP_CONTAINER_CLI=docker` (or `=podman`).

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
::::
