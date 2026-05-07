# Spend and Approval Thresholds

This document defines spending and approval authority across roles. UC3 uses
this content to ground the privileged-action agent's reasoning when a request
crosses a threshold.

## Spend Approval Thresholds

A spend request includes purchases, refunds, contractor engagements, vendor
agreements, and any other commitment of organization funds.

| Role             | Approval Authority   |
| ---------------- | -------------------- |
| Individual       | Up to $100           |
| Manager          | Up to $500           |
| Director         | Up to $5,000         |
| Senior Director  | Up to $25,000        |
| VP               | Up to $50,000        |
| SVP              | Up to $100,000       |
| C-Suite (non-CFO)| Up to $250,000       |
| CFO              | Unlimited            |

The threshold applies to the per-transaction or per-commitment amount, not to
an aggregate. Splitting a $1,200 purchase into three Manager-approved $400
items to avoid Director review is a policy violation.

## Two-Person Rule

Any commitment over $10,000 requires two approvers from any qualifying tier.
The two approvers must be different individuals; an approver may not approve
their own request.

## Refund Approval

Refund approval thresholds align with the spend thresholds above. See
`refund-procedures.md` (same domain) for the customer-facing refund flow.

## Contractor and Vendor Engagement

Engagements over $25,000 in committed value require Legal review prior to
approval. The Legal team enters its acknowledgement into the procurement
record before the spend approval is exercised.

## Recurring Spend

Subscriptions and other recurring spend commitments are evaluated against the
total annual cost, not the per-month amount. A $1,000-per-month subscription
is treated as a $12,000 annual commitment and routes through Director
approval plus the two-person rule.

## Out-of-Cycle Approvals

Any spend approval issued outside the standard procurement system (for
example, by direct email) is reconciled into the system within five business
days. Unreconciled out-of-cycle approvals are reviewed by Finance monthly.

## Workshop Note

The UC3 agent in Phase 6 receives a refund request that exceeds the
requesting support agent's authority. The agent retrieves this document to
identify the correct approver tier, requests the two-person-rule second
approval through IBM Verify Identity Access, and records both approver
identities in the audit log. The workshop's audit-correlation exercise then
joins the agent trace with the Verify decision events and the eventual
refund event using the W3C `traceparent` value propagated end-to-end.

*Synthetic workshop content; not from any real company.*
