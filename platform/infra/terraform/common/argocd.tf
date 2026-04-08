################################################################################
# GitOps Bridge: Bootstrap
################################################################################

module "gitops_bridge_bootstrap" {
  source  = "gitops-bridge-dev/gitops-bridge/helm"
  version = "0.1.0"
  
  create = true

  # In dev mode: install ArgoCD via Helm (no EKS ArgoCD Capability)
  # In gitlab mode: don't install via Helm (EKS ArgoCD Capability handles it)
  install = var.deployment_mode == "dev" ? true : false

  argocd = var.deployment_mode == "dev" ? {
    set = concat(
      # Disable Dex when using direct OIDC (prevents token resync timeouts)
      var.oidc_config != null ? [
        { name = "dex.enabled", value = "false" },
        { name = "configs.cm.url", value = "https://${aws_cloudfront_distribution.ingress.domain_name}/argocd" },
        { name = "configs.cm.oidc\\.tls\\.insecure\\.skip\\.verify", value = "true" },
      ] : [],
      # Always set rootpath and insecure mode for CloudFront
      [
        { name = "configs.params.server\\.rootpath", value = "/argocd" },
        { name = "configs.params.server\\.basehref", value = "/argocd" },
        { name = "configs.params.server\\.insecure", value = "true" },
      ]
    )
    set_sensitive = var.oidc_config != null ? [
      {
        name  = "configs.cm.oidc\\.config"
        value = yamlencode({
          name            = var.oidc_config.name
          issuer          = var.oidc_config.issuer_url
          clientID        = var.oidc_config.client_id
          clientSecret    = var.oidc_config.client_secret
          requestedScopes = var.oidc_config.scopes
        })
      }
    ] : []
  } : {}
  
  cluster = {
    cluster_name = local.hub_cluster.name
    environment  = local.hub_cluster.environment
    metadata     = local.addons_metadata[local.hub_cluster_key]
    addons       = local.addons[local.hub_cluster_key]
    # In dev mode: use in-cluster endpoint (Helm ArgoCD can't resolve ARNs)
    # In gitlab mode: use cluster ARN (EKS Managed ArgoCD resolves ARNs natively)
    server = var.deployment_mode == "dev" ? "https://kubernetes.default.svc" : data.aws_eks_cluster.clusters[local.hub_cluster_key].arn
  }

  apps = local.argocd_apps
}

# ArgoCD Git Secrets — only needed in gitlab mode (GitLab is a private repo)
# In dev mode, the GitHub repo is public so no credentials are needed
resource "kubernetes_secret" "git_secrets" {
  depends_on = [
    module.gitops_bridge_bootstrap,
  ]

  for_each = var.deployment_mode == "dev" ? {} : {
    git-repo-creds = {
      secret-type = "repo-creds"
      url         = "https://${local.gitlab_domain_name}/${local.git_username}"
      type        = "git"
      username    = "not-used"
      password    = local.gitlab_token
    }
    git-repository = {
      secret-type = "repository"
      url         = "https://${local.gitlab_domain_name}/${local.git_username}/${var.working_repo}.git"
      type        = "git"
    }
  }
  metadata {
    name      = each.key
    namespace = local.argocd_namespace
    labels = {
      "argocd.argoproj.io/secret-type" = "${each.value.secret-type}"
    }
  }
  data = each.value
}
