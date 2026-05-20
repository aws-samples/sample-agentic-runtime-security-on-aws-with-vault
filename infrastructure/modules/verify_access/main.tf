################################################################################
# IBM Verify Identity Access (IVIA) — 7-deployment Kubernetes module.
#
# Replaces the legacy single-pod-sidecar + RDS-HVDB + shell-curl autoconfig
# module with the sibling-repo verify-access-container-deployment proven happy
# path:
#   - 7 deployments (openldap, postgresql, iviaconfig, iviadsc, iviaop,
#     iviaruntime, iviawrprp1) in single 'verify-access' namespace.
#   - Pinned image tags (LMI/DSC/Runtime/WRP/Postgres 11.0.2.0,
#     OIDC Provider 25.10, OpenLDAP 10.0.6.0).
#   - In-cluster kubernetes_job_v1 running python -m ibmvia_autoconf 0.3.34
#     against a MINIMAL webseal.runtime base_layer.yaml.
#   - LMI external exposure via NLB Service (TCP passthrough on 9443).
#   - WRP browser exposure via existing ALB Ingress (separate path).
#
# Phase 7 plan: .planning/phases/07-ivia-deployment-refactor/
# Sibling reference: ~/git-repos/verify-access-container-deployment/phase-a/
################################################################################

terraform {
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.25" }
    aws        = { source = "hashicorp/aws", version = "~> 5.0" }
    random     = { source = "hashicorp/random", version = "~> 3.0" }
    tls        = { source = "hashicorp/tls", version = "~> 4.0" }
    time       = { source = "hashicorp/time", version = "~> 0.9" }
  }
}

locals {
  namespace = "verify-access"
  common_labels = {
    "app.kubernetes.io/part-of"    = "ivia"
    "app.kubernetes.io/managed-by" = "terraform"
  }
}

#-------------------------------------------------------------------------------
# Namespace
#-------------------------------------------------------------------------------

resource "kubernetes_namespace" "verify_access" {
  metadata {
    name   = local.namespace
    labels = local.common_labels
  }
}

#-------------------------------------------------------------------------------
# ICR image pull secret. Sibling pod manifests reference 'dockerlogin' verbatim
# (phase-a/ivia-eks.yaml imagePullSecrets blocks). Username 'iamapikey' is the
# target-verified form (RESEARCH §2.5, §7.2). Sibling uses 'cp'; both work for
# IBM entitlement keys.
#-------------------------------------------------------------------------------

resource "kubernetes_secret" "dockerlogin" {
  metadata {
    name      = "dockerlogin"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels    = local.common_labels
  }
  type = "kubernetes.io/dockerconfigjson"
  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        "icr.io" = {
          username = "iamapikey"
          password = var.icr_entitlement_key
          auth     = base64encode("iamapikey:${var.icr_entitlement_key}")
        }
      }
    })
  }
}

#-------------------------------------------------------------------------------
# Cross-node LDAPS (TCP/636). pdconfig running on iviaruntime pod may schedule
# on a different node than the openldap pod; the EKS node SG default ingress
# rules do not include TCP/636 between same-SG nodes. Source = same SG (self).
# Sibling reference: phase-a/03-ivia-deploy.sh:23-30. Pattern matches target's
# existing modules/rds/main.tf:54-72.
#-------------------------------------------------------------------------------

resource "aws_security_group_rule" "node_ldaps_self" {
  type                     = "ingress"
  from_port                = 636
  to_port                  = 636
  protocol                 = "tcp"
  security_group_id        = var.node_security_group_id
  source_security_group_id = var.node_security_group_id
  description              = "IVIA pdconfig: cross-node LDAPS from iviaruntime to openldap pod (sibling 03-ivia-deploy.sh:24-30)"
}

#-------------------------------------------------------------------------------
# RBAC for the autoconf Job. ibmvia_autoconf 0.3.34 requires:
#   - get/list secrets + configmaps   for !secret <ns>/<name>:<key> resolution
#   - get/list/patch deployments.apps for _restart_k8s_deployments
# (RESEARCH §8.3, evidenced by the RuntimeError trace at data_util.py:43 when
#  run outside a pod — see RESEARCH Pitfall 1.)
#-------------------------------------------------------------------------------

resource "kubernetes_service_account" "ivia_autoconf" {
  metadata {
    name      = "ivia-autoconf"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels    = local.common_labels
  }
  image_pull_secret {
    name = kubernetes_secret.dockerlogin.metadata[0].name
  }
}

resource "kubernetes_role" "ivia_autoconf" {
  metadata {
    name      = "ivia-autoconf"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels    = local.common_labels
  }
  rule {
    api_groups = [""]
    resources  = ["secrets", "configmaps"]
    verbs      = ["get", "list"]
  }
  rule {
    api_groups = ["apps"]
    resources  = ["deployments"]
    verbs      = ["get", "list", "patch"]
  }
}

resource "kubernetes_role_binding" "ivia_autoconf" {
  metadata {
    name      = "ivia-autoconf"
    namespace = kubernetes_namespace.verify_access.metadata[0].name
    labels    = local.common_labels
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.ivia_autoconf.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.ivia_autoconf.metadata[0].name
    namespace = kubernetes_namespace.verify_access.metadata[0].name
  }
}
