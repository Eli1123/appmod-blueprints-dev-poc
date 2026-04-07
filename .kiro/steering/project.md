# Platform Engineering on EKS — appmod-blueprints

## Project Identity

Platform implementation repo for the Platform Engineering on EKS workshop. Provides GitOps configurations, Terraform infrastructure, Backstage templates, and sample applications for a multi-cluster EKS platform.

Companion repo: [platform-engineering-on-eks](../platform-engineering-on-eks/) handles CDK bootstrap and workshop content.

## Repository Layout

| Path | Purpose |
|------|---------|
| `platform/infra/terraform/cluster/` | Terraform — EKS clusters (hub, spoke-dev, spoke-prod) |
| `platform/infra/terraform/common/` | Terraform — platform addons (ArgoCD, secrets, pod identity, observability) |
| `platform/infra/terraform/identity-center/` | Terraform — IDC/SCIM integration |
| `platform/infra/terraform/scripts/` | Init scripts (`0-init.sh`, `argocd-utils.sh`, IDC config) |
| `platform/infra/terraform/hub-config.yaml` | Single source of truth for cluster addon enablement |
| `gitops/addons/` | ArgoCD addon definitions, charts, environments, tenants |
| `gitops/apps/` | Application deployment manifests (backend, frontend, rollouts) |
| `gitops/fleet/` | Fleet management (Kro values, bootstrap, members) |
| `gitops/platform/` | Platform bootstrap, charts, team configs |
| `gitops/workloads/` | Workload definitions (Ray, etc.) |
| `applications/` | Sample apps (Rust, Java, Go, .NET, Next.js) |
| `backstage/` | Backstage IDP (Dockerfile, config, plugins) |
| `platform/backstage/templates/` | Backstage software templates |
| `platform/validation/` | Cluster and Kro validation scripts |
| `hack/` | IDE environment config (.kiro, .zshrc, .bashrc.d, k9s) |
| `docs/` | Architecture docs, troubleshooting, feature guides |
| `scripts/` | Utility scripts (validation, keycloak) |

## Tech Stack

- **IaC:** Terraform (cluster, common, identity-center modules)
- **GitOps:** ArgoCD ApplicationSets with sync waves (-5 to 6)
- **Kubernetes:** EKS Auto Mode + EKS Capabilities (ArgoCD, Kro, ACK)
- **IDP:** Backstage with Keycloak SSO
- **Progressive delivery:** Argo Rollouts, Kargo
- **Observability:** CloudWatch, Grafana, DevLake (DORA metrics)
- **Task runner:** Taskfile (`Taskfile.yml`)
- **CI:** GitHub Actions (`.github/workflows/`)

## Key Conventions

- Resource prefix: `peeks` (flows from env var through Terraform to cluster secrets)
- Cluster names: `peeks-hub`, `peeks-spoke-dev`, `peeks-spoke-prod`
- Deployment scripts: always use `deploy.sh` / `destroy.sh`, never raw `terraform apply/destroy`
- Addon enablement: `hub-config.yaml` → Terraform → cluster secret labels → ArgoCD ApplicationSets
- Dynamic values (resource_prefix, domain, region) live in `addons.yaml` valuesObject only, never in `values.yaml`

## Two Usage Contexts

This repo is used in two ways:

1. **Local development** (you, on macOS) — edit Terraform, GitOps configs, scripts, then push to GitHub
2. **Workshop IDE** (ec2-user, on the Code Editor instance) — workshop participants interact with the deployed platform. The `hack/` directory configures this environment, including `hack/.kiro/` for the IDE's Kiro agent.

The root `.kiro/` is for local dev. `hack/.kiro/` is for the workshop IDE — they serve different audiences.

## Codebase Review Procedure

When starting a new session or after a context refresh, perform this full codebase review before doing any work. This ensures you understand how all the pieces connect.

### Step 1: Steering & Documentation

Read all steering docs and project documentation first:

```
.kiro/steering/project.md              — this file
.kiro/steering/deployment-refinement.md — deployment refinement work context
.kiro/agents/appmod-blueprints.json    — custom agent config
docs/deployment-refinement/*.md         — all 6 deployment refinement docs
docs/platform/README.md                — platform installation overview
docs/platform/gitops-bridge-architecture.md — GitOps Bridge pattern deep dive
docs/design.md                         — original workshop design
platform/infra/terraform/README.md     — Terraform deployment guide
README.md                              — repo top-level README
```

### Step 2: Terraform — Cluster Stack

Understand how EKS clusters, capabilities, and VPCs are created:

```
platform/infra/terraform/hub-config.yaml  — single source of truth for cluster + addon config
platform/infra/terraform/cluster/main.tf  — EKS module, capabilities (ArgoCD/ACK/Kro), VPCs
platform/infra/terraform/cluster/locals.tf
platform/infra/terraform/cluster/variables.tf
platform/infra/terraform/cluster/data.tf
platform/infra/terraform/cluster/versions.tf
platform/infra/terraform/cluster/deploy.sh (list directory to confirm exists)
```

### Step 3: Terraform — Common Stack

Understand the platform services layer — this is the most complex stack:

```
platform/infra/terraform/common/argocd.tf     — gitops_bridge_bootstrap module, git secrets
platform/infra/terraform/common/secrets.tf     — Secrets Manager cluster configs + platform secrets
platform/infra/terraform/common/locals.tf      — repo URLs, addons metadata, service configs
platform/infra/terraform/common/gitlab.tf      — GitLab PAT, user data source (hard dependency)
platform/infra/terraform/common/variables.tf   — all input variables
platform/infra/terraform/common/data.tf        — EKS cluster data sources, VPC, subnets
platform/infra/terraform/common/providers.tf   — Helm/K8s/GitLab providers, spoke aliases
platform/infra/terraform/common/versions.tf    — required providers (note: gitlab is required)
platform/infra/terraform/common/main.tf        — usage telemetry
platform/infra/terraform/common/iam.tf         — ArgoCD hub/spoke IAM roles, team roles
platform/infra/terraform/common/ingress-nginx.tf — ingress controller + security groups
platform/infra/terraform/common/cloudfront.tf  — CloudFront distribution for ingress NLB
platform/infra/terraform/common/pod-identity.tf — pod identity for ~15 services across clusters
platform/infra/terraform/common/deploy.sh      — deployment script with gitlab_infra sub-stack
platform/infra/terraform/common/observability.tf — AMP, Grafana workspace
```

Also check the gitlab_infra sub-stack structure:
```
platform/infra/terraform/common/gitlab_infra/  — list directory
```

### Step 4: Deploy Scripts & Utilities

Understand the deployment flow and shared utilities:

```
platform/infra/terraform/scripts/utils.sh       — shared utilities (kubectl config, GitLab setup, backstage updates)
platform/infra/terraform/scripts/argocd-utils.sh — ArgoCD sync, health checks, dependency-aware sync
platform/infra/terraform/scripts/0-init.sh       — post-Terraform initialization (ArgoCD sync, IDC, GitLab)
platform/infra/terraform/scripts/1-tools-urls.sh — display platform URLs and credentials
platform/infra/terraform/common.sh               — shared shell functions (VPC cleanup, EKS access)
Taskfile.yml                                     — task runner configuration
```

### Step 5: GitOps Layer

Understand the three-tier addon system and fleet management:

```
gitops/addons/bootstrap/default/addons.yaml           — central addon registry (~40 addons, sync waves, selectors)
gitops/addons/environments/control-plane/addons.yaml   — environment-level addon enablement
gitops/addons/charts/application-sets/templates/application-set.yaml — ApplicationSet generator template
gitops/addons/charts/application-sets/templates/_helpers.tpl
gitops/addons/default/addons/                          — list directory (per-addon default values)

gitops/fleet/bootstrap/addons.yaml        — cluster-addons ApplicationSet (top-level)
gitops/fleet/bootstrap/clusters.yaml      — clusters ApplicationSet (Kro)
gitops/fleet/bootstrap/fleet-secrets.yaml — fleet-secrets ApplicationSet (ExternalSecrets for spokes)
gitops/fleet/charts/fleet-secret/templates/external-secret.yaml — ExternalSecret template
gitops/fleet/members/fleet-peeks-spoke-dev/values.yaml  — spoke member config
gitops/fleet/members/fleet-peeks-spoke-prod/values.yaml

platform/infra/terraform/common/manifests/applicationsets.yaml — bootstrap ApplicationSet
```

### Step 6: Backstage & Applications

Quick scan of the IDP templates and sample apps:

```
platform/backstage/templates/  — list directory (catalog-info.yaml, template directories)
applications/                  — list directory (java, golang, dotnet, etc.)
```

### What to Look For

When reviewing, pay attention to:

1. **Data flow**: hub-config.yaml → Terraform variables → cluster secrets (labels + annotations) → ArgoCD ApplicationSets → addon deployments
2. **Provider constraints**: GitLab provider is required in versions.tf; spoke providers are hardcoded aliases (spoke1/spoke2)
3. **ArgoCD mode**: `install = true/false` in gitops_bridge_bootstrap controls Helm vs EKS Capability; `server` field must match (ARN for capability, endpoint for Helm)
4. **Secret flow**: Terraform → Secrets Manager → ExternalSecrets → K8s secrets (60s reconciliation, no manual patches survive)
5. **Sync waves**: -5 (multi-acct) through 7 (devlake) — ordering matters for dependencies
6. **Conditional logic**: IDC guards on ArgoCD capability, SKIP_GITLAB in deploy.sh, node pool selection
