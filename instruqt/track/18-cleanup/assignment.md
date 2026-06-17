---
slug: cleanup
type: challenge
title: Cleanup
teaser: Tear down the workshop infrastructure (Instruqt also destroys the sandbox).
tabs:
  - title: Terminal
    type: terminal
    hostname: cloud-client
---

You've completed all three use cases. Time to tear down.

The track-play `cleanup-cloud-client` (which Instruqt runs automatically after this
challenge) invokes `bash infrastructure/scripts/teardown.sh --yes`, and
Instruqt then destroys the AWS sandbox account itself. This challenge is
belt-and-suspenders: it kicks off the same teardown now so you can observe
the cleanup output, instead of waiting for the implicit one after the
challenge advances.

```bash
cd /root/workshop
bash infrastructure/scripts/teardown.sh --yes
```

The script:

1. Drains LB-controller-managed Services (NLB / ALB) so VPC delete doesn't
   fail with `DependencyViolation`.
2. Runs `terraform destroy` against tier-3, tier-2, tier-1 in reverse order.
3. Sweeps any AWS resources tagged `Workshop=agentic-runtime-security` that
   escaped Terraform state.
4. Audits for zero residuals and prints a final summary.

When the script returns, Instruqt's own sandbox-destroy fires next. The AWS
account is reclaimed.

That's the full workshop. Thank you for going through it.
