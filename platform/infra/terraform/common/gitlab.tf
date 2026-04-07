################################################################################
# GitLab Token and Project Creation
# Skipped entirely in dev mode (no GitLab instance)
################################################################################

# Get user ID for the username
data "gitlab_user" "workshop" {
  count    = var.deployment_mode == "dev" ? 0 : 1
  username = local.git_username
}

resource "gitlab_personal_access_token" "workshop" {
  count      = var.deployment_mode == "dev" ? 0 : 1
  user_id    = data.gitlab_user.workshop[0].id
  name       = "Workshop Personal access token for ${var.git_username}"
  expires_at = "2026-12-31"

  scopes = ["api", "read_api", "read_repository", "write_repository"]
}

locals {
  gitlab_token = var.deployment_mode == "dev" ? "" : gitlab_personal_access_token.workshop[0].token
}
