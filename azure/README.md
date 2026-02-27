# Despliegue y destrucción de NGINX NIC / NAP-V5 en Azure

Este documento describe los workflows de GitHub Actions para desplegar y destruir un stack completo de NGINX Ingress Controller (NIC) con App Protect V5 (NAP) en Azure Kubernetes Service (AKS), incluyendo la aplicación de demo Arcadia.

---

## Requisitos previos

### Variables de GitHub (`vars`)

| Variable | Descripción | Ejemplo |
|----------|-------------|---------|
| `PROJECT_PREFIX` | Prefijo para todos los recursos de Azure | `proyaz` |
| `AZURE_REGION` | Región de Azure donde se desplegarán los recursos | `centralus` |
| `STORAGE_ACCOUNT_NAME` | Nombre de la Storage Account de Azure para el backend de Terraform | `staz` |

### Secretos de GitHub (`secrets`)

| Secreto | Descripción |
|---------|-------------|
| `AZURE_CREDENTIALS` | JSON del Service Principal de Azure (ver formato más abajo) |
| `NGINX_JWT` | Token JWT de licencia de NGINX |
| `NGINX_REPO_CRT` | Certificado del registro privado de NGINX (`nginx-repo.crt`) |
| `NGINX_REPO_KEY` | Clave del registro privado de NGINX (`nginx-repo.key`) |

### Formato del Service Principal de Azure

El secreto `AZURE_CREDENTIALS` debe ser un objeto JSON con el siguiente formato:

```json
{
  "clientId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "clientSecret": "your-client-secret",
  "subscriptionId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "tenantId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
}
```

Generarlo con:

```bash
az ad sp create-for-rbac \
  --name "github-actions-sp" \
  --role contributor \
  --scopes /subscriptions/<SUBSCRIPTION_ID> \
  --sdk-auth
```

---

## Despliegue

### Archivo del workflow

`.github/workflows/az-apply-nic-napv5.yaml`

### Disparadores

| Disparador | Descripción |
|------------|-------------|
| `push` a la rama `az-apply-nic-napv5` | Ejecución automática al hacer push |
| `workflow_dispatch` | Ejecución manual desde la interfaz de GitHub Actions |

### Arquitectura

El workflow despliega la siguiente infraestructura en secuencia:

```
terraform_blob → terraform_infra → terraform_aks → terraform_nap → terraform_policy → terraform_arcadia
```

### Jobs

#### 1. `terraform_blob` — Desplegar Blob Storage
**Directorio:** `azure/blob`

Crea el Resource Group de Azure y la Storage Account/Container de Blob usados como backend remoto de Terraform por todos los jobs siguientes.

- Usa **estado local** (sin backend remoto)
- Importa automáticamente recursos preexistentes al estado de Terraform para evitar conflictos en re-ejecuciones
- Recursos creados:
  - Resource Group: `<PROJECT_PREFIX>-rg`
  - Storage Account: `<STORAGE_ACCOUNT_NAME>`
  - Blob Container: `<STORAGE_ACCOUNT_NAME>-container`

#### 2. `terraform_infra` — Desplegar infraestructura de Azure
**Directorio:** `azure/infra`

Despliega la infraestructura de red base de Azure.

- Usa el backend remoto (Blob Storage creado en el job 1)
- Recursos creados:
  - Virtual Network (VNet)
  - Subredes
  - Network Security Groups

#### 3. `terraform_aks` — Desplegar clúster AKS
**Directorio:** `azure/aks`

Crea el clúster de Azure Kubernetes Service.

- Usa el backend remoto
- Tamaño de VM: `Standard_D2s_v3`
- Recursos creados:
  - Clúster AKS con identidad SystemAssigned
  - Plugin de red Azure CNI

#### 4. `terraform_nap` — Desplegar NGINX NIC / App Protect
**Directorio:** `azure/nap`

Instala NGINX Ingress Controller con App Protect V5 en el clúster AKS usando Helm/Terraform.

- Usa el backend remoto
- Requiere el secreto `NGINX_JWT` para autenticarse en el registro privado de NGINX
- Recursos creados:
  - Namespaces de Kubernetes: `nginx-ingress`, `monitoring`
  - NGINX Ingress Controller (release de Helm)
  - Prometheus + Grafana para monitoreo
  - Azure Load Balancer (provisionado automáticamente por AKS)

#### 5. `terraform_policy` — Desplegar política WAF de NGINX
**Directorio:** `azure/policy`

Compila y despliega la política de seguridad WAF en el NGINX Ingress Controller.

Pasos que realiza:
1. Obtiene las credenciales del AKS con `az aks get-credentials`
2. Instala Docker en el runner
3. Se autentica en `private-registry.nginx.com` usando `NGINX_REPO_CRT` / `NGINX_REPO_KEY`
4. Construye la imagen del compilador WAF (`waf-compiler-5.4.0`)
5. Compila `policy.json` → `compiled_policy.tgz`
6. Copia el bundle compilado directamente al pod de NGINX: `/etc/app_protect/bundles/compiled_policy.tgz`
7. Aplica Terraform para configurar la política en NIC

#### 6. `terraform_arcadia` — Desplegar Arcadia WebApp
**Directorio:** `azure/arcadia`

Despliega la aplicación de demo Arcadia Finance y la expone a través del NGINX Ingress Controller.

- Muestra el `external_name` (DNS) del Azure Load Balancer al finalizar

### Estado de Terraform

Todos los jobs (excepto `terraform_blob`) almacenan el estado en el backend de Azure Blob Storage:

| Parámetro | Valor |
|-----------|-------|
| Resource Group | `<PROJECT_PREFIX>-rg` |
| Storage Account | `<STORAGE_ACCOUNT_NAME>` |
| Container | `<STORAGE_ACCOUNT_NAME>-container` |

### Re-ejecución del workflow

El workflow es **idempotente**. Cada job verifica si hay cambios antes de aplicar:

- Si `terraform plan` muestra `No changes.` → `terraform apply` se omite
- Si los recursos ya existen en Azure pero no en el estado → se importan automáticamente (job blob)

---

## Destrucción

### Archivo del workflow

`.github/workflows/az-destroy-nic-napv5.yaml`

### Disparadores

| Disparador | Descripción |
|------------|-------------|
| `push` a la rama `az-destroy-nic-napv5` | Ejecución automática al hacer push |
| `workflow_dispatch` | Ejecución manual desde la interfaz de GitHub Actions |

### Arquitectura

El workflow de destrucción ejecuta los jobs en **orden inverso** al despliegue:

```
terraform_arcadia → terraform_policy → terraform_nap → terraform_aks → terraform_infra → terraform_blob
```

### Jobs

#### 1. `terraform_arcadia` — Destruir Arcadia WebApp
**Directorio:** `azure/arcadia`

Destruye la aplicación Arcadia y sus recursos de Kubernetes/Azure.

#### 2. `terraform_policy` — Destruir política NGINX
**Directorio:** `azure/policy`

Elimina la configuración de la política WAF del estado de Terraform y de Azure.

#### 3. `terraform_nap` — Destruir NGINX NIC / App Protect
**Directorio:** `azure/nap`

Desinstala el release de Helm de NGINX Ingress Controller y App Protect V5. También elimina Prometheus, Grafana, namespaces y secretos.

- Requiere el secreto `NGINX_JWT`

#### 4. `terraform_aks` — Destruir clúster AKS
**Directorio:** `azure/aks`

Elimina el clúster AKS. El Azure Load Balancer es eliminado automáticamente por AKS.

#### 5. `terraform_infra` — Destruir infraestructura de Azure
**Directorio:** `azure/infra`

Elimina la VNet, subredes y network security groups.

#### 6. `terraform_blob` — Eliminar Blob Storage
**Directorio:** `azure/blob`

Paso final de limpieza (no usa Terraform ya que el propio backend está siendo eliminado):

1. Obtiene la clave de la Storage Account vía Azure CLI
2. Elimina todos los blobs y snapshots del container
3. Elimina el Blob Container
4. Elimina el Resource Group (`az group delete --yes --no-wait`)
5. Espera 120 segundos y verifica que el Resource Group ya no existe

> **Nota:** Si el workflow de destrucción falla a mitad de la ejecución y los recursos ya están parcialmente eliminados, puedes eliminar manualmente el Resource Group con:
> ```bash
> az group delete --name <PROJECT_PREFIX>-rg --yes
> ```
