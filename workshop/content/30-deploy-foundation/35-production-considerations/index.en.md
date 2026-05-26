---
title: 'Production Considerations'
weight: 35
---

Several spots in this module's code are deliberately simplified to keep the workshop teachable in a 6-hour window. **Do not copy these directly into a production deployment.** The table below names each simplification, where it lives, and the canonical production pattern. The rest of the workshop's choices — workload-identity discipline, no-standing-privileges, audit-correlation, region pinning, helm 2.17 / opensearch 2.2.0 pins, EKS 1.33 / Pod Identity — *are* production-grade.

| Workshop simplification | Where | Production pattern |
| --- | --- | --- |
| EKS API endpoint exposed to `0.0.0.0/0` | `infrastructure/modules/eks/main.tf` (`cluster_endpoint_public_access_cidrs`) | Set `cluster_endpoint_public_access = false` and rely on `cluster_endpoint_private_access = true`; reach the cluster via AWS Client VPN, a bastion, or SSM Session Manager. Or pin `_cidrs` to corporate egress / VPN exit IPs. The `0.0.0.0/0` choice is needed for Workshop Studio attendees, who arrive from random IPs. |
| AOSS network policy `AllowFromPublic = true` | `infrastructure/modules/bedrock_kb_aoss/aoss.tf` | Set `AllowFromPublic = false` and add a VPC interface endpoint (`aws_vpc_endpoint` with `service_name = "com.amazonaws.<region>.aoss"`). Reference it from the network policy via `SourceVPCEs`. Bedrock KB → AOSS traffic stays inside the VPC. |
| AOSS data-access policy uses `aoss:*` | `infrastructure/modules/bedrock_kb_aoss/aoss.tf` | Split into two principal-scoped statements: the Bedrock KB role gets `aoss:APIAccessAll` only (read/write data + ingestion), and the workspace deploy principal gets `aoss:CreateIndex` / `aoss:UpdateIndex` / `aoss:DeleteIndex` / `aoss:DescribeIndex` (index lifecycle). Drop admin actions from both. |
| `enable_cluster_creator_admin_permissions = true` | `infrastructure/modules/eks/main.tf` | For pipeline-deployed clusters, set this to `false` and explicitly declare `access_entries` per role: platform team gets `AmazonEKSClusterAdminPolicy`, app teams get `AmazonEKSEditPolicy` scoped to namespaces, on-call gets `AmazonEKSViewPolicy`. The deploy role's access entry should be revoked post-bootstrap (Pitfall E3 — without revocation it persists and is hard to audit). |
| Deploy role attached `AdministratorAccess` | `infrastructure/scripts/bootstrap.sh` | Replace with a scoped least-privilege policy, then iterate against your real apply log to add any missing actions. Workshop pedagogy — IAM least-privilege design — is its own multi-day topic; this workshop teaches the workload-identity layer, not IAM design. |

The workshop's deliberate stop point: it teaches **the 5 control objectives at the workload-identity / data-plane layer**. The simplifications above are at the IAM / network-perimeter layer, which a different workshop (or a Hashicorp Validated Design) would tackle.

## Next steps

Continue to **[Platform — Vault and Verify Access](../../40-platform/)**. The Platform module will:

- Install HashiCorp Vault on EKS (3 Raft pods, one per AZ) with auto-unseal via a separate KMS key.
- Install IBM Verify Identity Access on EKS with LDAP authentication against an in-cluster OpenLDAP directory, fronted by an ALB Ingress (provisioned by the Load Balancer Controller you just deployed).
- Wire fluent-bit DaemonSets to ship Vault audit + IVIA decision logs into the **already-pre-created** `/workshop/vault-audit` and `/workshop/ivia-decision` log groups by ARN.
- Configure the Vault `jwt` auth method to trust IVIA's OIDC discovery URL — the OIDC seam where user intent becomes a Vault-vended credential.

The audit-correlation contract you just deployed is the foundation every later module joins against. By the end of Use Case 3, a single Athena query in workgroup `workshop` will JOIN the three audit planes (IVIA decision, Vault audit, RDS pgaudit) on `request_id` and answer "which user authorized which action against which database write?" — the load-bearing Use Case 3 deliverable.
