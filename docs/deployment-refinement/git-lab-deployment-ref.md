# Platform Engineering on EKS — Deployment Deep Dive

This document captures everything about how the `platform-engineering-on-eks` repo works, how it deploys, what it creates, and how all the pieces connect. Use this as a reference when working with the source repo (`appmod-blueprints`) to understand what the deployment automation expects and produces.

---

## Two-Repo Architecture

There are two repos that work together:

| Repo | Role |
|------|------|
| `platform-engineering-on-eks` (this repo) | Bootstrap infrastructure: CDK stacks, deployment automation, workshop content, taskcat scripts |
| `appmod-blueprints` | Platform implementation: Terraform modules, EKS cluster configs, ArgoCD/GitLab/Backstage setup, GitOps workflows, application blueprints |

The relationship is: this repo creates AWS infrastructure (via CDK → CloudFormation) that includes CodeBuild projects. Those CodeBuild projects clone `appmod-blueprints` at a specific branch and run its Terraform modules to provision the actual platform.

---

## What Gets Deployed (End to End)

### Phase 1: CDK Stack → CloudFormation

The CDK code in `cdk/lib/team-stack.ts` synthesizes into a CloudFormation template. This template creates:

1. **S3 Bucket** — Terraform state backend (versioned, RETAIN on delete)
2. **IAM Shared Role** — Used by EC2, CodeBuild, Lambda, Glue. Has `AdministratorAccess` + explicit SSM permissions
3. **VPC** — IDE VPC with 1 NAT gateway, 3 AZs, public + private subnets, Kubernetes ELB tags on subnets
4. **Code Editor IDE** — EC2 instance (c5a.2xlarge, 100GB disk) running VSCode in-browser, placed in the IDE VPC. Bootstrapped with `cdk/resources/bootstrap.sh`
5. **CodeBuild Project: Clusters** — Runs `buildspec-clusters.yaml`. 120-min timeout. Creates EKS clusters (hub + spokes) and Identity Center via Terraform
6. **CodeBuild Project: GitLab/Common** — Runs `buildspec-gitlab-and-common.yaml`. 90-min timeout. Deploys GitLab, common platform services via Terraform. Has retry logic (up to 3 attempts with 60s backoff)
7. **SSM Document** — Runs `0-init.sh` on the IDE instance after infrastructure is ready
8. **Lambda: IDE Init** — Discovers the IDE instance from its ASG, waits for SSM agent, sends the SSM command
9. **Lambda: Keycloak IDC Integration** — Assumes the shared role, stores temporary credentials in SSM Parameter Store for Keycloak/IDC SAML+SCIM setup
10. **Lambda: Init Status Checker** — Reads `/<prefix>/init-status` SSM parameter after WaitCondition completes, surfaces result in CFN outputs
11. **CloudFormation WaitCondition** — 1-hour timeout. Signals success when `0-init.sh` completes (always signals success to keep stack alive; actual exit code stored in SSM)
12. **CloudWatch Log Group** — For IDE init script logs (1-week retention)

### Phase 2: CodeBuild Execution Order

The CDK dependency chain enforces this order:

```
IDE VPC created
    ↓
Clusters CodeBuild runs (depends on VPC)
  → clones appmod-blueprints at WORKSHOP_GIT_BRANCH
  → runs: identity-center/deploy.sh → cluster/deploy.sh
  → creates: EKS hub cluster, spoke-dev, spoke-prod, Identity Center config
    ↓
GitLab/Common CodeBuild runs (depends on Clusters)
  → clones appmod-blueprints at WORKSHOP_GIT_BRANCH
  → runs: common/deploy.sh (with retry)
  → creates: GitLab, secrets, GitOps repos, platform services
    ↓
SSM Document created (depends on GitLab/Common)
    ↓
IDE Init Lambda triggered (depends on SSM Document)
  → sends SSM command to IDE instance
  → runs: 0-init.sh (ArgoCD sync, GitLab repos, IDC config)
    ↓
Keycloak IDC Lambda runs (depends on SSM Document)
  → stores temporary credentials in SSM for SCIM setup
    ↓
WaitCondition completes (1hr timeout)
    ↓
Init Status Checker Lambda reads result
```

### Phase 3: What 0-init.sh Does (on the IDE instance)

Located at `appmod-blueprints/platform/infra/terraform/scripts/0-init.sh`, this script:
- Configures ArgoCD applications and waits for health
- Sets up GitLab repositories
- Configures IDC/SCIM integration
- Signals CloudFormation WaitCondition on completion

### Phase 4: What bootstrap.sh Does (on the IDE instance at creation)

Located at `cdk/resources/bootstrap.sh`, this runs during IDE instance bootstrap:
- Installs system packages (jq, git, python3, npm, zsh, htop, etc.)
- Installs `mise` tool manager with pinned version, configures it for interactive/non-interactive shells
- Via mise, installs: kubectl, helm, terraform, go, argocd CLI, yq, k9s, kubectx, fzf, gh, task, node, python, uv, yarn
- Manually installs: kubectl-argo-rollouts, kubevela, eks-node-viewer, krew (+ stern, np-viewer plugins), chainsaw
- Clones `appmod-blueprints` repo at `WORKSHOP_GIT_BRANCH` into `/home/ec2-user/environment/<WORKING_REPO>`
- Installs oh-my-zsh with powerlevel10k theme
- Installs Kiro CLI and configures it
- Sets up `.bashrc.d/` scripts with all environment variables
- Creates `/etc/profile.d/workshop.sh` for non-interactive shells (SSM document execution)
- Configures git safe.directory and user identity

---

## Environment Variables — The Full Chain

### Where They Originate (Developer's Machine)

These env vars must be set before running CDK synth or taskcat deploy:

| Variable | Purpose | Default | Required |
|----------|---------|---------|----------|
| `AWS_PROFILE` | AWS CLI profile name | `taskcat` | Yes |
| `AWS_REGION` | Target AWS region | `us-west-2` | Yes |
| `WORKSHOP_GIT_BRANCH` | Branch of appmod-blueprints to deploy | `riv25` | Yes |
| `PARTICIPANT_ROLE_ARN` | IAM role ARN for participant access | None | Yes (for taskcat) |
| `RESOURCE_PREFIX` | Naming prefix for all resources | `peeks` | No |
| `WORKSHOP_GIT_URL` | Git URL for appmod-blueprints | `https://github.com/aws-samples/appmod-blueprints` | No |
| `FORCE_DELETE_VPC` | Whether to force-delete VPCs on destroy | `false` | No |

### How They Flow Through the System

```
Developer's shell (exports / .mise.toml / .envrc)
    ↓
Taskfile.yaml (reads from env, applies defaults)
    ↓
yarn generate-cfn-self (CDK synth — reads process.env in team-stack.ts)
    ↓
CloudFormation template (values baked into template at synth time)
    ↓
CodeBuild environment variables (set in CDK construct)
    ↓
Terraform modules (read from CodeBuild env)
    ↓
bootstrap.sh on IDE instance (values injected via Fn::Sub)
    ↓
.bashrc.d/platform.sh + /etc/profile.d/workshop.sh (persisted on IDE)
    ↓
0-init.sh (reads from profile.d on the IDE instance)
```

Critical insight: `WORKSHOP_GIT_BRANCH` is baked into the CloudFormation template at CDK synth time. If you change the branch after synth but before deploy, the template still has the old branch. You must re-run `yarn generate-cfn-self` after changing the branch.

### CDK Defaults (team-stack.ts)

```typescript
const DEFAULT_WORKSHOP_GIT_URL = "https://github.com/aws-samples/appmod-blueprints";
const DEFAULT_WORKSHOP_GIT_BRANCH = "riv25";
const DEFAULT_FORCE_DELETE_VPC = "false";
const DEFAULT_RESOURCE_PREFIX = "peeks";
const DEFAULT_GIT_USERNAME = "user1";
const DEFAULT_WORKING_REPO = "platform-on-eks-workshop";
const DEFAULT_WORKSHOP_CLUSTERS = "true";
```

---

## CDK Synth Modes

The CDK has two synth modes controlled by `CDK_SYNTH_MODE`:

| Mode | Env Var Value | What It Does |
|------|--------------|--------------|
| Self-serve | `SELF_SERVE_SYNTH` | Adds `ParticipantAssumedRoleArn` as a CFN parameter. Used for taskcat/local deployment |
| Workshop Studio | `WS_SYNTH` | Gets participant role from Workshop Studio context. Used for AWS Workshop Studio |

The `yarn generate-cfn-self` script sets `CDK_SYNTH_MODE=SELF_SERVE_SYNTH` and also sets `FORCE_DELETE_VPC=true` and a hardcoded `WORKSHOP_ID`.

Output files:
- `assets/peeks-workshop-team-stack-self.json` — Used by taskcat for local deployment
- `static/peeks-workshop-team-stack.json` — Used by Workshop Studio

---

## TaskCat Deployment Flow

TaskCat is a Python tool that deploys CloudFormation templates. The flow:

1. `yarn generate-cfn-self` → synthesizes CDK → produces `assets/peeks-workshop-team-stack-self.json`
2. Template is copied to `taskcat/templates/team-stack.yaml`
3. `taskcat/.taskcat.yml` configures: region, auth profile, test parameters (including `ParticipantAssumedRoleArn`)
4. `taskcat deploy run --regions us-west-2` creates the CloudFormation stack
5. `run-deploy.sh` waits for `stack-create-complete`

The `.taskcat.yml` is dynamically updated by the Taskfile before each run to inject the correct region, profile, and role ARN.

---

## The Taskfile — Key Tasks

```yaml
# Core deployment
task install          # npm install aws-cdk && yarn install
task bootstrap        # cdk bootstrap (first time only)
task cfn              # lint → generate-cfn-self → generate-cfn-studio → copy to taskcat/templates
task taskcat-deploy   # generate-cfn-self → update .taskcat.yml → run-deploy.sh
task taskcat-delete   # delete CloudFormation stack
task taskcat-validate # validate EKS clusters and ArgoCD apps

# Cleanup
task taskcat-clean-deployment          # validate + cleanup conflicting resources
task taskcat-clean-deployment-force    # force cleanup without prompts
task taskcat-clean-deployment-preview  # dry-run preview

# Validation
task taskcat-check    # pre-deployment validation only
```

### Taskfile Variable Resolution

```yaml
vars:
  AWS_REGION: '{{env "AWS_REGION" | default .AWS_REGION | default "us-west-2"}}'
  AWS_PROFILE: '{{.AWS_PROFILE | default (env "AWS_PROFILE") | default "taskcat"}}'
  PARTICIPANT_ROLE_ARN: '{{.PARTICIPANT_ROLE_ARN | default (env "PARTICIPANT_ROLE_ARN")}}'
  RESOURCE_PREFIX: '{{.RESOURCE_PREFIX | default "peeks"}}'
```

Variables can be overridden via: CLI args > env vars > defaults.

---

## GitLabCIRole — What It Is and Why

The `scripts/setup-gitlab-aws-role.sh` script creates:

1. An IAM user `gitlab-ci-user` with permission to assume a role
2. An IAM role `GitLabCIRole` with broad permissions (EKS, S3, CloudFormation, EC2, IAM, etc.)
3. Access keys for the user

This role is used as the `ParticipantAssumedRoleArn` parameter in the CloudFormation template. It's the identity that CodeBuild and other services use to interact with AWS resources during deployment.

The role has: `AdministratorAccess`-equivalent permissions via a combination of managed policies and inline policies covering EKS, S3, CloudFront, CloudFormation, EC2, IAM, DynamoDB, SSM, Secrets Manager, Lambda, Logs, KMS, CodeBuild, and Security Hub.

---

## Resource Naming Convention

All resources use the `RESOURCE_PREFIX` (default: `peeks`) as a naming prefix:

| Resource | Name Pattern |
|----------|-------------|
| EKS Hub Cluster | `<prefix>-hub-cluster` |
| EKS Spoke Dev | `<prefix>-spoke-dev` |
| EKS Spoke Prod | `<prefix>-spoke-prod` |
| Terraform State Bucket | `<PREFIX>-TFStateBackendBucket` (CDK-generated name) |
| Secrets Manager | `<prefix>-gitops-addons`, `<prefix>-gitops-fleet`, etc. |
| SSM Parameters | `<prefix>-argocd-central-role`, `/<prefix>/init-status`, etc. |
| CloudFormation Stack | `tCaT-peeks-workshop-test-*` (taskcat adds prefix) |
| CodeBuild Projects | `<PREFIX>-Clusters`, `<PREFIX>-Bootstrap` |
| IDE Instance | Tagged with `<prefix>` |

---

## The appmod-blueprints Terraform Modules

The CodeBuild projects clone appmod-blueprints and run these Terraform modules in order:

### 1. Identity Center (`identity-center/deploy.sh`)
- Sets up AWS IAM Identity Center
- Creates users and groups
- Run by the Clusters CodeBuild project

### 2. Cluster (`cluster/deploy.sh`)
- Creates EKS hub cluster in the IDE VPC (reuses VPC via `HUB_VPC_ID` and `HUB_SUBNET_IDS`)
- Creates spoke-dev and spoke-prod clusters in their own VPCs
- Configures EKS addons, node groups
- Run by the Clusters CodeBuild project

### 3. Common (`common/deploy.sh`)
- Creates shared secrets in AWS Secrets Manager
- Sets up GitOps repositories in GitLab
- Deploys GitLab, ArgoCD, Backstage, monitoring stack
- Configures the GitOps Bridge (passes infrastructure metadata to Kubernetes secrets)
- Run by the GitLab/Common CodeBuild project

### Key Terraform Environment Variables (passed from CodeBuild)

```
TFSTATE_BUCKET_NAME    — S3 bucket for Terraform state
WORKSHOP_GIT_URL       — appmod-blueprints repo URL
WORKSHOP_GIT_BRANCH    — branch to checkout
FORCE_DELETE_VPC       — whether to force-delete VPCs
RESOURCE_PREFIX        — naming prefix
HUB_VPC_ID             — IDE VPC ID (hub cluster goes here)
HUB_SUBNET_IDS         — IDE VPC private subnet IDs
GIT_PASSWORD           — IDE password (used for GitLab auth)
IDE_PASSWORD           — same as GIT_PASSWORD
GIT_USERNAME           — default: user1
WORKING_REPO           — default: platform-on-eks-workshop
WS_PARTICIPANT_ROLE_ARN — participant IAM role
WORKSHOP_CLUSTERS      — default: true
```

---

## GitOps Bridge — How Infrastructure Connects to Apps

The GitOps Bridge is the mechanism that passes infrastructure metadata from Terraform to ArgoCD:

1. Terraform creates EKS clusters and writes metadata to AWS Secrets Manager
2. External Secrets Operator (ESO) syncs those secrets into Kubernetes secrets on the hub cluster
3. ArgoCD ApplicationSets use cluster generator to discover clusters via those secrets
4. ApplicationSets deploy apps to the right clusters based on labels/annotations

### Cluster Registration Secret Structure

Each cluster gets a secret in Secrets Manager:
```json
{
  "cluster_name": "spoke-dev-us-west-2",
  "cluster_endpoint": "https://...",
  "environment": "dev",
  "tenant": "platform-team",
  "cluster_type": "spoke",
  "resource_prefix": "peeks",
  "labels": { "environment": "dev", "cluster-type": "spoke" },
  "annotations": { "addons_repo_basepath": "gitops/addons/", "kustomize_path": "environments/dev" }
}
```

### Secret Naming Convention

```
{resource_prefix}-{service}-{type}-password
```

Examples:
- `peeks-workshop-gitops-keycloak-admin-password`
- `peeks-workshop-gitops-backstage-postgresql-password`

---

## What the Final Platform Looks Like

After successful deployment, you get:

| Component | Where | Access |
|-----------|-------|--------|
| VSCode IDE | EC2 instance via CloudFront | Browser URL + auto-generated password |
| ArgoCD | Hub EKS cluster | In-cluster, accessible from IDE |
| GitLab | Hub EKS cluster | In-cluster, accessible from IDE |
| Backstage | Hub EKS cluster | In-cluster, accessible from IDE |
| Grafana/Monitoring | Hub EKS cluster | In-cluster |
| Hub EKS Cluster | `<prefix>-hub-cluster` | kubectl from IDE |
| Spoke Dev Cluster | `<prefix>-spoke-dev` | kubectl from IDE |
| Spoke Prod Cluster | `<prefix>-spoke-prod` | kubectl from IDE |

CloudFormation Outputs:
- `IdeUrl` — URL to access the VSCode IDE
- `IdePassword` — auto-generated password
- `InitScriptStatus` — SUCCESS or FAILED with exit code

---

## Deployment Timeline

| Phase | Duration | What Happens |
|-------|----------|-------------|
| CDK Synth | ~30s | Generates CloudFormation template |
| CloudFormation Stack Creation | ~5 min | Creates VPC, IAM, S3, IDE instance |
| IDE Bootstrap | ~10 min | Installs tools, clones repos |
| Clusters CodeBuild | ~30 min | Creates 3 EKS clusters + Identity Center |
| GitLab/Common CodeBuild | ~20 min | Deploys GitLab, platform services |
| 0-init.sh | ~15 min | ArgoCD sync, GitLab repos, IDC config |
| Total | ~45-60 min | Full platform ready |

---

## Cleanup — What Gets Deleted

The enhanced cleanup system (`taskcat/scripts/enhanced-cleanup/`) handles:

- CloudWatch Log Groups (`/aws/eks/peeks-*`, `/aws/containerinsights/peeks-*`)
- EKS Clusters (hub, spoke-dev, spoke-prod + nodegroups + addons)
- CloudFormation Stacks (`peeks-workshop-test`, `tCaT-peeks-*`)
- EC2 Instances (IDE instances with peeks tags)
- Secrets Manager Secrets (`<prefix>-gitops-*`)
- SSM Parameters (`<prefix>-*`)
- DynamoDB Tables, Lambda Functions, IAM Roles
- ECR Repositories
- CloudFront Distributions + Policies
- S3 Buckets (with `--force` flag)
- VPCs and all network resources (IGWs, NAT gateways, subnets)
- KMS Aliases

Resource patterns matched: `peeks`, `tcat`, `tCaT`, `PEEKS`, `TCAT`, `peeks-workshop`, `tCaT-peeks`, `tcat-peeks`

---

## Known Failure Points and Gotchas

### Environment Variable Fragility
- `is assume` (Isengard) launches a subshell that doesn't load mise, so env vars disappear
- Stale `AWS_ACCESS_KEY_ID` in shell conflicts with profile-based auth
- `WORKSHOP_GIT_BRANCH` must match between CDK synth and the actual branch on remote

### CDK Synth Timing
- Branch is baked into the template at synth time. Changing the branch after synth but before deploy means the template has the wrong branch
- Must re-run `yarn generate-cfn-self` after any env var change

### 0-init.sh Timeout
- WaitCondition has 1-hour timeout
- Script always signals CFN success (to keep stack alive), but stores real exit code in SSM
- Check `/<prefix>/init-status` SSM parameter for actual result

### Python Version for TaskCat
- `networkx==3.6.1` requires Python 3.11+
- macOS default Python 3.10 won't work
- Must create venv with explicit Python 3.11: `/opt/homebrew/bin/python3.11 -m venv .venv`
- Use `.venv/bin/python -m pip install` (not bare `pip`) to ensure correct Python

### IAM Propagation
- GitLabCIRole creation needs ~15s for IAM propagation before it can be used
- The setup script has retry logic for this

### Security Hub
- Must be enabled before deployment
- Terraform modules create Security Hub insights that fail if it's not enabled

---

## Local Deployment Prerequisites (macOS)

### One-Time Installs

| Tool | Install Command | Verify | Notes |
|------|----------------|--------|-------|
| AWS CLI v2 | `brew install awscli` | `aws --version` | |
| Task | `brew install go-task/tap/go-task` | `task --version` | |
| Node.js 20+ | `nvm install 20` | `node --version` | nvm must be loaded per-terminal |
| Yarn | Comes with Node via corepack or `npm install -g yarn` | `yarn --version` | |
| AWS CDK | `npm install -g aws-cdk` | `cdk --version` | Also installed locally by `task install` |
| mise | `curl https://mise.run \| sh` | `mise --version` | Add `eval "$(mise activate zsh)"` to ~/.zshrc |
| jq | `brew install jq` | `jq --version` | |
| yq | `brew install yq` | `yq --version` | |
| Python 3.11+ | `brew install python@3.11` | `python3.11 --version` | For taskcat venv |

### Per-Project Setup (once per clone)

```bash
# Create Python venv with correct version
/opt/homebrew/bin/python3.11 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt

# Verify
.venv/bin/python --version    # 3.11.x
.venv/bin/taskcat --version   # 0.9.58

# Activate venv (needed per terminal session)
source .venv/bin/activate
```

### Per-Terminal Session

```bash
# Load nvm (if not in .zshrc)
export NVM_DIR="$HOME/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

# Activate Python venv
source .venv/bin/activate

# Load mise (if not in .zshrc)
eval "$(mise activate zsh)"
```

### When to Redo the Venv

- After deleting `.venv/`
- After fresh clone
- After `requirements.txt` changes
- NOT needed between terminal sessions (venv persists on disk, just re-activate)

---

## File Map — What's Where and Why

```
platform-engineering-on-eks/
├── cdk/
│   ├── bin/cdk.ts                    # CDK app entry point — creates TeamStack + CentralAccountStack
│   ├── lib/
│   │   ├── team-stack.ts             # THE main infrastructure definition — everything starts here
│   │   ├── central-stack.ts          # Central account stack (mostly empty, for Workshop Studio)
│   │   └── index.ts                  # Exports both stacks
│   ├── resources/
│   │   ├── bootstrap.sh              # IDE instance bootstrap — installs all tools, clones repos
│   │   ├── buildspec-clusters.yaml   # CodeBuild: creates EKS clusters + Identity Center
│   │   ├── buildspec-gitlab-and-common.yaml  # CodeBuild: deploys GitLab + platform services
│   │   ├── lambda.py                 # Lambda: discovers IDE instance, sends SSM command
│   │   └── keycloak-idc-integration-credentials-lambda.py  # Lambda: stores IDC creds in SSM
│   ├── package.json                  # CDK dependencies
│   └── cdk.json                      # CDK config
├── taskcat/
│   ├── .taskcat.yml                  # TaskCat config — region, profile, test parameters
│   ├── templates/                    # Generated CFN templates go here
│   └── scripts/
│       ├── run-deploy.sh             # Main deployment script — runs taskcat, waits for stack
│       ├── delete-stack.sh           # Stack deletion
│       ├── clean-deployment.sh       # Resource cleanup
│       ├── enhanced-cleanup/         # Comprehensive cleanup system
│       ├── validate-*.sh             # Various validation scripts
│       └── check-*.sh               # Pre-deployment checks
├── assets/
│   ├── peeks-workshop-team-stack-self.json    # Generated CFN template (self-serve mode)
│   └── peeks-workshop-central-stack-self.json # Generated central stack template
├── static/
│   ├── peeks-workshop-team-stack.json         # Generated CFN template (Workshop Studio mode)
│   └── peeks-workshop-central-stack.json      # Generated central stack template
├── scripts/
│   ├── setup-gitlab-aws-role.sh      # Creates GitLabCIRole IAM role + user
│   └── deploy/                       # (empty — planned for deploy CLI)
├── content/                          # Workshop content (markdown tutorials)
├── Taskfile.yaml                     # Task runner — all deployment commands
├── package.json                      # Root package.json — yarn workspaces, synth/deploy scripts
├── requirements.txt                  # Python deps (taskcat + dependencies)
├── contentspec.yaml                  # Workshop Studio configuration
├── .envrc.example                    # Example environment variables
├── deploy-config.example.yaml        # Example deploy config (planned)
└── Deployment Process Docs/
    └── deploy-cli-strategy.md        # Planned deployment CLI improvement
```

---

## package.json Scripts — The CDK Pipeline

Key scripts in the root `package.json`:

```
yarn synth-self          → CDK synth in SELF_SERVE mode (for taskcat/local deploy)
yarn synth-studio        → CDK synth in WS_SYNTH mode (for Workshop Studio)
yarn generate-cfn-self   → synth-self + copy templates to assets/
yarn generate-cfn-studio → synth-studio + copy templates to static/
yarn deploy              → cdk deploy with ParticipantAssumedRoleArn parameter
yarn destroy             → cdk destroy
```

The `generate-cfn-self` script is the critical one for local deployment. It:
1. Sets `CDK_SYNTH_MODE=SELF_SERVE_SYNTH`
2. Passes `WORKSHOP_GIT_URL`, `WORKSHOP_GIT_BRANCH`, `FORCE_DELETE_VPC=true`
3. Runs `cdk synth`
4. Copies output to `assets/peeks-workshop-team-stack-self.json`

---

## contentspec.yaml — Workshop Studio Integration

```yaml
infrastructure:
  cloudformationTemplates:
    - templateLocation: static/peeks-workshop-team-stack.json
      parameters:
        - templateParameter: ParticipantAssumedRoleArn
          defaultValue: '{{.ParticipantAssumedRoleArn}}'
        - templateParameter: AssetsBucketName
          defaultValue: "{{.AssetsBucketName}}"
        - templateParameter: AssetsBucketPrefix
          defaultValue: "{{.AssetsBucketPrefix}}"
```

Workshop Studio deploys the template from `static/` (not `assets/`). The `assets/` version is for local/taskcat deployment. The `static/` version is for Workshop Studio and doesn't include `FORCE_DELETE_VPC` or the hardcoded workshop ID.

---

## How to Apply This Knowledge to appmod-blueprints

When working directly with the `appmod-blueprints` repo, here's what matters:

### The Terraform Modules Expect These Environment Variables

Set these before running any Terraform module:

```bash
export TFSTATE_BUCKET_NAME="<your-s3-bucket>"
export RESOURCE_PREFIX="peeks"
export AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export WORKSHOP_GIT_URL="https://github.com/aws-samples/appmod-blueprints"
export WORKSHOP_GIT_BRANCH="<your-branch>"
export HUB_VPC_ID="<vpc-id>"           # Only if reusing existing VPC for hub
export HUB_SUBNET_IDS="['subnet-1','subnet-2']"  # Only if reusing existing VPC
export GIT_PASSWORD="<password>"        # Used for GitLab auth
export GIT_USERNAME="user1"
export IDE_PASSWORD="<password>"        # Same as GIT_PASSWORD typically
export WORKING_REPO="platform-on-eks-workshop"
export WORKSHOP_CLUSTERS="true"
```

### The Terraform Module Execution Order

```bash
# 1. Identity Center (creates IAM Identity Center users/groups)
cd platform/infra/terraform/identity-center
./deploy.sh

# 2. Clusters (creates EKS hub + spoke clusters)
cd platform/infra/terraform/cluster
./deploy.sh

# 3. Common (deploys GitLab, secrets, GitOps repos, platform services)
cd platform/infra/terraform/common
./deploy.sh

# 4. Init (ArgoCD sync, GitLab repos, IDC config — normally run on IDE instance)
cd platform/infra/terraform/scripts
./0-init.sh
```

### The Destroy Order (Reverse)

```bash
cd platform/infra/terraform/common && ./destroy.sh
cd platform/infra/terraform/cluster && ./destroy.sh
cd platform/infra/terraform/identity-center && ./destroy.sh
```

### What the Hub Cluster Needs

- VPC with private subnets tagged `kubernetes.io/role/internal-elb: 1`
- Public subnets tagged `kubernetes.io/role/elb: 1`
- NAT gateway for outbound internet access
- The hub cluster hosts: ArgoCD, GitLab, Backstage, monitoring, ingress controllers

### What Spoke Clusters Need

- Their own VPCs (created by the cluster Terraform module)
- Registration in AWS Secrets Manager (for ArgoCD discovery)
- Ingress controllers for application access

---

## Cost Estimate

| Resource | Approximate Daily Cost |
|----------|----------------------|
| EKS Clusters (3) | ~$14.40/day ($0.20/hr × 3) |
| EC2 Instances (IDE c5a.2xlarge + node groups) | ~$5-15/day |
| NAT Gateways (3-4) | ~$3-4/day |
| CloudFront | ~$0.10/day |
| S3, EBS, other | ~$1-2/day |
| Total | ~$25-35/day |

Always run `task taskcat-delete` or `task taskcat-clean-deployment-force` when done.
