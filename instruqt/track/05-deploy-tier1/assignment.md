---
slug: deploy-tier1
type: challenge
title: Deploy Tier 1 — Core Infrastructure
teaser: VPC, EKS, RDS, Bedrock KB, ECR, IAM, add-ons. About 25-35 minutes.
tabs:
  - title: Terminal
    type: terminal
    hostname: shell
---

Tier 1 deploys the core AWS infrastructure: VPC, EKS, RDS PostgreSQL with
pgaudit, Bedrock Knowledge Base, ECR, IAM, audit substrate, and the EKS
add-ons (cert-manager, external-dns, AWS Load Balancer Controller). No pods
yet — that comes in tier 2.

`deploy-workshop.sh --tier 1` runs steps 1-4 of the orchestrator:

1. `terraform apply` against `infrastructure/` (the tier-1 root)
2. `aws eks update-kubeconfig` to point `kubectl` at the new cluster
3. `build-images.sh` — builds and pushes the Use Case agent images to ECR
4. Load Balancer Controller readiness gate

The challenge `setup-shell` invokes this for you. The deploy is idempotent —
if anything fails, re-running the same command converges (Project CLAUDE.md
mandate).

{% hint style="info" %}
First-time tier-1 deploy takes ~25-35 minutes — EKS (~12 min), RDS (~10 min
including pgaudit reboot), Bedrock KB (~3 min), add-ons (~5 min). Timing
tracks AWS API response, not your sandbox.
{% endhint %}

## Inspect what landed

```bash
cd /root/workshop
kubectl get nodes
```

Expected: five nodes in `Ready` state running an EKS-managed node group.

```bash
kubectl get pods -n kube-system
```

Expected: cert-manager (3 pods), aws-load-balancer-controller (2 pods),
external-dns (1 pod), aws-ebs-csi-driver, coredns, and EKS Pod Identity Agent
all `Running`.

When all the above shows green, advance to the next challenge.
