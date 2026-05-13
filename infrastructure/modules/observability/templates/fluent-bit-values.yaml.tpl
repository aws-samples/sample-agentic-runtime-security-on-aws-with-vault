# fluent-bit Helm values — aws-for-fluent-bit chart
# Routes pod logs from vault, ivia, and uc3-agent pods to the pre-created
# /workshop/* CloudWatch log groups. auto_create_group = false because the
# audit module owns those log group lifecycle resources.
#
# NOTE: This template is rendered by templatefile() in main.tf.
# Variable: ${region}

serviceAccount:
  create: true
  name: fluent-bit

firehose:
  enabled: false

kinesis:
  enabled: false

elasticsearch:
  enabled: false

cloudWatch:
  enabled: false

# Raw Fluent Bit configuration via the 'config' block
config:
  service: |
    [SERVICE]
        Flush         5
        Daemon        Off
        Log_Level     info
        Parsers_File  parsers.conf

  inputs: |
    [INPUT]
        Name              tail
        Tag               kube.*
        Path              /var/log/containers/*.log
        Parser            cri
        DB                /var/log/flb_kube.db
        Mem_Buf_Limit     50MB
        Skip_Long_Lines   On
        Refresh_Interval  10

  filters: |
    [FILTER]
        Name                kubernetes
        Match               kube.*
        Kube_URL            https://kubernetes.default.svc:443
        Kube_CA_File        /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
        Kube_Token_File     /var/run/secrets/kubernetes.io/serviceaccount/token
        Merge_Log           On
        Keep_Log            Off
        K8S-Logging.Parser  On
        K8S-Logging.Exclude Off

  outputs: |
    [OUTPUT]
        Name                cloudwatch_logs
        Match               kube.var.log.containers.vault-*
        region              ${region}
        log_group_name      /workshop/vault-audit
        log_stream_prefix   vault-
        auto_create_group   false
        retry_limit         2

    [OUTPUT]
        Name                cloudwatch_logs
        Match               kube.var.log.containers.isvaop-*
        region              ${region}
        log_group_name      /workshop/ivia-decision
        log_stream_prefix   ivia-
        auto_create_group   false
        retry_limit         2

    [OUTPUT]
        Name                cloudwatch_logs
        Match               kube.var.log.containers.uc3-agent-*
        region              ${region}
        log_group_name      /workshop/agent-trace
        log_stream_prefix   agent-
        auto_create_group   false
        retry_limit         2
