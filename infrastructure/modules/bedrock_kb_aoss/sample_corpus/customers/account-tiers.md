# Account Tiers

This document defines the four customer account tiers and the benefits each
tier receives. Tiers are recalculated quarterly based on rolling twelve-month
lifetime value (LTV).

## Tier Definitions

### Bronze

The default tier for any customer not yet meeting a higher tier threshold.
No LTV minimum.

- Standard support via email and the help center.
- Self-service onboarding through the published documentation.
- Access to the public knowledge base and community forum.

### Silver

Awarded to customers with rolling LTV greater than $10,000.

- All Bronze benefits.
- Priority email support with a four-hour response objective during business
  hours.
- One annual product training session, delivered remotely.

### Gold

Awarded to customers with rolling LTV greater than $50,000.

- All Silver benefits.
- Dedicated Customer Success Manager with quarterly business reviews.
- Priority access to new features in beta when applicable.
- Two annual on-site or virtual training engagements.

### Platinum

Awarded to customers with rolling LTV greater than $250,000.

- All Gold benefits.
- Custom integrations engagement budget (up to one engineer-quarter per year).
- Architecture review with a Principal Engineer once per year.
- Named technical account manager and a 24/7 escalation channel.
- Influence over the published roadmap through a quarterly steering forum.

## Tier Recalculation

Tier evaluation runs on the first business day of each calendar quarter. A
customer whose rolling LTV crosses an upgrade threshold moves up immediately
and receives a welcome packet for the new tier. A customer whose LTV falls
below their current tier's threshold for two consecutive quarters is moved
down at the next evaluation; no customer drops more than one tier per
evaluation cycle.

## Benefits Eligibility

Benefits are available to all named contacts under a customer record. The
primary contact receives upgrade and downgrade notifications; secondary
contacts may be added through the customer portal.

## Workshop Note

The four tiers and the eight customer records in `customer-records.md` drive
UC2 — when an attendee identifies as the primary contact for `CUST-0006`
(Wingtip Toy Designs, Bronze), the agent should answer "your account is
Bronze tier; you have access to standard support and the help center" rather
than enumerating Platinum benefits. The agent does this by combining JWT
claims with KB retrieval.

*Synthetic workshop content; not from any real company.*
