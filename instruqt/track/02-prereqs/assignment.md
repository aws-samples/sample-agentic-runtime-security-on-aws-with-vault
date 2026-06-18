---
slug: prereqs
id: yfmvdznl5fkb
type: challenge
title: Prerequisites
teaser: Verify your sandbox account, the workshop repo, and your IBM Verify mobile
  app are ready.
tabs:
- id: 5ij52ehlz9b7
  title: Terminal
  type: terminal
  hostname: cloud-client
difficulty: ""
enhanced_loading: null
---

## Mobile prerequisite — IBM Verify app

Use Case 3 (Privileged Action with CIBA) will ask you to approve a refund on a
**separate device** — your phone — via an MMFA mobile push notification. Install
the free **IBM Verify** app on your mobile device before you continue:

- **iOS** — App Store, search "IBM Verify" (by IBM, Inc.):
  [apps.apple.com/us/app/ibm-verify/id1294985003](https://apps.apple.com/us/app/ibm-verify/id1294985003)
- **Android** — Google Play, search "IBM Verify" (by IBM Corporation):
  [play.google.com/store/apps/details?id=com.ibm.security.verifyapp](https://play.google.com/store/apps/details?id=com.ibm.security.verifyapp)

You will enroll the app against the workshop's IBM Verify Access (IVIA) server
during the Use Case 3 challenges — you don't need to enroll yet, just have the
app installed.

> [!NOTE]
> On your phone, allow IBM Verify to send push notifications. Without
> notifications, you won't see an Approve prompt when the CIBA refund flow runs,
> and Use Case 3 cannot complete end-to-end.

## Sandbox AWS account

The track-play setup script provisioned a fresh AWS account for you and
configured `~/.aws/credentials` automatically. Confirm it from the Terminal tab:

```bash
aws sts get-caller-identity
```

The `Account` field should match the sandbox account Instruqt allocated for
this play.

## Workshop repository

Setup also cloned the workshop repo to `/root/workshop` over SSH using the
deploy key that's stored as an Instruqt org secret. Verify:

```bash
ls /root/workshop && git -C /root/workshop log -1 --oneline
```

You should see the workshop tree (`infrastructure/`, `workshop/`, `instruqt/`,
…) and the latest commit on `main`.

## CLI tools

The Instruqt sandbox image has the workshop's required CLI tools pre-installed
(no install step needed):

```bash
terraform version && kubectl version --client && helm version --short \
  && vault version && aws --version && jq --version
```

The minimum versions the workshop expects are: kubectl 1.34.x, helm 3.12+,
terraform 1.10+, vault 1.21.x, aws CLI v2.

## Service quotas + Bedrock model access

These are validated automatically in the next challenge by
`check-prerequisites.sh --skip-tools` (which the setup script already ran
once). For reference, the deploy needs:

| Quota                | Minimum | Quota code   |
| -------------------- | ------- | ------------ |
| EC2 standard vCPUs   | 32      | `L-1216C47A` |
| VPC Elastic IPs      | 4       | `L-0263D0A3` |
| RDS DB instances     | 1       | `L-7B6409FD` |
| AOSS indexing OCUs   | 2       | `L-50FA809B` |
| AOSS search OCUs     | 2       | `L-4E98D4EB` |

Plus access to Amazon Nova Pro (your primary region) and Amazon Nova 2
Multimodal Embeddings (the Bedrock KB region). Fresh AWS accounts typically
have Nova enabled by default — Instruqt's sandbox provisioning unlocks both.

When the checks below pass, advance to the next challenge.
