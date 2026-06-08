---
title: 'Test the Refund Flow'
weight: 70.5
---

This is the heart of Use Case 3 — a refund write executes only after the human approves it out-of-band on a mobile device, and only with a 5-minute Vault-issued database credential.

**1. Open the banking app** — incognito window, sign in `jaime` / `WorkshopUser1!`. The banking UI is served on the nip.io FQDN that `bash infrastructure/scripts/configure-workshop.sh` provisioned a Let's Encrypt cert for (stored in `infrastructure/.acme-state` as `NIP_FQDN_BANKING`):

```bash
grep '^NIP_FQDN_BANKING=' infrastructure/.acme-state
```

Open `https://<NIP_FQDN_BANKING>/` in your browser — you should see a lock icon (trusted Let's Encrypt cert). If you see a "Your connection is not private" warning, re-run `bash infrastructure/scripts/configure-workshop.sh` to re-issue the cert.

**2. Click the red `I need a refund` button** in the chat suggestions bar.

**3. Pick the transaction.** When the agent asks which transaction to refund, reply with the transaction number from your recent transactions list, then confirm when prompted.

**4. Approve the push** on the IBM Verify app (tap **Approve**).

**5. In the chat, type:** `I approved`

**6. Confirm.** The chat reports the refund succeeded. The transaction list shows the new refund row.

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

If no push arrives: ensure notifications are enabled for IBM Verify and that you completed enrollment.
