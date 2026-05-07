################################################################################
# bedrock_kb_index Module — Outputs
#
# Consumed by:
#   - infrastructure/outputs.tfcomponent.hcl: knowledge_base_id surfaced as a Stack output.
#   - workshop content (test scripts, modules) that reference the KB id for
#     start-ingestion-job and bedrock-agent-runtime retrieve calls.
################################################################################

output "knowledge_base_id" {
  description = "Bedrock Knowledge Base ID. Phase 4-6 agents reference this when retrieving from the KB via the bedrock-agent-runtime API."
  value       = aws_bedrockagent_knowledge_base.kb.id
}

output "knowledge_base_arn" {
  description = "Bedrock Knowledge Base ARN. IAM policies on agent roles scope bedrock:Retrieve / bedrock:RetrieveAndGenerate to this ARN."
  value       = aws_bedrockagent_knowledge_base.kb.arn
}

output "data_source_ids" {
  description = "Map of domain name → Bedrock data source ID. Keys: hr-handbook, customers, finance. Used by workshop content for `aws bedrock-agent start-ingestion-job` invocations."
  value       = { for k, ds in aws_bedrockagent_data_source.domain : k => ds.data_source_id }
}
