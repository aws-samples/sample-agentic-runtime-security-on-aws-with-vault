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

## Bring Your Own GHCR Registry

A power-user/fork reference for hosting the five workshop images in your own GHCR namespace. This is **not** a step in the main deploy flow — the default `deploy-workshop.sh` builds the images into your own account ECR, and the `--image-source ghcr` opt-out pulls pre-built images from `ghcr.io/sharepointoscar` anonymously. Use this reference only if you want to repoint that GHCR base to your own account.

### 1. Prerequisites

You need:

- A GitHub account with a `write:packages` scope on your CLI token:

```bash
gh auth refresh -h github.com -s write:packages
```

- A running container runtime (Docker or Podman) — publishing builds the images locally before pushing. See [Self-paced: container runtime](../20-prerequisites/23-pre-flight-checks/#self-paced-container-runtime---image-source-ecr) for setup instructions.

### 2. Publish to your namespace

Build all five images (`--platform linux/amd64`) and push them to your GHCR base. The script reads the `write:packages` token from `GHCR_PAT` env or `gh auth token`:

```bash
bash infrastructure/scripts/publish-images.sh --registry-base ghcr.io/<your-github-username>
```

### 3. Make the five packages Public

After pushing, set each of the five packages to **Public** visibility via the GitHub web UI (Settings → Packages on your GitHub profile). There is no REST API for container-package visibility.

The five package names (under `ghcr.io/<your-github-username>/`):

- `workshop-uc1-agent`
- `workshop-banking-app-ui`
- `workshop-banking-app-agent`
- `workshop-banking-app-mcp`
- `workshop-uc3-agent`

### 4. Deploy pointing consume at your base

Pass `--image-source ghcr` and `--ghcr-registry-base` so the deploy pulls from your namespace instead of the default:

```bash
bash infrastructure/scripts/deploy-workshop.sh --tier 1 --image-source ghcr --ghcr-registry-base ghcr.io/<your-github-username>
bash infrastructure/scripts/deploy-workshop.sh --tier 2 --image-source ghcr --ghcr-registry-base ghcr.io/<your-github-username>
bash infrastructure/scripts/deploy-workshop.sh --tier 3 --image-source ghcr --ghcr-registry-base ghcr.io/<your-github-username>
```

### 5. Gotcha — publish base must equal consume base

The `--registry-base` you pass to `publish-images.sh` and the `--ghcr-registry-base` you pass to `deploy-workshop.sh` **must be identical**. Pointing the consume side at a base where the packages do not exist, or where they are still Private, results in `ImagePullBackOff` on all five pods with no other error message.

| Publish flag | Script | Example |
|---|---|---|
| `--registry-base` | `publish-images.sh` | `ghcr.io/<your-github-username>` |
| `--ghcr-registry-base` | `deploy-workshop.sh` | `ghcr.io/<your-github-username>` |

### 6. Update an image after a change

When you change one app's source, republish **only that image** at the next version — unchanged images keep their existing tag, so they never get a meaningless new version. The image names are `uc1-agent`, `banking-ui`, `banking-agent`, `banking-mcp`, `uc3-agent`.

**6.1** Build and push just the changed image at a new version (here `banking-ui` to `v2`):

```bash
bash infrastructure/scripts/publish-images.sh --image banking-ui --version v2 --registry-base ghcr.io/<your-github-username>
```

**6.2** Bump the matching pin in `infrastructure/workloads/main.tf` (the `ghcr_*` locals) from its current tag to the next one (use whatever the current and next tags are — e.g. `…banking-app-ui:v1` → `:v2`). Leave the other four locals untouched.

**6.3** Re-deploy Tier 3. The new tag makes Terraform roll the Deployment and the pod pull the new image (`IfNotPresent` would never re-pull an unchanged tag):

```bash
bash infrastructure/scripts/deploy-workshop.sh --tier 3 --image-source ghcr --ghcr-registry-base ghcr.io/<your-github-username>
```

A new `:tag` on an existing public package is already Public, so no visibility step is needed (that one-time step applies only the first time a package is created).

