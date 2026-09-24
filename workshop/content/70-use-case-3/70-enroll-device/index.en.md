---
title: 'Enroll Your Device'
weight: 70.4
---

## Objective 3 · Actions tied to user intent

A refund moves money, so the agent is not allowed to decide alone — it has to ask a person, on a device the agent does not control. This page gives you that device.

Enroll once per deployment. If you have not installed the IBM Verify app yet, see [Prerequisites — IBM Verify app](../../20-prerequisites/#mobile-prerequisite--ibm-verify-app) first.

### 1. Open the enrollment URL

**Why:** The enrollment link is minted per deployment, so it carries your own workshop hostname. Resolve it rather than typing one.

Incognito window, sign in `jaime` / `WorkshopUser1!`.

```bash
NIP_FQDN_WRP=$(grep '^NIP_FQDN_WRP=' infrastructure/.acme-state | cut -d= -f2)
echo "https://${NIP_FQDN_WRP}/mga/sps/oauth/oauth20/authorize?response_type=code&client_id=AuthenticatorClient&scope=mmfaAuthn"
```

### 2. Scan the QR code

**Why:** This binds *your* phone to *this* IVIA. Until it happens the agent has nobody to ask, and the refund flow on the next page has nowhere to send its approval.

IBM Verify app → **+** → **Scan QR code** → approve.

### 3. Refresh the page

**Why:** Confirm the binding took before you rely on it. An empty list now is a failed refund later.

Your device appears in the "Authenticators" list. If empty, repeat step 1 — the code expired.

:::alert{type="warning" header="A certificate warning here is a real problem, not a click-through"}
You should see a lock icon in the address bar, and IBM Verify should accept the certificate without prompting you to trust an unknown one. Either warning means the Let's Encrypt cert is not serving on the ALB — re-run `bash infrastructure/scripts/deploy-workshop.sh` and check its output for ACME errors.
:::
