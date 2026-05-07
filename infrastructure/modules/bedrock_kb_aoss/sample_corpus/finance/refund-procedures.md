# Refund Procedures

This document describes the customer refund procedures used by the support
and finance teams. UC3 (privileged-action agent) references this document
when proposing or executing a refund on behalf of a support agent.

## Refund Types

There are three refund outcomes for a customer request.

### Full Refund

Available when the request is received within 30 days of the original
purchase date and the underlying service was paid for and either unused or
materially defective.

- Returned to the original payment method.
- Processed within five business days of approval.

### Partial Refund

Available when the request is received between 31 and 90 days from the
original purchase date, or when the customer received some material value
from the purchase before the request.

- Amount is calculated pro rata against unused portion of the service.
- Returned to the original payment method.

### Store Credit

The default outcome for requests received more than 90 days from the original
purchase date. Store credit may also be offered as a goodwill alternative to a
full refund within the 30-day window when both parties agree.

- Issued as account credit valid for 12 months.
- Cannot be transferred between customer accounts.

## Approval Thresholds

Refund approval thresholds depend on the refund amount and the requester's
role. The published thresholds in `approval-thresholds.md` (same domain)
apply.

In short:

- Up to $500: support agent may approve directly.
- $500 to $5,000: requires Manager approval.
- $5,000 to $50,000: requires Director approval.
- Over $50,000: requires VP approval and a written customer-impact memo.
- Over $250,000: requires CFO approval and notification to the Board's audit
  committee.

## Escalation Path

When a customer escalates a refund decision, the request moves up one
approval tier and is reviewed within three business days. The reviewing
manager records the decision rationale in the case record. A second
escalation goes to the next tier; further escalation is decided by the
office of the customer experience executive.

## Documentation Requirements

Every refund decision is documented with:

- Customer ID and case ID.
- Original transaction ID and amount.
- Refund type, amount, and target (original payment method or store credit).
- Approver identity and approval timestamp.
- Reason code from the published refund-reason taxonomy.

## Audit Trail

All refund actions emit an audit event written to the finance-audit log
group. Phase 6 of the workshop demonstrates a UC3 audit-correlation query
that joins the agent's trace with the IBM Verify decision and the actual
refund event in this log group.

*Synthetic workshop content; not from any real company.*
