---
title: 'Resources'
weight: 90
---

## Videos

- [Agentic Runtime Security — Executive Overview](https://youtu.be/HtnlUosO3XA?si=Xg9FxIB-B00Pq_So)
- [Agentic Runtime Security — Technical Deep Dive](https://youtu.be/NH0plIdqDMk?si=Pu-afmrVn3HZxiKr) by Tyler Lynch

## IBM Verify Identity Access (IVIA)

- **IVIA Trial Certificate** — the signed trial certificate that activates the Config container modules (wga, mga, federation) ships bundled with the workshop at `infrastructure/modules/verify_access/base_layer/ISAM-Trial-HashiCorp.cer`; Terraform reads it automatically, so there is nothing to obtain or upload
- [IVIA OIDC Provider — Kubernetes Deployment](https://docs.verify.ibm.com/ibm-security-verify-access/docs/deployment-k8s) — full K8s manifest examples, RBAC, probes
- [IVIA OIDC Provider — YAML Configuration Reference](https://docs.verify.ibm.com/ibm-security-verify-access/docs/yaml_config) — all config sections, special types (`secret:`, `ks:`, `B64:`, `@`)
- [IVIA OIDC Provider — Server Settings](https://docs.verify.ibm.com/ibm-security-verify-access/docs/yaml_provider-https_server) — `server.activation_code`, SSL, ports
- [IVIA OIDC Provider — Runtime Database (PostgreSQL)](https://docs.verify.ibm.com/ibm-security-verify-access/docs/deployment-postgres) — schema init, required tables, `SESSION_ID` column
- [IVIA v11.0.2 Download (Technote 7247411)](https://www.ibm.com/support/pages/node/7247411)

## HashiCorp Vault

- [Vault 2.0 Release Notes](https://developer.hashicorp.com/vault/docs/updates/release-notes)
- [Vault OAuth Resource Server](https://developer.hashicorp.com/vault/docs/concepts/oauth-resource-server) — validates the IVIA OAuth JWT directly via `X-Vault-Token` (JWKS discovery); the native replacement for the retired JWT/OIDC auth method + `bound_claims`
- [Vault Agent Registry](https://developer.hashicorp.com/vault/docs/concepts/agent-registry) — first-class agent identities with `ceiling_policies`, resolved from the token's `act.sub`
- [Vault SPIFFE Secrets Engine](https://developer.hashicorp.com/vault/api-docs/secret/spiffe) — JWT-SVID minting for agent identity (Vault 2.0, Enterprise)
- [Vault SPIFFE Auth Method](https://developer.hashicorp.com/vault/docs/auth/spiffe) — workload authentication via SPIFFE SVIDs
- [Secure AI Agent Communication with A2A + Vault](https://developer.hashicorp.com/vault/tutorials/auth-methods/secure-ai-agent-communication-a2a-vault-kubernetes)
- [AI Agent Identity Validated Pattern](https://developer.hashicorp.com/validated-patterns/vault/ai-agent-identity-with-hashicorp-vault)
- [Agentic Runtime Security Blog](https://www.hashicorp.com/en/blog/agentic-runtime-security-solving-agentic-ai-identity-and-access-gaps) — five implementation imperatives
- [Zero Trust for Agentic Systems Blog](https://www.hashicorp.com/en/blog/zero-trust-for-agentic-systems-managing-non-human-identities-at-scale) — ten exploit categories
- [SPIFFE for Agentic AI Blog](https://www.hashicorp.com/en/blog/spiffe-securing-the-identity-of-agentic-ai-and-non-human-actors)
- [Native AI Agent Support in Vault (May 2026)](https://www.hashicorp.com/en/blog/announcing-native-ai-agent-support-in-hashicorp-vault) — Agent Registry, ceiling-policy intersection, OBO delegation, ephemeral authorization

### Native Agent Identity (deployed in this workshop — Enterprise 2.0.3)

- [Vault Agent Registry — Concept](https://developer.hashicorp.com/vault/docs/concepts/agent-registry) — register each agent as a first-class identity (`agent-registry/registration/display-name/<name>`) with `ceiling_policies`, distinct from human users and traditional NHIs
- [Vault OAuth Resource Server — Concept](https://developer.hashicorp.com/vault/docs/concepts/oauth-resource-server) — authorize a Vault request directly with an external OAuth JWT via `X-Vault-Token`; no `jwt_login`, no intermediate token
- [Vault OAuth Resource Server — API](https://developer.hashicorp.com/vault/api-docs/system/oauth-resource-server) — profile config (issuer, JWKS, audiences, `user_claim`, `optional_authorization_details`) and per-request `authorization_details` of `type: vault:path_access`
- [Secure Agent Permissions with Vault (Tutorial)](https://developer.hashicorp.com/vault/tutorials/enterprise/secure-agent-permissions-with-vault) — entities/aliases, ceiling intersection, and `vault:path_access` RAR enforcement end-to-end
- [`vault_oauth_resource_server_config_profile` (Terraform)](https://registry.terraform.io/providers/hashicorp/vault/latest/docs/resources/oauth_resource_server_config_profile) — declares the `ivia` resource-server profile
- [`vault_agent_registration` (Terraform)](https://registry.terraform.io/providers/hashicorp/vault/latest/docs/resources/agent_registration) — registers `uc1-agent` / `agent-uc2` / `uc3-actor` with their ceiling policies
