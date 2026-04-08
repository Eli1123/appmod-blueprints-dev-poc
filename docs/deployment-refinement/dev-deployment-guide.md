# Dev Deployment Guide

Deploy the full platform from a bare AWS account without GitLab, Identity Center, or the CDK/CloudFormation wrapper. ArgoCD runs via Helm, gitops repos point to GitHub.

## How Dev Mode Differs from GitLab Mode

| Component | GitLab Mode (default) | Dev Mode |
|-----------|----------------------|----------|
| ArgoCD | EKS Managed Capability (via IDC) | Helm-installed |
| GitLab | Deployed in-cluster | Skipped entirely |
| Git repos | GitLab CloudFront URLs | Public GitHub URLs |
| ArgoCD git secrets | GitLab PAT | None (public repo) |
| Cluster secret server | ARN (EKS Capability resolves natively) | Actual endpoint URL |
| Cluster secret auth | Transparent IAM | Explicit awsAuthConfig |
| Identity Center | Required for ArgoCD SSO | Not needed |
| Backstage | Full with GitLab integration | Degraded (no GitLab catalog) |
| Fleet secrets | Created by fleet-secrets ApplicationSet via GitLab repo | Created directly by Terraform |

## Prerequisites

### Tools

| Tool | Version | Install |
|------|---------|---------|
| AWS CLI | 2.17+ | `brew install awscli` |
| Terraform | 1.5+ | `brew install terraform` |
| kubectl | 1.30+ | `brew install kubectl` |
| Helm | 3.x | `brew install helm` |
| yq | 4.x | `brew install yq` |
| jq | 1.6+ | `brew install jq` |

### AWS Account Setup

You need a dedicated AWS account with:

1. **VPC** with private subnets (NAT gateway) and public subnets, tagged for Kubernetes:
   - Private subnets: `kubernetes.io/role/internal-elb: 1`
   - Public subnets: `kubernetes.io/role/elb: 1`

2. **S3 bucket** for Terraform state (versioned):
   ```bash
   aws s3api create-bucket --bucket peeks-tfstate-<ACCOUNT_ID> \
     --region us-west-2 \
     --create-bucket-configuration LocationConstraint=us-west-2
   aws s3api put-bucket-versioning \
     --bucket peeks-tfstate-<ACCOUNT_ID> \
     --versioning-configuration Status=Enabled
   ```

3. **Security Hub** enabled:
   ```bash
   aws securityhub enable-security-hub --region us-west-2
   ```

## Environment Variables

```bash
export AWS_PROFILE=<your-profile>
export AWS_REGION=us-west-2
export RESOURCE_PREFIX=peeks
export TFSTATE_BUCKET_NAME=peeks-tfstate-<ACCOUNT_ID>
export HUB_VPC_ID=<vpc-id>
export HUB_SUBNET_IDS='["<private-subnet-1>","<private-subnet-2>"]'
export USER1_PASSWORD=<your-password>
export IDE_PASSWORD=<your-password>
export GIT_USERNAME=user1
export WORKING_REPO=platform-on-eks-workshop
export WORKSHOP_CLUSTERS=true
export DEPLOYMENT_MODE=dev
export WS_PARTICIPANT_ROLE_ARN=""
```

## Deployment

### Phase 1: Cluster Infrastructure (~15 min)

Creates 3 EKS clusters (hub + 2 spokes), VPCs for spokes, and EKS Capabilities (ACK, Kro on all clusters; ArgoCD skipped without IDC).

```bash
cd platform/infra/terraform/cluster
./deploy.sh
```

### Phase 2: Platform Addons (~20 min)

Deploys ArgoCD via Helm, ingress-nginx, CloudFront, secrets, pod identity, observability. Skips GitLab entirely.

```bash
cd platform/infra/terraform/common
./deploy.sh
```

The `deploy.sh` script automatically sets `SKIP_GITLAB=true` when `DEPLOYMENT_MODE=dev`.

### Phase 3: Verify

```bash
# Configure kubectl
aws eks update-kubeconfig --name peeks-hub --alias peeks-hub
aws eks update-kubeconfig --name peeks-spoke-dev --alias peeks-spoke-dev
aws eks update-kubeconfig --name peeks-spoke-prod --alias peeks-spoke-prod

# Check ArgoCD apps
kubectl get applications -n argocd --context peeks-hub

# Get ArgoCD URL
terraform -chdir=platform/infra/terraform/common output -json | jq -r '.ingress_domain_name.value'
```

ArgoCD is accessible at `https://<cloudfront-domain>/argocd` with credentials `admin` / `<USER1_PASSWORD>`.

## What Gets Deployed

### Hub Cluster
- ArgoCD (Helm) — manages all GitOps deployments
- Ingress-nginx + CloudFront — external access
- External Secrets — syncs secrets from AWS Secrets Manager
- Keycloak — identity management
- Backstage — developer portal (degraded without GitLab)
- Kargo, Argo Workflows, Argo Events — progressive delivery
- Crossplane — infrastructure provisioning
- Grafana Operator — observability dashboards
- KubeVela — application delivery
- JupyterHub, Ray Operator, Spark Operator — ML/AI platform
- DevLake — DORA metrics

### Spoke Clusters (dev + prod)
- External Secrets, Cert Manager, Ingress-nginx
- Argo Rollouts — progressive delivery
- Crossplane + AWS provider
- Flux, KubeVela
- Monitoring stack (Prometheus, CloudWatch, metrics)

## Known Limitations

1. **GitLab addon deploys but is non-functional** — The deploy script now automatically sets `enable_gitlab: false` in the generated tfvars when `DEPLOYMENT_MODE=dev`. On a fresh deploy, GitLab won't be deployed at all. If you see a degraded `gitlab-peeks-hub` app from a previous deploy, it will be cleaned up on the next terraform apply.

2. **Backstage requires custom image and fork** — The Backstage Docker image must be rebuilt with the config-driven auth changes (GitLab plugin removed, generic OIDC provider). Use the CodeBuild project `peeks-backstage-build` to build and push to ECR. The fork must have the chart changes (conditional auth, catalog, templates) pushed. ArgoCD reads from the fork, so chart changes take effect on push.

3. **Crossplane-AWS and KubeVela may show as Missing** — ArgoCD's server-side apply can hit nil pointer errors with large CRDs. These usually resolve with a manual sync retry. This is a pre-existing ArgoCD issue, not dev-mode-specific.

4. **Fleet secrets created differently** — In GitLab mode, spoke cluster secrets are created by the fleet-secrets ApplicationSet reading from the GitLab repo. In dev mode, they're created directly by Terraform because the public GitHub repo doesn't have the fleet member directories.

5. **No 0-init.sh** — The initialization script (`0-init.sh`) is designed for the workshop IDE environment and has dependencies on files that don't exist locally (`/etc/profile.d/workshop.sh`, `~/.bashrc.d/platform.sh`). ArgoCD auto-sync handles most of what `0-init.sh` does.

## Cleanup

Destroy in reverse order:

```bash
# 1. Platform addons
cd platform/infra/terraform/common
./destroy.sh

# 2. Cluster infrastructure
cd platform/infra/terraform/cluster
./destroy.sh
```

Then manually delete:
- S3 state bucket (if no longer needed)
- VPC and networking resources
- Security Hub can be left enabled

## Architecture Notes

### How Dev Mode Works Under the Hood

The `deployment_mode` variable (`"dev"` or `"gitlab"`) controls conditional logic across both Terraform stacks:

- **Cluster stack**: The `deployment_mode` variable is accepted but currently doesn't change cluster creation behavior. Both modes create identical clusters with `system` + `general-purpose` node pools. The ArgoCD EKS Capability is gated on Identity Center (separate from deployment_mode).

- **Common stack**: This is where the mode matters:
  - `gitlab.tf`: All GitLab resources get `count = 0` in dev mode
  - `argocd.tf`: `install = true` (Helm ArgoCD) and `server = https://kubernetes.default.svc` in dev mode
  - `secrets.tf`: Spoke cluster secrets use actual endpoint URLs + `awsAuthConfig` instead of ARNs
  - `locals.tf`: All gitops repo URLs point to GitHub instead of GitLab
  - `secrets.tf`: ExternalSecrets for spoke clusters created directly (bypassing fleet-secrets ApplicationSet)

### GitOps Bridge Data Flow (Dev Mode)

```
hub-config.yaml
    → Terraform reads cluster + addon config
    → Creates EKS clusters (cluster stack)
    → Creates Secrets Manager entries with cluster metadata (common stack)
    → Installs ArgoCD via Helm (common stack)
    → Creates hub cluster secret with labels + annotations
    → Creates spoke ExternalSecrets directly (common stack)
    → ExternalSecrets sync spoke configs from Secrets Manager → K8s secrets
    → ArgoCD ApplicationSets discover clusters via secret labels
    → Addons deployed based on enable_* labels
```

The key difference from GitLab mode: steps involving GitLab (git secrets, repo push, fleet-secrets ApplicationSet) are replaced with direct Terraform resources.
