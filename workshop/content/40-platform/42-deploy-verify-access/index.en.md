---
title: 'Deploy Verify Access'
weight: 42
---

## Overview

In this step you deploy IBM Verify Identity Access (IVIA) 11.0.2 as a self-hosted OIDC provider and CIBA authorization server on the EKS cluster. IVIA runs as raw Kubernetes workloads (Deployment, Service, Ingress) rather than a Helm chart — raw manifests as Terraform resources make the full configuration visible and reviewable.

IVIA authenticates users against **AWS Simple AD** — a lightweight managed Active Directory deployed in the same VPC as EKS. In a real enterprise, this would be your organization's existing Active Directory or LDAP directory. The workshop pre-provisions two employees (Oscar and Adriana) so you can test the OAuth and CIBA flows end-to-end.

The IVIA deployment is exposed externally via an AWS Application Load Balancer managed by AWS Load Balancer Controller.

## Prerequisites

:::alert{header="IBM entitlement key required" type="warning"}
The IVIA container image is pulled from IBM Container Registry (`icr.io`). You must have a valid IBM entitlement key. The `icr_entitlement_key` was set in the HCP Terraform variable set during bootstrap. If the IVIA pod shows `ImagePullBackOff`, verify the key is correct in the HCP Terraform UI under your variable set.
:::

## Step 1 — Review the verify_access module

Open `infrastructure/main.tf` and locate the `verify_access` module block. It depends on `module.addons` (same `time_sleep.alb_webhook_ready` gate) which ensures cert-manager and AWS Load Balancer Controller are available.

The `verify_access` module calls `infrastructure/modules/verify_access/` which provisions:

- A `verify-access` Kubernetes namespace.
- An ICR pull secret (`icr-pull-secret`) for `icr.io` authentication, wired into both the ServiceAccount's `imagePullSecrets` and the Deployment's pod template.
- The IVIA Deployment (image `icr.io/ibmid/verify-access:26.03`), ConfigMap, and Service.
- An `Ingress` resource annotated for AWS Load Balancer Controller, which provisions an ALB.
- A `wait_for_rollout` resource that ensures the deployment is healthy before the module reports success.

## Step 2 — Already deployed

The `verify_access` module was deployed as part of the foundation `terraform apply` in the previous module. It deploys in the same wave as `vault` — after the `addons` wave completes, both `vault` and `verify_access` apply. No separate apply step is needed.

## Step 3 — What happens during apply

When the `verify_access` module applies:

1. The `verify-access` namespace is created.
2. An `icr-pull-secret` Kubernetes Secret of type `kubernetes.io/dockerconfigjson` is created with the IBM entitlement key as the password for `icr.io`.
3. The IVIA Deployment, ConfigMap, and Service are created. The Deployment uses the `26.03` image tag (IVIA 11.0.2 release).
4. The `Ingress` resource triggers AWS Load Balancer Controller to provision an ALB. The ALB hostname is output as `ivia_alb_hostname`.
5. IVIA bootstraps a PostgreSQL schema in the workshop RDS instance (connection string configured via Terraform variables).
6. IVIA starts the OIDC provider on port `443` internally and the management interface on port `9443`.

## Step 4 — Verify pods are running

```bash
kubectl get pods -n verify-access
```

Expected output:

```
NAME                            READY   STATUS    RESTARTS   AGE
ivia-deployment-<hash>          1/1     Running   0          5m
```

Check the Ingress and ALB hostname:

```bash
kubectl get ingress -n verify-access
```

```
NAME            CLASS   HOSTS   ADDRESS                                                  PORTS   AGE
ivia-ingress    alb     *       k8s-verifyac-ivia-xxxx.elb.amazonaws.com   80,443  5m
```

## Step 5 — Verify OIDC discovery endpoint

IVIA exposes its OIDC discovery document at `/oauth2/.well-known/openid-configuration`. Test the in-cluster endpoint (used by Vault `jwt` auth):

```bash
kubectl run oidc-check --image=curlimages/curl --rm -i --restart=Never \
  -n verify-access -- \
  curl -sk https://isvaop.verify-access.svc.cluster.local:8436/oauth2/.well-known/openid-configuration \
  | jq .
```

Expected output includes:

```json
{
  "issuer": "https://isvaop.verify-access.svc.cluster.local:8436/oauth2",
  "authorization_endpoint": "https://isvaop.verify-access.svc.cluster.local:8436/oauth2/authorize",
  "token_endpoint": "https://isvaop.verify-access.svc.cluster.local:8436/oauth2/token",
  "jwks_uri": "https://isvaop.verify-access.svc.cluster.local:8436/oauth2/jwks",
  ...
}
```

The `issuer` value is the URL Vault will use as `bound_issuer` in the `jwt` auth configuration. Save it:

```bash
IVIA_ISSUER=$(kubectl run oidc-issuer --image=curlimages/curl --rm -i --restart=Never \
  -n verify-access -- \
  curl -sk https://isvaop.verify-access.svc.cluster.local:8436/oauth2/.well-known/openid-configuration \
  | jq -r .issuer)
echo "IVIA issuer: $IVIA_ISSUER"
```

:::collapsible{header="IVIA architecture — why raw Kubernetes manifests?"}
IBM Verify Identity Access does not publish a Helm chart. The `verify_access` Terraform module uses the `kubernetes` provider to manage each Kubernetes resource as a Terraform resource (`kubernetes_namespace`, `kubernetes_secret`, `kubernetes_deployment`, `kubernetes_service`, `kubernetes_ingress_v1`).

Using the `kubernetes` provider (rather than `kubectl_manifest` with raw YAML) keeps the full configuration visible as Terraform HCL and avoids introducing a second provider dependency. Attendees can read the exact Deployment spec, resource requests, environment variables, and volume mounts directly in `infrastructure/modules/verify_access/main.tf`.

The image tag `26.03` corresponds to IVIA release 11.0.2 — IBM tags IVIA images by release date rather than semantic version.
:::
