---
title: 'Deploy the Use Case 1 Agent'
weight: 51
---

## Overview

In this module you build and push the Use Case 1 agent container image to Amazon ECR, set the image URI in `terraform.tfvars`, and run `terraform apply` to deploy the agent pod and its Kubernetes resources.

By the end of this module the following Kubernetes objects exist in the `uc1` namespace:

- A Namespace (`uc1`)
- A ServiceAccount (`uc1-retriever-sa`) — the identity Vault validates
- A ConfigMap holding non-secret runtime configuration
- A Deployment (1 replica) running the FastAPI + Strands agent container
- A ClusterIP Service (`uc1-agent-svc`) on port 80
- A NetworkPolicy (`uc1-egress`) restricting outbound traffic

## Step 1 — Create the ECR repository

```bash
aws ecr create-repository \
  --repository-name workshop/uc1-agent \
  --region <REGION>
```

Record the repository URI from the output — you will need it in Step 3:

```bash
export UC1_REPO_URI=$(aws ecr describe-repositories \
  --repository-names workshop/uc1-agent \
  --region <REGION> \
  --query 'repositories[0].repositoryUri' \
  --output text)
echo "Repository: $UC1_REPO_URI"
```

## Step 2 — Build and push the agent image

Authenticate Docker to ECR, then build and push:

```bash
aws ecr get-login-password --region <REGION> | \
  docker login --username AWS --password-stdin \
  "$(aws sts get-caller-identity --query Account --output text).dkr.ecr.<REGION>.amazonaws.com"

cd infrastructure/modules/uc1_agent/agent

docker build --platform linux/amd64 -t workshop/uc1-agent:latest .

docker tag workshop/uc1-agent:latest "${UC1_REPO_URI}:latest"
docker push "${UC1_REPO_URI}:latest"
```

Confirm the image is in ECR:

```bash
aws ecr describe-images \
  --repository-name workshop/uc1-agent \
  --region <REGION> \
  --query 'imageDetails[0].{Tag:imageTags[0],PushedAt:imagePushedAt}'
```

## Step 3 — Set the image URI in terraform.tfvars

Open `infrastructure/terraform.tfvars` (a local file, not tracked in version control) and locate the `uc1_agent_image` variable. Replace the placeholder with your ECR URI:

```hcl
uc1_agent_image = "<ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/workshop/uc1-agent:latest"
```

## Step 4 — Run terraform apply

Apply the change to deploy the Use Case 1 agent:

```bash
terraform -chdir=infrastructure apply
```

Terraform generates a plan showing the `uc1_agent` module resources. Review the plan, then type `yes` to confirm.

The `uc1_agent` module is applied after `vault_config` (Vault Kubernetes auth role and policy must exist before pod startup). During apply the following resources are created:

1. `kubernetes_namespace.uc1` — namespace for all UC1 resources
2. `kubernetes_service_account.uc1_retriever` — the `uc1-retriever-sa` identity
3. `kubernetes_config_map.uc1_agent_config` — non-secret env vars (Vault address, RDS host, KB ID)
4. `kubernetes_deployment.uc1_agent` — agent pod
5. `kubernetes_service.uc1_agent` — ClusterIP service
6. `kubernetes_network_policy.uc1_egress` — egress constraints

## Step 5 — Verify the pod and ServiceAccount

After apply completes, confirm the `uc1` namespace resources are healthy:

```bash
kubectl get pods -n uc1
```

Expected output:

```
NAME                          READY   STATUS    RESTARTS   AGE
uc1-agent-7f9d6c4b5f-x2kqm   1/1     Running   0          2m
```

Verify the ServiceAccount that Vault will validate:

```bash
kubectl get sa -n uc1
```

Expected output:

```
NAME               SECRETS   AGE
default            0         2m
uc1-retriever-sa   0         2m
```

Inspect the NetworkPolicy:

```bash
kubectl get networkpolicy -n uc1
kubectl describe networkpolicy uc1-egress -n uc1
```

Expected egress rules — four ports only:

```
Egress:
  To Port: 53/UDP        # kube-dns
  To Port: 8200/TCP      # Vault
  To Port: 5432/TCP      # RDS Postgres
  To Port: 443/TCP       # Bedrock + STS VPC endpoints
```

Check the agent logs to confirm Vault authentication succeeded at pod startup:

```bash
kubectl logs -n uc1 deploy/uc1-agent --tail=20
```

You should see lines similar to:

```
INFO:     vault_client: Authenticated to Vault via Kubernetes auth (role=uc1)
INFO:     vault_client: Vault token TTL=3600s, renewable=True
INFO:     Application startup complete.
```

:::expand{header="Agent Developer Track — How the vault_client.py startup auth works"}

The agent container runs `app.py` (FastAPI entry point) which calls `VaultClient.login()` once at startup. Here is the code path:

**`vault_client.py` — startup login**

```python
SA_TOKEN_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token"

class VaultClient:
    def __init__(self):
        self._client = None

    def login(self):
        with open(SA_TOKEN_PATH) as f:
            sa_jwt = f.read()
        self._client = hvac.Client(url=os.environ["VAULT_ADDR"])
        self._client.auth.kubernetes.login(
            role=os.environ["VAULT_ROLE"],   # "uc1"
            jwt=sa_jwt,
        )
        logger.info(
            "Authenticated to Vault via Kubernetes auth (role=%s)",
            os.environ["VAULT_ROLE"],
        )
```

Key observations:

- The SA JWT is mounted automatically by the Kubernetes kubelet at the standard path — no secret required.
- `hvac.Client.auth.kubernetes.login()` posts to Vault's `/v1/auth/kubernetes/login` endpoint.
- The returned Vault token is stored in `self._client` — it is **never written to disk or exposed in environment variables**.
- The token TTL is 1 hour (set in `vault_config` `vault_kubernetes_auth_backend_role.uc1.token_ttl`).
- JIT database and STS credentials are fetched **per agent request** inside each `@tool` function — not cached here. This is the pedagogical design: each query shows a fresh credential issuance event in the Vault audit log.

Why `hvac` SDK instead of Vault Agent sidecar? The hvac approach puts the credential-fetch code directly in the application where attendees can read it. A Vault Agent sidecar would inject credentials via shared memory or a file, hiding the mechanism behind a template annotation on the pod spec.
:::

:::expand{header="Platform/Security Track — NetworkPolicy egress rules explained"}

The `uc1-egress` NetworkPolicy applies to all pods in the `uc1` namespace (empty `podSelector`) and allows four outbound paths only.

| Port | Protocol | Destination | Why Required |
|---|---|---|---|
| 53 | UDP | kube-dns | DNS resolution for `vault.vault.svc.cluster.local` and `rds.<REGION>.amazonaws.com` |
| 8200 | TCP | Vault ClusterIP | Kubernetes auth login + dynamic credential fetch |
| 5432 | TCP | RDS Postgres | JIT credential database connection |
| 443 | TCP | VPC endpoints | Bedrock Knowledge Base retrieve + STS `AssumeRole` via Vault AWS secrets engine |

There is no **ingress** rule in the NetworkPolicy. The ClusterIP Service (`uc1-agent-svc`) handles inbound traffic — kube-proxy routes ClusterIP traffic without requiring an explicit NetworkPolicy ingress rule.

Why is there **no IRSA** on the agent pod? OBJ-2 (no standing privileges) requires that the pod hold no ambient AWS IAM identity. IRSA attaches a Pod Identity Association that grants IAM permissions continuously, which is a standing credential. Instead, the pod authenticates to Vault (workload identity), and Vault generates a scoped STS session on demand. When the session expires, the pod has no AWS access — no cleanup required, no rotation needed.
:::
