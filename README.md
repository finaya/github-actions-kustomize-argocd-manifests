# Kustomize ArgoCD manifests

GitHub action used kustomize applications manifests

## ✨ New Feature: Individual PRs per Microservice

This action now creates **individual Pull Requests for each microservice** instead of bundling multiple microservices in a single PR.

### Benefits:
- **Isolated deployments**: Each microservice gets its own PR
- **Better traceability**: Easy to track changes per service
- **Reduced conflicts**: No more merge conflicts between simultaneous deployments
- **Granular rollbacks**: Rollback specific microservices independently

### Branch Naming:
- Format: `deploy/{microservice-name}/{timestamp}`
- Example: `deploy/bb-api-gateway/20241021-223000`

## Inputs

- **gitops-repo-name:** The name of GitOps git repository;
- **gitops-repo-url:** The URL of GitOps repository;
- **gh_access_token:** The access token of GitOps repository;
- **image_name**: The container image name;
- **app_id:** The App ID (microservice name);
- **github_actor:** The github commit actor ID;

**OBS.:** All inputs are **required** 

## Outputs

There are no outputs for this action

## Example usage

```yaml
      - name: Individual Kustomize step
        uses: finaya/github-actions-kustomize-argocd-manifests@v1.3.0
        with:
          gitops-repo-name: 'corpx-gitops-manifest'
          gitops-repo-url: 'github.com/finaya/corpx-gitops-manifest.git'
          gh_access_token: ${{ secrets.actor-access-token }}
          image_name: gcr.io/${{ secrets.gcp-project-id }}/bb-api-gateway
          app_id: bb-api-gateway
          github_actor: ${{ github.actor }}
```

## How it works

1. **Creates unique branch** per microservice: `deploy/{app_id}/{timestamp}`
2. **Updates only the specific microservice** in the GitOps repository
3. **Opens individual PR** with detailed information:
   - Microservice name and version
   - Environment (DEV/HOMOLOG/PRODUCTION)
   - Deployer information
   - Branch reference

## Migration from previous version

The action is **backward compatible**. Simply update your workflow to use the new version:

```yaml
# Before
uses: finaya/github-actions-kustomize-argocd-manifests@v1.2.3

# After  
uses: finaya/github-actions-kustomize-argocd-manifests@v1.3.0
```

## How to send updates?
If you wants to update or make changes in module code you should use the **develop** branch of this repository, you can test your module changes passing the `@develop` in module calling. Ex.:

```yaml
      # Example using this actions
      - name: Individual Kustomize Deploy
        uses: finaya/github-actions-kustomize-argocd-manifests@develop
```
After execute all tests you can open a pull request to the master branch. 