# Dev Deployment Plan — Making the Terraform Path Work from a Bare Account

## Goal

Deploy the full platform from `appmod-blueprints` using the direct Terraform path (not the CDK/CloudFormation wrapper) against a fresh AWS account, from a local machine.

## Current State

- Account: `612524168818`
- Region: `us-west-2`
- Profile: `deployment-refinement-v2`
- Phase 1 (clusters): ✅ Complete — 3 EKS clusters, Kro + ACK capabilities created
- Phase 2 (common): ❌ Blocked — GitLab dependency

## Problem Analysis

The `common/deploy.sh` has two sub-stacks:
1. `gitlab_infra/` — deploys GitLab (NLB, CloudFront, Helm chart) on the hub cluster
2. Main common stack — deploys everything else (secrets, ArgoCD bootstrap, pod identity, observability, Keycloak, Backstage, etc.)

The main common stack has a hard dependency on GitLab:
- `data "gitlab_user"` — queries GitLab API during plan (fails if GitLab doesn't exist)
- `gitlab_personal_access_token` — creates a PAT (fails if GitLab doesn't exist)
- `local.gitlab_token` — used in ArgoCD git secrets
- `local.gitlab_domain_name` — used in all gitops repo URLs

The `SKIP_GITLAB` flag only skips the `gitlab_infra/` sub-stack. It does NOT skip the GitLab references in the main common stack. So even with `SKIP_GITLAB=true`, the main stack fails at plan time.

## Approach

Run the deployment in the correct order WITHOUT `SKIP_GITLAB`. The `gitlab_infra/` sub-stack will:
1. Create a GitLab NLB on the hub cluster
2. Create a CloudFront distribution pointing to it
3. Deploy GitLab via Helm

Then the main common stack can query GitLab and proceed normally.

### Pre-requisites already done
- [x] VPC created (`vpc-0ba6640a9aa005cde`) with public/private subnets, IGW, NAT
- [x] S3 state bucket (`peeks-tfstate-612524168818`)
- [x] Security Hub enabled
- [x] Phase 1 clusters deployed
- [x] `main.tf` ArgoCD access policy guard restored (no IDC = skip ArgoCD capability)

### Fixes already applied
- [x] `platform/infra/terraform/cluster/main.tf` — restored Identity Center guard on ArgoCD access policy association
- [x] `platform/infra/terraform/common/deploy.sh` — wrapped GitLab domain retrieval in `SKIP_GITLAB` conditional (this fix is still needed for future use, but we won't use SKIP_GITLAB for this deployment)

## Execution Plan

### Step 1: Run common/deploy.sh without SKIP_GITLAB

```bash
export SKIP_GITLAB=false  # or just don't set it
bash platform/infra/terraform/common/deploy.sh
```

This will:
1. Configure kubectl for all 3 clusters
2. Initialize and apply `gitlab_infra/` sub-stack (creates GitLab + CloudFront)
3. Get GitLab domain from terraform output
4. Create spoke cluster secret values in `gitops/fleet/members/`
5. Push repo to GitLab
6. Initialize and apply main common stack

Expected duration: ~15-20 minutes

### Step 2: Run 0-init.sh

```bash
bash platform/infra/terraform/scripts/0-init.sh
```

This will:
1. Verify cluster readiness
2. Wait for ArgoCD to be ready (EKS capability)
3. Sync ArgoCD applications
4. Configure Identity Center (will skip — no IDC)
5. Initialize GitLab repos
6. Display tool URLs

Expected duration: ~10-15 minutes

### Step 3: Verify

```bash
bash platform/infra/terraform/scripts/1-tools-urls.sh
```

## Known Risks

1. **ArgoCD EKS Capability not deployed** — no Identity Center means no ArgoCD capability. ArgoCD won't be running as an EKS managed service. The `0-init.sh` script waits for ArgoCD but it may never appear. Need to check if the common stack deploys ArgoCD via Helm as a fallback.

2. **CloudFront distribution creation** — can take 5-15 minutes. The `gitlab_infra` stack has `wait_for_deployment = false` so it won't block, but GitLab may not be accessible immediately.

3. **Disk space** — we had issues earlier. Need ~2-3GB free for Terraform providers.

4. **GitLab Helm chart** — deploys on the hub cluster. Needs nodes to be ready and ingress to be working.

## Fallback

If the full deployment fails, we can use `-target` to deploy specific resources:
```bash
terraform apply -target=module.gitops_bridge_bootstrap -target=aws_secretsmanager_secret_version.cluster_secrets ...
```

This would give us the core GitOps infrastructure without GitLab/Backstage.
