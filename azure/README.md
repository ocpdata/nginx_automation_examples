# Deploy & Destroy NGINX NIC / NAP-V5 in Azure

This document covers the GitHub Actions workflows to deploy and destroy a complete stack of NGINX Ingress Controller (NIC) with App Protect V5 (NAP) on Azure Kubernetes Service (AKS), including the Arcadia demo application.

---

## Prerequisites

### GitHub Variables (`vars`)

| Variable | Description | Example |
|----------|-------------|---------|
| `PROJECT_PREFIX` | Prefix for all Azure resource names | `proyaz` |
| `AZURE_REGION` | Azure region to deploy resources | `centralus` |
| `STORAGE_ACCOUNT_NAME` | Name of the Azure Storage Account for Terraform backend | `staz` |

### GitHub Secrets (`secrets`)

| Secret | Description |
|--------|-------------|
| `AZURE_CREDENTIALS` | Azure Service Principal JSON (see below) |
| `NGINX_JWT` | NGINX license JWT token |
| `NGINX_REPO_CRT` | NGINX private registry certificate (`nginx-repo.crt`) |
| `NGINX_REPO_KEY` | NGINX private registry key (`nginx-repo.key`) |

### Azure Service Principal format

The `AZURE_CREDENTIALS` secret must be a valid JSON object in this format:

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

---

## Deploy

### Workflow file

`.github/workflows/az-apply-nic-napv5.yaml`

### Triggers

| Trigger | Description |
|---------|-------------|
| `push` to `az-apply-nic-napv5` branch | Automatic execution on push |
| `workflow_dispatch` | Manual execution from GitHub Actions UI |

### Architecture

The workflow deploys the following infrastructure in sequence:

```
terraform_blob → terraform_infra → terraform_aks → terraform_nap → terraform_policy → terraform_arcadia
```

### Jobs

#### 1. `terraform_blob` — Deploy Blob Storage
**Directory:** `azure/blob`

Creates the Azure Resource Group and Blob Storage Account/Container used as the remote Terraform backend for all subsequent jobs.

- Uses **local state** (no remote backend)
- Automatically imports pre-existing resources into the Terraform state to avoid conflicts on re-runs
- Resources created:
  - Resource Group: `<PROJECT_PREFIX>-rg`
  - Storage Account: `<STORAGE_ACCOUNT_NAME>`
  - Blob Container: `<STORAGE_ACCOUNT_NAME>-container`

#### 2. `terraform_infra` — Deploy Azure Infrastructure
**Directory:** `azure/infra`

Deploys the base Azure network infrastructure.

- Uses remote backend (Blob Storage created in job 1)
- Resources created:
  - Virtual Network (VNet)
  - Subnets
  - Network Security Groups

#### 3. `terraform_aks` — Deploy AKS Cluster
**Directory:** `azure/aks`

Creates the Azure Kubernetes Service cluster.

- Uses remote backend
- VM size: `Standard_D2s_v3`
- Resources created:
  - AKS Cluster with SystemAssigned identity
  - Azure CNI network plugin

#### 4. `terraform_nap` — Deploy NGINX NIC / App Protect
**Directory:** `azure/nap`

Installs NGINX Ingress Controller with App Protect V5 on the AKS cluster using Helm/Terraform.

- Uses remote backend
- Requires `NGINX_JWT` secret for authenticating with the NGINX private registry
- Resources created:
  - Kubernetes namespaces: `nginx-ingress`, `monitoring`
  - NGINX Ingress Controller (Helm release)
  - Prometheus + Grafana for monitoring
  - Azure Load Balancer (automatically provisioned by AKS)

#### 5. `terraform_policy` — Deploy NGINX WAF Policy
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

#### 6. `terraform_arcadia` — Deploy Arcadia WebApp
**Directory:** `azure/arcadia`

Deploys the Arcadia Finance demo application and exposes it via the NGINX Ingress Controller.

- Outputs the `external_name` (DNS) of the Azure Load Balancer upon completion

### Terraform State

All jobs (except `terraform_blob`) store state in the Azure Blob Storage backend:

| Parameter | Value |
|-----------|-------|
| Resource Group | `<PROJECT_PREFIX>-rg` |
| Storage Account | `<STORAGE_ACCOUNT_NAME>` |
| Container | `<STORAGE_ACCOUNT_NAME>-container` |

### Re-running the workflow

The workflow is **idempotent**. Each job checks for changes before applying:

- If `terraform plan` shows `No changes.` → `terraform apply` is skipped
- If resources already exist in Azure but not in state → they are automatically imported (blob job)

---

## Destroy

### Workflow file

`.github/workflows/az-destroy-nic-napv5.yaml`

### Triggers

| Trigger | Description |
|---------|-------------|
| `push` to `az-destroy-nic-napv5` branch | Automatic execution on push |
| `workflow_dispatch` | Manual execution from GitHub Actions UI |

### Architecture

The destroy workflow runs jobs in **reverse order** relative to the deploy:

```
terraform_arcadia → terraform_policy → terraform_nap → terraform_aks → terraform_infra → terraform_blob
```

### Jobs

#### 1. `terraform_arcadia` — Destroy Arcadia WebApp
**Directory:** `azure/arcadia`

Destroys the Arcadia application and its Kubernetes/Azure resources.

#### 2. `terraform_policy` — Destroy NGINX Policy
**Directory:** `azure/policy`

Removes the WAF policy configuration from Terraform state and Azure.

#### 3. `terraform_nap` — Destroy NGINX NIC / App Protect
**Directory:** `azure/nap`

Uninstalls the NGINX Ingress Controller and App Protect V5 Helm release. Also removes Prometheus, Grafana, namespaces, and secrets.

- Requires `NGINX_JWT` secret

#### 4. `terraform_aks` — Destroy AKS Cluster
**Directory:** `azure/aks`

Deletes the AKS cluster. The Azure Load Balancer is automatically removed by AKS.

#### 5. `terraform_infra` — Destroy Azure Infrastructure
**Directory:** `azure/infra`

Removes the VNet, subnets, and network security groups.

#### 6. `terraform_blob` — Delete Blob Storage
**Directory:** `azure/blob`

Final cleanup step (does **not** use Terraform since the backend itself is being deleted):

1. Retrieves the Storage Account key via Azure CLI
2. Deletes all blobs and snapshots from the container
3. Deletes the Blob Container
4. Deletes the Resource Group (`az group delete --yes --no-wait`)
5. Waits 120 seconds and verifies the Resource Group no longer exists

> **Note:** If the destroy workflow fails mid-run and resources are already partially deleted, you can manually delete the Resource Group with:
> ```bash
> az group delete --name <PROJECT_PREFIX>-rg --yes
> ```
