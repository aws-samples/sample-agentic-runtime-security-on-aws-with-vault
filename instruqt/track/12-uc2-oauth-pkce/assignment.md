---
slug: uc2-oauth-pkce
type: challenge
title: Use Case 2 — OAuth + PKCE Login
teaser: Sign in to the banking UI; observe the JWT IVIA issued.
tabs:
  - title: Terminal
    type: terminal
    hostname: cloud-client
---

Use Case 2 adds **user identity** to the credential flow. The banking UI
authenticates you through IBM Verify Access (IVIA) using the OAuth
Authorization Code + PKCE flow, and that user identity propagates all the way
to the database through short-lived, per-user-scoped Vault credentials.

This use case adds **Objective 3 — actions tied to user intent** on top of the
workload identity and JIT credential foundations from Use Case 1.

## Find the banking UI URL

The deploy emitted a CNAME-friendly `nip.io` hostname for the banking UI ALB.
Resolve it from the tier-3 Terraform output (the value resolves to the
LE-trusted nip.io FQDN once `.acme-state` is written, else the raw ALB
hostname):

```bash
cd /root/workshop
echo "https://$(terraform -chdir=infrastructure/workloads output -raw effective_banking_host)"
```

Open the URL in your own browser (copy from the terminal output).

## Sign in as Jaime

Click **Sign in**. You will be redirected to the IVIA login page (note the
trusted Let's Encrypt cert on a `nip.io` host, registered with the `LE_EMAIL`
you supplied at track start). Authenticate as:

- Username: `jaime`
- Password: see the LDAP seed file at `infrastructure/modules/verify_access/openldap/users.ldif`

After login, IVIA redirects back to the banking UI with the OAuth
authorization code, the SvelteKit server exchanges it for a JWT at the IVIA
token endpoint, and the dashboard renders Jaime's accounts.

## Inspect the JWT IVIA issued

The MCP Server logs every JWT it receives. Tail its logs:

```bash
kubectl --context "$(kubectl config current-context)" -n banking-app logs deploy/banking-mcp-server --tail=20 \
  | grep -E '"sub":' | head -5
```

You should see a recent entry with `"sub":"jaime"`, plus `"aud":"agent-uc2"`
and `"azp":"agent-uc2"`. Vault's `jwt` auth method validates those three
claims against `auth/jwt/role/uc2-jwt` and binds the resulting token to the
`uc2-personal` policy.

When the banking UI dashboard renders with Jaime's accounts, advance to the
next challenge.
