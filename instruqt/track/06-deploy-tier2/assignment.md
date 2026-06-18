---
slug: deploy-tier2
id: wflxu3adr2ch
type: challenge
title: Deploy Tier 2 — Vault + IBM Verify Access
teaser: HashiCorp Vault HA cluster + the 7-pod IVIA stack. About 20-30 minutes.
tabs:
- id: xjc1kuaogq2l
  title: Terminal
  type: terminal
  hostname: cloud-client
difficulty: ""
enhanced_loading: null
---

Tier 2 deploys two stateful workloads on top of the tier-1 EKS cluster:

- **HashiCorp Vault** — 3-node Raft HA cluster auto-unsealed with AWS KMS
- **IBM Verify Access** — seven-pod stack (`iviaconfig`, `iviawrprp1`,
  `iviaruntime`, `iviaop`, `iviadsc`, `openldap`, `postgresql`) configured
  unattended by the autoconf Job

`deploy-workshop.sh --tier 2` runs steps 5-9 of the orchestrator:

5. `terraform apply` against `infrastructure/services/` (vault_server + ivia)
6. **Initialize Vault** (`vault-init.sh`) — writes `~/vault-init.json`
7. **Issue ACME cert**, sync to ACM, re-apply IVIA on the trusted `nip.io` host
8. **Configure Vault** (`vault-configure.sh`) — auth methods, policies, secrets engines
9. **Configure IVIA** (`ivia-configure.sh`) — verify OIDC discovery

## Run the deploy

```bash
cd /root/workshop
bash infrastructure/scripts/deploy-workshop.sh --tier 2
```

The preflight values you entered in tier 1 (LE email, ICR entitlement
key, IVIA MMFA push secret) are cached in `terraform.tfvars` and reused
silently — no re-prompt.

## Inspect what landed

After the deploy finishes, verify Vault is unsealed and serving:

```bash
kubectl get pods -n vault
export VAULT_ROOT_TOKEN=$(jq -r '.root_token' ~/vault-init.json)
kubectl exec -n vault vault-0 -- vault status
```

Expected: `Sealed: false`, `Initialized: true`, `Seal Type: awskms`.

```bash
kubectl exec -n vault vault-0 -- \
  sh -c "VAULT_TOKEN='${VAULT_ROOT_TOKEN}' vault operator raft list-peers"
```

Expected: three peers (`vault-0`, `vault-1`, `vault-2`), one leader.

Verify the IVIA seven-pod stack and the autoconf Job:

```bash
kubectl get pods -n verify-access
```

Expected: seven `Running` pods plus the `ivia-autoconf-<hash>` Job showing
`Completed`. If the autoconf Job is still running, give it 4-6 more minutes
and re-check.

> [!IMPORTANT]
> The `~/vault-init.json` file contains the **Vault root token** — keep it
> private. The `nip.io` trusted certificate is real Let's Encrypt and uses the
> email you supplied during the tier-1 preflight prompt.

When all checks pass, advance to tier 3.
