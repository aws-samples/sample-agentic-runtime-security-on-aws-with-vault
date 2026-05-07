################################################################################
# bedrock_kb_aoss Module — Outputs
#
# Consumed by:
#   - infrastructure/providers.tfcomponent.hcl: opensearch provider URL =
#     component.bedrock_kb_aoss.aoss_collection_endpoint
#   - component "bedrock_kb_index": all of these outputs flow as inputs.
################################################################################

output "aoss_collection_endpoint" {
  description = "OpenSearch Serverless collection endpoint URL. Wired into the Stack-level opensearch provider config so bedrock_kb_index can create the vector index."
  value       = aws_opensearchserverless_collection.kb.collection_endpoint
}

output "aoss_collection_arn" {
  description = "OpenSearch Serverless collection ARN. Consumed by bedrock_kb_index for the KB storage_configuration block."
  value       = aws_opensearchserverless_collection.kb.arn
}

output "aoss_collection_name" {
  description = "OpenSearch Serverless collection name. Used by bedrock_kb_index for any policy/index naming continuity."
  value       = aws_opensearchserverless_collection.kb.name
}

output "kb_role_arn" {
  description = "ARN of the IAM service role assumed by bedrock.amazonaws.com to read the corpus bucket and invoke the embedding model."
  value       = aws_iam_role.bedrock_kb.arn
}

output "kb_corpus_bucket_arn" {
  description = "ARN of the S3 corpus bucket. Consumed by bedrock_kb_index for the data_source bucket_arn fields."
  value       = aws_s3_bucket.kb_corpus.arn
}

output "kb_corpus_bucket_id" {
  description = "Name of the S3 corpus bucket. Used for ad-hoc inspection (aws s3 ls) during the workshop."
  value       = aws_s3_bucket.kb_corpus.id
}

output "embedding_model_arn" {
  description = "ARN of the Titan Text Embeddings v2 foundation model. Consumed by bedrock_kb_index for the KB vector_knowledge_base_configuration."
  value       = data.aws_bedrock_foundation_model.embedding.model_arn
}

output "iam_propagate_id" {
  description = "Time-sleep resource ID used as a propagation barrier — bedrock_kb_index waits for the entire bedrock_kb_aoss component to complete (which includes this sleep) before creating the KB."
  value       = time_sleep.kb_iam_propagate.id
}
