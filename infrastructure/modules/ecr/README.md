# ECR Module

Pre-creates ECR repositories for workshop container images so build scripts
only need to `docker push` — no ad-hoc `aws ecr create-repository`.

## Repositories

| Name | Built By | Images |
|------|----------|--------|
| `workshop/uc1-agent` | `scripts/build-uc1-agent.sh` | `:latest` |
| `workshop/uc3-agent` | `scripts/build-uc3-agent.sh` | `:latest` |
| `workshop-banking-app` | `scripts/build-banking-app.sh` | `:ui`, `:agent`, `:mcp` |

## Teardown

`force_delete = true` on all repos — `terraform destroy` removes them even
with images present. The teardown script also includes a `sweep_ecr_repos()`
fallback for orphan cleanup.
