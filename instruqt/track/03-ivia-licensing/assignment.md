---
slug: ivia-licensing
id: cakzx4esvxyp
type: challenge
title: IVIA Licensing
teaser: Upload your IVIA trial activation certificate.
tabs:
- id: csw2y85tczac
  title: Terminal
  type: terminal
  hostname: cloud-client
- id: n4abzhigtzbv
  title: IDE
  type: service
  hostname: cloud-client
  path: /
  port: 8080
difficulty: ""
enhanced_loading: null
---

IBM Verify Access (IVIA) 11.0.2 runs self-hosted on EKS as the OIDC provider
and CIBA authorization server for all three use cases. To deploy, the IVIA
module needs your own **trial activation certificate** — a free 90-day PEM
tied to an IBM account, no purchase required.

## Obtain your trial certificate

1. Sign in (or create an IBMid) at **`https://isva-trial.verify.ibm.com/`**
2. Request a fresh trial certificate; download the PEM file IBM emails you
   (filename ends in `.cer`)

## Upload it into the sandbox

3. Switch to the **IDE** tab (right side of this challenge — VS Code in the
   browser, rooted at `/root`)
4. In the file explorer, navigate to
   `workshop/infrastructure/modules/verify_access/base_layer/`
5. Drag and drop your downloaded `.cer` file onto the file
   `ISAM-Trial-HashiCorp.cer` (or right-click the folder → **Upload...** →
   select your file → rename to `ISAM-Trial-HashiCorp.cer` to match)
6. Confirm in the editor pane that the PEM begins with
   `-----BEGIN CERTIFICATE-----` and ends with `-----END CERTIFICATE-----`

## Verify

Switch back to the **Terminal** tab and confirm the cert is present and not
expired:

```bash
cd /root/workshop
[ -f infrastructure/modules/verify_access/base_layer/ISAM-Trial-HashiCorp.cer ] \
  && openssl x509 \
       -in infrastructure/modules/verify_access/base_layer/ISAM-Trial-HashiCorp.cer \
       -noout -dates
```

The `notAfter=` date must be in the future.
