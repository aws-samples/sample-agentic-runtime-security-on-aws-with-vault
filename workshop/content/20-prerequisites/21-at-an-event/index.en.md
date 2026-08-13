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

![Workshop Studio OTP sign-in — enter email to receive a one-time passcode](/static/images/ws-otp-signin.png)

Check your inbox for the 6-digit passcode and enter it:

![Workshop Studio email OTP entry — enter the 6-digit passcode from your inbox](/static/images/ws-email-passcode.png)

### Step 3 — Join the event and open the AWS console

After signing in you land on the event page. Click **Join event**, then **Open AWS console**:

![Workshop Studio event page — Join event button, then Open AWS console](/static/images/ws-open-console.png)

This opens a federated AWS console session under the **`WSParticipantRole`** identity — your workshop account for the event.

Most of the hands-on work runs from **AWS CloudShell** (a browser-based terminal with the AWS CLI pre-installed). Once your console session is open, launch CloudShell in the workshop region:

:button[Open CloudShell]{href="https://:param{key=region}.console.aws.amazon.com/cloudshell/home?region=:param{key=region}" target="_blank" variant="primary" iconName="external" iconAlign="right"}

### Step 4 — Confirm the region

In the AWS console, check the region selector in the top-right corner. It must show **`:param{key=region}`**. If it shows a different region, click the selector and switch to **`:param{key=region}`** before proceeding.

## What Is Already Provisioned for You

::::alert{header="Tier-1 and Tier-2 are pre-provisioned — you run Tier 3" type="info"}
When your AWS account was provisioned for this event, a **CloudFormation stack** ran a CodeBuild build that deployed the workshop's **Tier 1** foundation **and Tier 2** identity substrate on your behalf.

**Tier 1 — foundation:**

- Amazon VPC, EKS cluster (5-node managed node group), and add-ons
- RDS PostgreSQL with pgaudit
- Bedrock Knowledge Base and Amazon OpenSearch Serverless collection
- IAM roles, KMS keys, and audit substrate (CloudTrail, Athena, Firehose)

**Tier 2 — identity substrate:**

- HashiCorp Vault Enterprise, HA (3-node Raft), auto-unsealed with KMS — including the **Agent Registry** and the **OAuth resource server** profile
- IBM Verify Identity Access (the seven-pod IVIA stack plus OpenLDAP)
- A trusted **Let's Encrypt** certificate for your event's `nip.io` hostnames
- The Use Case container images, built and pushed to your account's ECR

This takes approximately 40 minutes and happens during account setup — not during your lab time.

**Your hands-on work begins at Tier 3** (Use Case 1, 2, and 3 agent pods). You *verify* the Tier-2 identity substrate rather than deploying it — the checks on the deploy page walk you through what was built and why each piece matters.
::::

::::alert{header="You are never asked for a licensing secret" type="info"}
Tier 2 needs a Vault Enterprise license and two IBM secrets. Your **organizer supplied all three once** at event setup, and they were used inside the build and then shredded. You do not need them, will not be prompted for them, and by design cannot read them from your account.
::::

Your `WSParticipantRole` session already has EKS cluster access (granted by the CodeBuild build). You will use that access on the [Deploy — At an Event](../../30-deploy-foundation/31-deploy-at-an-event/) page to pull the pre-provisioned state and run Tier 3.

## Next Steps

1. **Install the IBM Verify app** — Use Case 3 (CIBA mobile push) requires the IBM Verify mobile app. Install it on your phone now — see the [Prerequisites overview](../) for download links.
2. **Continue to Deploy — At an Event** — [Deploy — At an Event](../../30-deploy-foundation/31-deploy-at-an-event/) is where you pull the pre-provisioned state and run Tier 3.

The [IVIA Licensing](../22-ivia-licensing/) and [Pre-flight Checks](../23-pre-flight-checks/) pages describe what a self-paced deployer has to supply and install. At an event both are already handled — read them for background if you are curious, but there is nothing for you to do on either.
