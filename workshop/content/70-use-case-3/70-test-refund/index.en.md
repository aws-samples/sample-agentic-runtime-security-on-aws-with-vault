---
title: 'Test the Refund Flow'
weight: 70.5
---

## Objective 3 · Actions tied to user intent

This is the whole point of Use Case 3. Watch an agent ask for permission it does not have, wait for a human on a separate device, and only then be handed a database credential that lives five minutes and can write nothing but refunds.

### 1. Open the banking app

**Why:** The banking URL is minted per deployment, like the enrollment one. Resolve it rather than typing it.

```bash
source infrastructure/.acme-state && echo "https://${NIP_FQDN_BANKING}/"
```

Open the printed URL, incognito window, sign in `jaime` / `WorkshopUser1!`.

### 2. Ask for a refund

**Why:** You are talking to an agent that can read your transactions but cannot move money on its own. Watch where it stops.

Click the red **I need a refund** button in the chat suggestions bar. When the agent asks which transaction, reply with the transaction number from your recent transactions list, then confirm.

### 3. Approve on your phone

**Why:** This is the control. The approval arrives somewhere the agent cannot reach, and nothing is written until you tap.

Tap **Approve** in the IBM Verify app, then type `I approved` in the chat.

### 4. Confirm the refund landed

**Why:** The chat's answer and the transaction list should agree. If they do, a credential was issued, used once, and expired — all inside the time it took you to read the reply.

The chat reports the refund succeeded and the transaction list shows the new row.

Sample output:

> The refund has been successfully completed. Here are the details:
>
> - **Refund ID:** a2c3c62a-6e87-4e42-ab6d-43bd2adfcd05
> - **Request ID:** b4b8f72b-6231-4fb5-832e-5966c1ad740b
> - **Account ID:** a2000000-0000-0000-0000-000000000001
> - **Transaction ID:** b2000001-0000-0000-0000-000000000005
> - **Amount:** $34.99
> - **Currency:** USD
> - **Approved By:** jaime
> - **Status:** approved
> - **Created At:** 2026-06-03T17:50:15.788006+00:00

Your IDs, amount, and timestamp will differ. What matters is that the chat returns `Status: approved` and the new row appears in your transaction list.

### If the approval push never arrives

**Why:** The agent is an LLM, and occasionally it *says* it sent the push without calling the tool that fires one. Nothing reaches your phone, and the chat looks like it worked.

Force it to actually send. Reply in the chat:

> Actually send it now — start the refund and push the approval request to my IBM Verify app. Don't just describe it.

The push should land within a few seconds. Confirm the tool really fired — a `mmfa_push_fired` line appears only when a push actually went out:

```bash
kubectl logs -n banking-app -l app=uc3-agent --tail=-1 | grep mmfa_push_fired
```

:::alert{type="warning" header="`--tail=-1` is load-bearing — without it a working push looks like a broken one"}
Given a label selector, `kubectl logs` returns only the last few lines per pod unless you ask for the whole log, and the agent writes a burst of polling lines after the push. A blank result from a truncated log is indistinguishable from "the push never fired".
:::

If the push still doesn't arrive, enable notifications for IBM Verify on your phone and confirm you completed device enrollment.
