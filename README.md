# Agentic Runtime Security on AWS

A hands-on AWS Workshop Studio workshop that teaches platform and security teams how to implement the IBM Verify + HashiCorp Vault joint reference architecture for **runtime agentic security on AWS**. Attendees leave able to deploy and explain a real implementation of the 5 control objectives — every agent has a verifiable identity, no standing privileges, actions tied to user intent, enforcement at point of use, and correlated audit evidence — using the IBM Verify + HashiCorp Vault stack on AWS EKS.

## Overview

This repository delivers a Workshop Studio site + reveal-md slide deck + Terraform Stacks IaC that progressively layers three use cases on a single-region (`us-west-2`) EKS cluster:

- **UC1 — Non-personalized read-only:** Strands agent with workload identity (Vault Kubernetes auth), JIT R/O Postgres credentials (TTL 15m), and scoped Bedrock STS for Knowledge Base retrieval (Objectives 1, 2, 5)
- **UC2 — OAuth personalized read-only:** OAuth Authorization Code + PKCE against IBM Verify Access establishes user identity; Vault `jwt` auth vends per-user-scoped credentials; Layer 2 + Layer 3 enforcement demonstrated (adds Objective 3)
- **UC3 — CIBA privileged + three-plane audit correlation:** CIBA out-of-band approval; tokens carry `may_act` (RFC 8693) and `authorization_details` (RFC 9396 RAR) claims enforced by Vault `bound_claims`; time-boxed R/W credentials (TTL 5m); single Athena query joining IVIA decision logs + Vault audit + AWS CloudTrail by `request_id` (all 5 Objectives)

The workshop mirrors the structure of [`eks-terraform-stacks`](https://github.com/aws-samples/eks-terraform-stacks): Workshop Studio site at `workshop/`, reveal-md slide deck at `slides.md`, Terraform Stacks IaC at `infrastructure/`.

## Architecture

![Reference architecture](assets/architecture-overview.svg)

The reference architecture diagram (regenerated from Excalidraw source in `assets/`) shows the joint Verify + Vault responsibility split: IBM Verify owns human IAM (user authentication, OAuth, CIBA); HashiCorp Vault owns non-human IAM (workload identity, policy enforcement, JIT credential vending). All three agents (UC1/UC2/UC3) run as pods on a single EKS cluster alongside Vault (Raft 3-node, KMS auto-unseal) and IBM Verify Identity Access (Config Service + Runtime + DSC).

Deeper diagrams (per-use-case flows, audit correlation) are produced in Phase 1 by the Excalidraw → SVG pipeline and embedded in `workshop/content/` and `slides.md`.

## Prerequisites

Workshop attendees do not install CLI tools manually. A single consolidated `preflight.sh` script auto-installs every required CLI and verifies the AWS account in one shot; `bootstrap.sh` then wires up HCP Terraform.

```bash
# 1. Single pre-flight: install CLI tools (kubectl 1.33.x, helm 3.12+,
#    terraform 1.10+, vault 1.21.x, aws v2, jq, yq) AND verify
#    Bedrock access (us.amazon.nova-pro-v1:0 — Amazon Nova Pro via
#    cross-region inference profile) + service quotas + IAM permissions
./infrastructure/scripts/preflight.sh

# 2. Bootstrap HCP Terraform org/varset/OIDC/IAM
./infrastructure/scripts/bootstrap.sh <HCP_ORG>
```

`preflight.sh` emits colored `✓ PASS` / `✗ FAIL` / `⚠ WARN` markers and a single consolidated summary with full inline copy-paste remediation for any failure (no "see external doc" indirection). Flags: `--interactive` (prompt before each install + each check section), `--dry-run` (print install plan), `--help`.

### Slide deck preview

The workshop slide deck lives in `slides.md` (reveal-md markdown format — no build step required). Diagrams are authored in Excalidraw and exported to SVG via `python3 infrastructure/scripts/excalidraw-to-svg.py`.

```bash
# Present (opens browser)
npx reveal-md slides.md

# Export to PDF
npx reveal-md slides.md --print slides.pdf
```

### Workshop content preview

Preview the Workshop Studio content locally (downloads the AWS preview utility on first run):

```bash
./workshop/scripts/preview.sh
```

## Deploy

After prerequisites and bootstrap, run the end-to-end deploy + verification:

```bash
./infrastructure/scripts/workshop-e2e.sh <HCP_ORG> --interactive --skip-teardown
```

The deploy story will cover applying the Terraform Stacks `vpc` + `eks` + `rds` + `bedrock_kb` + (later) `vault` + `verify_access` + `vault_config` + `isva_config` + (later) `uc1_agent` + `uc2_agent` + `uc3_agent` + `observability` components on HCP Terraform, plus the `aws eks update-kubeconfig` one-liner to reach the cluster from `kubectl`.

## Cleanup

*Cleanup instructions populated in Phase 7 (Cleanup, Summary, Appendices).*

The cleanup story will cover the one-shot `infrastructure/scripts/teardown.sh` that decommissions all workshop resources (Stacks deployments, EKS, RDS, Bedrock KB + OpenSearch Serverless, Vault PVCs, IBM Verify Access snapshots, audit log groups, Secrets Manager entries, ENIs, Load Balancers, EBS volumes) with no orphans surviving — so the same account can immediately host a second workshop run.

## Project Structure

```
.
├── README.md
├── LICENSE                          # MIT-0 (AWS Workshop Studio convention)
├── TESTING.md                       # Workshop testing/verification guide
├── slides.md                        # reveal-md slide deck
├── reveal-md.json                   # reveal-md theme + transition config
├── assets/                          # Excalidraw sources + exported SVGs (six diagrams)
├── workshop/                        # AWS Workshop Studio content
│   ├── contentspec.yaml             # Workshop Studio v2 schema
│   └── content/
│       ├── 10-introduction/
│       ├── 20-prerequisites/
│       ├── 30-foundational/         # Phase 2 content
│       ├── 40-platform/             # Phase 3 content
│       ├── 50-integration/          # Phase 3 content
│       ├── 60-uc1-non-personalized/ # Phase 4 content
│       ├── 70-uc2-personalized/     # Phase 5 content
│       ├── 80-uc3-privileged/       # Phase 6 content
│       ├── 97-appendices/           # Phase 7 content
│       ├── 98-summary/              # Phase 7 content
│       ├── 99-credits/
│       └── 99-resources/            # Phase 7 content
└── infrastructure/                  # Terraform Stacks IaC (HCP working directory)
    ├── modules/
    │   ├── vpc/                     # Phase 2
    │   ├── eks/                     # Phase 2
    │   ├── rds/                     # Phase 2
    │   ├── bedrock_kb/              # Phase 2
    │   ├── vault/                   # Phase 3
    │   ├── verify_access/           # Phase 3
    │   ├── vault_config/            # Phase 3
    │   ├── isva_config/             # Phase 3
    │   ├── observability/           # Phase 6
    │   ├── uc1_agent/               # Phase 4
    │   ├── uc2_agent/               # Phase 5
    │   └── uc3_agent/               # Phase 6
    └── scripts/
        ├── preflight.sh             # PREF-01/02/03/05 — install CLIs + verify Bedrock + quotas + IAM
        ├── bootstrap.sh             # PREF-04 — HCP Terraform org/varset/OIDC/IAM setup
        ├── common-checks.sh         # shared bash library (print_pass/fail, confirm, print_summary)
        └── excalidraw-to-svg.py     # SVG regeneration pipeline
```

> **HCP Terraform Working Directory:** When creating the Stack in HCP Terraform, set the working directory to `infrastructure/`. This tells HCP Terraform where to find the Stacks HCL files.

## Known Issues

- **IVIA OIDC Provider 25.10 — ROPC + `scope=openid` crashes id_token generation.** The ROPC flow does not propagate the authenticated user identity to the `pretoken` mapping rule, causing a nil pointer at `access_response_writer.go:28`. A workaround is applied in the `pretoken` rule. See [`infrastructure/modules/verify_access/README.md`](infrastructure/modules/verify_access/README.md#known-issue--ivia-2510-ropc--scopeopenid-id_token-generation-crash) for full details, root cause analysis, and the Goja JS runtime API reference.

## References

- [Terraform Stacks Documentation](https://developer.hashicorp.com/terraform/language/stacks)
- [HashiCorp Validated Design — Organizing Resources](https://developer.hashicorp.com/validated-designs/terraform-operating-guides-adoption/organizing-resources#terraform-stacks)
- [AWS EKS Blueprints for Terraform](https://github.com/aws-ia/terraform-aws-eks-blueprints)
- [HashiCorp Vault on Kubernetes (Helm)](https://developer.hashicorp.com/vault/docs/platform/k8s/helm)
- [IBM Verify Identity Access](https://www.ibm.com/products/verify-identity-access)
- [Strands Agents](https://strandsagents.com/)
- [Reference workshop — `eks-terraform-stacks`](https://github.com/aws-samples/eks-terraform-stacks)

## License

See LICENSE file (MIT-0).
