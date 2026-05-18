################################################################################
# EDR Module — Uptycs KSPM (k8sosquery + kubequery)
#
# Deploys two Helm charts from uptycslabs/kspm-helm-charts:
#   1. k8sosquery — DaemonSet (one pod per node), privileged. Uptycs osquery
#      agent with Protect enabled for host + container telemetry.
#   2. kubequery  — Deployment (single pod). Kubernetes API telemetry,
#      compliance scanning, and admission controller webhooks.
#
# Values files in values/ are tenant-specific downloads from the Uptycs
# console (Assets > Helm Values). They contain enrollment secrets and TLS
# certs — do NOT commit to public repos.
################################################################################

resource "helm_release" "k8sosquery" {
  name             = "k8sosquery"
  repository       = "https://uptycslabs.github.io/kspm-helm-charts"
  chart            = "k8sosquery"
  version          = var.k8sosquery_chart_version
  namespace        = "uptycs"
  create_namespace = true

  values = [file("${path.module}/values/k8sosquery-values.yaml")]
}

resource "helm_release" "kubequery" {
  name             = "kubequery"
  repository       = "https://uptycslabs.github.io/kspm-helm-charts"
  chart            = "kubequery"
  version          = var.kubequery_chart_version
  namespace        = "kubequery"
  create_namespace = true

  values = [file("${path.module}/values/kubequery-values.yaml")]

  set {
    name  = "deployment.spec.hostname"
    value = var.cluster_name
  }
}
