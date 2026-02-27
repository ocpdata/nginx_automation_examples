# Deploy NGINX NIC / NAP-V5 in Azure

This workflow deploys a complete stack of NGINX Ingress Controller (NIC) with App Protect V5 (NAP) on Azure Kubernetes Service (AKS), including the Arcadia demo application.

## Workflow file

`.github/workflows/az-apply-nic-napv5.yaml`

## Triggers

| Trigger | Description |
|---------|-------------|
| `push` to `az-apply-nic-napv5` branch | Automatic execution on push |
| `workflow_dispatch` | Manual execution from GitHub Actions UI |

## Prerequisites

### GitHub Variables (`vars`)

| Variable | Description | Example |
|----------|-------------|---------|
| `project_prefix` | Prefix for all Azure resource names | `proyaz` |
| `azure_region` | Azure region to deploy resources | `centralus` |
| `storage_account_name` | Name of the Azure Storage Account for Terraform backend | `staz` |

### GitHub Secrets (`secrets`)

| Secret | Description |
|--------|-------------|
| `azure_credentials` | Azure Service Principal JSON (see below) |
| `NGINX_JWT` | NGINX license JWT token |
| `NGINX_REPO_CRT` | NGINX private registry certificate (`nginx-repo.crt`) |
| `NGINX_REPO_KEY` | NGINX private registry key (`nginx-repo.key`) |

### Azure Service Principal format

The `azure_credentials` secret must be a valid JSON object in this format:

```json
{
  "clientId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "clientSecret": "your-client-secret",
  "subscriptionId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "tenantId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
}
```

Generate it with:

```bash
az ad sp create-for-rbac \
  --name "github-actions-sp" \
  --role contributor \
  --scopes /subscriptions/<SUBSCRIPTION_ID> \
  --sdk-auth
```

## Architecture

The workflow deploys the following infrastructure in sequence:

```
terraform_blob → terraform_infra → terraform_aks → terraform_nap → terraform_policy → terraform_arcadia
```

## Jobs

### 1. `terraform_blob` — Deploy Blob Storage
**Directory:** `azure/blob`

Creates the Azure Resource Group and Blob Storage Account/Container used as the remote Terraform backend for all subsequent jobs.

- Uses **local state** (no remote backend)
- Automatically imports pre-existing resources into the Terraform state to avoid conflicts on re-runs
- Resources created:
  - Resource Group: `<project_prefix>-rg`
  - Storage Account: `<storage_account_name>`
  - Blob Container: `<storage_account_name>-container`

### 2. `terraform_infra` — Deploy Azure Infrastructure
**Directory:** `azure/infra`

Deploys the base Azure network infrastructure.

- Uses remote backend (Blob Storage created in job 1)
- Resources created:
  - Virtual Network (VNet)
  - Subnets
  - Network Security Groups

### 3. `terraform_aks` — Deploy AKS Cluster
**Directory:** `azure/aks`

Creates the Azure Kubernetes Service cluster.

- Uses remote backend
- VM size: `Standard_D2s_v3`
- Resources created:
  - AKS Cluster with SystemAssigned identity
  - Azure CNI network plugin

### 4. `terraform_nap` — Deploy NGINX NIC / App Protect
**Directory:** `azure/nap`

Installs NGINX Ingress Controller with App Protect V5 on the AKS cluster using Helm/Terraform.

- Uses remote backend
- Requires `NGINX_JWT` secret for authenticating with the NGINX private registry
- Resources created:
  - Kubernetes namespaces: `nginx-ingress`, `monitoring`
  - NGINX Ingress Controller (Helm release)
  - Prometheus + Grafana for monitoring
  - Azure Load Balancer (automatically provisioned by AKS)

### 5. `terraform_policy` — Deploy NGINX WAF Policy
**Directory:** `azure/policy`

Compiles and deploys the WAF security policy to the NGINX Ingress Controller.

Steps performed:
1. Fetches AKS credentials via `az aks get-credentials`
2. Installs Docker on the runner
3. Authenticates to `private-registry.nginx.com` using `NGINX_REPO_CRT` / `NGINX_REPO_KEY`
4. Builds the WAF compiler image (`waf-compiler-5.4.0`)
5. Compiles `policy.json` → `compiled_policy.tgz`
6. Copies the compiled bundle directly to the NGINX pod: `/etc/app_protect/bundles/compiled_policy.tgz`
7. Applies Terraform to configure the policy in NIC

### 6. `terraform_arcadia` — Deploy Arcadia WebApp
**Directory:** `azure/arcadia`

Deploys the Arcadia Finance demo application and exposes it via the NGINX Ingress Controller.

- Outputs the `external_name` (DNS) of the Azure Load Balancer upon completion

## Terraform State

All jobs (except `terraform_blob`) store state in the Azure Blob Storage backend:

| Parameter | Value |
|-----------|-------|
| Resource Group | `<project_prefix>-rg` |
| Storage Account | `<storage_account_name>` |
| Container | `<storage_account_name>-container` |

## Re-running the workflow

The workflow is **idempotent**. Each job checks for changes before applying:

- If `terraform plan` shows `No changes.` → `terraform apply` is skipped
- If resources already exist in Azure but not in state → they are automatically imported (blob job)

## Destroy

To tear down the entire stack, use the destroy workflow:

`.github/workflows/az-destroy-nic-napv5.yaml`

It can be triggered manually from GitHub Actions → **Run workflow**.
