---
title: 'Clone the Repository'
weight: 21
---

Clone the workshop repository to your local machine. Forking is optional — you only need your own fork if you plan to push configuration changes to a personal remote.

## Step 1: Clone the Repository

```bash
git clone https://github.com/sharepointoscar/agentic-runtime-security-aws.git
cd agentic-runtime-security-aws
```

If you want your own remote copy (optional), fork first at <https://github.com/sharepointoscar/agentic-runtime-security-aws>, then replace the URL above with `https://github.com/<YOUR_GH_USER>/agentic-runtime-security-aws.git`.

## Step 2: Verify AWS Access

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

## Step 3: Verify Bedrock Model Access

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
