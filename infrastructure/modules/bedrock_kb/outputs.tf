################################################################################
# bedrock_kb Module — Outputs
#
# Consumed by:
#   - root component for cross-component wiring (KB id → agents in Phase 4-6)
#   - workshop content modules that show validation commands (start-ingestion-job)
#   - any future plan that needs to issue queries against the corpus bucket
################################################################################

output "knowledge_base_id" {
  description = "Bedrock Knowledge Base ID. Phase 4-6 agents reference this when retrieving from the KB via the bedrock-agent-runtime API."
  value       = aws_bedrockagent_knowledge_base.kb.id
}

output "knowledge_base_arn" {
  description = "Bedrock Knowledge Base ARN. IAM policies on agent roles scope bedrock:Retrieve / bedrock:RetrieveAndGenerate to this ARN."
  value       = aws_bedrockagent_knowledge_base.kb.arn
}

output "kb_role_arn" {
  description = "ARN of the IAM service role assumed by bedrock.amazonaws.com to read the corpus bucket and invoke the embedding model."
  value       = aws_iam_role.bedrock_kb.arn
}

output "kb_corpus_bucket" {
  description = "Name of the S3 bucket holding the synthetic workshop corpus. Used for ad-hoc inspection (aws s3 ls) during the workshop."
  value       = aws_s3_bucket.kb_corpus.id
}

output "data_source_ids" {
  description = "Map of domain name → Bedrock data source ID. Keys: hr-handbook, customers, finance. Used by workshop content for `aws bedrock-agent start-ingestion-job` invocations."
  value       = { for k, ds in aws_bedrockagent_data_source.domain : k => ds.data_source_id }
}

output "aoss_collection_endpoint" {
  description = "OpenSearch Serverless collection endpoint URL. Useful for dashboard access via aws opensearchserverless dashboards."
  value       = aws_opensearchserverless_collection.kb.collection_endpoint
}

output "aoss_collection_arn" {
  description = "OpenSearch Serverless collection ARN. Reference for any future per-attendee data access policy expansions."
  value       = aws_opensearchserverless_collection.kb.arn
}
