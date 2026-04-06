# Dev Deployment Learnings — What Works, What Doesn't, What We Changed

Running log of discoveries while deploying `appmod-blueprints` via the direct Terraform path from a bare AWS account (`612524168818`).

---

## Account Setup

### What we created manually
- VPC `vpc-0ba6640a9aa005cde` with 3 AZs, public + private subnets, IGW, NAT gateway
- S3 bucket `peeks-tfstate-612524168818` for Terraform state (versioned)
- Security Hub enabled
- AWS profile `deployment-refinement-v2`

### Lesson: Default VPC is not suitable
The hub cluster needs private subnets with NAT gateway for outbound access. The default VPC only has public subnets. A dedicated VPC is required.

### Lesson: Security Hub must be enabled before deployment
Terraform modules reference Security Hub. If not enabled, the deployment fails.

---

## Phase 1: Cluster Deployment

### Bug found: ArgoCD access policy association guard

**File:** `platform/infra/terraform/cluster/main.tf`

**Problem:** Commit `9019656f` removed the Identity Center guard from `aws_eks_access_policy_association.argocd`, changing:
```hcl
for_each = { for k, v in var.clusters : k => v if v.environment == "control-plane" && var.identity_center_instance_arn != "" }
```
to:
```hcl
for_each = { for k, v in var.clusters : k => v if v.environment == "control-plane" }
```

This causes the access policy to be created even when there's no Identity Center. The policy references the ArgoCD capability IAM role, but without IDC, the ArgoCD capability is skipped, so there's no access entry for that role on the cluster. Result: `ResourceNotFoundException` — the principal ARN doesn't exist.

**Fix:** Restored the Identity Center guard. The access policy association should only be created when the ArgoCD capability is created, which requires Identity Center.

**Impact:** This would also break any deployment without Identity Center on main, not just this branch.

### What worked
- 3 EKS clusters created successfully (~15 min)
- Kro capabilities on all 3 clusters (~48-50s each)
- ACK capabilities on all 3 clusters (~2 min each)
- Spoke VPCs created automatically by Terraform
- Identity Center detection works correctly (skips when not available)

---

## Phase 2: Common Stack Deployment

### Bug found: deploy.sh GitLab domain retrieval runs unconditionally

**File:** `platform/infra/terraform/common/deploy.sh`

**Problem:** Lines 108-109 run outside the `if ! $SKIP_GITLAB` block:
```bash
export GITLAB_DOMAIN=$(terraform -chdir=$DEPLOY_SCRIPTDIR/gitlab_infra output -raw gitlab_domain_name)
GITLAB_SG_ID=$(terraform -chdir=$DEPLOY_SCRIPTDIR/gitlab_infra output -raw gitlab_security_groups)
```

When `SKIP_GITLAB=true`, the `gitlab_infra` sub-stack was never initialized, so `terraform output` fails. With `set -euo pipefail`, this kills the script.

**Fix:** Wrapped the GitLab domain retrieval and repo setup in a `SKIP_GITLAB` conditional.

### Discovery: SKIP_GITLAB doesn't actually skip GitLab

Even with the deploy.sh fix, the main common stack's Terraform code has unconditional GitLab dependencies:
- `data "gitlab_user" "workshop"` — queries GitLab API during plan
- `gitlab_personal_access_token` — creates a PAT
- `local.gitlab_token` — used in ArgoCD git secrets

These are in `gitlab.tf` and are not behind any conditional. The GitLab provider tries to connect to the GitLab API during `terraform plan`, and if there's no GitLab instance, it fails with `http: no Host in request URL`.

**Conclusion:** `SKIP_GITLAB` is only useful for skipping the `gitlab_infra` sub-stack deployment. It cannot skip the main stack's GitLab integration. The common stack fundamentally requires GitLab to exist.

### Lesson: The "dev path" was never tested from a bare account

The Terraform README documents a 4-step deployment process, but it was only ever run from inside the CDK-bootstrapped IDE where GitLab was already deployed by the outer stack. Running it from a bare account exposes dependencies that aren't documented.

---

## Disk Space

### Issue: macOS disk full during Terraform init

Terraform providers (especially `hashicorp/aws` at ~300MB) need significant disk space. The machine had only 245MB free, causing `no space left on device` during provider download.

**Fix:** Cleaned up `.terraform/` directories from both stacks. User freed additional space externally.

**Lesson:** Need ~2-3GB free for Terraform providers across both stacks.

---

## Changes Made (Summary)

| File | Change | Reason |
|------|--------|--------|
| `platform/infra/terraform/cluster/main.tf` | Restored IDC guard on ArgoCD access policy | Prevents ResourceNotFoundException when no IDC |
| `platform/infra/terraform/common/deploy.sh` | Wrapped GitLab domain retrieval in SKIP_GITLAB conditional | Prevents script failure when SKIP_GITLAB=true |

---

## ArgoCD Without Identity Center — Critical Finding

The ArgoCD EKS Managed Capability requires Identity Center (IDC). The `aws_eks_capability.argocd` resource has `for_each` gated on `var.identity_center_instance_arn != ""`. Without IDC, the capability is skipped entirely.

The `gitops_bridge_bootstrap` module in `argocd.tf` has `install = false` — it explicitly does NOT install ArgoCD via Helm. It only creates the cluster secret for the GitOps Bridge pattern.

**Result:** Without Identity Center, there is NO ArgoCD on the hub cluster. The entire GitOps flow (ApplicationSets, addon deployments, spoke cluster management) is non-functional.

**Options:**
1. Deploy Identity Center first (`identity-center/deploy.sh`) — this creates the IDC groups needed for the ArgoCD capability
2. Change `install = false` to `install = true` in the gitops_bridge_bootstrap module — this would install ArgoCD via Helm as a fallback
3. Accept that the dev path requires Identity Center

**Decision:** We need to either set up Identity Center or modify the bootstrap to install ArgoCD via Helm. Identity Center requires an AWS Organizations setup which a fresh standalone account may not have.

---

## Open Questions

1. **Can GitLab be made optional?** — The common stack could be refactored to make GitLab conditional using `count` on the GitLab resources and a fallback to GitHub URLs for the gitops repos. This would enable a true "dev path" without GitLab.

2. **Identity Center availability** — Does account `612524168818` have AWS Organizations and Identity Center available? If not, the ArgoCD capability path is blocked and we need the Helm fallback.

3. **CloudFront for GitLab** — The `gitlab_infra` sub-stack creates its own CloudFront distribution. In the CDK path, there's a separate CloudFront for the main ingress. Are both needed?


---

## ArgoCD Helm Install — Node Scheduling Issue

### Problem

ArgoCD pods installed via Helm are stuck in `Pending` because the hub cluster only has EKS Auto Mode `system` node pool nodes, which carry a `CriticalAddonsOnly:NoSchedule` taint. ArgoCD pods don't have tolerations for this taint.

### Root Cause

EKS Auto Mode with `node_pools: ["system"]` only creates nodes for critical system addons. In the normal flow, ArgoCD runs as an EKS Managed Capability which handles its own scheduling (likely runs on the system nodes with the right tolerations). When installing ArgoCD via Helm, the pods are treated as regular workloads and can't schedule on system nodes.

### Fix Options

1. Add a `general-purpose` node pool to the hub cluster config — this creates nodes without the `CriticalAddonsOnly` taint
2. Add tolerations to the ArgoCD Helm values so it can run on system nodes
3. Both

### Decision

Option 1 is cleaner — a general-purpose node pool is needed anyway for GitLab, Backstage, Keycloak, and other platform services that also won't tolerate the system taint. This is likely why the normal flow works: the EKS capabilities (ArgoCD, ACK, Kro) run on system nodes, but everything else (deployed via Helm/ArgoCD) needs general-purpose nodes.

### What this means for the dev path

The hub cluster needs `node_pools: ["system", "general-purpose"]` instead of just `["system"]`. This is a `hub-config.yaml` change or a Terraform variable override.


---

## Phase 2 Success — With Workarounds

### What worked
- GitLab infrastructure deployed (NLB, CloudFront VPC Origin, CloudFront distribution, Helm chart)
- GitLab CloudFront domain: `d1zpajxmobzscu.cloudfront.net` (from `gitlab_infra` sub-stack, separate from main ingress CloudFront)
- Main common stack: all resources created (secrets, ArgoCD bootstrap, pod identity, AMP scrapers, Grafana workspace, ingress, CloudFront)
- AMP scrapers both created successfully this time (~16 min each)
- ArgoCD Helm release recovered after manual `helm upgrade` to fix failed status

### Issues encountered

1. **ArgoCD Helm timeout** — The gitops_bridge_bootstrap module installs ArgoCD via Helm with a default timeout. On EKS Auto Mode with only `system` node pool, pods can't schedule (CriticalAddonsOnly taint). The Helm install times out waiting for pods to be ready.

2. **General-purpose node pool required** — Had to add `"general-purpose"` to `compute_config.node_pools` in `cluster/main.tf` for all clusters. This is needed for any workload that isn't a critical system addon.

3. **Helm release failed state** — After the timeout, the Helm release was in `failed` state. Even though the pods eventually started (once general-purpose nodes appeared), Terraform kept trying to uninstall and reinstall. Fixed with `helm upgrade --reuse-values` to flip the status to `deployed`.

4. **ARGOCD_DOMAIN unbound variable** — The `update_backstage_defaults` function in `deploy.sh` references `ARGOCD_DOMAIN` which isn't set in the dev path (it's set by `1-tools-urls.sh` or the workshop environment). The `set -euo pipefail` kills the script. Non-critical — the Terraform apply already completed.

5. **Backend config mismatch** — Manually running `terraform init` with different backend-config keys than what `deploy.sh` uses causes "Backend configuration changed" errors. Never manually init — always let `deploy.sh` handle it, or match the exact key from `versions.tf`.

### Changes made for this phase
- `platform/infra/terraform/common/argocd.tf` — changed `install = false` to `install = true` in gitops_bridge_bootstrap module
- `platform/infra/terraform/cluster/main.tf` — added `"general-purpose"` to `compute_config.node_pools`
- `platform/infra/terraform/common/deploy.sh` — wrapped GitLab domain retrieval in SKIP_GITLAB conditional


---

## Phase 3: 0-init.sh — Multiple Issues

### macOS `timeout` command missing

The script uses `timeout` (GNU coreutils) which doesn't exist on macOS. ArgoCD readiness check silently fails and loops for 30 minutes.

**Fix:** Installed `coreutils` via brew and added `/opt/homebrew/opt/coreutils/libexec/gnubin` to PATH.

### Cluster secrets use ARNs instead of endpoints

The gitops_bridge_bootstrap module sets the cluster secret `server` field to the EKS cluster ARN. EKS Managed ArgoCD can resolve ARNs natively. Helm-installed ArgoCD cannot — it tries to parse the ARN as an HTTP URL and fails.

**Fix:** Manually patched all 3 cluster secrets (hub, spoke-dev, spoke-prod) to use actual endpoints:
- Hub: `https://kubernetes.default.svc` (in-cluster)
- Spoke-dev: actual EKS API endpoint
- Spoke-prod: actual EKS API endpoint

**Root cause:** The `gitops_bridge_bootstrap` module's `server` field is set to `data.aws_eks_cluster.clusters[local.hub_cluster_key].arn` in `argocd.tf`. For Helm-installed ArgoCD, this should be the actual endpoint URL.

### Spoke cluster secrets lack authentication

The fleet-secret ExternalSecrets create spoke cluster secrets with only TLS config — no authentication credentials. EKS Managed ArgoCD authenticates via its IAM capability role. Helm-installed ArgoCD needs either:
1. A bearer token (service account token from the spoke cluster)
2. An `execProviderConfig` that runs `aws eks get-token`
3. An IAM role ARN with `awsAuthConfig`

Without authentication, ArgoCD can reach the spoke API endpoints but gets 401 Unauthorized.

**This is the biggest gap between EKS Managed ArgoCD and Helm-installed ArgoCD.** The entire fleet management pattern assumes EKS Managed ArgoCD's transparent IAM authentication.

### `grep -P` not available on macOS

Multiple places in the scripts use `grep -P` (Perl regex) which macOS grep doesn't support. Non-fatal but produces error output.

### Missing workshop environment files

`0-init.sh` sources `/etc/profile.d/workshop.sh` and `/home/ec2-user/.bashrc.d/platform.sh` which don't exist on a local machine. Non-fatal — the script continues.

---

## Critical Finding: Helm ArgoCD Cannot Manage Spoke Clusters Without Auth Config

The entire multi-cluster GitOps pattern relies on ArgoCD being able to deploy to spoke clusters. With EKS Managed ArgoCD, this works transparently via IAM roles. With Helm-installed ArgoCD, the spoke cluster secrets need explicit authentication configuration.

Options to fix:
1. Add `awsAuthConfig` with the ArgoCD hub role ARN to spoke cluster secrets
2. Create service account tokens on spoke clusters and add them to the secrets
3. Use an exec-based auth provider (`aws eks get-token`) in the cluster config

Option 1 is cleanest — the IAM role already exists (`peeks-argocd-hub-*`), and the spoke clusters already have access entries for it. We just need to add it to the cluster secret config.


---

## Step Back: ExternalSecrets Overwrites Manual Patches

### Problem
Manual patches to spoke cluster secrets (server URL, auth config) get overwritten every 60 seconds by the ExternalSecrets operator, which reconciles from AWS Secrets Manager.

### Failed approach
Setting `reconcile.external-secrets.io/managed=false` annotation didn't prevent reconciliation — the ExternalSecret resource still syncs on its refresh interval.

### Correct approach
The source of truth is `platform/infra/terraform/common/secrets.tf`. The `aws_secretsmanager_secret_version.cluster_config` resource writes the cluster config to Secrets Manager. For Helm ArgoCD, this needs:
1. `server` field: actual EKS API endpoint instead of ARN
2. `config` field: `awsAuthConfig` with cluster name and role ARN, plus CA data

This requires modifying `secrets.tf` and rerunning `terraform apply` for the common stack. The ExternalSecrets will then pick up the correct values automatically.

### Key insight
You cannot work around the ExternalSecrets reconciliation loop with manual patches. The Terraform code that writes to Secrets Manager is the only place to fix this properly. This is actually good design — single source of truth — but it means every fix must go through Terraform, not kubectl.
