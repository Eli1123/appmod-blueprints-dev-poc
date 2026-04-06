# Local Deployment Guide

How to deploy this platform from a local machine (not the CloudFormation-bootstrapped IDE).

## Prerequisites

### Tools (one-time install)

| Tool | Version | Purpose |
|------|---------|---------|
| AWS CLI | 2.17+ | AWS API access |
| Terraform | 1.5+ | Infrastructure provisioning |
| kubectl | 1.30+ | Kubernetes cluster management |
| Helm | 3.x | Chart dependency management |
| yq | 4.x | YAML processing (used by deploy scripts and utils.sh) |
| jq | 1.6+ | JSON processing |
| git | 2.x | Source control |
| Node.js + yarn | 18+ | CFN template generation, Backstage |
| Python 3 | 3.9+ | Identity Center config, ArgoCD token automation |
| CDK | 2.x | CloudFormation stack bootstrapping |
| go-task | 3.x | Task runner (Taskfile.yml) |

The `.devcontainer.json` in the repo root provides a base Ubuntu image with docker, kind, kubectl, helm, AWS CLI, and Terraform — but it's missing yq, jq, Node.js, yarn, Python, CDK, and go-task. If using devcontainers, you'll need to install those manually or extend the config.

### AWS Account Setup (one-time per account)

1. An AWS account with permissions to create EKS clusters, VPCs, IAM roles, AMP workspaces, CloudFront distributions, etc.
2. Security Hub enabled in the target region:
   ```bash
   aws securityhub enable-security-hub --region us-west-2
   ```
3. A VPC and subnets for the hub cluster (the spoke clusters create their own VPCs via Terraform).
4. An S3 bucket for Terraform state:
   ```bash
   aws s3api create-bucket --bucket <unique-bucket-name> --region us-west-2 \
     --create-bucket-configuration LocationConstraint=us-west-2
   ```

### GitLabCIRole (one-time per account)

The deployment creates a GitLab instance that needs an IAM role to interact with AWS:

```bash
bash scripts/setup-gitlab-aws-role.sh
```

This often fails on first run due to IAM propagation. Wait 15 seconds and run it again.

Verify:
```bash
aws iam get-role --role-name GitLabCIRole --query 'Role.Arn'
```

## Environment Variables

These must be set before running any deployment scripts. The deploy scripts source `utils.sh` which reads most of these.

### Required

| Variable | Example | Where it's used |
|----------|---------|-----------------|
| `RESOURCE_PREFIX` | `peeks` | Naming prefix for all resources. Default: `peeks` |
| `AWS_REGION` | `us-west-2` | Target region. Default: `us-west-2` |
| `USER1_PASSWORD` (or `IDE_PASSWORD`) | `<your-password>` | ArgoCD admin, Keycloak users, GitLab auth |
| `HUB_VPC_ID` | `vpc-0abc123` | VPC for the hub cluster |
| `HUB_SUBNET_IDS` | `'["subnet-aaa","subnet-bbb"]'` | Private subnets for the hub cluster |
| `TFSTATE_BUCKET_NAME` | `my-tf-state-bucket` | S3 bucket for Terraform remote state |

### Optional / Auto-detected

| Variable | Default | Notes |
|----------|---------|-------|
| `WORKSHOP_GIT_BRANCH` | `main` | Git branch to deploy. Only relevant for CFN-based deploys |
| `GIT_USERNAME` | `user1` | GitLab username |
| `PARTICIPANT_ROLE_ARN` | (none) | IAM role ARN for workshop participants. Only needed for CFN-based deploys |
| `WORKSHOP_CLUSTERS` | `false` | Set to `true` if deploying via the workshop CloudFormation stack. Prefixes cluster names with `RESOURCE_PREFIX` |
| `WS_PARTICIPANT_ROLE_ARN` | (none) | Passed to Terraform for EKS access entries |
| `SKIP_GITLAB` | `false` | Skip GitLab infrastructure deployment |

### Identity Center (optional)

If your account has IAM Identity Center enabled, the cluster deploy script auto-detects it. If you want to use it:

```bash
cd platform/infra/terraform/identity-center
./deploy.sh
```

This creates SSO groups (admin, editor, viewer) used by the EKS ArgoCD Managed Capability. If Identity Center is not configured, ArgoCD still works but without SSO integration.

## Deployment Phases

The platform deploys in 4 sequential phases. Each phase has its own `deploy.sh` script with built-in retry logic. Never run `terraform apply` directly — always use the scripts.

### Phase 1: Cluster Infrastructure (~20-30 min)

Creates 3 EKS clusters (hub, spoke-dev, spoke-prod), VPCs for spokes, EKS Managed Capabilities (ArgoCD, ACK, Kro), and IAM roles.

```bash
cd platform/infra/terraform/cluster
./deploy.sh
```

What can go wrong:
- EKS Managed Capabilities (ArgoCD, ACK, Kro) can occasionally get stuck in `CREATING` state. This is a transient AWS service-side issue. Delete the stack and redeploy.
- Identity Center groups must exist before this step if you want SSO-enabled ArgoCD.

### Phase 2: Platform Addons (~15-20 min)

Deploys GitLab, ArgoCD bootstrap config, Keycloak, External Secrets, AMP scrapers, Grafana workspace, pod identity associations, and pushes the repo to GitLab.

```bash
cd platform/infra/terraform/common
./deploy.sh
```

What can go wrong:
- AMP Prometheus Scrapers can get stuck in `CREATING` (same transient issue as capabilities).
- GitLab Helm install can timeout on first attempt — the script retries 3 times.
- Stale Terraform state locks from previous failed runs — the script auto-detects and force-unlocks.

### Phase 3: Platform Initialization (~10-15 min)

Waits for ArgoCD to be ready, syncs all ApplicationSets, configures Identity Center integration, retrieves ArgoCD auth token, initializes GitLab repos, and runs health checks.

```bash
cd platform/infra/terraform/scripts
./0-init.sh
```

This script:
- Verifies all 3 clusters are reachable
- Fixes EKS security group self-referencing rules if missing
- Waits up to 30 min for ArgoCD EKS capability to become ready
- Creates the `default` AppProject if missing
- Configures IAM Identity Center (if available)
- Syncs ArgoCD applications with dependency awareness
- Runs `recover-argocd-apps.sh` for any stuck apps
- Initializes GitLab with `2-gitlab-init.sh`
- Runs `check-workshop-setup.sh` for final validation

### Phase 4: Access Platform Services

Get URLs and credentials for all platform tools:

```bash
cd platform/infra/terraform/scripts
./1-tools-urls.sh
```

Displays a table with URLs and credentials for ArgoCD, Backstage, Kargo, Argo Workflows, JupyterHub, Keycloak, GitLab, and Grafana.

## Deployment via CloudFormation (alternative)

For automated/CI deployments, the platform can be deployed via a CloudFormation stack that wraps all the above phases into a single CodeBuild job:

```bash
# Generate the CFN template
yarn generate-cfn-self

# Copy to taskcat templates
cp ./assets/peeks-workshop-team-stack-self.json taskcat/templates/team-stack.yaml

# Verify the branch is correct
grep '"WORKSHOP_GIT_BRANCH": "' taskcat/templates/team-stack.yaml

# Bootstrap CDK
cdk bootstrap aws://<account-id>/<region> --profile <profile>

# Deploy
task install
task taskcat-deploy
```

This is what the workshop uses. The CFN stack creates the IDE, clones the repo, and runs the deploy scripts inside CodeBuild. The entire process takes ~60-90 minutes.

## Cleanup

Destroy in reverse order:

```bash
# 1. Platform addons
cd platform/infra/terraform/common
./destroy.sh

# 2. Cluster infrastructure
cd platform/infra/terraform/cluster
./destroy.sh

# 3. Identity Center (if deployed)
cd platform/infra/terraform/identity-center
./destroy.sh
```

For failed deployments with orphaned resources, use:
```bash
task taskcat-clean-deployment-force
```

## Configuration

All cluster and addon configuration lives in `platform/infra/terraform/hub-config.yaml`. Edit this before deploying to enable/disable addons, change Kubernetes versions, or modify cluster settings.

Key sections:
- `clusters.hub` — control-plane cluster with ArgoCD, Backstage, Keycloak, etc.
- `clusters.spoke1` — dev environment
- `clusters.spoke2` — prod environment
- Each cluster has an `addons` block with `enable_*` flags

## Known Issues

- AMP Scrapers and EKS Managed Capabilities can randomly get stuck in `CREATING` during provisioning. This is an AWS service-side issue (~0.4% failure rate across 250 deployments). Fix: delete the stack and redeploy.
- The `is assume` tool (or similar AWS profile switchers) can clobber environment variables needed by the deploy scripts. Always verify `aws sts get-caller-identity` matches your target account before deploying.
- `DNS_DEV` and `DNS_PROD` environment variables are not set by any script. If you need them for validation, manually export the spoke cluster ingress ALB hostnames.
