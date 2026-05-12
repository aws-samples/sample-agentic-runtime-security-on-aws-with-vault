# isva_config Module

Provisions all IVIA (IBM Verify Identity Access) OAuth/CIBA/RAR configuration required by the three workshop use cases. All resources are managed via the [Mastercard/restapi](https://registry.terraform.io/providers/Mastercard/restapi/latest) provider against the IVIA Config Service REST API.

## Purpose

The `isva_config` module bridges the IVIA deployment (Phase 3, Plan 02) to the three agent use cases (Phases 4-6). It registers OAuth clients, configures the CIBA policy for user-consent gating, defines Rich Authorization Request (RAR) types for structured authorization data, and provisions the JWT signing key used by IVIA's OIDC token endpoint.

## Resources Created

| Resource | Type | Description |
|---|---|---|
| `restapi_object.uc1_client` | OAuth client | `agent-uc1` — `client_credentials` grant, `database:read` scope |
| `restapi_object.uc2_client` | OAuth client | `agent-uc2` — `authorization_code` + PKCE, user-delegated personal data |
| `restapi_object.uc3_client` | OAuth client | `agent-uc3` — CIBA grant (`urn:openid:params:grant-type:ciba`) |
| `restapi_object.ciba_policy` | CIBA policy | `workshop-ciba-policy`: poll mode, 5s interval, 300s expiry, browser consent |
| `restapi_object.rar_types` | RAR type | `refund_approval` — RFC 9396 structured authorization data schema |
| `restapi_object.jwt_signing` | JWT signing key | RS256, 2048-bit, runtime key store |

## API Endpoint Paths

The restapi provider uses these IVIA Config Service REST API paths:

| Resource | HTTP Method | Path |
|---|---|---|
| OAuth clients | POST/GET/PUT/DELETE | `/mga/sps/oauth/oauth20/clients` |
| CIBA policy | POST/GET/PUT/DELETE | `/mga/sps/authservice/authentication/mechanisms/ciba` |
| RAR types | POST/GET/PUT/DELETE | `/mga/sps/oauth/oauth20/rar-types` |
| JWT signing | POST/GET/PUT/DELETE | `/mga/sps/oauth/oauth20/jwt-signing` |

## Pitfalls

### Pitfall 5: `insecure=true` for self-signed certificate (workshop only)

The IVIA Config Service serves a self-signed TLS certificate in the workshop environment. The `restapi` provider must be configured with `insecure = true` to skip TLS verification. This is declared in the root module's `providers.tf`:

```hcl
provider "restapi" {
  uri      = "https://${var.ivia_service_endpoint}"
  insecure = true
  # ... basic auth headers
}
```

**Do not use `insecure = true` in production.** Production IVIA deployments use a certificate from a trusted CA.

### Pitfall 6: restapi provider `id_attribute` must match the API response key

The `id_attribute` in each `restapi_object` block must match the field name in the IVIA Config Service API response that uniquely identifies the resource. The provider uses this attribute to detect drift (GET by ID) and to construct DELETE requests. Wrong `id_attribute` causes the provider to create duplicate resources on every apply.

### Pitfall 7: `api_response` attribute is a JSON string

`restapi_object.*.api_response` is the raw JSON response from the IVIA API, stored as a string. Use `jsondecode()` to extract nested values in outputs:

```hcl
output "uc1_client_id" {
  value = jsondecode(restapi_object.uc1_client.api_response).client_id
}
```

## Inputs

| Name | Type | Description |
|---|---|---|
| `ivia_service_endpoint` | `string` | IVIA ClusterIP DNS (host only, no scheme). restapi provider constructs URI as `https://<endpoint>`. |
| `ivia_admin_username` | `string` | IVIA admin username (default: `admin`). |
| `ivia_admin_password` | `string` (sensitive) | IVIA admin password. |
| `vault_config_jwt_auth_path` | `string` | JWT auth path from `module.vault_config` (default: `jwt`). Cross-reference for documentation. |

## Outputs

| Name | Description |
|---|---|
| `uc1_client_id` | OAuth client ID for UC1 agent (`agent-uc1`). |
| `uc2_client_id` | OAuth client ID for UC2 agent (`agent-uc2`). |
| `uc3_client_id` | OAuth client ID for UC3 agent (`agent-uc3`). |
| `ciba_policy_name` | CIBA policy name (`workshop-ciba-policy`). |

## Root module wiring

```hcl
# In infrastructure/main.tf
module "isva_config" {
  source = "./modules/isva_config"

  ivia_service_endpoint      = module.ivia.ivia_service_endpoint
  vault_config_jwt_auth_path = module.vault_config.jwt_auth_path
  ivia_admin_username        = var.ivia_admin_username
  ivia_admin_password        = var.ivia_admin_password

  depends_on = [module.vault_config]
}
```

## Design Decisions

- **PKCE required on UC2**: `pkce_required = true` ensures the authorization code grant cannot be exchanged without the PKCE verifier — prevents interception attacks in the agent callback flow.
- **CIBA poll mode**: The workshop uses `poll` delivery mode (not `push` or `ping`) so attendees can observe the polling loop directly in UC3 agent logs. The `delivery_mode = "poll"` on the UC3 client must match the CIBA policy configuration.
- **RAR type schema stored as `jsonencode`**: The IVIA API expects the schema as a JSON string within the RAR type document. The double-encode pattern (`jsonencode` inside `jsonencode`) is intentional.
- **RS256 JWT signing**: Vault's jwt auth backend requires RS256 (or RS384/RS512) for the JWKS verification. IVIA's default is HS256 (symmetric) — the explicit RS256 signing key registration overrides this.

## References

- IVIA Config Service REST API reference: https://www.ibm.com/docs/en/svaa/9.0.x?topic=configuration-oauth-20-client
- RFC 9396 — Rich Authorization Requests: https://datatracker.ietf.org/doc/rfc9396/
- OpenID Connect CIBA Core specification: https://openid.net/specs/openid-client-initiated-backchannel-authentication-core-1_0.html
- Mastercard/restapi Terraform provider: https://registry.terraform.io/providers/Mastercard/restapi/latest/docs
