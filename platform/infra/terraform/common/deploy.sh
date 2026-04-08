#!/usr/bin/env bash

# Disable Terraform color output to prevent ANSI escape sequences
export TF_CLI_ARGS="-no-color"

set -euo pipefail

SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOTDIR="$(cd ${SCRIPTDIR}/../..; pwd )"
[[ -n "${DEBUG:-}" ]] && set -x

# Save the current script directory before sourcing utils.sh
DEPLOY_SCRIPTDIR="$SCRIPTDIR"

# Force regeneration of CONFIG_FILE to pick up latest hub-config.yaml changes
unset CONFIG_FILE

source $SCRIPTDIR/../scripts/utils.sh

# Check if clusters are created through Workshop
export WORKSHOP_CLUSTERS=${WORKSHOP_CLUSTERS:-false}

# Deployment mode: 'gitlab' (default) or 'dev' (no GitLab, no IDC, Helm ArgoCD)
export DEPLOYMENT_MODE=${DEPLOYMENT_MODE:-gitlab}

# OIDC configuration for ArgoCD SSO (optional)
# Set these env vars to configure OIDC at deployment time:
#   OIDC_ISSUER_URL, OIDC_CLIENT_ID, OIDC_CLIENT_SECRET, OIDC_PROVIDER_NAME
OIDC_TF_VAR=""
if [[ -n "${OIDC_ISSUER_URL:-}" && -n "${OIDC_CLIENT_ID:-}" && -n "${OIDC_CLIENT_SECRET:-}" ]]; then
  OIDC_TF_VAR="-var=oidc_config={issuer_url=\"${OIDC_ISSUER_URL}\",client_id=\"${OIDC_CLIENT_ID}\",client_secret=\"${OIDC_CLIENT_SECRET}\",name=\"${OIDC_PROVIDER_NAME:-SSO}\"}"
  log "OIDC configuration detected: ${OIDC_PROVIDER_NAME:-SSO} (${OIDC_ISSUER_URL})"
fi

# In dev mode, automatically skip GitLab
if [[ "${DEPLOYMENT_MODE}" == "dev" ]]; then
  export SKIP_GITLAB=true
  log "Dev deployment mode: SKIP_GITLAB=true (auto-set)"
fi

# Main deployment function
main() {
  log "Starting bootstrap stack deployment..."

  if [[ -z "${USER1_PASSWORD:-${USER_PASSWORD:-}}" ]]; then
    log_error "USER1_PASSWORD environment variable is required"
    exit 1
  fi

    # Configure kubectl access to use kubectl in terraform external resources
  for cluster in "${CLUSTER_NAMES[@]}"; do
    if ! kubectl get nodes --request-timeout=10s --context $cluster &>/dev/null; then
      log_warning "kubectl cannot connect to cluster, setting up kubectl access"
      configure_kubectl_with_fallback "$cluster" || {
        log_error "kubectl configuration failed, cannot proceed with bootstrap"
        exit 1
      }
    fi
    log_success "kubectl is working for $cluster, proceeding..."
  done
  
  # Validate backend configuration
  validate_backend_config

  export GENERATED_TFVAR_FILE="$(mktemp).tfvars.json"
  yq eval -o=json '.' $CONFIG_FILE > $GENERATED_TFVAR_FILE

  # In dev mode, disable GitLab addon in the generated tfvars
  # (GitLab has no infrastructure in dev mode, so the addon would just be broken)
  if [[ "${DEPLOYMENT_MODE}" == "dev" ]]; then
    log "Dev mode: disabling enable_gitlab in cluster config"
    local PATCHED_TFVAR_FILE="$(mktemp).tfvars.json"
    jq '.clusters |= with_entries(.value.addons.enable_gitlab = false)' "$GENERATED_TFVAR_FILE" > "$PATCHED_TFVAR_FILE"
    export GENERATED_TFVAR_FILE="$PATCHED_TFVAR_FILE"
  fi

  if ! $SKIP_GITLAB ; then
    # Initialize Terraform with S3 backend
    initialize_terraform "gitlab infra" "$DEPLOY_SCRIPTDIR/gitlab_infra"
    
    # Check for and clear any stale locks
    cd "$DEPLOY_SCRIPTDIR/gitlab_infra"
    if terraform state list &>/dev/null; then
      log "State accessible, no lock issues"
    else
      log_warning "State lock detected, attempting to force unlock"
      LOCK_ID=$(terraform force-unlock -force 2>&1 | grep -oP 'Lock ID: \K[a-f0-9-]+' || echo "")
      if [[ -n "$LOCK_ID" ]]; then
        log "Force unlocking with ID: $LOCK_ID"
        terraform force-unlock -force "$LOCK_ID" || log_warning "Force unlock failed, continuing anyway"
      fi
    fi
    cd -
    
    # Apply Terraform configuration with retry logic
    log "Applying gitlab infra resources..."
    
    # Retry function with exponential backoff
    retry_terraform_apply() {
      local max_attempts=3
      local attempt=1
      local delay=30
      
      while [ $attempt -le $max_attempts ]; do
        log "Attempt $attempt of $max_attempts for gitlab infra stack..."
        
        if terraform -chdir=$DEPLOY_SCRIPTDIR/gitlab_infra apply \
          -var-file="${GENERATED_TFVAR_FILE}" \
          -var="git_username=${GIT_USERNAME}" \
          -var="git_password=${USER1_PASSWORD}" \
          -var="working_repo=${WORKING_REPO}" \
          -parallelism=10 -auto-approve; then
          log_success "Terraform apply succeeded on attempt $attempt"
          return 0
        fi
        
        if [ $attempt -eq $max_attempts ]; then
          log_error "Terraform apply failed after $max_attempts attempts"
          return 1
        fi
        
        log_warning "Attempt $attempt failed, waiting ${delay}s before retry..."
        sleep $delay
        delay=$((delay * 2))  # Exponential backoff
        attempt=$((attempt + 1))
      done
    }
    
    if ! retry_terraform_apply; then
      exit 1
    fi
  fi

  if ! $SKIP_GITLAB ; then
    # Get gitlab cloudfront domain from gitlab infra stack
    export GITLAB_DOMAIN=$(terraform -chdir=$DEPLOY_SCRIPTDIR/gitlab_infra output -raw gitlab_domain_name)
    GITLAB_SG_ID=$(terraform -chdir=$DEPLOY_SCRIPTDIR/gitlab_infra output -raw gitlab_security_groups)

    # Create spoke cluster secret values
    create_spoke_cluster_secret_values

    # Push repo to Gitlab
    gitlab_repository_setup
  else
    log "Skipping GitLab domain retrieval and repo setup (SKIP_GITLAB=true)"
    export GITLAB_DOMAIN="${GITLAB_DOMAIN:-""}"
    GITLAB_SG_ID="${GITLAB_SG_ID:-""}"

    # Still create spoke cluster secret values
    create_spoke_cluster_secret_values
  fi
  
  # Initialize Terraform with S3 backend
  initialize_terraform "bootstrap" "$DEPLOY_SCRIPTDIR"
  
  # Check for and clear any stale locks
  cd "$DEPLOY_SCRIPTDIR"
  if terraform state list &>/dev/null; then
    log "State accessible, no lock issues"
  else
    log_warning "State lock detected, attempting to force unlock"
    LOCK_ID=$(terraform force-unlock -force 2>&1 | grep -oP 'Lock ID: \K[a-f0-9-]+' || echo "")
    if [[ -n "$LOCK_ID" ]]; then
      log "Force unlocking with ID: $LOCK_ID"
      terraform force-unlock -force "$LOCK_ID" || log_warning "Force unlock failed, continuing anyway"
    fi
  fi
  cd -
  
  # Apply Terraform configuration with retry mechanism
  deploy_bootstrap_stack() {
    local max_attempts=3
    local delay=30
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
      log "Attempt $attempt of $max_attempts for bootstrap stack..."
      
      if terraform -chdir=$DEPLOY_SCRIPTDIR apply \
        -var-file="${GENERATED_TFVAR_FILE}" \
        -var="deployment_mode=${DEPLOYMENT_MODE}" \
        -var="gitlab_domain_name=${GITLAB_DOMAIN:-""}" \
        -var="gitlab_security_groups=${GITLAB_SG_ID:-""}" \
        -var="ide_password=${USER1_PASSWORD}" \
        -var="git_username=${GIT_USERNAME}" \
        -var="git_password=${USER1_PASSWORD}" \
        -var="resource_prefix=${RESOURCE_PREFIX}" \
        -var="working_repo=${WORKING_REPO}" \
        ${OIDC_TF_VAR} \
        -parallelism=10 -auto-approve; then
        log_success "Bootstrap stack deployment succeeded on attempt $attempt"
        return 0
      fi
      
      if [ $attempt -eq $max_attempts ]; then
        log_error "Bootstrap stack deployment failed after $max_attempts attempts"
        return 1
      fi
      
      log_warning "Attempt $attempt failed, waiting ${delay}s before retry..."
      log_warning "Restarting Kyverno admission controller to fix potential webhook issues..."
      kubectl rollout restart deployment kyverno-admission-controller -n kyverno 2>/dev/null || true
      sleep $delay
      delay=$((delay * 2))  # Exponential backoff
      attempt=$((attempt + 1))
    done
  }

  log "Applying bootstrap resources..."
  if ! deploy_bootstrap_stack; then
    log_error "Bootstrap stack deployment failed after all retry attempts, exiting"
    exit 1
  fi

  # Get Ingress domain from Terraform output
  export INGRESS_DOMAIN=$(terraform -chdir=$DEPLOY_SCRIPTDIR output -raw ingress_domain_name)

  if [[ "${DEPLOYMENT_MODE}" != "dev" ]]; then
    # Update backstage default values now that both domains are available
    update_backstage_defaults
    
    # Push repo to Gitlab
    gitlab_repository_setup
  else
    log "Dev mode: skipping Backstage defaults update and GitLab repo push"
  fi
  
  log_success "Bootstrap stack deployment completed successfully"
}

# Run main function
main "$@"
