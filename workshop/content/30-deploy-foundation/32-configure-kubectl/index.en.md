---
title: 'Configure kubectl'
weight: 32
---

**Why:** Every page from here on talks to the cluster, and `kubectl` does not know where it is yet. Tier-1 emits the exact `update-kubeconfig` command for your cluster, so there is nothing to substitute.

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

EKS authorization is separate from the kubeconfig this command writes. **Self-paced:** you created the cluster, so you already hold `cluster-admin`. **At an event:** the cluster was provisioned for you by the account setup, which granted `cluster-admin` to your `WSParticipantRole` — so `kubectl` works with the identity Workshop Studio gave you.

If a node is `NotReady`, check the `vpc-cni` Pod Identity Association — the most common failure is `before_compute` ordering when a manual reapply skips the Pod Identity Agent.

If instead you see `error: You must be logged in to the server (Unauthorized)`, your CLI identity is not the one granted cluster access. Confirm who you are with `aws sts get-caller-identity` — at an event you must be operating as `WSParticipantRole` (the identity Workshop Studio assigned), which is the principal that holds `cluster-admin`.
