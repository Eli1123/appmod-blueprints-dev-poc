---
inclusion: manual
---

# Deployment Refinement — Work Session Context

## Background

We're making the `appmod-blueprints` repo deployable via a direct Terraform path from a bare AWS account. The repo was designed for a CDK/CloudFormation workshop flow and has hard dependencies on GitLab and Identity Center that don't exist in a bare account.

We're building two deployment modes:
- `gitlab` (default) — full workshop experience with GitLab, Identity Center, EKS Managed ArgoCD
- `dev` — minimal, no GitLab, no IDC, ArgoCD via Helm, gitops repos point to GitHub

## Status

### GitLab Deployment Path: ✅ COMPLETE
- Account: `612524168818`, Profile: `deployment-refinement-v2`
- Platform running: 61 ArgoCD apps, all Healthy
- ArgoCD: `https://d1zpajxmobzscu.cloudfront.net/argocd`
- GitLab: `https://dqaec5goq4oys.cloudfront.net`
- VPC: `vpc-0ba6640a9aa005cde`, State bucket: `peeks-tfstate-612524168818`

### Dev Deployment Path: ✅ COMPLETE (2 known issues)
- Account: `934822760716`, Profile: `dev-deployment-v2`
- Platform running: 59 ArgoCD apps, 57 Healthy (97%)
- ArgoCD: `https://d181j7b7fhjtqq.cloudfront.net/argocd`
- VPC: `vpc-01cd5e901f3944abe`, State bucket: `peeks-tfstate-934822760716`
- Known issues: backstage CrashLoopBackOff (GitLab config hardcoded), gitlab app degraded (being disabled)
- Guide: `docs/deployment-refinement/dev-deployment-guide.md`
- Design doc: `docs/deployment-refinement/dev-path-design.md`
- Account needs: VPC, S3 state bucket, Security Hub (same setup as GitLab account)
- Password: `Password123!` (test accounts)

## What Was Changed for GitLab Path (uncommitted local changes)

| File | Change | Why |
|------|--------|-----|
| `platform/infra/terraform/cluster/main.tf` | Restored IDC guard on `aws_eks_access_policy_association.argocd` | Without IDC, the ArgoCD capability isn't created, so the access entry doesn't exist → 404 |
| `platform/infra/terraform/cluster/main.tf` | Added `"general-purpose"` to `compute_config.node_pools` | EKS Auto Mode `system` nodes have `CriticalAddonsOnly` taint — Helm-installed ArgoCD and other workloads can't schedule |
| `platform/infra/terraform/common/argocd.tf` | Changed `install = false` to `install = true` in gitops_bridge_bootstrap | Install ArgoCD via Helm when EKS ArgoCD Capability is unavailable |
| `platform/infra/terraform/common/argocd.tf` | Changed server from `data.aws_eks_cluster...arn` to `https://kubernetes.default.svc` | Helm ArgoCD can't resolve EKS ARNs as server URLs |
| `platform/infra/terraform/common/secrets.tf` | Changed spoke server from `.arn` to `.endpoint` | Helm ArgoCD needs actual API endpoints, not ARNs |
| `platform/infra/terraform/common/secrets.tf` | Added `awsAuthConfig` with role ARN and CA data to spoke cluster configs | Helm ArgoCD needs explicit IAM auth for spoke cluster access |
| `platform/infra/terraform/common/deploy.sh` | Wrapped GitLab domain retrieval in `SKIP_GITLAB` conditional | Script crashed when SKIP_GITLAB=true because gitlab_infra terraform wasn't initialized |

## What Needs to Happen for Dev Path

All the above changes need to be made CONDITIONAL on a `deployment_mode` variable instead of unconditional. The design is in `docs/deployment-refinement/dev-path-design.md`. Key changes:

1. Add `deployment_mode` variable (`"gitlab"` or `"dev"`) to both cluster and common stacks
2. `cluster/main.tf`: node_pools conditional on mode
3. `common/gitlab.tf`: all resources get `count = var.deployment_mode == "dev" ? 0 : 1`
4. `common/argocd.tf`: `install` flag and `server` URL conditional on mode
5. `common/secrets.tf`: server (endpoint vs ARN) and config (awsAuthConfig vs empty) conditional on mode
6. `common/locals.tf`: repo URLs point to GitHub in dev mode, GitLab in gitlab mode
7. `common/argocd.tf`: git secrets skipped in dev mode (public GitHub repo)
8. `deploy.sh`: auto-set `SKIP_GITLAB=true` in dev mode

## Key Architectural Insights

- EKS Managed ArgoCD resolves cluster ARNs natively and authenticates via IAM roles transparently
- Helm-installed ArgoCD needs actual endpoint URLs and explicit `awsAuthConfig` in cluster secrets
- ExternalSecrets reconciles every 60s from Secrets Manager — manual kubectl patches get overwritten. All fixes must go through Terraform → Secrets Manager → ExternalSecrets
- The `gitops_bridge_bootstrap` Helm module controls ArgoCD installation (`install = true/false`) and creates the hub cluster secret
- Spoke cluster secrets are created by ExternalSecrets from Secrets Manager data written by `common/secrets.tf`

## Documentation Files

| File | Purpose |
|------|---------|
| `docs/deployment-refinement/dev-deployment-learnings.md` | Full running log of every issue, fix, and discovery |
| `docs/deployment-refinement/dev-deployment-plan.md` | Execution plan for the GitLab deployment |
| `docs/deployment-refinement/dev-path-design.md` | Design for the dev deployment mode with code examples |
| `docs/deployment-refinement/deploy-cli-strategy.md` | Future deploy CLI design (setup → verify → run) |
| `docs/deployment-refinement/local-deployment-guide.md` | How the deployment works today |
| `docs/deployment-refinement/git-lab-deployment-ref.md` | Reference doc from the outer `platform-engineering-on-eks` repo |
| `docs/deployment-refinement/dev-deployment-guide.md` | Getting started guide for the dev deployment path |

## macOS Compatibility Issues Found

- `timeout` command missing → `brew install coreutils`, add `/opt/homebrew/opt/coreutils/libexec/gnubin` to PATH
- `grep -P` (Perl regex) not available → non-fatal, produces error output
- `sed -i` syntax differs (BSD vs GNU) → `update_workshop_var` function errors but still works
- `~/.bashrc.d/platform.sh` doesn't exist → must create `mkdir -p ~/.bashrc.d && touch ~/.bashrc.d/platform.sh`
- `/etc/profile.d/workshop.sh` doesn't exist → non-fatal, script continues

## Rules for Autonomous Work

1. Keep `dev-deployment-learnings.md` updated with every discovery
2. Don't stop waiting for user input — keep progressing
3. If stuck for 2+ hours with no progress, stop and document where you are
4. If context refreshes, follow the full "Codebase Review Procedure" in `.kiro/steering/project.md` before continuing
5. Both deployment modes must coexist — don't break the GitLab path while building the dev path
6. When hitting circular problems — STOP, step back, analyze root cause. Write it down in learnings doc. Only proceed with a concrete plan.
7. If a fix requires understanding how the existing system works, read the relevant code first. Don't guess.
8. For dev path account: Profile `dev-deployment-v2`, Account `934822760716`, Region `us-west-2`
9. For GitLab path account: Profile `deployment-refinement-v2`, Account `612524168818`, Region `us-west-2`
10. Common env vars: RESOURCE_PREFIX=peeks, USER1_PASSWORD=Password123!, IDE_PASSWORD=Password123!, GIT_USERNAME=user1, WORKING_REPO=platform-on-eks-workshop, WORKSHOP_CLUSTERS=true
