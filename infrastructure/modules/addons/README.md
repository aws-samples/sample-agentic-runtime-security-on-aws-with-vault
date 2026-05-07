# addons

Phase 2 Stacks component that installs the three **external** (non-managed) EKS cluster addons via [`aws-ia/eks-blueprints-addons ~> 1.0`](https://registry.terraform.io/modules/aws-ia/eks-blueprints-addons/aws/latest):

- cert-manager
- external-dns
- AWS Load Balancer Controller

The five **managed** cluster addons (`vpc-cni`, `coredns`, `kube-proxy`, `eks-pod-identity-agent`, `aws-ebs-csi-driver`) are owned by the [`eks`](../eks/README.md) module (Plan 02-03), which installs them with **Pod Identity Associations** on the two addons that need IAM (`vpc-cni`, `ebs-csi`).

## Overview

CONTEXT.md ([Phase 2 context](../../../.planning/phases/02-foundation-infrastructure/02-CONTEXT.md)) chose to front-load these three external addons into Phase 2 — rather than letting Phase 3+ install them ad-hoc — so every Phase 3+ plan can assume they exist:

- **Phase 3** (Vault + IBM Verify Identity Access): cert-manager issues TLS material; the AWS Load Balancer Controller fronts the IVIA management UI; external-dns publishes the records attendees navigate to.
- **Phase 4-6** (UC1, UC2, UC3 agent pods): ALB Ingress on top of agent Services; cert-manager issuers for service-to-service TLS.

## Decisions (locked from CONTEXT)

- **3 external addons enabled** — cert-manager, external-dns, AWS Load Balancer Controller. Front-loaded in Phase 2.
- **Helm provider pinned `~> 2.17`** — Pitfall H1; do NOT bump to 3.x. The `aws-ia/eks-blueprints-addons` module's `helm_release` shape is incompatible with helm provider 3.x as of pin time.
- **Pod Identity vs IRSA** — accept the pinned `eks-blueprints-addons` v1.x module's defaults. Per RESEARCH Open Question 2/3, that version installs the 3 external addons via **IRSA** (consumes `oidc_provider_arn`). CONTEXT's "Pod Identity for cluster addons" decision applies to MANAGED addons (vpc-cni, ebs-csi) which are owned by the `eks` module — external addons inherit module defaults.
- **cert-manager** ships with the default `selfsigned` ClusterIssuer; **Vault PKI integration is deferred to Phase 3+**.
- **Karpenter is OUT of scope** — `enable_karpenter = false`. Cluster runs with managed node group only (per project [CLAUDE.md](../../../CLAUDE.md)).
- **ArgoCD is OUT of scope** — `enable_argocd = false`. Deploys are Helm-direct or Stacks (per project [CLAUDE.md](../../../CLAUDE.md)).
- **`aws_load_balancer_controller.replicaCount = 2`** — keeps the mutating webhook reachable across pod restarts; otherwise brief webhook outages can fail concurrent Service applies.

## Inputs

| Name                | Type          | Default      | Description                                                                                                  |
| ------------------- | ------------- | ------------ | ------------------------------------------------------------------------------------------------------------ |
| `region`            | `string`      | _(required)_ | AWS region (canonical value from `deployments.tfdeploy.hcl`).                                                |
| `cluster_name`      | `string`      | _(required)_ | EKS cluster name — wired from `component.eks.cluster_name`.                                                  |
| `cluster_endpoint`  | `string`      | _(required)_ | EKS API server endpoint — wired from `component.eks.cluster_endpoint`.                                       |
| `cluster_version`   | `string`      | _(required)_ | Kubernetes version — wired from `component.eks.cluster_version`. Gates addon chart-version selection.        |
| `oidc_provider_arn` | `string`      | _(required)_ | IRSA OIDC provider ARN — wired from `component.eks.oidc_provider_arn`.                                       |
| `tags`              | `map(string)` | `{}`         | Tags applied to all resources.                                                                               |

## Outputs

| Name                                   | Description                                                                                              |
| -------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| `cert_manager_release`                 | cert-manager `helm_release` attributes (name, namespace, version, status).                               |
| `external_dns_release`                 | external-dns `helm_release` attributes.                                                                  |
| `aws_load_balancer_controller_release` | AWS Load Balancer Controller `helm_release` attributes.                                                  |

Phase 3+ components depending on a specific addon's presence (e.g. an Ingress depending on the ALB Controller webhook being live) can `depends_on` these outputs at the component level in `components.tfcomponent.hcl`.

## Component wiring

The `addons` component is a Wave 2 dependency on `eks`:

```hcl
component "addons" {
  source     = "./modules/addons"
  depends_on = [component.eks]

  providers = {
    aws        = provider.aws.main
    helm       = provider.helm.main
    kubernetes = provider.kubernetes.main
    time       = provider.time.main
    random     = provider.random.main
  }

  inputs = {
    region            = var.region
    cluster_name      = component.eks.cluster_name
    cluster_endpoint  = component.eks.cluster_endpoint
    cluster_version   = component.eks.cluster_version
    oidc_provider_arn = component.eks.oidc_provider_arn
    tags              = var.tags
  }
}
```

The `helm` and `kubernetes` providers are configured at the root of the Stacks deployment (in `providers.tfcomponent.hcl`) using `component.eks.cluster_endpoint`, `component.eks.cluster_certificate_authority_data`, and `component.eks.cluster_token`. This module does not redeclare provider blocks — it inherits them from the Stacks root.

## Pitfall H1 — helm provider 2.17 (NOT 3.x)

The `helm` provider is pinned `~> 2.17`. The `aws-ia/eks-blueprints-addons` module's `helm_release` resource shape is incompatible with helm provider 3.x as of pin time — bumping to 3.x triggers `unsupported argument` errors during `terraform validate`.

**Do NOT auto-upgrade** the helm provider in this module's `required_providers` block. If a future eks-blueprints-addons release moves to helm 3.x, validate end-to-end against an attendee-equivalent cluster before bumping here.

## References

- [`aws-ia/eks-blueprints-addons` — module docs](https://registry.terraform.io/modules/aws-ia/eks-blueprints-addons/aws/latest)
- [cert-manager](https://cert-manager.io/)
- [external-dns](https://kubernetes-sigs.github.io/external-dns/)
- [AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/)
- [`eks` module README](../eks/README.md) — managed addon ownership (the 5 with Pod Identity).
- [`02-06-PLAN.md`](../../../.planning/phases/02-foundation-infrastructure/02-06-PLAN.md) — plan that creates this module.
- Pitfall H1 — `02-RESEARCH.md` Pitfall H1 (helm provider 3.x incompatibility).
