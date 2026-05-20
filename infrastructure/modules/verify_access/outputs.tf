# Outputs are added in Plan 07-08 (NLB hostname + WRP ALB hostname + admin
# password reference for isva_config wiring). This stub keeps the module
# valid through plans 02-07.

output "namespace" {
  description = "Kubernetes namespace where all IVIA resources live."
  value       = kubernetes_namespace.verify_access.metadata[0].name
}
