---
inclusion: manual
---

# Deployment Refinement — Work Session Context

## Background

We made the `appmod-blueprints` repo deployable via a direct Terraform path from a bare AWS account, without GitLab, Identity Center, or the CDK/CloudFormation wrapper. We then extended it with GitHub as the git provider and Okta as the identity provider, proving the platform can be componentized.

## Current State — POC Complete

### What's Deployed (Account 934822760716)

| Component | Status | Details |
|-----------|--------|---------|
| EKS Clusters | ✅ 3 clusters (hub, spoke-dev, spoke-prod) | All ACTIVE, Auto Mode, system + general-purpose node pools |
| ArgoCD | ✅ 58+ apps healthy | Helm-installed, Okta SSO, probes removed (Dex issue) |
| Backstage | ✅ Working | Custom ECR image, Okta SSO, config-driven auth, GitHub templates |
| Argo Workflows | ✅ Working | Okta SSO configured |
| Kargo | ⚠️ Partial | Admin login works, OIDC RBAC blocked by Okta free plan |
| Scaffolding | ✅ Working | Backstage → GitHub repo → ArgoCD app (tested end-to-end) |
| Ingress | ✅ CloudFront + NLB | `d181j7b7fhjtqq.cloudfront.net` |

### Fork
- Repo: `https://github.com/Eli1123/appmod-blueprints-dev-poc`
- All changes pushed, ArgoCD reads from this fork

### Okta
- Org: `https://integrator-8021951.okta.com` (Integrator Free Plan)
- Apps: ArgoCD, Backstage, Argo Workflows, Kargo (SPA/PKCE)
- Groups claim configured on default authorization server
- API token created for programmatic access
- Limitation: Free plan can't use custom auth server as SPA issuer (blocks Kargo OIDC RBAC)

### Accounts
- Dev: `934822760716`, Profile: `dev-deployment-v2`, Region: `us-west-2`
- GitLab (old): `612524168818`, Profile: `deployment-refinement-v2`

## Key Documentation Files

| File | Purpose |
|------|---------|
| `docs/deployment-refinement/dev-deployment-learnings.md` | **PRIMARY** — Full running log of every issue, fix, discovery, and componentization finding |
| `docs/deployment-refinement/fresh-deploy-validation.md` | Checklist for validating a fresh deployment |
| `docs/deployment-refinement/dev-deployment-guide.md` | Getting started guide for dev mode deployment |
| `docs/deployment-refinement/dev-poc-plan.md` | POC plan with phase status |
| `docs/deployment-refinement/dev-path-design.md` | Original design for the dev deployment mode |
| `docs/deployment-refinement/deploy-cli-strategy.md` | Future deploy CLI design (setup → verify → run) |
| `docs/deployment-refinement/local-deployment-guide.md` | How the full deployment works |
| `docs/deployment-refinement/git-lab-deployment-ref.md` | Reference from the outer platform-engineering-on-eks repo |

## What Was Implemented

### Terraform — deployment_mode Conditional Logic
- `deployment_mode` variable (`"gitlab"` or `"dev"`) in both stacks
- `gitlab.tf` resources conditional (count=0 in dev)
- `argocd.tf` — install flag, server URL, OIDC config, Dex disable all conditional
- `secrets.tf` — endpoint vs ARN, awsAuthConfig, dev-mode ExternalSecrets for spokes
- `locals.tf` — repo URLs conditional
- `deploy.sh` / `destroy.sh` — DEPLOYMENT_MODE handling, SKIP_GITLAB, OIDC env vars, enable_gitlab patch

### Backstage — Custom Image + Config-Driven Auth
- Frontend: `apis.ts` and `App.tsx` read auth provider from `auth.sso.*` config
- Backend: Generic OIDC provider (renamed from keycloak-oidc), GitLab imports removed
- Build: CodeBuild project `peeks-backstage-build`, image in ECR `peeks-backstage:latest`
- Chart: Conditional GitLab/GitHub integration, catalog, envFrom, auth providers

### GitOps — GitHub Templates
- `catalog-info-github.yaml` — GitHub-only template catalog with populated system-info
- `template-github.yaml` for S3 KRO and App Deploy — use `publish:github`, read values from system-info
- Chart template uses `addons_repo_url` value for catalog location

### ArgoCD — Deployment-Time OIDC
- `oidc_config` Terraform variable → Helm `set_sensitive` for OIDC config
- Dex disabled via `set` when OIDC configured
- rootpath, basehref, insecure mode set at install time
- deploy.sh reads `OIDC_ISSUER_URL`, `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET`, `OIDC_PROVIDER_NAME`

## What Still Needs Work (for next deployment)

### Must Fix
- ArgoCD ingress — not created by Helm module, needs Terraform resource
- ArgoCD RBAC default — `policy.default: role:admin` needs to be in Helm values
- Backstage image variable — needs to be configurable, not hardcoded
- Backstage GitHub token — needs proper secret management (env var → Secrets Manager → ExternalSecret)
- system-info entity values — should be populated by deploy.sh, not hardcoded in catalog-info-github.yaml
- Backstage startup probe — needs to use correct auth endpoint based on provider

### Should Fix
- Argo Workflows / Kargo Okta config — should be deployment-time, not manual patches
- Backstage homepage links — hardcoded GitLab/Keycloak in CustomHomepage.tsx
- hub-config.yaml — should have a `deployment_mode` field or separate dev overlay
- Security alerts — 70+ container image CVEs (sev 4) from outdated base images and pinned versions

### Nice to Have
- Dockerfile build arg for optional GitLab plugin (`ARG INCLUDE_GITLAB=false`)
- GitHub App instead of PAT for Backstage scaffolder
- Okta Terraform provider for automated app registration
- Automated Backstage image builds via GitHub Actions
- Single gitops repo pattern instead of one repo per resource

## Critical Lessons Learned

1. **Don't fix what isn't broken** — ArgoCD i/o timeout was cosmetic, trying to fix it caused a regression
2. **Track all external changes** — Okta redirect URIs must be reverted when reverting config
3. **Never delete argocd-secret** — contains encryption keys that aren't auto-regenerated
4. **ExternalSecrets overwrite manual patches** — all fixes must go through Terraform → Secrets Manager
5. **Hot-reload vs cold start** — ArgoCD ConfigMap hot-reload works but cold start fails with Dex enabled
6. **Backstage build is fragile** — pre-existing TypeScript errors require build fixes
7. **Each component has its own RBAC** — 4 different systems to configure when swapping IdP
8. **Okta free plan limitations** — can't use custom auth server for SPA apps without custom domain

## Environment Variables for Dev Deployment

```bash
export AWS_PROFILE=dev-deployment-v2
export AWS_REGION=us-west-2
export RESOURCE_PREFIX=peeks
export TFSTATE_BUCKET_NAME=peeks-tfstate-934822760716
export HUB_VPC_ID=vpc-01cd5e901f3944abe
export HUB_SUBNET_IDS='["subnet-06bfe1590a4d2d6b2","subnet-0d96060b5018f6158"]'
export USER1_PASSWORD=Password123!
export IDE_PASSWORD=Password123!
export GIT_USERNAME=user1
export WORKING_REPO=appmod-blueprints-dev-poc
export WORKSHOP_CLUSTERS=true
export DEPLOYMENT_MODE=dev
export WS_PARTICIPANT_ROLE_ARN=""

# OIDC (Okta)
export OIDC_ISSUER_URL=https://integrator-8021951.okta.com
export OIDC_CLIENT_ID=0oa11q5hs1ex6xcV1698
export OIDC_CLIENT_SECRET=<secret>
export OIDC_PROVIDER_NAME=Okta
```

## Rules for Autonomous Work

1. Keep `dev-deployment-learnings.md` updated with every discovery
2. If context refreshes, follow the "Codebase Review Procedure" in `.kiro/steering/project.md`, then read `dev-deployment-learnings.md` fully
3. Both deployment modes must coexist — don't break the GitLab path
4. When hitting circular problems — STOP, step back, document root cause before proceeding
5. Don't try to fix cosmetic warnings (like ArgoCD i/o timeout) — document and move on
6. Track every external change (Okta settings, secrets, ConfigMaps) so they can be reverted
7. Use `sleep` with reasonable intervals when waiting for long operations, don't poll every few seconds
