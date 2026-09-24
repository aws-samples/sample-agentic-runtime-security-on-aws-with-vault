---
title: 'Self-paced AWS Account'
weight: 21
---

::::alert{header="Skip this section if you are at an AWS-led event" type="warning"}
If you received a Workshop Studio invite link or a 12-digit event code from an instructor, your AWS account is already provisioned and Tier-1 infrastructure is already running. Go to [At an Event](../21-at-an-event/) instead. The steps on this page apply only to self-paced attendees running the workshop in their own AWS account.
::::

## Tooling Prerequisites

Install the following tools before running any workshop scripts. The workshop's `check-prerequisites.sh` script verifies each one and installs missing tools automatically (Homebrew on macOS, apt on Linux).

| Tool | Minimum version | Notes |
|------|----------------|-------|
| AWS CLI | v2 | `aws --version` |
| Terraform | 1.10+ | `terraform -version` — 1.10 is required for the workshop's deploy scripts |
| kubectl | 1.34+ | `kubectl version --client` |
| Helm | 3.12+ | `helm version` |
| Docker or Podman | Any recent | Required for the default self-paced deploy (builds the images into your account ECR). Only the optional no-build GHCR path (advanced; documented in the repo README) skips it. |
| jq | 1.6+ | `jq --version` |

The checker lives inside the workshop repo, so you clone first and run it in **Step 2** below.

## Deployer IAM Permissions

Your AWS CLI identity needs permissions to create all Tier-1 resources: EKS cluster, VPC, RDS, Bedrock KB, IAM roles, KMS keys, CloudWatch log groups, Firehose delivery streams, Athena workgroup, and AOSS collection. The `bootstrap.sh` script stamps your current identity as `admin_principal_arn` in `infrastructure/terraform.tfvars`.

At minimum you need the AWS managed policies **PowerUserAccess** plus **IAMFullAccess**, or an equivalent custom policy. The workshop does not restrict attendees to least-privilege for the deployer identity — the lesson focuses on workload-identity controls at runtime, not on deployer IAM.

## Step 1: Configure Your AWS CLI Credentials

Everything that follows — the pre-flight checker, `bootstrap.sh`, every `terraform apply` — runs as whatever identity your AWS CLI is configured with. Set that up first. Pick the environment you will work in:

### Option A — AWS CloudShell (nothing to configure)

Sign in to the AWS console as your own account, confirm the region selector reads **`:param{key=region}`**, then launch CloudShell:

:button[Open CloudShell]{href="https://:param{key=region}.console.aws.amazon.com/cloudshell/home?region=:param{key=region}" target="_blank" variant="primary" iconName="external" iconAlign="right"}

CloudShell runs with your console session's own credentials, so there is nothing to configure. Skip to the verification command below.

::::alert{header="CloudShell forgets your tools, not your files" type="info"}
Tools installed outside `$HOME` are gone after an idle disconnect. If your session drops, re-run the pre-flight script in Step 2. The Vault license you upload and the `~/vault-init.json` the deploy writes both live in `$HOME` and survive.
::::

### Option B — Your own terminal or IDE

macOS or Linux. Configure the AWS CLI with whichever of these matches your account.

**IAM Identity Center (AWS SSO)** — the usual case for an organization account:

```bash
aws configure sso
```

Answer the prompts, then sign in from the browser tab it opens. It writes a named profile; select it for this shell with `export AWS_PROFILE=<profile-name>`.

**Long-lived IAM access keys:**

```bash
aws configure
```

It prompts for your access key ID, secret access key, default region (**`:param{key=region}`**) and output format. Create the key pair in the IAM console under your own user — never reuse someone else's.

**A profile you already have** — just select it:

```bash
export AWS_PROFILE=<profile-name>
```

### Verify — both options

**Why:** Confirm the CLI is configured, pointed at the account you meant, and carrying the identity that will own everything the deploy creates.

```bash
aws sts get-caller-identity
```

**Expected output:**

```json
{
    "UserId": "AIDAXXXXXXXXXXXXXXXXX",
    "Account": "123456789012",
    "Arn": "arn:aws:iam::123456789012:user/your-user"
}
```

If the output starts with `arn:aws:sts::` (assumed role), note the underlying IAM role ARN — `bootstrap.sh` stamps it as `admin_principal_arn` in `infrastructure/terraform.tfvars`.

If it fails with `Unable to locate credentials`, nothing above took effect — re-run the configuration route that matches your account.

## Step 2: Clone the Repository and Run the Pre-flight Checker

**Why:** Everything below runs from inside the repo. This clone is safe to re-run — if the repo is already there it just moves you into it.

```bash
cd ~ && { [ -d sample-agentic-runtime-security-on-aws-with-vault ] || git clone https://github.com/aws-samples/sample-agentic-runtime-security-on-aws-with-vault.git; } && cd sample-agentic-runtime-security-on-aws-with-vault && pwd
```

**Why:** One command installs and verifies every CLI tool in the table above, then checks the things that silently break a deploy two hours later — Bedrock model access, service quotas, IAM permissions. It authenticates as the identity you set up in Step 1.

```bash
bash infrastructure/scripts/check-prerequisites.sh
```

## Step 3: Verify Bedrock Model Access

The workshop uses two Amazon Nova models. Verify they are enabled before deploying.

**Nova Pro** is reached through a cross-region inference (CRIS) profile. Validate it with `get-inference-profile`:

```bash
aws bedrock get-inference-profile --inference-profile-identifier us.amazon.nova-pro-v1:0 --query 'inferenceProfileId' --output text
```

**Expected output:** `us.amazon.nova-pro-v1:0`

**Nova 2 Multimodal Embeddings** is a direct model, validated with `get-foundation-model`:

```bash
aws bedrock get-foundation-model --model-identifier amazon.nova-2-multimodal-embeddings-v1:0 --region us-east-1 --query 'modelDetails.modelId' --output text
```

**Expected output:** `amazon.nova-2-multimodal-embeddings-v1:0`

If either command returns access denied, request access via the Bedrock console model-access page in **your deploy Region** (for Nova Pro) and in [**us-east-1**](https://us-east-1.console.aws.amazon.com/bedrock/home#/modelaccess) (for the Nova 2 embeddings model, which is us-east-1-only).

::::alert{header="Amazon Nova is usually enabled by default" type="info"}
Amazon's own Nova family is generally enabled by default in fresh AWS accounts (no click-through acceptance), unlike Anthropic Claude models.
::::

## Step 4: Gather Your Inputs

The deploy script needs these inputs on its first run. Have them ready:

| Input | Where to obtain |
|-------|----------------|
| **Let's Encrypt contact email** (`acme_email`) | A real, deliverable email address for TLS certificate issuance and renewal notices. The placeholder `example.com` is rejected by Let's Encrypt. |
| **IBM Container Registry entitlement key** | From [Obtain IVIA Licenses](../22-ivia-licensing/) — the key to pull the IVIA container image from `icr.io`. Input is hidden when pasted, or set `ICR_ENTITLEMENT_KEY` to skip the prompt. |
| **IBM Verify MMFA push client secret** | From [Obtain IVIA Licenses](../22-ivia-licensing/) — required by Use Case 3 (CIBA mobile push). Input is hidden when pasted, or set `IVIA_MMFA_PUSH_CLIENT_SECRET` to skip the prompt. |
| **Vault Enterprise license** (`.hclic`) | From [Obtain IVIA Licenses](../22-ivia-licensing/#vault-enterprise-license-you-supply-this) — Tier 2 runs Vault in Enterprise mode. Read from a **file**, not prompted: save it to `~/Downloads/vault-ent.hclic` or set `VAULT_ENTERPRISE_LICENSE_PATH`. |

The script writes the prompted values into the gitignored `terraform.tfvars` files; subsequent tiers and re-runs reuse them silently. The Vault Enterprise license is re-read from its file on every run.

## Step 5: Deploy

Go to [Deploy — Self-paced](../../30-deploy-foundation/31-deploy-self-paced/): `bootstrap.sh` → Tier 1 → Tier 2 → Tier 3.
