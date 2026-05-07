# Customer Records

This document holds the synthetic customer roster used by the workshop's
personalized retrieval scenario (UC2 — "show me my records"). Every record
below is fabricated; no field corresponds to a real person, organization, or
account. Email addresses use the `example.invalid` TLD reserved by RFC 6761.

## Record Schema

Each customer entry has the following fields:

- `customer_id` — Stable identifier in the form `CUST-NNNN`.
- `name` — Display name of the account.
- `account_tier` — One of `Bronze`, `Silver`, `Gold`, `Platinum`.
- `opened_date` — Date the account was opened (ISO 8601).
- `contact_email` — Primary contact email; `example.invalid` TLD.
- `region` — Synthetic deployment region label.

Tier definitions live in `account-tiers.md` (same domain).

## Records

### CUST-0001

- Name: Northwind Trading Cooperative
- Tier: Platinum
- Opened: 2019-03-14
- Contact: ops@northwind.example.invalid
- Region: NA-West

### CUST-0002

- Name: Adatum Library Network
- Tier: Gold
- Opened: 2020-07-22
- Contact: support@adatum.example.invalid
- Region: NA-East

### CUST-0003

- Name: Contoso Bicycle Manufactory
- Tier: Silver
- Opened: 2021-01-09
- Contact: orders@contoso.example.invalid
- Region: EU-Central

### CUST-0004

- Name: Fabrikam Sustainable Foods
- Tier: Gold
- Opened: 2018-11-30
- Contact: hello@fabrikam.example.invalid
- Region: EU-North

### CUST-0005

- Name: Tailspin Robotics Lab
- Tier: Platinum
- Opened: 2017-04-02
- Contact: research@tailspin.example.invalid
- Region: AP-East

### CUST-0006

- Name: Wingtip Toy Designs
- Tier: Bronze
- Opened: 2022-09-18
- Contact: hello@wingtip.example.invalid
- Region: NA-West

### CUST-0007

- Name: Litware Educational Services
- Tier: Silver
- Opened: 2020-02-11
- Contact: admin@litware.example.invalid
- Region: NA-Central

### CUST-0008

- Name: Proseware Civic Tools
- Tier: Bronze
- Opened: 2023-05-27
- Contact: contact@proseware.example.invalid
- Region: AP-South

## Access Notes

These records are intentionally exposed inside the corpus so the workshop's
UC2 agent can demonstrate JWT-scoped retrieval — an attendee identified as
the contact for one record should be able to retrieve only that record, not
the full roster. Phase 4-6 implements that scoping; Phase 2 just stages the
data.

*Synthetic workshop content; not from any real company.*
