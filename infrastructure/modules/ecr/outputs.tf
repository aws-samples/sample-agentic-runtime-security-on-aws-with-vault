output "repository_urls" {
  value       = { for name, repo in aws_ecr_repository.workshop : name => repo.repository_url }
  description = "Map of repository name to ECR URI (account.dkr.ecr.region.amazonaws.com/name)."
}
