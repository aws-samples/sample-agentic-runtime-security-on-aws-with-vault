---
title: 'Configure kubectl'
weight: 32
---

The `eks` module emits a ready-to-run `aws eks update-kubeconfig` command. Run it in one shot — no substitution needed — and verify nodes:

```bash
$(terraform -chdir=infrastructure output -raw kubectl_config_command)
kubectl get nodes
```

**Expected output** — five nodes in `Ready` state:

```
NAME                                       STATUS   ROLES    AGE   VERSION
ip-10-1-1-xxx.<region>.compute.internal    Ready    <none>   5m    v1.34.x-eks-xxxx
ip-10-1-2-xxx.<region>.compute.internal    Ready    <none>   5m    v1.34.x-eks-xxxx
ip-10-1-3-xxx.<region>.compute.internal    Ready    <none>   5m    v1.34.x-eks-xxxx
ip-10-1-4-xxx.<region>.compute.internal    Ready    <none>   5m    v1.34.x-eks-xxxx
ip-10-1-5-xxx.<region>.compute.internal    Ready    <none>   5m    v1.34.x-eks-xxxx
```

If a node is `NotReady`, check the `vpc-cni` Pod Identity Association — the most common failure is `before_compute` ordering when a manual reapply skips the Pod Identity Agent.
