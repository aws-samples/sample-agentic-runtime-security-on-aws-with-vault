---
title: 'Prerequisites'
weight: 20
---

## Choose your path

Two choices decide which pages you follow. Find yours on the diagram before you start.

![Choose your path — two choices decide which workshop pages you follow. Choice 1, where your AWS account comes from: At an Event, where an AWS-led event gave you an account, Tier 1 already deployed by CodeBuild; or Self-paced, your own AWS account, where you deploy all three tiers yourself. Both then run Obtain IVIA Licenses and Run Pre-flight Checks. Choice 2, made on Run Pre-flight Checks Step 1, is where you run the commands: AWS CloudShell or your own terminal or IDE — either account can use either one. Your account then decides the deploy page, Deploy — At an Event or Deploy — Self-paced, and both merge at Configure kubectl, from where every remaining page is identical.](/static/images/choose-your-path.png)

**Choice 1 — where your AWS account comes from.** It picks your first page and your deploy page:

- An AWS-led event gave you an account — start at [At an Event](21-at-an-event/).
- You are using your own AWS account — start at [Self-paced AWS Account](21-aws-account/).

**Choice 2 — where you run the commands.** Both paths reach [Obtain IVIA Licenses](22-ivia-licensing/) and [Run Pre-flight Checks](23-pre-flight-checks/), and Step 1 of the pre-flight page asks you to pick AWS CloudShell or your own terminal. Either account works with either one.

From **Configure kubectl** onward every page is the same for everyone.

## Before you start

Before deploying any infrastructure, set up your environment using the workshop's automation scripts. Work through the sub-modules in the left navigation in order.

## Mobile prerequisite — IBM Verify app

Use Case 3 (Privileged Action with CIBA) requires you to approve a refund on a **separate device** — your phone — via an MMFA mobile push notification. Install the free **IBM Verify** app on your mobile device before the workshop starts.

- **iOS** — App Store, search "IBM Verify" (by IBM, Inc.): [apps.apple.com/us/app/ibm-verify/id1162190392](https://apps.apple.com/us/app/ibm-verify/id1162190392)
- **Android** — Google Play, search "IBM Verify" (by IBM Corporation): [play.google.com/store/apps/details?id=com.ibm.security.verifyapp](https://play.google.com/store/apps/details?id=com.ibm.security.verifyapp)

You will enroll the app against the workshop's IBM Verify Identity Access (IVIA) server **after** deployment completes — that step is covered on the [Use Case 3 landing page](../70-use-case-3/) under "Enroll your device for this workshop". You do not need to enroll yet; just have the app installed.

:::alert{header="Push notifications must be enabled" type="info"}
On your phone, allow IBM Verify to send push notifications. Without notifications, you will see no Approve prompt when the CIBA refund flow runs, and Use Case 3 cannot complete end-to-end.
:::
