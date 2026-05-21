# EDR Module — Uptycs KSPM (k8sosquery + kubequery)

Deploys Uptycs Kubernetes Security Posture Management agents on EKS for HC-COMPUTE-011 compliance:

- **k8sosquery** — DaemonSet (one pod per node), privileged. Uptycs osquery agent with Protect enabled for host + container telemetry.
- **kubequery** — Deployment (single pod). Kubernetes API telemetry, compliance scanning, and admission controller webhooks.

Both charts come from `https://uptycslabs.github.io/kspm-helm-charts`.

**Reference docs:** [IBM CISO Uptycs Kubernetes documentation](https://pages.github.ibm.com/CISO-Platform-Network-Defense/Uptycs-Documentation/Containers/Kubernetes/Overview/)

## Toggle

Controlled by `var.enable_edr` in the root module (default `false`). Set to `true` in `terraform.tfvars` to deploy.

## Values files

Values files in `values/` are tenant-specific downloads from the Uptycs console (**Assets > Downloads > Helm Values**). They contain enrollment secrets and TLS certs — do NOT commit to public repos.

To refresh from a new tenant:

```sh
tar -xzf <tenant>-k8sosquery-<tenant>-kubequery-protect-helm-values-<version>.tar.gz \
  -C infrastructure/modules/edr/values/
```

## Manual install (reference — Terraform does this for you)

From the Uptycs official docs.

### 3. Installing K8sosquery and Kubequery

Uptycs gives you the ability to install the sensors either in your own custom namespace or in the Uptycs default namespace.

**Custom namespace:**

```sh
helm install k8sosquery -f <path_to_downloaded_k8sosquery_values_file> \
  kspm-helm-charts/k8sosquery --namespace <desired-namespace> --create-namespace

helm install kubequery --set deployment.spec.hostname=<cluster_name_in_uptycs_ui> \
  -f <path_to_downloaded_kubequery_values_file> \
  kspm-helm-charts/kubequery --namespace <desired-namespace> --create-namespace
```

**Default namespace:**

```sh
helm install k8sosquery -f <path_to_downloaded_k8sosquery_values_file> \
  kspm-helm-charts/k8sosquery

helm install kubequery --set deployment.spec.hostname=<cluster_name_in_uptycs_ui> \
  -f <path_to_downloaded_kubequery_values_file> \
  kspm-helm-charts/kubequery
```

### 4. Verifying the Installation

Edit the namespace if you used a custom one.

- **Kubernetes:** `kubectl get po -n uptycs && kubectl get po -n kubequery`
- **OpenShift:** `kubectl get po -n uptycs && kubectl get po -n uptycs-kubequery`

### Verification

Use Uptycs' verification tool and enter your asset ID or worker node UUID:

```sh
kubectl get nodes -o=jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.labels.ibm-cloud\.kubernetes\.io/worker-id}{"\t"}{.status.nodeInfo.systemUUID}{"\n"}{end}'
```

### Upgrade

```sh
helm repo update kspm-helm-charts
helm upgrade k8sosquery -f values/k8sosquery-values.yaml kspm-helm-charts/k8sosquery -n uptycs
helm upgrade kubequery --set deployment.spec.hostname=<cluster_name> \
  -f values/kubequery-values.yaml kspm-helm-charts/kubequery -n kubequery
```

Terraform handles upgrades automatically when `k8sosquery_chart_version` / `kubequery_chart_version` are bumped in `variables.tf`.
