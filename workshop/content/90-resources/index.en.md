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

## Bring Your Own GHCR Registry

A power-user/fork reference for hosting the five workshop images in your own GHCR namespace. This is **not** a step in the main deploy flow — the default `deploy-workshop.sh` pulls images from `ghcr.io/sharepointoscar` anonymously. Use this reference only if you want to repoint the GHCR base to your own account.

### 1. Prerequisites

You need:

- A GitHub account with a `write:packages` scope on your CLI token:

```bash
gh auth refresh -h github.com -s write:packages
```

- A running container runtime (Docker or Podman) — publishing builds the images locally before pushing. See [Self-paced: build images locally](../20-prerequisites/23-pre-flight-checks/#self-paced-build-images-locally---image-source-ecr) for setup instructions.

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

