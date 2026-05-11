################################################################################
# isva_config Module — Main
#
# Provisions all IVIA configuration required by the three workshop use cases:
#   - OAuth clients (CONF-05): agent-uc1 (client_credentials), agent-uc2
#     (authorization_code + PKCE), agent-uc3 (CIBA grant)
#   - CIBA policy: poll mode, 5s interval, 300s expiry, browser consent
#   - RAR types: refund_approval type definition
#   - JWT signing key: RS256 signing algorithm
#
# All resources are managed via the Mastercard/restapi provider against the
# IVIA Config Service REST API.
#
# Pitfall 5: insecure=true is required for the self-signed TLS certificate
# served by the IVIA Config Service in workshop environments. NOT for production.
################################################################################

terraform {
  required_providers {
    restapi = {
      source  = "Mastercard/restapi"
      version = "~> 1.19"
    }
  }
}

locals {
  enabled_instances = var.enabled ? { main = true } : {}
}

################################################################################
# OAuth Clients — CONF-05
# Three clients matching the three use-case agent identities.
# The restapi provider POSTs to /mga/sps/oauth/oauth20/clients and manages
# the JSON object keyed by client_id.
################################################################################

# UC1: client_credentials grant — background agent with no user context
resource "restapi_object" "uc1_client" {
  for_each = local.enabled_instances

  path         = "/mga/sps/oauth/oauth20/clients"
  id_attribute = "client_id"

  data = jsonencode({
    client_id                  = "agent-uc1"
    client_name                = "Agentic Runtime UC1 — Read-Only"
    grant_types                = ["client_credentials"]
    response_types             = ["token"]
    scope                      = "database:read"
    token_endpoint_auth_method = "client_secret_basic"
  })
}

# UC2: authorization_code + PKCE — user-delegated personal data agent
resource "restapi_object" "uc2_client" {
  for_each = local.enabled_instances

  path         = "/mga/sps/oauth/oauth20/clients"
  id_attribute = "client_id"

  data = jsonencode({
    client_id                  = "agent-uc2"
    client_name                = "Agentic Runtime UC2 — Personal Data"
    grant_types                = ["authorization_code"]
    response_types             = ["code"]
    scope                      = "openid profile database:read bedrock:invoke"
    token_endpoint_auth_method = "none"
    pkce_required              = true
    redirect_uris              = ["https://localhost/callback"]
  })
}

# UC3: CIBA grant — asynchronous user consent for financial operation
resource "restapi_object" "uc3_client" {
  for_each = local.enabled_instances

  path         = "/mga/sps/oauth/oauth20/clients"
  id_attribute = "client_id"

  data = jsonencode({
    client_id                       = "agent-uc3"
    client_name                     = "Agentic Runtime UC3 — CIBA Refund"
    grant_types                     = ["urn:openid:params:grant-type:ciba"]
    response_types                  = ["token"]
    scope                           = "openid profile database:write bedrock:invoke"
    token_endpoint_auth_method      = "client_secret_basic"
    backchannel_token_delivery_mode = "poll"
  })
}

################################################################################
# CIBA Policy
# poll mode, 5-second interval, 300-second (5-minute) expiry, browser consent.
# Attendees observe the polling loop in the UC3 agent logs — this is the
# pedagogical money shot for OBJ-3 (user-consent-gated action).
################################################################################

resource "restapi_object" "ciba_policy" {
  for_each = local.enabled_instances

  path         = "/mga/sps/authservice/authentication/mechanisms/ciba"
  id_attribute = "id"

  data = jsonencode({
    name             = "workshop-ciba-policy"
    delivery_mode    = "poll"
    polling_interval = 5
    expires_in       = 300
    consent_method   = "browser"
    binding_message  = "Confirm refund authorisation in your browser"
  })
}

################################################################################
# RAR (Rich Authorization Requests) Types — CONF-05
# refund_approval type defines the structured authorization data schema
# that UC3 agent passes in the CIBA authorization_details claim.
################################################################################

resource "restapi_object" "rar_types" {
  for_each = local.enabled_instances

  path         = "/mga/sps/oauth/oauth20/rar-types"
  id_attribute = "type"

  data = jsonencode({
    type        = "refund_approval"
    description = "Structured authorisation details for refund operations (RFC 9396 RAR type)"
    schema = jsonencode({
      type = "object"
      properties = {
        refund_id  = { type = "string" }
        amount     = { type = "number" }
        currency   = { type = "string" }
        account_id = { type = "string" }
      }
      required = ["refund_id", "amount", "currency", "account_id"]
    })
  })
}

################################################################################
# JWT Signing Key
# RS256 algorithm — IVIA signs OIDC tokens with this key.
# Vault jwt auth backend uses IVIA's OIDC discovery URL to fetch JWKS
# and validates tokens signed by this key.
################################################################################

resource "restapi_object" "jwt_signing" {
  for_each = local.enabled_instances

  path         = "/mga/sps/oauth/oauth20/jwt-signing"
  id_attribute = "algorithm"

  data = jsonencode({
    algorithm = "RS256"
    key_size  = 2048
    key_store = "runtime"
  })
}
