---
title: 'Resources'
weight: 90
---

## Videos

- [Agentic Runtime Security — Executive Overview](https://youtu.be/HtnlUosO3XA?si=Xg9FxIB-B00Pq_So)
- [Agentic Runtime Security — Technical Deep Dive](https://youtu.be/NH0plIdqDMk?si=Pu-afmrVn3HZxiKr) by Tyler Lynch

## IBM Verify Identity Access (IVIA)

- [IVIA Trial Certificate](https://isva-trial.verify.ibm.com/) — obtain a 90-day trial certificate to activate Config container modules (wga, mga, federation)
- [IVIA OIDC Provider — Kubernetes Deployment](https://docs.verify.ibm.com/ibm-security-verify-access/docs/deployment-k8s) — full K8s manifest examples, RBAC, probes
- [IVIA OIDC Provider — YAML Configuration Reference](https://docs.verify.ibm.com/ibm-security-verify-access/docs/yaml_config) — all config sections, special types (`secret:`, `ks:`, `B64:`, `@`)
- [IVIA OIDC Provider — Server Settings](https://docs.verify.ibm.com/ibm-security-verify-access/docs/yaml_provider-https_server) — `server.activation_code`, SSL, ports
- [IVIA OIDC Provider — Runtime Database (PostgreSQL)](https://docs.verify.ibm.com/ibm-security-verify-access/docs/deployment-postgres) — schema init, required tables, `SESSION_ID` column
- [IVIA Container Image Configuration](https://www.ibm.com/docs/en/sva/11.0.2?topic=support-container-image-configuration) — CONFIG container env vars, snapshot management
- [IVIA v11.0.2 Download (Technote 7247411)](https://www.ibm.com/support/pages/node/7247411)

## HashiCorp Vault

- [Vault 2.0 Release Notes](https://developer.hashicorp.com/vault/docs/updates/release-notes)
- [Vault JWT/OIDC Auth Method](https://developer.hashicorp.com/vault/docs/auth/jwt) — `bound_claims`, `bound_audiences`, JWKS discovery
- [Vault SPIFFE Secrets Engine](https://developer.hashicorp.com/vault/api-docs/secret/spiffe) — JWT-SVID minting for agent identity (Vault 2.0, Enterprise)
- [Vault SPIFFE Auth Method](https://developer.hashicorp.com/vault/docs/auth/spiffe) — workload authentication via SPIFFE SVIDs
- [Secure AI Agent Communication with A2A + Vault](https://developer.hashicorp.com/vault/tutorials/auth-methods/secure-ai-agent-communication-a2a-vault-kubernetes)
- [AI Agent Identity Validated Pattern](https://developer.hashicorp.com/validated-patterns/vault/ai-agent-identity-with-hashicorp-vault)
- [Agentic Runtime Security Blog](https://www.hashicorp.com/en/blog/agentic-runtime-security-solving-agentic-ai-identity-and-access-gaps) — five implementation imperatives
- [Zero Trust for Agentic Systems Blog](https://www.hashicorp.com/en/blog/zero-trust-for-agentic-systems-managing-non-human-identities-at-scale) — ten exploit categories
- [SPIFFE for Agentic AI Blog](https://www.hashicorp.com/en/blog/spiffe-securing-the-identity-of-agentic-ai-and-non-human-actors)
- [Native AI Agent Support in Vault (May 2026)](https://www.hashicorp.com/en/blog/announcing-native-ai-agent-support-in-hashicorp-vault) — agent registry, 4-layer policy intersection, OBO delegation, ephemeral authorization

