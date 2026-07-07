################################################################################
# Root Module — tier 3 (end-user workloads)
# Agentic Runtime Security Workshop
#
# Deploys the attendee-facing application workloads that sit ON TOP of the
# core infrastructure (tier 1) and the shared identity/secrets fabric (tier 2):
#   - Use Case 1 agent           — modules/uc1_agent
#   - Use Case 2 banking app      — modules/uc2_agent (ui + agent + mcp)
#   - Use Case 3 privileged agent — modules/uc3_agent
#   - iviaop-config deferred patch + rollout (issuer + redirect_uri injection)
#
# Provisioning ORDER is structural, not script-staged: this root reads tier-1
# state (local.infra.*) AND tier-2 state (local.services.*) via remote_state, so
# it cannot apply until both upstream roots have written their state. By then
# the ECR images exist (build-images.sh), Vault is initialized + configured
# (vault-config), and IVIA is up — so uc1/uc2/uc3 pods never ImagePullBackOff or
# Vault-403 CrashLoop. deploy-workshop.sh runs this apply last.
################################################################################

locals {
  # banking-ui nip.io FQDN propagation. The IVIA (WRP) nip.io host + issuer are
  # resolved ONCE in tier 2 (local.services.effective_ivia_host / ivia_issuer)
  # and consumed here verbatim — the single coherence point, so iviaop's iss
  # claim and Vault's bound_issuer can never drift. Only the BANKING host is a
  # tier-3 concern, because module.uc2_app produces the banking-ui ALB hostname.
  #
  # hashicorp/local's data.local_file fails hard on a missing file, so we use
  # the pure built-ins fileexists() + file() instead — no provider, no failure
  # on absent file. regex() captures NIP_FQDN_BANKING; try() unwraps with ""
  # when .acme-state is absent or pre-ACME (banking FQDN not yet written).
  _acme_state_exists  = fileexists(var.deploy_id_state_path)
  _acme_state_content = local._acme_state_exists ? file(var.deploy_id_state_path) : ""
  nip_io_banking_host = try(regex("NIP_FQDN_BANKING=([^\n]+)", local._acme_state_content)[0], "")

  # IVIA browser-facing host + issuer come straight from tier 2 — NO recompute.
  effective_ivia_host = local.services.effective_ivia_host
  ivia_public_issuer  = local.services.ivia_issuer

  # Banking host: prefer the LE-trusted nip.io FQDN once .acme-state is written;
  # raw ALB only as pre-ACME bootstrap fallback. coalesce() skips the empty nip
  # slot (Terraform treats "" as null).
  effective_banking_host = coalesce(local.nip_io_banking_host, module.uc2_app.banking_ui_alb_hostname)
  uc2_redirect_uri       = "https://${local.effective_banking_host}/callback"

  # ---------------------------------------------------------------------------
  # Image source toggle (D-13 / D-14 / D-15)
  #
  # GHCR URIs: derived from var.ghcr_registry_base so a fork repoints everything
  # with one setting. Var defaults can't interpolate other vars, so derivation
  # lives here. The five suffixes (D-03 flattened names) are the canonical GHCR
  # package names published by infrastructure/scripts/publish-images.sh. Each
  # image is versioned independently: only an image whose source actually
  # changed gets a new :tag (publish-images.sh --image <name> --version vN).
  # banking-ui is :v2 (real logout terminates the WebSEAL session); banking-agent
  # is :v2 (per-request agent + request-scoped JWT — fixes the cross-user data
  # leak from the shared singleton agent); the rest :v1.
  # ---------------------------------------------------------------------------
  ghcr_uc1_agent     = "${var.ghcr_registry_base}/workshop-uc1-agent:v1"
  ghcr_banking_ui    = "${var.ghcr_registry_base}/workshop-banking-app-ui:v2"
  ghcr_banking_agent = "${var.ghcr_registry_base}/workshop-banking-app-agent:v3"
  ghcr_banking_mcp   = "${var.ghcr_registry_base}/workshop-banking-app-mcp:v1"
  ghcr_uc3_agent     = "${var.ghcr_registry_base}/workshop-uc3-agent:v2"

  # Mode-driven imagePullPolicy (D-14):
  #   ghcr mode → IfNotPresent (pinned immutable :tags; per-node cache avoids redundant pulls)
  #   ecr mode  → Always       (mutable :latest; matches today's ECR opt-in behaviour)
  image_pull_policy = var.image_source == "ecr" ? "Always" : "IfNotPresent"

  iviaop_provider_yml_resolved = templatefile(
    "${path.module}/../modules/verify_access/iviaop-config/provider.yml.tftpl",
    {
      ivia_public_url    = "${local.ivia_public_issuer}/isvaop"
      ivia_public_issuer = local.ivia_public_issuer
    }
  )

  iviaop_clients_yml_resolved = templatefile(
    "${path.module}/../modules/verify_access/iviaop-config/clients.yml.tftpl",
    {
      ivia_client_secret = local.services.ivia_client_secret
      uc2_redirect_uri   = local.uc2_redirect_uri
    }
  )
}

#-------------------------------------------------------------------------------
# Use Case 1 — read-only RAG agent
#-------------------------------------------------------------------------------

module "uc1_agent" {
  source = "../modules/uc1_agent"

  vault_addr        = "http://vault.vault.svc.cluster.local:8200"
  vault_role        = "uc1"
  rds_address       = local.infra.rds_address
  rds_port          = local.infra.rds_port
  rds_db_name       = local.infra.rds_db_name
  knowledge_base_id = local.infra.kb_id
  region            = local.infra.region
  kb_region         = local.infra.kb_region
  agent_image       = var.image_source == "ecr" ? var.uc1_agent_image : local.ghcr_uc1_agent
  image_pull_policy = local.image_pull_policy
  bedrock_model_id  = var.bedrock_model_id
  tags              = local.infra.tags
}

#-------------------------------------------------------------------------------
# Use Case 2 — banking app (UI + agent + MCP) with OAuth/PKCE via IVIA
#-------------------------------------------------------------------------------

module "uc2_app" {
  source = "../modules/uc2_agent"

  vault_addr            = "http://vault.vault.svc.cluster.local:8200"
  vault_k8s_role        = "uc2-agent"
  vault_jwt_role        = "uc2-jwt"
  vault_db_role         = "uc2-personal-readonly"
  rds_address           = local.infra.rds_address
  rds_port              = local.infra.rds_port
  rds_db_name           = local.infra.rds_db_name
  rds_cidr              = local.infra.vpc_cidr
  knowledge_base_id     = local.infra.kb_id
  region                = local.infra.region
  kb_region             = local.infra.kb_region
  ui_image              = var.image_source == "ecr" ? var.banking_app_ui_image : local.ghcr_banking_ui
  agent_image           = var.image_source == "ecr" ? var.banking_app_agent_image : local.ghcr_banking_agent
  mcp_image             = var.image_source == "ecr" ? var.banking_app_mcp_image : local.ghcr_banking_mcp
  image_pull_policy     = local.image_pull_policy
  bedrock_model_id      = var.bedrock_model_id
  ivia_ingress_hostname = local.services.ivia_ingress_hostname
  ivia_service_endpoint = local.services.ivia_service_endpoint
  ivia_client_id        = "agent-uc2"
  ivia_client_secret    = local.services.ivia_client_secret
  tls_certificate_arn   = local.infra.tls_certificate_arn
  # CR-01 fix: use LE-trusted nip.io FQDN when available; raw ALB only as
  # pre-ACME bootstrap fallback. effective_ivia_host is resolved in tier 2.
  ivia_public_issuer = "https://${local.effective_ivia_host}"
  ivia_oidc_ca_pem   = local.services.ivia_oidc_ca_pem
  # Phase 07.8 D-02: pass the nip.io banking FQDN so banking-ui's REDIRECT_URI
  # + ORIGIN are LE-trusted instead of raw ALB. Empty string until
  # deploy-workshop.sh ACME step writes .acme-state (pre-bootstrap fallback).
  nip_io_banking_host = local.nip_io_banking_host
  tags                = local.infra.tags
}

#-------------------------------------------------------------------------------
# Use Case 3 — privileged-action agent (token exchange + CIBA + SCIM)
#-------------------------------------------------------------------------------

module "uc3_agent" {
  source = "../modules/uc3_agent"

  namespace              = "banking-app"
  vault_endpoint         = "http://vault.vault.svc.cluster.local:8200"
  ivia_base_url          = "https://${local.services.ivia_service_endpoint}:8436"
  ivia_client_id         = "agent-uc3"
  ivia_id_token_audience = "agent-uc2"
  ivia_client_secret     = local.services.ivia_client_secret
  # CR-01 fix: use LE-trusted nip.io FQDN when available; raw ALB only as
  # pre-ACME bootstrap fallback. effective_ivia_host is resolved in tier 2.
  ivia_external_url   = "https://${local.effective_ivia_host}"
  db_host             = local.infra.rds_address
  db_name             = "workshop"
  uc3_agent_image     = var.image_source == "ecr" ? var.uc3_agent_image : local.ghcr_uc3_agent
  image_pull_policy   = local.image_pull_policy
  bedrock_model_id    = var.bedrock_model_id
  region              = local.infra.region
  rds_cidr            = local.infra.vpc_cidr
  ivia_oidc_ca_pem    = local.services.ivia_oidc_ca_pem
  ivia_runtime_url    = "https://iviaruntime.${local.services.ivia_namespace}.svc.cluster.local:9443"
  ivia_scim_user      = local.services.ivia_runtime_user
  ivia_scim_password  = local.services.ivia_runtime_user_password
  ivia_runtime_ca_pem = local.services.ivia_runtime_ca_pem
  ivia_namespace      = local.services.ivia_namespace
  tags                = local.infra.tags

  depends_on = [module.uc2_app]
}

#-------------------------------------------------------------------------------
# iviaop-config issuer + redirect_uri injection — Path A (deferred patch)
#
# Two values in the iviaop-config ConfigMap can only be known after the ALBs
# exist, and both depend on hostnames the AWS Load Balancer Controller assigns
# post-apply:
#   - provider.yml  issuer/base_url      → the ivia-wrp (login) host (tier 2)
#   - clients.yml   agent-uc2 redirect_uri → the banking-ui ALB hostname (uc2)
#
# module.uc2_app already consumes tier-2 IVIA outputs, and inside module.ivia
# (tier 2) the iviaop-config ConfigMap is created before its own Ingress
# reconciles — so neither place can read the final banking-ui ALB hostname.
# Resolution: tier 2 ships provider.yml + clients.yml with placeholder hosts;
# after module.uc2_app completes here (ALB hostname known), this root-level
# patch overwrites just those two ConfigMap keys with the real hosts, then
# rolls the iviaop Deployment so it reloads them at startup. agent-uc1/agent-uc3
# entries are unaffected.
#-------------------------------------------------------------------------------

resource "kubernetes_config_map_v1_data" "iviaop_clients_patch" {
  metadata {
    name      = "iviaop-config"
    namespace = "verify-access"
  }

  data = {
    "provider.yml" = local.iviaop_provider_yml_resolved
    "clients.yml"  = local.iviaop_clients_yml_resolved
  }

  field_manager = "root-tf-clients-patch"
  force         = true

  depends_on = [module.uc2_app]
}

# Roll the iviaop Deployment whenever the resolved provider.yml or clients.yml
# changes. The iviaop pod loads both files only at startup; without a restart
# the patched ConfigMap would sit on disk unread.
resource "null_resource" "iviaop_rollout_restart" {
  triggers = {
    iviaop_config_sha256 = sha256("${local.iviaop_provider_yml_resolved}${local.iviaop_clients_yml_resolved}")
  }

  # Point kubectl at this cluster first — during `terraform apply` the attendee's
  # kubeconfig may not be configured yet, so a bare `kubectl` cannot resolve the
  # API endpoint. update-kubeconfig is idempotent and derives cluster name/region
  # from tier-1 remote_state (no literals).
  provisioner "local-exec" {
    command = "aws eks update-kubeconfig --region ${local.infra.region} --name ${local.infra.cluster_name} && kubectl rollout restart deploy/iviaop -n verify-access && kubectl rollout status deploy/iviaop -n verify-access --timeout=180s"
  }

  depends_on = [kubernetes_config_map_v1_data.iviaop_clients_patch]
}
