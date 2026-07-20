---
title: 'At an Event'
weight: 21
---

You are attending an **AWS-led workshop event**. Before joining, read through the checklist below, then follow the access steps to open your temporary AWS account.

## Before You Start

- **Log out of any existing AWS accounts** in your browser. The workshop gives you a fresh, temporary account — if another session is active, the sign-in link may land on the wrong account.
- **No confidential data.** The workshop account is shared infrastructure for the event duration. Do not upload personal files, credentials, or proprietary data.
- **Temporary account.** The account and all resources are reclaimed by AWS after the event. Do not save work here that you need after the workshop.
- **Region: `:param{key=region}`.** Every resource the workshop deploys lives in `:param{key=region}`. Confirm the region selector in the AWS console top-right matches **`:param{key=region}`** after signing in.

## Access Steps

Follow these steps in order to join the event and open your AWS account.

### Step 1 — Open the join link

Your instructor provides either:
- A **direct join URL** (e.g., `https://catalog.us-east-1.prod.workshops.aws/join?access-code=XXXX-XXXX-XXXX`), or
- A **12-digit event code** that you type at [https://catalog.us-east-1.prod.workshops.aws/join](https://catalog.us-east-1.prod.workshops.aws/join).

Open the URL or enter the code to reach the Workshop Studio sign-in page.

### Step 2 — Sign in with Email OTP

Workshop Studio authenticates you with a one-time passcode sent to your email address.

Enter your email address on the sign-in page and click **Send passcode**:

![Workshop Studio OTP sign-in — enter email to receive a one-time passcode](/images/ws-otp-signin.png)

Check your inbox for the 6-digit passcode and enter it:

![Workshop Studio email OTP entry — enter the 6-digit passcode from your inbox](/images/ws-email-passcode.png)

### Step 3 — Join the event and open the AWS console

After signing in you land on the event page. Click **Join event**, then **Open AWS console**:

![Workshop Studio event page — Join event button, then Open AWS console](/images/ws-open-console.png)

This opens a federated AWS console session under the **`WSParticipantRole`** identity — your workshop account for the event.

Most of the hands-on work runs from **AWS CloudShell** (a browser-based terminal with the AWS CLI pre-installed). Once your console session is open, launch CloudShell in the workshop region:

:button[Open CloudShell]{href="https://:param{key=region}.console.aws.amazon.com/cloudshell/home?region=:param{key=region}" target="_blank" variant="primary" iconName="external" iconAlign="right"}

### Step 4 — Confirm the region

In the AWS console, check the region selector in the top-right corner. It must show **`:param{key=region}`**. If it shows a different region, click the selector and switch to **`:param{key=region}`** before proceeding.

## What Is Already Provisioned for You

::::alert{header="Tier-1 infrastructure is pre-provisioned — you run tier-2 and tier-3" type="info"}
When your AWS account was provisioned for this event, a **CloudFormation stack** ran a CodeBuild build that deployed the workshop's **Tier 1** foundation on your behalf:

- Amazon VPC, EKS cluster (5-node managed node group), and add-ons
- RDS PostgreSQL with pgaudit
- Bedrock Knowledge Base and Amazon OpenSearch Serverless collection
- IAM roles, KMS keys, and audit substrate (CloudTrail, Athena, Firehose)

This step takes approximately 17–22 minutes and happens during account setup — not during your lab time.

**Your hands-on work begins at Tier 2** (Vault + IBM Verify Identity Access) and **Tier 3** (Use Case 1, 2, and 3 agent pods). Those two tiers are the core of the workshop's security lesson and are what you deploy and explore yourself.
::::

Your `WSParticipantRole` session already has EKS cluster access (granted by the CodeBuild build). You will use that access on the [Deploy — At an Event](../../30-deploy-foundation/31-deploy-at-an-event/) page to pull the Tier-1 state and run Tier 2 and Tier 3.

## Next Steps

1. **Obtain IVIA licenses** — [Obtain IVIA Licenses](../22-ivia-licensing/) walks you through the IBM Container Registry entitlement key and the 90-day IVIA trial certificate. Both are required before you deploy Tier 2.
2. **Install the IBM Verify app** — Use Case 3 (CIBA mobile push) requires the IBM Verify mobile app. Install it on your phone now — see the [Prerequisites overview](../) for download links.
3. **Continue to Deploy — At an Event** — [Deploy — At an Event](../../30-deploy-foundation/31-deploy-at-an-event/) is where you pull the Tier-1 state and run Tier 2 and Tier 3.
