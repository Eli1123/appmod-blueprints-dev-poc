# Dev POC Plan — Fork-Based Deployment with GitHub + Okta

## Goal

Use the dev deployment mode to deploy the platform from a personal GitHub fork, with Okta as the identity provider instead of Keycloak. Validate the full developer workflow end-to-end and document what needs to change to make this solution properly componentized and usable beyond a reference implementation.

## Current State

- Dev deployment mode is working in account `934822760716`
- 58 ArgoCD apps, all healthy
- ArgoCD installed via Helm, accessible at `https://d181j7b7fhjtqq.cloudfront.net/argocd`
- Platform reads from the public `aws-samples/appmod-blueprints` repo (read-only)
- Keycloak running as identity provider
- Backstage running but with patched ConfigMap (chart changes not in remote repo)
- No write-back capability (can't scaffold apps, push manifests, or do PR workflows)

## What We Want

- ArgoCD reads/writes from a GitHub fork we control
- Backstage scaffolds apps into the fork
- Okta provides SSO for all platform components
- Full developer workflow: Backstage template → git commit → ArgoCD sync → deployment
- Document every friction point for componentization

---

## Phase 1: Fork + Git Provider Setup

### 1.1 Create GitHub Fork

- Fork `aws-samples/appmod-blueprints` to personal/org GitHub account
- Push all local changes (dev mode conditionals, Backstage chart fix, etc.) to the fork
- Set the fork's default branch to match our working branch

### 1.2 GitHub PAT

- Create a GitHub Personal Access Token with scopes: `repo`, `read:org`
- This token is used by:
  - ArgoCD to pull/push gitops configs
  - Backstage scaffolder to create repos and push manifests

### 1.3 Configure ArgoCD Git Secrets

Currently in dev mode, ArgoCD has no git secrets (public repo, no auth needed). With a fork:

- Create ArgoCD repo credentials secret for the fork URL
- Create ArgoCD repository secret pointing to the fork

**Files to change:**
- `common/argocd.tf` — add GitHub git secrets in dev mode (conditional on git token being provided)
- `common/deploy.sh` — accept `GIT_TOKEN` env var for GitHub PAT

### 1.4 Update Repo URLs

- `hub-config.yaml` — change `repo.url` to the fork URL
- Or pass via env var / deploy.sh so hub-config.yaml stays generic

### 1.5 Push Fleet Member Directories

With a fork we control, we can push the `gitops/fleet/members/` directories directly. This means:
- The fleet-secrets ApplicationSet will work natively (reads member dirs from the fork)
- We can potentially remove the `kubernetes_manifest.spoke_external_secrets` Terraform workaround

**Questions to resolve:**
- Do we want the fork URL hardcoded in hub-config.yaml or passed as an env var?
- Should deploy.sh prompt for the GitHub PAT or read from env?

---

## Phase 2: Okta as Identity Provider

### 2.1 Okta Setup (One-Time)

- Create Okta developer account at developer.okta.com (free)
- Create OIDC app integrations:
  - `argocd` — Web app, authorization code flow
  - `backstage` — Web app, authorization code flow
  - `argo-workflows` — Web app, authorization code flow
  - `kargo` — Web app, authorization code flow
- Configure redirect URIs for each (CloudFront domain + app path)
- Create groups: `platform-admin`, `platform-editor`, `platform-viewer`
- Assign test users to groups

### 2.2 Remove Keycloak

- Set `enable_keycloak: false` in hub-config.yaml (or patch in deploy.sh for dev mode)
- Remove Keycloak-related secrets from Secrets Manager (`keycloak_admin_password`, `keycloak_postgres_password`)
- Remove Keycloak pod identity association from `pod-identity.tf`
- Remove Keycloak-related ExternalSecrets

**Risk:** Other components may reference Keycloak URLs or secrets. Need to audit:
- Backstage OIDC config references `KEYCLOAK_NAME_METADATA` and `KEYCLOAK_CLIENT_SECRET`
- ArgoCD OIDC config references Keycloak issuer URL
- Argo Workflows SSO config
- Kargo SSO config

### 2.3 Configure ArgoCD for Okta

Current ArgoCD OIDC config (in `addons.yaml` valuesObject):
```yaml
oidc.config: |
  name: Keycloak
  issuer: https://{{.metadata.annotations.ingress_domain_name}}/keycloak/realms/platform
  clientID: argocd
  enablePKCEAuthentication: true
  requestedScopes: ["openid", "profile", "email", "groups"]
```

New config for Okta:
```yaml
oidc.config: |
  name: Okta
  issuer: https://<okta-domain>.okta.com
  clientID: <argocd-client-id>
  clientSecret: $oidc.okta.clientSecret
  requestedScopes: ["openid", "profile", "email", "groups"]
```

**Where this lives:** `gitops/addons/bootstrap/default/addons.yaml` in the `argocd` section. Since we have a fork, we can modify this directly.

**Secret management:** The Okta client secret needs to be stored in AWS Secrets Manager and synced via ExternalSecrets, similar to how Keycloak secrets work today.

### 2.4 Configure Backstage for Okta

Current Backstage auth config (in chart template `install.yaml`):
```yaml
auth:
  providers:
    keycloak-oidc:
      development:
        metadataUrl: ${KEYCLOAK_NAME_METADATA}
        clientId: backstage
        clientSecret: ${KEYCLOAK_CLIENT_SECRET}
```

New config for Okta:
```yaml
auth:
  providers:
    okta:
      development:
        metadataUrl: https://<okta-domain>.okta.com/.well-known/openid-configuration
        clientId: <backstage-client-id>
        clientSecret: ${OKTA_CLIENT_SECRET}
        audience: api://default
```

**Backstage image concern:** The current Docker image may not include `@backstage/plugin-auth-backend-module-okta-provider`. Need to check. If not included, we'd need to either:
- Build a custom Backstage image with the Okta module
- Use a generic OIDC provider if available in the image

### 2.5 Configure Argo Workflows + Kargo for Okta

Both use SSO config that points to the OIDC provider. Similar pattern — swap Keycloak issuer/clientID for Okta values.

### 2.6 Store Okta Secrets

- Store Okta client secrets in AWS Secrets Manager (one per component)
- Create ExternalSecrets to sync them into the appropriate namespaces
- This replaces the Keycloak secrets flow

**Questions to resolve:**
- Do we have an Okta developer account?
- What's the Okta org URL?
- Do we want to store Okta config (issuer URL, client IDs) in hub-config.yaml, env vars, or Secrets Manager?

---

## Phase 3: Validate Developer Workflow

### 3.1 Backstage Template Scaffolding

- Open Backstage in browser
- Log in via Okta SSO
- Use a template (e.g., app-deploy) to scaffold a new application
- Verify it creates the right manifests in the GitHub fork
- Verify ArgoCD picks up the new app and deploys it

### 3.2 Argo Rollouts Progressive Delivery

- Deploy the rollouts-demo app to spoke-dev
- Trigger a canary deployment
- Verify metrics-driven analysis works with AMP/Prometheus
- Promote to spoke-prod

### 3.3 Multi-Cluster Management

- Verify ArgoCD manages all 3 clusters
- Deploy an addon to a spoke cluster by changing a label
- Verify the ApplicationSet generates the app and deploys it

### 3.4 Observability

- Access Grafana workspace
- Verify dashboards show metrics from spoke clusters
- Check AMP scraper data

---

## Phase 4: Document Componentization Findings

As we go through phases 1-3, document:

### What Was Easy
- Things that "just worked" when swapping components
- Clean abstractions that made changes simple

### What Was Hard
- Hardcoded assumptions (e.g., Keycloak URLs baked into chart templates)
- Tight coupling between components
- Things that required changes in multiple places for a single logical change

### What Needs Componentizing
- Identity provider should be pluggable (config-driven, not hardcoded)
- Git provider should be pluggable (already partially done with deployment_mode)
- Backstage image should be configurable or built from a template
- Secrets management pattern should be provider-agnostic

### Specific Friction Points to Track
- How many files need to change to swap the identity provider?
- How many files need to change to swap the git provider?
- Are there circular dependencies between components?
- What's the minimum viable platform (which addons are truly required vs optional)?
- How long does each change take to propagate through the system?

---

## Prerequisites Checklist

- [ ] GitHub account with fork of appmod-blueprints
- [ ] GitHub PAT with `repo` and `read:org` scopes
- [ ] Okta developer account (developer.okta.com)
- [ ] Okta OIDC app registrations (argocd, backstage, argo-workflows, kargo)
- [ ] Okta groups configured (admin, editor, viewer)
- [ ] Okta redirect URIs configured with CloudFront domain
- [ ] AWS account `934822760716` with existing dev deployment

## Estimated Timeline

| Phase | Effort | Dependencies |
|-------|--------|-------------|
| Phase 1: Fork + Git | 2-3 hours | GitHub account, PAT |
| Phase 2: Okta | 4-6 hours | Okta account, may need Backstage image rebuild |
| Phase 3: Validate | 2-3 hours | Phases 1+2 complete |
| Phase 4: Document | Ongoing | Notes taken during phases 1-3 |

Total: ~1-2 days of focused work.

---

## Open Questions

1. GitHub fork — personal account or org? This affects the repo URL pattern.
2. Okta — do we already have an account, or creating fresh?
3. Backstage image — should we check if the current image supports generic OIDC before committing to an Okta-specific module?
4. Scope — do we want to keep ALL current addons (crossplane, kubevela, jupyterhub, spark, ray, etc.) or trim to a minimal set for the POC?
5. Hub-config.yaml — should we create a separate `hub-config-dev.yaml` for the POC, or keep modifying the single file with deploy.sh patches?
