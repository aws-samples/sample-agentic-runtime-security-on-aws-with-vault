---
title: 'Configure kubectl'
weight: 32
---

The `eks` module emits a one-liner output. Read it from the Terraform output:

```bash
terraform -chdir=infrastructure output -raw kubectl_config_command
```

Run the command it prints:

```bash
aws eks update-kubeconfig \
  --region <REGION> \
  --name <CLUSTER_NAME> \
  --alias workshop
```

Substitute `<REGION>` and `<CLUSTER_NAME>` from the run output, then verify:

```bash
kubectl get nodes
```

**Expected output** — three nodes in `Ready` state:

```
NAME                                       STATUS   ROLES    AGE   VERSION
ip-10-1-1-xxx.<region>.compute.internal    Ready    <none>   5m    v1.33.x-eks-xxxx
ip-10-1-2-xxx.<region>.compute.internal    Ready    <none>   5m    v1.33.x-eks-xxxx
ip-10-1-3-xxx.<region>.compute.internal    Ready    <none>   5m    v1.33.x-eks-xxxx
```

If a node is `NotReady`, check the `vpc-cni` Pod Identity Association — the most common failure is `before_compute` ordering when a manual reapply skips the Pod Identity Agent.
