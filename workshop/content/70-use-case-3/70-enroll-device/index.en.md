---
title: 'Enroll Your Device'
weight: 70.4
---

The refund approval arrives as a mobile push to IBM Verify on your phone. Enroll once per deployment.

If you have not installed the IBM Verify app yet, see [Prerequisites — IBM Verify app](../../20-prerequisites/#mobile-prerequisite--ibm-verify-app) first.

**1. Open the enrollment URL** — incognito window, sign in `jaime` / `WorkshopUser1!`:

```bash
echo "https://$(terraform -chdir=infrastructure output -raw wrp_public_fqdn)/mga/sps/oauth/oauth20/authorize?response_type=code&client_id=AuthenticatorClient&scope=mmfaAuthn"
```

**2. Scan the QR** — IBM Verify app → **+** → **Scan QR code** → approve.

**3. Refresh the page.** Your device appears in the "Authenticators" list. If empty, repeat step 1 (code expired).
