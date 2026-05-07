################################################################################
# bedrock_kb_aoss Module — IAM-propagation bridge (Pitfall B1).
#
# After the 4 inline role policies are attached, AWS IAM needs ~10-20s for the
# permission grants to propagate before bedrock.amazonaws.com can assume the
# role and exercise them. The KB resource (in bedrock_kb_index) waits for
# component.bedrock_kb_aoss to fully complete — which means time_sleep here
# acts as the propagation barrier between the two components.
################################################################################

resource "time_sleep" "kb_iam_propagate" {
  create_duration = "20s"

  depends_on = [
    aws_iam_role_policy.kb_aoss,
    aws_iam_role_policy.kb_s3,
    aws_iam_role_policy.kb_bedrock,
    aws_iam_role_policy.kb_kms,
  ]
}
