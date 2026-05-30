<!--
Most fixes are handled by the maintainer. Only open a PR if you fixed something AND verified it works.
Main is protected: all changes land via PR + review.
-->

## What this fixes

Closes #<!-- issue number -->

## Proof it works (required)

A PR is only reviewable with proof. Show that your fix works:

- **Workshop page that now passes:** `<!-- e.g. workshop/content/60-uc1-non-personalized/index.en.md -->`
- **Exact commands you ran and their output** (paste below — redact account IDs, ARNs, tokens, IPs):

```
<!-- commands + real output here -->
```

## Checklist

- [ ] I verified this live against AWS — not just by reading the code.
- [ ] Any infra / deploy change goes through the existing scripts (idempotent, safe to re-run) — no ad-hoc `terraform` / `kubectl` / `vault` / `aws` mutations.
- [ ] Secrets redacted from everything in this PR (account IDs, ARNs, access keys, tokens, private IPs).
- [ ] Only files related to this fix are changed; `terraform fmt` is clean where applicable.
