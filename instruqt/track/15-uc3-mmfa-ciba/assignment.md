---
slug: uc3-mmfa-ciba
type: challenge
title: Use Case 3 — MMFA Enrollment + CIBA Refund
teaser: Enroll your phone in IBM Verify, then approve a refund out-of-band.
tabs:
  - title: Terminal
    type: terminal
    hostname: cloud-client
---

Use Case 3 demonstrates **Objective 3 — actions tied to user intent** for a
privileged write. The refund agent will not issue a 5-minute Postgres write
credential until the human user (Jaime) approves the refund **on a separate
device** via an MMFA mobile push notification — the OpenID Connect CIBA
(Client-Initiated Backchannel Authentication) flow.

## Step 1 — Enroll your phone in IBM Verify

Open the IVIA WRP authenticator URL on a desktop browser. The
deploy stamped its FQDN into `infrastructure/.acme-state`:

```bash
cd /root/workshop
NIP_FQDN_WRP=$(grep '^NIP_FQDN_WRP=' infrastructure/.acme-state | cut -d= -f2)
echo "https://${NIP_FQDN_WRP}/mga/sps/oauth/oauth20/authorize?response_type=code&client_id=AuthenticatorClient&scope=mmfaAuthn"
```

Open the printed URL, sign in as `jaime` / `WorkshopUser1!`, and scan the QR
with the IBM Verify app (you installed it during Challenge 02). The trust
store on the phone should accept the Let's Encrypt cert without prompting.

Refresh the page — your device should appear in the **Authenticators** list.

## Step 2 — Trigger a CIBA refund

Open the banking UI in another tab:

```bash
NIP_FQDN_BANKING=$(grep '^NIP_FQDN_BANKING=' infrastructure/.acme-state | cut -d= -f2)
echo "https://${NIP_FQDN_BANKING}/"
```

Sign in as `jaime` / `WorkshopUser1!`. In the chat panel:

1. Click the red **I need a refund** button in the chat suggestions bar.
2. When the agent asks which transaction to refund, reply with one of the
   transaction IDs from your recent-transactions list, then confirm.
3. **Your phone vibrates with an IBM Verify push.** Tap **Approve**.
4. Back in the chat, type: `I approved`
5. The chat reports the refund succeeded with a `Status: approved` line and
   the new refund row appears in your transaction list.

{% hint style="info" %}
The push is a real MMFA notification, not a simulation. If you don't see it,
make sure (a) the IBM Verify app has notifications enabled, (b) your phone
has data/wifi, (c) the device shows in the Authenticators list at the URL
from Step 1.
{% endhint %}

## What just happened (in plain English)

| Plane                  | What it recorded                                                       |
| ---------------------- | ---------------------------------------------------------------------- |
| IVIA decision log      | Jaime authorized refund `${request_id}` from the IBM Verify app        |
| Vault audit log        | `uc3-agent` exchanged Jaime's JWT for a 5-minute DB write credential    |
| RDS pgaudit log        | `INSERT INTO banking.refunds(...)` ran under that credential            |

A single `request_id` (W3C `traceparent`) propagated through every plane.
The next challenge inspects the Vault `bound_claims` that enforced this at
the token-exchange step.
