---
inclusion: manual
---

# Deployment Refinement — Autonomous Work Session

## Current Mission

Complete the GitLab deployment approach end-to-end, then build a working dev deployment approach (no GitLab/IDC dependency). Document everything learned along the way.

## Context

- Account: `612524168818`, Profile: `deployment-refinement-v2`, Region: `us-west-2`
- Branch: `crossplane-version-upgrade-v2-2026` with latest main merged
- VPC: `vpc-0ba6640a9aa005cde` (custom, 3 AZs, public+private subnets, NAT)
- State bucket: `peeks-tfstate-612524168818`
- Password: `Password123!` (test account)
- Phase 1 (clusters): ✅ Complete — 3 EKS clusters with general-purpose node pools
- Phase 2 (common): ✅ Complete — GitLab, ArgoCD (Helm), secrets, observability all deployed
- Phase 3 (0-init.sh): 🔄 In progress — ArgoCD syncing apps, recovery phase running

## Key Files Modified

| File | Change | Why |
|------|--------|-----|
| `platform/infra/terraform/cluster/main.tf` | Restored IDC guard on ArgoCD access policy; added `general-purpose` to node_pools | Fix 404 without IDC; fix pod scheduling |
| `platform/infra/terraform/common/argocd.tf` | Changed `install = false` to `install = true` | Install ArgoCD via Helm when EKS capability unavailable |
| `platform/infra/terraform/common/deploy.sh` | Wrapped GitLab domain retrieval in SKIP_GITLAB conditional | Fix script crash when SKIP_GITLAB=true |

## Key Fixes Applied at Runtime

- Patched hub cluster secret `server` field from ARN to `https://kubernetes.default.svc` (Helm ArgoCD can't resolve ARNs)
- Ran `helm upgrade --reuse-values` to fix ArgoCD Helm release stuck in `failed` state
- Installed `coreutils` for macOS `timeout` command compatibility

## Documentation Files

| File | Purpose |
|------|---------|
| `docs/deployment-refinement/dev-deployment-plan.md` | Execution plan for this deployment |
| `docs/deployment-refinement/dev-deployment-learnings.md` | Running log of discoveries and fixes |
| `docs/deployment-refinement/local-deployment-guide.md` | How the deployment works today |
| `docs/deployment-refinement/deploy-cli-strategy.md` | Future deploy CLI design |
| `docs/deployment-refinement/git-lab-deployment-ref.md` | Reference doc from outer repo |

## Rules for Autonomous Work

1. Keep `dev-deployment-learnings.md` updated with every discovery
2. Don't stop waiting for user input — keep progressing
3. If stuck for 2+ hours with no progress, stop and document where you are
4. If context refreshes, re-read all docs in `docs/deployment-refinement/` before continuing
5. For the dev approach: make GitLab optional, use GitHub URLs, install ArgoCD via Helm
6. Both approaches should coexist — don't break the GitLab path while building the dev path
7. Use profile `deployment-refinement-v2` for all AWS operations
8. When hitting circular problems — STOP, step back, analyze what's actually failing and why. Write down the problem clearly in the learnings doc, consider alternative approaches, and only proceed when you have a concrete plan that addresses the root cause. Don't keep retrying the same failing approach.
9. If a fix requires understanding how the existing system works, read the relevant Terraform/script code first before making changes. Don't guess.
10. All env vars: AWS_PROFILE=deployment-refinement-v2, AWS_REGION=us-west-2, RESOURCE_PREFIX=peeks, USER1_PASSWORD=Password123!, IDE_PASSWORD=Password123!, HUB_VPC_ID=vpc-0ba6640a9aa005cde, HUB_SUBNET_IDS=["subnet-0543a0e4eeb4f368c","subnet-0ce3fa376d22493e7","subnet-068cae9a3930cafde"], GIT_USERNAME=user1, WORKING_REPO=platform-on-eks-workshop, WORKSHOP_CLUSTERS=true
