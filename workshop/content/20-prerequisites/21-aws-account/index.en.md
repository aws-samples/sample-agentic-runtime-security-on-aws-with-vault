---
title: 'Clone the Repository'
weight: 21
---

You need **your own GitHub repository** for this workshop. HCP Terraform connects to a Git repository you control so it can watch branches and trigger plans on push.

## Step 1: Fork the Repository

1. Sign in to GitHub and go to <https://github.com/sharepointoscar/agentic-runtime-security-aws>
2. Click **Fork** (top right) and create a copy under your own GitHub account or org

## Step 2: Clone Your Fork

Replace `<YOUR_GH_USER>` with your GitHub username (or org name):

```bash
git clone https://github.com/<YOUR_GH_USER>/agentic-runtime-security-aws.git
cd agentic-runtime-security-aws
```

## Step 3: Verify AWS Access

Confirm your AWS CLI is configured and you can reach the target account:

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

If the output starts with `arn:aws:sts::` (assumed role), note the underlying IAM role ARN — you will need it as `admin_principal_arn` in the next step.

## Step 4: Verify Bedrock Model Access

The workshop uses two Amazon Nova models. Verify they are enabled:

```bash
aws bedrock get-foundation-model \
  --model-identifier us.amazon.nova-pro-v1:0 \
  --region us-west-2 \
  --query 'modelDetails.modelId' \
  --output text
```

**Expected output:** `us.amazon.nova-pro-v1:0`

```bash
aws bedrock get-foundation-model \
  --model-identifier amazon.nova-2-multimodal-embeddings-v1:0 \
  --region us-east-1 \
  --query 'modelDetails.modelId' \
  --output text
```

**Expected output:** `amazon.nova-2-multimodal-embeddings-v1:0`

If either command returns access denied, request access via the Bedrock console model-access page in both [us-west-2](https://us-west-2.console.aws.amazon.com/bedrock/home#/modelaccess) and [us-east-1](https://us-east-1.console.aws.amazon.com/bedrock/home#/modelaccess).

:::alert{header="Amazon Nova is usually enabled by default" type="info"}
Amazon's own Nova family is generally enabled by default in fresh AWS accounts (no click-through acceptance), unlike Anthropic Claude models. **Cost note:** Nova Pro on-demand pricing (~$0.80 / 1M input tokens, ~$3.20 / 1M output tokens); total LLM cost for a single workshop run is typically under $0.10.
:::
