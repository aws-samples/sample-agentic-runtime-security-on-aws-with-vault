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

## OIDC / OAuth 2.0 Specifications

- [RFC 9396 — Rich Authorization Requests (RAR)](https://datatracker.ietf.org/doc/html/rfc9396)
- [RFC 8693 — OAuth 2.0 Token Exchange](https://datatracker.ietf.org/doc/html/rfc8693)
- [OpenID CIBA — Client Initiated Backchannel Authentication](https://openid.net/specs/openid-client-initiated-backchannel-authentication-core-1_0.html)
- [RFC 7636 — PKCE (Proof Key for Code Exchange)](https://datatracker.ietf.org/doc/html/rfc7636)

## Alternative OIDC Providers (Evaluated)

- [Auth0 for AI Agents](https://auth0.com/ai) — RAR, CIBA, token exchange, MCP auth (Enterprise tier for advanced features)
- [Auth0 CIBA Flow](https://auth0.com/docs/get-started/authentication-and-authorization-flow/client-initiated-backchannel-authentication-flow)
- [Auth0 RAR Configuration](https://auth0.com/docs/get-started/authentication-and-authorization-flow/authorization-code-flow/authorization-code-flow-with-rar)
- [Okta CIBA Guide](https://developer.okta.com/docs/guides/configure-ciba/main/) — poll mode only
- [Okta Token Exchange](https://developer.okta.com/docs/guides/set-up-token-exchange/main/)
- [AWS Cognito OIDC Grants](https://docs.aws.amazon.com/cognito/latest/developerguide/federation-endpoints-oauth-grants.html) — no RAR, no CIBA, no token exchange
- [Keycloak](https://www.keycloak.org/) — open source, CIBA + token exchange, Apache 2.0

## AWS

- [Amazon EKS Documentation](https://docs.aws.amazon.com/eks/latest/userguide/)
- [Amazon Bedrock Knowledge Bases](https://docs.aws.amazon.com/bedrock/latest/userguide/knowledge-base.html)
- [AWS Cognito Pricing](https://aws.amazon.com/cognito/pricing/)
