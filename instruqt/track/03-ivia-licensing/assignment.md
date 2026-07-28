---
slug: ivia-licensing
id: cakzx4esvxyp
type: challenge
title: IVIA Licensing
teaser: Confirm the bundled IVIA trial activation certificate is in place.
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
module needs a **trial activation certificate** — a signed PEM that unlocks
the IVIA server's OIDC and CIBA features.

## The certificate is already provided

You do **not** obtain, download, or upload this certificate. It ships with the
workshop, committed in the repository at:

```
infrastructure/modules/verify_access/base_layer/ISAM-Trial-HashiCorp.cer
```

When you clone the workshop repo, the certificate comes with it. Terraform
reads this file during the `verify_access` module apply, and the IVIA autoconf
job imports it automatically — no manual LMI interaction and no attendee action
are required.

## Verify it's present

Open the **Terminal** tab and confirm the bundled certificate is present and
still in date:

```bash
cd /root/workshop
[ -f infrastructure/modules/verify_access/base_layer/ISAM-Trial-HashiCorp.cer ] \
  && openssl x509 \
       -in infrastructure/modules/verify_access/base_layer/ISAM-Trial-HashiCorp.cer \
       -noout -dates
```

The `notAfter=` date must be in the future. If the file is missing, your clone
is incomplete — re-clone the workshop repository rather than trying to source
the certificate yourself. If the certificate has expired, notify your workshop
organizer; it is refreshed by the workshop maintainer, not by attendees.
