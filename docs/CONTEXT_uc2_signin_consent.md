# Context — Use Case 2 sign-in: suppress OAuth consent for first-party banking app

Saved 2026-06-02. Branch `experimental/signin-mmfa-stepup-consent`.

## Goal

Logging into the OscarVault banking app must be: password → straight into the app.
No OAuth consent form, no MMFA push at login. The banking app is a **first-party
trusted client** (`client_id = agent-uc2`); a scope-consent screen is wrong for a
first-party app signing the user into its own bank.

## The fix (implemented, deployed)

`infrastructure/modules/verify_access/iviaop-config/accesspolicy.yaml` — the ISVAOP
JavaScript access policy `isvaop_policy` runs at `/oauth2/authorize` for every client.
For `clientId == "agent-uc2"` it calls `pctx.setConsentDecision(scopes)` (IBM's
documented external-consent pattern), so ISVAOP issues the auth code **without**
rendering its consent page. Every other client falls through to the global
`consent_prompt: ALWAYS_PROMPT` (least privilege). CIBA `agent-uc3` never hits
`/oauth2/authorize`, so the refund approval flow is untouched.

This is the **only** file modified in git status. base_layer.yaml.tftpl, main.tf,
and the OIDC issuer were all reverted to main per Bear's revert demand (issuer is
back on the ELB baseline, not the FQDN).

## Login-page scare — RESOLVED, was a stale read

Mid-session the live WebSEAL login page appeared broken (username/password form
commented out by an extra `<!--`). This was a **stale observation** taken before the
autoconf import + WRP restart finished. Re-curl of
`https://ivia.oscar-medina.sbx.hashidemos.io/` now shows:
form open (`<form method="POST" action="/pkmslogin.form">`), 1 username input,
1 password input, 2 forms total. Page is correct.

### Factual mechanism (from pinned `ibmvia_autoconf 0.3.21` source — corrects an earlier wrong theory)

- The log line `INFO:ibmvia_autoconf.webseal:RTE already configured, skipping
  configuration.` is `webseal.py:712`, inside `runtime()`. It gates ONLY the
  **policy-server / runtime component**, NOT the reverse proxy. (Earlier I wrongly
  claimed it skipped the whole WebSEAL block incl. the page import — false.)
- `wrp()` (`webseal.py:496`) lists instances; if `rp1` exists it **deletes and
  recreates** it (`delete_instance` → `create_instance`), then re-imports
  `management_root` (`webseal.py:541-543` → `_import_management_root` :193).
- Proof from last job `ivia-autoconf-e4e96d4c` log: line "Successfully configured
  proxy rp1" and **"Successfully imported reverse_proxy.zip to rp1 proxy management
  root."** So the correct `login.html` WAS re-imported. A WRP pod restart then serves it.
- Deploy chain: `data.archive_file.ivia_management_pages` zips
  `base_layer/management-pages/` → `reverse_proxy.zip` → stored in
  `kubernetes_secret.base_layer_p12.binary_data["reverse_proxy.zip"]` → imported via
  base_layer.yaml `management_root: ["reverse_proxy.zip"]` (lines 240-241). Staged
  secret zip verified correct (form open, 3804 bytes).
- Post-apply rule still holds: rollout-restart `iviawrprp1` + `iviaruntime` after
  every verify_access apply so the WRP picks up the recreated instance + imported pages.

## Current verified state

- accesspolicy.yaml consent fix deployed to live iviaop.
- Live login page correct (form open, username+password present).
- iviawrprp1 + iviaruntime restarted after the apply.
- OIDC issuer = ELB baseline (matches main).

## Updated 2026-06-02 — Path A confirmed + smoking gun found

Bear confirmed Path A: workshop entry URL is **banking-ui ALB**, not IVIA FQDN.
Workshop docs (`content/60-use-case-2/61-oauth-pkce-flow:131-152`) match. The
banking-app `/callback` requires its own `pkce`+`state` cookie, so cold-start from
IVIA FQDN cannot land on `/dashboard` — wrong question to ask. See memory
[[ivia-canonical-entry-url-is-the-custom-domain]] (corrected this session).

### Smoking gun (still uncommitted, awaiting Bear to drive)

`infrastructure/modules/verify_access/base_layer/management-pages/management/C/login.html:77`
has `<input TYPE="hidden" NAME="login-response-type" VALUE="success_page">` inside
an HTML comment (lines 73–78). The browser doesn't submit it, so WebSEAL defaults to
`success_page` → serves `login_success.html` (the IBM "Application Gateway" help
page Bear was landing on) instead of redirecting back to the original
`/isvaop/oauth2/authorize?...` URL. OAuth code never issued → banking-app
`/callback` never reached → `/dashboard` never reached.

### Fix (one line, deploy via standard cycle)

Add an active hidden input to the password form in `login.html` (near line 66
alongside `login-form-type`):

```html
<input TYPE="hidden" NAME="login-response-type" VALUE="original_url">
```

Then:
1. `terraform apply -target=module.ivia` (re-zips `reverse_proxy.zip`, autoconf
   re-imports via `_import_management_root`)
2. `kubectl rollout restart -n verify-access deploy/iviawrprp1` (per
   [[project_ivia_post_apply_restart]])
3. Re-test Path A in browser per [[browser-e2e-clean-start]]: clean cookies
   (banking-app + IVIA raw ELB + IVIA FQDN origins), open banking-ui ALB,
   accept cert warning, log in jaime/`WorkshopUser1!`, expect 303 chain ending
   at `/dashboard`.

### Curl evidence captured this session

```
$ curl -sk -L --max-redirs 0 -o /dev/null -w '%{http_code} %{redirect_url}\n' \
    https://k8s-bankinga-bankingu-14878db878-85041441.us-west-2.elb.amazonaws.com/
302 https://k8s-verifyac-iviawrp-8b70662954-618854826.us-west-2.elb.amazonaws.com/isvaop/oauth2/authorize?response_type=code&client_id=agent-uc2&redirect_uri=https%3A%2F%2Fk8s-bankinga-bankingu-14878db878-85041441.us-west-2.elb.amazonaws.com%2Fcallback&...
```

banking-app correctly sets `pkce` cookie on its own origin; IVIA serves the login
form with `PD-S-SESSION-ID`. All upstream pieces healthy; the only thing breaking
end-to-end is the missing `login-response-type=original_url` post-data field.

### Separate UX item (NOT blocking the fix above)

Two cert-warning origins on the Path A user path:
1. Banking-ui ALB presents `CN=*.us-west-2.elb.amazonaws.com` (self-signed
   placeholder bound at `arn:aws:acm:...:certificate/5a7c0a6e-...`).
2. IVIA raw ELB is what banking-app's OAuth redirect points at (`main.tf:519/580`
   resolves `ivia_public_issuer` to the raw ALB hostname, NOT the FQDN).

Workshop docs already say "accept it to proceed" (`61-oauth-pkce-flow:147`). If
Bear wants zero cert warnings: separate work to add a banking-ui FQDN + ACM cert
AND flip OIDC issuer to the IVIA FQDN. Out of scope for the
`login-response-type` fix.
