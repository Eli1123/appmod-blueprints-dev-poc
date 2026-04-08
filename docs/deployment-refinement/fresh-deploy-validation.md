# Fresh Deploy Validation Checklist

After all the manual patching and testing on the live deployment, these items need to be validated on a clean fresh deploy to confirm the deployment-time configuration works end-to-end without manual intervention.

## Pre-Deploy Prerequisites

These must be in place before running any deployment scripts:

| # | Prerequisite | How to Verify |
|---|-------------|---------------|
| 0.1 | Dedicated VPC with private subnets + NAT gateway (NOT default VPC) | `aws ec2 describe-vpcs` — needs private subnets tagged `kubernetes.io/role/internal-elb: 1` |
| 0.2 | S3 bucket for Terraform state (versioned) | `aws s3api head-bucket --bucket <bucket>` |
| 0.3 | Security Hub enabled | `aws securityhub describe-hub` — must not return error |
| 0.4 | ~2-3GB free disk space | `df -h /` — Terraform providers are large |
| 0.5 | Required CLI tools installed | aws, terraform, kubectl, helm, yq, jq |
| 0.6 | macOS: GNU coreutils installed | `brew install coreutils` — needed for `timeout` command in scripts |
| 0.7 | Fork of appmod-blueprints with dev mode changes pushed | `git ls-remote <fork> main` |
| 0.8 | Okta OIDC apps created (if using Okta) | ArgoCD, Backstage, Argo Workflows, Kargo apps in Okta |
| 0.9 | Okta groups claim configured on default authorization server | Security → API → default → Claims → groups claim with regex `.*` |
| 0.10 | Backstage custom image built and in ECR | `aws ecr describe-images --repository-name peeks-backstage` |

## Pre-Deploy Configuration

These environment variables should be set before running `deploy.sh`:

```bash
# Required
export DEPLOYMENT_MODE=dev
export RESOURCE_PREFIX=peeks
export TFSTATE_BUCKET_NAME=<bucket>
export HUB_VPC_ID=<vpc-id>
export HUB_SUBNET_IDS='["<subnet-1>","<subnet-2>"]'
export USER1_PASSWORD=<password>
export IDE_PASSWORD=<password>
export WORKSHOP_CLUSTERS=true

# OIDC (optional — omit for no SSO)
export OIDC_ISSUER_URL=https://<org>.okta.com
export OIDC_CLIENT_ID=<argocd-client-id>
export OIDC_CLIENT_SECRET=<argocd-client-secret>
export OIDC_PROVIDER_NAME=Okta

# GitHub (required for Backstage scaffolding)
export GITHUB_TOKEN=<github-pat-with-repo-scope>
```

## Validation Items

### Phase 1: Cluster Stack

| # | Check | How to Verify | Status |
|---|-------|---------------|--------|
| 1.1 | 3 EKS clusters created | `aws eks list-clusters` shows hub, spoke-dev, spoke-prod | |
| 1.2 | All clusters ACTIVE | `aws eks describe-cluster --name <name> --query cluster.status` | |
| 1.3 | ACK capabilities on all clusters | Check in AWS console or `aws eks describe-capability` | |
| 1.4 | Kro capabilities on all clusters | Same as above | |
| 1.5 | ArgoCD capability skipped (no IDC) | No ArgoCD capability in `aws eks list-capabilities` | |
| 1.6 | Node pools: system + general-purpose | `kubectl get nodes` shows nodes from both pools | |

### Phase 2: Common Stack

| # | Check | How to Verify | Status |
|---|-------|---------------|--------|
| 2.1 | ArgoCD installed via Helm | `kubectl get pods -n argocd` shows running pods | |
| 2.2 | Dex disabled (when OIDC configured) | No dex-server pod in argocd namespace | |
| 2.3 | OIDC config in argocd-cm | `kubectl get cm argocd-cm -n argocd -o jsonpath='{.data.oidc\.config}'` shows issuer | |
| 2.4 | ArgoCD rootpath /argocd set | `kubectl get cm argocd-cmd-params-cm -o jsonpath='{.data.server\.rootpath}'` returns `/argocd` | |
| 2.5 | ArgoCD insecure mode | `kubectl get cm argocd-cmd-params-cm -o jsonpath='{.data.server\.insecure}'` returns `true` | |
| 2.6 | ArgoCD server starts without probe failures | Pod is 1/1 Running with 0 restarts after 5 minutes | |
| 2.7 | No GitLab resources created | No gitlab namespace, no gitlab pods | |
| 2.8 | Ingress-nginx deployed | `kubectl get pods -n ingress-nginx` shows running pods | |
| 2.9 | CloudFront distribution created | Terraform output `ingress_domain_name` returns a domain | |
| 2.10 | ArgoCD ingress exists | `kubectl get ingress -n argocd` shows ingress for /argocd | |
| 2.11 | Spoke ExternalSecrets created | `kubectl get externalsecrets -n argocd` shows spoke secrets | |
| 2.12 | Spoke cluster secrets synced | `kubectl get secrets -n argocd -l argocd.argoproj.io/secret-type=cluster` shows 3 secrets | |
| 2.13 | enable_gitlab=false in hub secret | `kubectl get secret peeks-hub -n argocd -o jsonpath='{.metadata.labels.enable_gitlab}'` returns `false` | |

### Phase 3: ArgoCD Applications

| # | Check | How to Verify | Status |
|---|-------|---------------|--------|
| 3.1 | Bootstrap app healthy | `kubectl get app bootstrap -n argocd` shows Synced/Healthy | |
| 3.2 | cluster-addons app exists | `kubectl get app cluster-addons -n argocd` | |
| 3.3 | 55+ apps total | `kubectl get apps -n argocd --no-headers \| wc -l` | |
| 3.4 | 90%+ apps healthy | Count healthy vs total | |
| 3.5 | No gitlab app generated | `kubectl get app gitlab-peeks-hub -n argocd` returns NotFound | |
| 3.6 | Spoke addons deploying | `kubectl get apps -n argocd \| grep spoke` shows apps | |

### Phase 4: ArgoCD Okta SSO

| # | Check | How to Verify | Status |
|---|-------|---------------|--------|
| 4.1 | ArgoCD UI accessible | `https://<cloudfront>/argocd` loads login page | |
| 4.2 | "LOG IN VIA Okta" button visible | Login page shows SSO option | |
| 4.3 | Okta redirect works | Clicking SSO redirects to Okta login | |
| 4.4 | Okta login completes | After Okta auth, returns to ArgoCD with apps visible | |
| 4.5 | No i/o timeout errors | Check browser console — no timeout errors during login | |
| 4.6 | RBAC works | Authenticated user can see all apps (policy.default: role:admin) | |
| 4.7 | Admin login still works | Can login with admin/<generated-password> as fallback | |

### Phase 5: Backstage

| # | Check | How to Verify | Status |
|---|-------|---------------|--------|
| 5.1 | Backstage pod running | `kubectl get pods -n backstage` shows 1/1 Running | |
| 5.2 | Custom image used | Pod image is the ECR image, not public.ecr.aws/seb-demo | |
| 5.3 | "Sign in using SSO" button | `https://<cloudfront>/backstage` shows config-driven login | |
| 5.4 | Okta login works | SSO redirects to Okta and returns authenticated | |
| 5.5 | No GitLab crash | Pod doesn't CrashLoopBackOff (no GitLab integration errors) | |
| 5.6 | Catalog loads | Templates visible from GitHub repo | |
| 5.7 | Only GitHub templates shown | No GitLab-specific templates in Create page | |
| 5.8 | system-info entity populated | Check catalog for system-info with correct gituser, account ID, etc. | |
| 5.9 | GitHub token configured | Backstage can create repos (test with a template) | |
| 5.10 | Scaffolding works end-to-end | Template creates GitHub repo + ArgoCD app + catalog entry | |

### Phase 6: Other Components

| # | Check | How to Verify | Status |
|---|-------|---------------|--------|
| 6.1 | Keycloak running (if enabled) | `kubectl get pods -n keycloak` | |
| 6.2 | Argo Workflows accessible | `https://<cloudfront>/argo-workflows` loads | |
| 6.3 | Kargo accessible | `https://<cloudfront>/` loads Kargo UI | |
| 6.4 | Kargo admin login works | Login with admin account password | |
| 6.5 | Grafana workspace accessible | Check Terraform output for Grafana URL | |

## Known Issues to Watch For

| Issue | Symptom | Workaround |
|-------|---------|------------|
| ArgoCD probe timeout with OIDC | Pod restarts repeatedly | Should be fixed with Dex disabled at install time. If still occurs, increase probe timeouts or remove probes |
| Backstage GitLab references on homepage | Dead links to GitLab and Keycloak on dashboard | Cosmetic — doesn't affect functionality. Fix by updating CustomHomepage.tsx |
| Kargo OIDC RBAC | SSO login works but "forbidden" on list projects | Use admin account login. For OIDC RBAC, need custom auth server (`/oauth2/default`) and proper claim mapping via ServiceAccount annotations |
| cluster-addons Degraded | Shows Degraded in ArgoCD but all child apps are Healthy | Cosmetic — ApplicationSet health check is stricter than app health |
| Backstage chart changes need fork | ArgoCD reads charts from remote repo | Must push chart changes to fork before they take effect |
| macOS `grep -P` not available | Scripts produce error output for Perl regex | Non-fatal — scripts continue. Install `brew install grep` for GNU grep if needed |
| macOS `sed -i` syntax differs | `update_workshop_var` function errors | Non-fatal — BSD sed vs GNU sed difference |
| macOS `timeout` missing | ArgoCD readiness check loops for 30 min | Install `brew install coreutils`, add `/opt/homebrew/opt/coreutils/libexec/gnubin` to PATH |
| Helm release failed state after timeout | Terraform keeps trying to uninstall/reinstall | Run `helm upgrade <release> --reuse-values` to flip status to deployed |
| Backend config mismatch | "Backend configuration changed" errors | Never manually run `terraform init` — always use `deploy.sh` |
| ExternalSecrets overwrite manual patches | kubectl patches to secrets get reverted every 60s | All fixes must go through Terraform → Secrets Manager → ExternalSecrets |
| ArgoCD admin password | Not `Password123!` — Helm generates random password | Check `kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' \| base64 -d` |

## Okta Redirect URIs Reference

Each component uses a different callback path. These must match exactly in the Okta app settings:

| Component | Okta App Type | Sign-in Redirect URI |
|-----------|--------------|---------------------|
| ArgoCD | Web Application | `https://<cloudfront>/argocd/auth/callback` |
| Backstage | Web Application | `https://<cloudfront>/backstage/api/auth/oidc/handler/frame` |
| Argo Workflows | Web Application | `https://<cloudfront>/argo-workflows/oauth2/callback` |
| Kargo | Single-Page Application (PKCE) | `https://<cloudfront>/login` |

**Critical:** If you change the OIDC routing (e.g., switching between direct OIDC and Dex), the redirect URI changes. Always verify the redirect URI matches after any OIDC config change.

## Items That Were Manually Patched (need to be deployment-time)

These were done via kubectl on the live deployment. On a fresh deploy, they should be handled by Terraform/Helm or the deploy script:

| Item | Current (manual) | Target (deployment-time) | Status |
|------|-----------------|-------------------------|--------|
| ArgoCD OIDC config | kubectl patch argocd-cm | `oidc_config` Terraform variable → Helm values | ✅ Implemented |
| ArgoCD Dex disabled | kubectl scale dex to 0 | `dex.enabled: false` in Helm values when OIDC set | ✅ Implemented |
| ArgoCD rootpath/basehref | kubectl patch argocd-cmd-params-cm | Helm `set` values in argocd.tf | ✅ Implemented |
| ArgoCD insecure mode | kubectl patch argocd-cmd-params-cm | Helm `set` values in argocd.tf | ✅ Implemented |
| ArgoCD RBAC default | kubectl patch argocd-rbac-cm | Need to add to Helm values or Terraform | ❌ Not yet |
| ArgoCD ingress | kubectl apply ingress manifest | Need to add to Terraform or enable ArgoCD addon | ❌ Not yet |
| ArgoCD probe removal | kubectl patch deployment | Should not be needed with Dex disabled | ⚠️ Needs verification |
| Backstage ConfigMap (Okta auth) | kubectl patch backstage-config | Chart template conditional (already in fork) | ✅ In chart |
| Backstage image | kubectl set image | Need to add image variable to deploy.sh or Terraform | ❌ Not yet |
| Backstage envFrom (okta-vars) | kubectl patch deployment | Chart template conditional (already in fork) | ✅ In chart |
| Backstage startup probe | kubectl remove probe | Chart template needs update | ❌ Not yet |
| Backstage Okta ExternalSecret | kubectl apply | Need to add to Terraform | ❌ Not yet |
| Argo Workflows Okta config | kubectl patch configmap | Need to add to addons.yaml or Terraform | ❌ Not yet |
| Kargo Okta config | kubectl patch configmap | Need to add to addons.yaml or Terraform | ❌ Not yet |
| Kargo OIDC issuer (custom auth server) | kubectl patch configmap | Need to add to addons.yaml or Terraform | ❌ Not yet |
| GitHub PAT for Backstage scaffolder | Inline in ConfigMap | Need to add to deploy.sh as env var → Secrets Manager → ExternalSecret | ❌ Not yet |
| GitHub-specific template catalog | Manual import via /catalog-import | Chart template uses `addons_repo_url` value for catalog location | ✅ In chart |
| system-info entity values | Hardcoded in catalog-info-github.yaml | Should be populated by deploy.sh from env vars | ❌ Not yet |
| Backstage custom image reference | kubectl set image | Need to add `backstage_image` variable to deploy.sh or Terraform | ❌ Not yet |
