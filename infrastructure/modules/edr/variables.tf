################################################################################
# EDR Module Variables
################################################################################

variable "cluster_name" {
  description = "EKS cluster name (used as kubequery hostname for Uptycs enrollment)"
  type        = string
}

variable "k8sosquery_chart_version" {
  description = "Helm chart version for k8sosquery"
  type        = string
  default     = "1.3.7"
}

variable "kubequery_chart_version" {
  description = "Helm chart version for kubequery"
  type        = string
  default     = "1.3.3"
}

