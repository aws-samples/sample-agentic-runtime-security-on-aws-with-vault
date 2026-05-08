---
title: 'Introduction'
weight: 10
---

## The problem

AI agentic systems break the assumptions security tooling has relied on for two decades. Agents are not users — they don't fit IAM Identity Center personas. Agents are not workloads in the classic sense — they're sometimes acting on behalf of a user, sometimes acting autonomously, and the boundary moves request to request. Bearer tokens with hard-coded scopes don't compose. Standing database credentials with broad GRANTs accumulate sprawl with every new agent. And when something goes wrong, "which user authorized this action?" becomes unanswerable across IDP logs, IAM logs, and database logs that don't share a correlation key.

The agentic-systems threat model stretches across three trust planes simultaneously — user identity (who is asking?), workload identity (which agent process is acting?), and data plane (what credentials does it actually present to Postgres or Bedrock?). Most existing tooling owns one plane and assumes the other two are someone else's problem. That assumption is what this workshop dismantles.

Continue through the sub-modules:

1. **[Five Control Objectives](11-five-control-objectives/)** — The five security objectives this workshop implements, and the three use cases that demonstrate them
2. **[Architecture](12-architecture/)** — The IBM Verify + HashiCorp Vault architecture, workshop structure, and design rationale
