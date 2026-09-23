---
title: 'Prerequisites'
weight: 20
---

Before deploying any infrastructure, set up your environment using the workshop's automation scripts. Work through the sub-modules in the left navigation in order.

## Mobile prerequisite — IBM Verify app

Use Case 3 (Privileged Action with CIBA) requires you to approve a refund on a **separate device** — your phone — via an MMFA mobile push notification. Install the free **IBM Verify** app on your mobile device before the workshop starts.

- **iOS** — App Store, search "IBM Verify" (by IBM, Inc.): [apps.apple.com/us/app/ibm-verify/id1162190392](https://apps.apple.com/us/app/ibm-verify/id1162190392)
- **Android** — Google Play, search "IBM Verify" (by IBM Corporation): [play.google.com/store/apps/details?id=com.ibm.security.verifyapp](https://play.google.com/store/apps/details?id=com.ibm.security.verifyapp)

You will enroll the app against the workshop's IBM Verify Identity Access (IVIA) server **after** deployment completes — that step is covered on the [Use Case 3 landing page](../70-use-case-3/) under "Enroll your device for this workshop". You do not need to enroll yet; just have the app installed.

:::alert{header="Push notifications must be enabled" type="info"}
On your phone, allow IBM Verify to send push notifications. Without notifications, you will see no Approve prompt when the CIBA refund flow runs, and Use Case 3 cannot complete end-to-end.
:::
