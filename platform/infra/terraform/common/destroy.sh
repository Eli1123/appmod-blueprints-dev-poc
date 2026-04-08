#!/usr/bin/env bash

# Disable Terraform color output to prevent ANSI escape sequences
export TF_CLI_ARGS="-no-color"

set -euo pipefail

SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOTDIR="$(cd ${SCRIPTDIR}/..; pwd )"
[[ -n "${DEBUG:-}" ]] && set -x

# Save the current script directory before sourcing utils.sh
DEPLOY_SCRIPTDIR="$SCRIPTDIR"
source $SCRIPTDIR/../scripts/utils.sh

# Deployment mode: 'gitlab' (default) or 'dev'
export DEPLOYMENT_MODE=${DEPLOYMENT_MODE:-gitlab}

# In dev mode, automatically skip GitLab
if [[ "${DEPLOYMENT_MODE}" == "dev" ]]; then
  export SKIP_GITLAB=true
fi

# Main destroy function
main() {
  
  if [[ -z "${USER1_PASSWORD:-}" ]]; then
    log_error "USER1_PASSWORD environment variable is required"
    exit 1
  fi

  # Remove ArgoCD resources from all clusters
  for cluster in "${CLUSTER_NAMES[@]}"; do
      if ! cleanup_kubernetes_resources_with_fallback "$cluster"; then
        log_warning "Failed to cleanup Kubernetes resources for cluster: $cluster"
        # Don't exit in dev mode — continue with best-effort cleanup
        if [[ "${DEPLOYMENT_MODE}" != "dev" ]]; then
          exit 1
        fi
      fi
  done

  # Dev mode: pre-destroy cleanup for resources that block terraform destroy
  if [[ "${DEPLOYMENT_MODE}" == "dev" ]]; then
    log "Dev mode: running pre-destroy cleanup..."

    # Delete ingress-nginx to release NLB and ENIs before destroying security groups
    for cluster in "${CLUSTER_NAMES[@]}"; do
      log "Deleting ingress-nginx from $cluster..."
      helm uninstall ingress-nginx -n ingress-nginx --kube-context "$cluster" 2>/dev/null || true
    done

    # Wait for NLB ENIs to be released (they block security group deletion)
    log "Waiting 120s for NLB ENIs to release..."
    sleep 120

    # Clean up manually-created resources not in Terraform state
    log "Cleaning up manually-created resources..."

    # Delete CodeBuild project
    aws codebuild delete-project --name peeks-backstage-build --region "${AWS_REGION}" 2>/dev/null || true

    # Delete Backstage ECR repo
    aws ecr delete-repository --repository-name peeks-backstage --region "${AWS_REGION}" --force 2>/dev/null || true

    # Delete Okta secrets from Secrets Manager
    aws secretsmanager delete-secret --secret-id peeks-hub/okta --region "${AWS_REGION}" --force-delete-without-recovery 2>/dev/null || true
    # Delete DevLake secret if it wasn't cleaned up by Terraform
    aws secretsmanager delete-secret --secret-id peeks-devlake/mysql-connection --region "${AWS_REGION}" --force-delete-without-recovery 2>/dev/null || true

    # Delete CloudWatch log groups
    for lg in "/aws/codebuild/peeks-backstage-build" "/aws/lambda/peeks-trigger-ray-neuron-build" "/aws/lambda/peeks-trigger-ray-vllm-build"; do
      aws logs delete-log-group --log-group-name "$lg" --region "${AWS_REGION}" 2>/dev/null || true
    done

    # Delete RDS/Aurora clusters created by Crossplane (DevLake)
    for cluster_id in $(aws rds describe-db-clusters --region "${AWS_REGION}" --query "DBClusters[?contains(DBClusterIdentifier,'devlake')].DBClusterIdentifier" --output text 2>/dev/null); do
      log "Deleting RDS cluster: $cluster_id"
      # Delete instances first
      for instance_id in $(aws rds describe-db-instances --region "${AWS_REGION}" --query "DBInstances[?DBClusterIdentifier=='$cluster_id'].DBInstanceIdentifier" --output text 2>/dev/null); do
        aws rds delete-db-instance --db-instance-identifier "$instance_id" --skip-final-snapshot --region "${AWS_REGION}" 2>/dev/null || true
      done
      # Then delete the cluster
      aws rds delete-db-cluster --db-cluster-identifier "$cluster_id" --skip-final-snapshot --region "${AWS_REGION}" 2>/dev/null || true
    done

    # Delete IAM roles created by ACK (argo-rollouts) — these are outside Terraform
    for role in "peeks-spoke-dev-argo-rollouts" "peeks-spoke-prod-argo-rollouts"; do
      # Detach all policies first
      for policy_arn in $(aws iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[*].PolicyArn' --output text 2>/dev/null); do
        aws iam detach-role-policy --role-name "$role" --policy-arn "$policy_arn" 2>/dev/null || true
      done
      # Delete inline policies
      for policy_name in $(aws iam list-role-policies --role-name "$role" --query 'PolicyNames[*]' --output text 2>/dev/null); do
        aws iam delete-role-policy --role-name "$role" --policy-name "$policy_name" 2>/dev/null || true
      done
      aws iam delete-role --role-name "$role" 2>/dev/null || true
    done

    log "Pre-destroy cleanup complete"
  fi

  log "Starting boostrap stack destruction..."

  # Validate backend configuration
  validate_backend_config

  # Delete backstage ecr repo
  delete_backstage_ecr_repo

  # Force-delete ECR repos and empty S3 bucket that block terraform destroy
  force_cleanup_ray_resources
  
  export GENERATED_TFVAR_FILE="$(mktemp).tfvars.json"
  yq eval -o=json '.' $CONFIG_FILE > $GENERATED_TFVAR_FILE

  if ! $SKIP_GITLAB ; then
    initialize_terraform "gitlab infra" "$DEPLOY_SCRIPTDIR/gitlab_infra" # required to fetch values from gitlab_infra
    GITLAB_DOMAIN=$(terraform -chdir=$DEPLOY_SCRIPTDIR/gitlab_infra output -raw gitlab_domain_name)
    GITLAB_SG_ID=$(terraform -chdir=$DEPLOY_SCRIPTDIR/gitlab_infra output -raw gitlab_security_groups)
  fi


  # Initialize Terraform with S3 backend
  initialize_terraform "boostrap" "$DEPLOY_SCRIPTDIR"

  cd "$DEPLOY_SCRIPTDIR" # Get into common stack directory
  
  # Check for and clear any stale locks
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
  
  # Remove GitLab resources from state, if they exist (gitlab mode only)
  if [[ "${DEPLOYMENT_MODE}" != "dev" ]]; then
    if ! terraform state rm gitlab_personal_access_token.workshop || ! terraform state rm data.gitlab_user.workshop; then
      log_warning "GitLab resources not found in state"
    fi
  fi

  # Dev mode: remove resources from state that cause destroy issues
  if [[ "${DEPLOYMENT_MODE}" == "dev" ]]; then
    log "Dev mode: removing problematic resources from Terraform state..."
    terraform state rm 'kubernetes_manifest.spoke_external_secrets["spoke1"]' 2>/dev/null || true
    terraform state rm 'kubernetes_manifest.spoke_external_secrets["spoke2"]' 2>/dev/null || true
  fi

  # Remove data sources that may reference resources already deleted by ArgoCD cleanup
  terraform state rm data.aws_lb.ingress_nginx 2>/dev/null || log_warning "data.aws_lb.ingress_nginx not found in state"

  # Remove data sources that may reference resources already deleted by ArgoCD cleanup
  terraform state rm data.aws_lb.ingress_nginx 2>/dev/null || log_warning "data.aws_lb.ingress_nginx not found in state"

  cd - # Go back

  # Destroy Terraform resources
  log "Destroying bootstrap resources..."
  if ! terraform -chdir=$DEPLOY_SCRIPTDIR destroy \
    -var-file="${GENERATED_TFVAR_FILE}" \
    -var="deployment_mode=${DEPLOYMENT_MODE}" \
    -var="gitlab_domain_name=${GITLAB_DOMAIN:-""}" \
    -var="gitlab_security_groups=${GITLAB_SG_ID:-""}" \
    -var="ide_password=${USER1_PASSWORD}" \
    -var="git_username=${GIT_USERNAME}" \
    -var="git_password=${USER1_PASSWORD}" \
    -var="working_repo=${WORKING_REPO}" \
    -auto-approve; then
    log_warning "Bootstrap stack destroy failed, checking for lock issues"
    
    # Extract lock ID from error if present
    cd "$DEPLOY_SCRIPTDIR"
    LOCK_ID=$(terraform plan 2>&1 | grep -oP 'ID:\s+\K[a-f0-9-]+' | head -1 || echo "")
    if [[ -n "$LOCK_ID" ]]; then
      log "Forcing unlock with ID: $LOCK_ID"
      terraform force-unlock -force "$LOCK_ID" || true
    fi
    cd -
    
    log_warning "Retrying destroy after lock handling"
    if ! terraform -chdir=$DEPLOY_SCRIPTDIR destroy \
      -var-file="${GENERATED_TFVAR_FILE}" \
      -var="deployment_mode=${DEPLOYMENT_MODE}" \
      -var="gitlab_domain_name=${GITLAB_DOMAIN:-""}" \
      -var="gitlab_security_groups=${GITLAB_SG_ID:-""}" \
      -var="ide_password=${USER1_PASSWORD}" \
      -var="git_username=${GIT_USERNAME}" \
      -var="git_password=${USER1_PASSWORD}" \
      -var="working_repo=${WORKING_REPO}" \
      -auto-approve; then
      log_error "Bootstrap stack destroy failed again, exiting"
      exit 1
    fi
  fi

  if ! $SKIP_GITLAB ; then
    
    initialize_terraform "gitlab infra" "$DEPLOY_SCRIPTDIR/gitlab_infra"

    # Destroy Terraform resources
    log "Destroying gitlab infra resources..."
    if ! terraform -chdir=$DEPLOY_SCRIPTDIR/gitlab_infra destroy \
      -var-file="${GENERATED_TFVAR_FILE}" \
      -var="git_username=${GIT_USERNAME}" \
      -var="git_password=${IDE_PASSWORD}" \
      -var="working_repo=${WORKING_REPO}" \
      -auto-approve; then
      log_warning "Gitlab infra stack destroy failed, trying one more time"
      if ! terraform -chdir=$DEPLOY_SCRIPTDIR/gitlab_infra destroy \
        -var-file="${GENERATED_TFVAR_FILE}" \
        -var="git_username=${GIT_USERNAME}" \
        -var="git_password=${IDE_PASSWORD}" \
        -var="working_repo=${WORKING_REPO}" \
        -auto-approve; then
        log_error "Gitlab infra stack destroy failed again, exiting"
        exit 1
      fi
    fi
  fi

  log_success "Bootstrap stack destroy completed successfully"

  # Dev mode: post-destroy cleanup for orphaned security groups
  if [[ "${DEPLOYMENT_MODE}" == "dev" ]]; then
    log "Dev mode: cleaning up orphaned security groups..."
    # Find and delete security groups created by the platform (ingress SGs)
    for sg_id in $(aws ec2 describe-security-groups --region "${AWS_REGION}" \
      --query "SecurityGroups[?contains(GroupName,'ingress')].GroupId" --output text 2>/dev/null); do
      log "Deleting orphaned security group: $sg_id"
      aws ec2 delete-security-group --group-id "$sg_id" --region "${AWS_REGION}" 2>/dev/null || \
        log_warning "Could not delete $sg_id — may still have dependent ENIs. Retry after a few minutes."
    done
    # Clean up EKS cluster security groups
    for sg_id in $(aws ec2 describe-security-groups --region "${AWS_REGION}" \
      --query "SecurityGroups[?contains(GroupName,'eks-cluster-sg')].GroupId" --output text 2>/dev/null); do
      log "Deleting orphaned EKS security group: $sg_id"
      aws ec2 delete-security-group --group-id "$sg_id" --region "${AWS_REGION}" 2>/dev/null || \
        log_warning "Could not delete $sg_id"
    done
    # Clean up RDS security groups
    for sg_id in $(aws ec2 describe-security-groups --region "${AWS_REGION}" \
      --query "SecurityGroups[?contains(GroupName,'rds-mysql-sg')].GroupId" --output text 2>/dev/null); do
      log "Deleting orphaned RDS security group: $sg_id"
      aws ec2 delete-security-group --group-id "$sg_id" --region "${AWS_REGION}" 2>/dev/null || \
        log_warning "Could not delete $sg_id"
    done
    # Clean up DB subnet groups
    for sg_name in $(aws rds describe-db-subnet-groups --region "${AWS_REGION}" \
      --query "DBSubnetGroups[?contains(DBSubnetGroupName,'devlake')].DBSubnetGroupName" --output text 2>/dev/null); do
      log "Deleting orphaned DB subnet group: $sg_name"
      aws rds delete-db-subnet-group --db-subnet-group-name "$sg_name" --region "${AWS_REGION}" 2>/dev/null || \
        log_warning "Could not delete $sg_name — RDS cluster may still be deleting"
    done
    log "Post-destroy cleanup complete."
    log "NOTE: The hub VPC (${HUB_VPC_ID}) was manually created and is NOT managed by Terraform."
    log "To delete it, run: aws ec2 delete-vpc --vpc-id ${HUB_VPC_ID} (after deleting NAT gateway, subnets, route tables, IGW)"
    log "Check for remaining resources: aws ec2 describe-security-groups --query 'SecurityGroups[?GroupName!=\`default\`]'"
  fi
}

# Run main function
main "$@"
