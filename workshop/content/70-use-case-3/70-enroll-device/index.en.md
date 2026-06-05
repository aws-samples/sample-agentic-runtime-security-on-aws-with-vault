---
title: 'Enroll Your Device'
weight: 70.4
---

The refund approval arrives as a mobile push to IBM Verify on your phone. Enroll once per deployment.

If you have not installed the IBM Verify app yet, see [Prerequisites — IBM Verify app](../../20-prerequisites/#mobile-prerequisite--ibm-verify-app) first.

**1. Open the enrollment URL** — incognito window, sign in `jaime` / `WorkshopUser1!`. The IVIA WRP is served on the nip.io FQDN that `bash infrastructure/scripts/configure-workshop.sh` provisioned a Let's Encrypt cert for (stored in `infrastructure/.acme-state` as `NIP_FQDN_WRP`):

```bash
NIP_FQDN_WRP=$(grep '^NIP_FQDN_WRP=' infrastructure/.acme-state | cut -d= -f2)
echo "https://${NIP_FQDN_WRP}/mga/sps/oauth/oauth20/authorize?response_type=code&client_id=AuthenticatorClient&scope=mmfaAuthn"
```

You should see a lock icon in your browser address bar when the page loads (Let's Encrypt cert on the workshop ALB). If your browser shows a "Your connection is not private" warning, this is a regression — re-run `bash infrastructure/scripts/configure-workshop.sh` to re-issue the cert.

**2. Scan the QR** — IBM Verify app → **+** → **Scan QR code** → approve. The IBM Verify app should accept the certificate without prompting you to trust an unknown cert. If you see a trust-override prompt, the Let's Encrypt cert is not yet serving on the ALB — check the output of `bash infrastructure/scripts/configure-workshop.sh` for ACME errors and re-run.

**3. Refresh the page.** Your device appears in the "Authenticators" list. If empty, repeat step 1 (code expired).
