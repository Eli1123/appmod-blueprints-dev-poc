# Dev Deployment Path — Design Document

## Goal

A deployment path that works from a bare AWS account without Identity Center or GitLab. ArgoCD installed via Helm, gitops repos point to GitHub directly.

## What the GitLab Path Taught Us

The GitLab deployment path works but requires 7 code changes and several manual steps. The key insight is that the platform was designed around two assumptions:
1. EKS Managed ArgoCD (requires Identity Center)
2. GitLab as the git server (deployed in-cluster)

Removing both of these requires changes at the Terraform level, not just the deploy scripts.

## Design: DEPLOYMENT_MODE Variable

Add a `deployment_mode` variable to the common Terraform stack:

```hcl
variable "deployment_mode" {
  description = "Deployment mode: 'gitlab' (full platform with GitLab) or 'dev' (minimal, GitHub-based)"
  type        = string
  default     = "gitlab"
  validation {
    condition     = contains(["gitlab", "dev"], var.deployment_mode)
    error_message = "deployment_mode must be 'gitlab' or 'dev'"
  }
}
```

### What changes per mode

| Component | GitLab Mode | Dev Mode |
|-----------|-------------|----------|
| ArgoCD | EKS Capability (if IDC) or Helm | Always Helm |
| GitLab | Deployed in-cluster | Skipped entirely |
| Git repos | GitLab CloudFront URLs | GitHub URLs |
| ArgoCD git secrets | GitLab PAT | GitHub PAT or public repo |
| Cluster secret server | ARN (if EKS Capability) or endpoint | Always endpoint |
| Cluster secret config | Empty (if EKS Capability) or awsAuthConfig | Always awsAuthConfig |
| Node pools | system (if EKS Capability) or system+general-purpose | Always system+general-purpose |
| Backstage | Full with GitLab integration | Minimal or skipped |
| Keycloak | Full with IDC SAML | Minimal or skipped |

### Terraform Changes Required

#### `cluster/main.tf`
```hcl
compute_config = {
  enabled    = true
  node_pools = var.deployment_mode == "dev" ? ["system", "general-purpose"] : ["system"]
}
```

#### `common/argocd.tf`
```hcl
module "gitops_bridge_bootstrap" {
  install = var.deployment_mode == "dev" ? true : false
  
  cluster = {
    server = var.deployment_mode == "dev" ? "https://kubernetes.default.svc" : data.aws_eks_cluster.clusters[local.hub_cluster_key].arn
  }
}
```

#### `common/gitlab.tf`
```hcl
data "gitlab_user" "workshop" {
  count    = var.deployment_mode == "dev" ? 0 : 1
  username = local.git_username
}

resource "gitlab_personal_access_token" "workshop" {
  count      = var.deployment_mode == "dev" ? 0 : 1
  user_id    = data.gitlab_user.workshop[0].id
  # ...
}

locals {
  gitlab_token = var.deployment_mode == "dev" ? "" : gitlab_personal_access_token.workshop[0].token
}
```

#### `common/secrets.tf`
```hcl
server = each.value.environment != "control-plane" ? (
  var.deployment_mode == "dev" ? data.aws_eks_cluster.clusters[each.key].endpoint : data.aws_eks_cluster.clusters[each.key].arn
) : ""

config = each.value.environment != "control-plane" ? (
  var.deployment_mode == "dev" ? jsonencode({
    awsAuthConfig = { clusterName = each.value.name, roleARN = aws_iam_role.spoke[each.key].arn }
    tlsClientConfig = { insecure = false, caData = data.aws_eks_cluster.clusters[each.key].certificate_authority[0].data }
  }) : jsonencode({ tlsClientConfig = { insecure = false } })
) : jsonencode({ tlsClientConfig = { insecure = false } })
```

#### `common/locals.tf`
```hcl
gitops_addons_repo_url = var.deployment_mode == "dev" ? var.repo.url : (
  local.gitlab_domain_name != "" ? "https://${local.gitlab_domain_name}/${var.git_username}/platform-on-eks-workshop.git" : var.repo.url
)
```

#### `common/argocd.tf` (git secrets)
```hcl
resource "kubernetes_secret" "git_secrets" {
  count = var.deployment_mode == "dev" ? 0 : 1
  # ... (skip GitLab-specific secrets in dev mode)
}
```

For dev mode, if the GitHub repo is public, no git secrets are needed. If private, a GitHub PAT would be configured instead.

#### `common/deploy.sh`
```bash
if [[ "${DEPLOYMENT_MODE:-gitlab}" == "dev" ]]; then
  export SKIP_GITLAB=true
fi
```

### What Gets Skipped in Dev Mode

- GitLab infrastructure (NLB, CloudFront, Helm chart)
- GitLab user/token creation
- GitLab-specific ArgoCD git secrets
- GitLab repo push
- Identity Center configuration
- ArgoCD token automation (browser-based)

### What Still Works in Dev Mode

- All 3 EKS clusters
- ArgoCD (via Helm) with full ApplicationSet-based addon management
- All addons (Crossplane, Kro, ACK, ingress-nginx, cert-manager, etc.)
- Backstage (pointing to GitHub instead of GitLab)
- Keycloak (without IDC SAML)
- Grafana, AMP, observability stack
- Spoke cluster management

### Implementation Priority

1. Add `deployment_mode` variable
2. Make `gitlab.tf` conditional
3. Make `secrets.tf` mode-aware (endpoints vs ARNs, auth config)
4. Make `argocd.tf` mode-aware (install flag, server URL)
5. Make `locals.tf` mode-aware (repo URLs)
6. Make `deploy.sh` mode-aware (skip GitLab steps)
7. Make `cluster/main.tf` mode-aware (node pools)
8. Update `0-init.sh` to skip GitLab-specific steps in dev mode
9. Handle macOS compatibility (timeout, grep -P, sed -i, platform.sh)

### Testing Strategy

Deploy dev mode to the same account (after cleaning up the GitLab deployment) or a separate account. Verify:
- [ ] All 3 clusters created with general-purpose nodes
- [ ] ArgoCD installed via Helm and syncing
- [ ] All addons deployed to hub and spokes
- [ ] Backstage accessible (even without GitLab)
- [ ] No GitLab resources created
- [ ] Repo URLs point to GitHub
- [ ] Clean destroy works
