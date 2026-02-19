# OpenClaw on Azure Container Apps

Deploy [OpenClaw](https://github.com/openclaw/openclaw) on Azure Container Apps — containerized, with GitHub Copilot as the LLM provider.

OpenClaw is an open-source AI agent that runs 24/7 — it can browse the web, execute tasks, manage files, and communicate through multiple channels. This guide deploys it on Azure with managed HTTPS, NFS-backed persistent storage, and no Docker Desktop required on your machine.

## Prerequisites

- Azure CLI 2.80+ (`az version`)
- Active Azure subscription (`az account show`)
- Git

Docker Desktop is **not required** — images are built remotely via `az acr build`.

Verify resource providers are registered:

```powershell
az provider show --namespace Microsoft.App --query "registrationState" -o tsv
az provider show --namespace Microsoft.ContainerRegistry --query "registrationState" -o tsv
az provider show --namespace Microsoft.Storage --query "registrationState" -o tsv
az provider show --namespace Microsoft.OperationalInsights --query "registrationState" -o tsv
az provider show --namespace Microsoft.ManagedIdentity --query "registrationState" -o tsv
```

If any show `NotRegistered`: `az provider register --namespace <name>`.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│ Azure Resource Group: rg-openclaw                               │
│                                                                 │
│  ┌──────────────────── VNet (10.1.0.0/26) ───────────────────┐  │
│  │                                                            │  │
│  │  ┌─ ACA subnet (/27) ───────────────────────────────────┐ │  │
│  │  │  Container Apps Environment                           │ │  │
│  │  │  ┌─────────────────────────────────────────────────┐  │ │  │
│  │  │  │ ca-openclaw                                     │  │ │  │
│  │  │  │ 2 vCPU / 4 GiB · Port 18789 · HTTPS ingress    │  │ │  │
│  │  │  └───────────────────────┬─────────────────────────┘  │ │  │
│  │  │                         │ NFS mount                    │ │  │
│  │  └─────────────────────────┼──────────────────────────────┘ │  │
│  │  ┌─ PE subnet (/28) ──────┼──────────────────────────────┐ │  │
│  │  │  Private Endpoint ──────┘                              │ │  │
│  │  └────────────────────────────────────────────────────────┘ │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                 │
│  ACR · Premium NFS Storage · Log Analytics                      │
└─────────────────────────────────────────────────────────────────┘
```

---

## Quick Deploy

```powershell
# 0. Clone this repo
git clone https://github.com/spiroskon/openclaw-azure-containerapps.git
cd openclaw-azure-containerapps

# 1. Infrastructure (~5 min) — names are auto-generated, nothing to configure
az group create --name rg-openclaw --location swedencentral
az deployment group create --resource-group rg-openclaw `
  --template-file bicep/main.bicep --parameters bicep/main.bicepparam

# 2. Build + deploy + configure (~10 min) — clones source, builds image, configures gateway
.\deploy-openclaw.ps1 -ResourceGroup rg-openclaw

# 3. GitHub Copilot auth (only interactive step)
az containerapp exec --name ca-openclaw --resource-group rg-openclaw
#   node openclaw.mjs models auth login-github-copilot    → device flow in browser
#   exit
```

Open the Control UI URL from the script output. Send a test message.

### What Bicep creates

| Resource | Type |
|----------|------|
| VNet + 2 subnets | `Microsoft.Network/virtualNetworks` |
| Premium FileStorage + NFS share | `Microsoft.Storage/storageAccounts` |
| Private endpoint + DNS | `Microsoft.Network/privateEndpoints` |
| Azure Container Registry | `Microsoft.ContainerRegistry/registries` |
| Log Analytics Workspace | `Microsoft.OperationalInsights/workspaces` |
| ACA Environment + NFS storage | `Microsoft.App/managedEnvironments` |
| Container App (placeholder) | `Microsoft.App/containerApps` |

### What the deploy script does

1. Clones OpenClaw source (if not already present)
2. Builds the image from source and pushes to ACR (~6 min)
3. Generates a secure gateway token
4. Updates the Container App with full config (image, NFS mount, startup command)
5. Runs non-interactive onboard, sets model, enables Control UI access
6. Outputs the Control UI URL with the token

---

## Post-Deploy: Security Audit

```powershell
az containerapp exec --name ca-openclaw --resource-group rg-openclaw `
  --command "node openclaw.mjs security audit"
```

| Finding | Severity | Verdict |
|---------|----------|---------|
| `allowInsecureAuth` enabled | CRITICAL | **By design** — ACA terminates TLS; internal hop is inside the managed environment |
| State dir world-writable (777) | CRITICAL | **Cosmetic** — NFS mount root is 777; files inside are owned by `node` with correct permissions |
| No auth rate limiting | WARN | **Accepted** — 256-bit token; brute force infeasible |

---

## Key Design Decisions

- **Azure Container Apps** over ACI/VM — managed ingress, auto-TLS, consumption pricing
- **NFS over SMB** — NFS authenticates via network rules (private endpoint), bypassing `allowSharedKeyAccess: false` tenant policies
- **Two-phase deploy** — Bicep (infrastructure + placeholder) then script (image build + app update)
- **GitHub Copilot as LLM provider** — built-in provider with device flow auth, no API keys needed

---

## Manual CLI Reference

<details>
<summary>Deploy without Bicep — every Azure resource created individually (8 steps)</summary>

These steps show how each resource was originally configured. Every gotcha is already handled in the Bicep template.

### Step 1: Create Resource Group

```powershell
az group create --name rg-openclaw --location swedencentral
```

### Step 2: Create Azure Container Registry

```powershell
az acr create --name <your-acr-name> --resource-group rg-openclaw `
  --sku Basic --admin-enabled true --location swedencentral
```

**Gotcha**: ACR names must be globally unique. Check with `az acr check-name --name <name>`.

### Step 3: Clone source and build image

```powershell
git clone https://github.com/openclaw/openclaw.git openclaw-repo
az acr build --registry <your-acr-name> --image openclaw:latest `
  --file openclaw-repo/Dockerfile openclaw-repo/
```

### Step 4: Create networking + NFS storage

> **Why NFS?** Some tenants enforce `allowSharedKeyAccess: false`. NFS authenticates via network rules (private endpoint), bypassing the restriction.

```powershell
az network vnet create --resource-group rg-openclaw --name vnet-openclaw `
  --location swedencentral --address-prefix 10.1.0.0/26

az network vnet subnet create --resource-group rg-openclaw --vnet-name vnet-openclaw `
  --name snet-aca --address-prefixes 10.1.0.0/27 `
  --delegations Microsoft.App/environments --service-endpoints Microsoft.Storage

az network vnet subnet create --resource-group rg-openclaw --vnet-name vnet-openclaw `
  --name snet-pe --address-prefixes 10.1.0.32/28

az storage account create --name <your-storage-name> --resource-group rg-openclaw `
  --location swedencentral --sku Premium_LRS --kind FileStorage `
  --enable-large-file-share --https-only false

az storage share-rm create --storage-account <your-storage-name> `
  --resource-group rg-openclaw --name openclaw-state --quota 100 --enabled-protocols NFS

$storageId = (az storage account show --name <your-storage-name> `
  --resource-group rg-openclaw --query "id" -o tsv)

az network private-endpoint create --resource-group rg-openclaw --name pep-storage `
  --vnet-name vnet-openclaw --subnet snet-pe `
  --private-connection-resource-id $storageId --group-id file `
  --connection-name connection-storage --location swedencentral

az network private-dns zone create --resource-group rg-openclaw `
  --name "privatelink.file.core.windows.net"

az network private-dns link vnet create --resource-group rg-openclaw `
  --zone-name "privatelink.file.core.windows.net" --name link-vnet `
  --virtual-network vnet-openclaw --registration-enabled false

az network private-endpoint dns-zone-group create --resource-group rg-openclaw `
  --endpoint-name pep-storage --name dnsgroup-storage `
  --private-dns-zone "privatelink.file.core.windows.net" --zone-name file
```

### Step 5: Create Log Analytics Workspace

```powershell
az monitor log-analytics workspace create --resource-group rg-openclaw `
  --workspace-name law-openclaw --location swedencentral
```

### Step 6: Create Container Apps Environment + NFS storage

```powershell
$SUBNET_ID = (az network vnet subnet show --resource-group rg-openclaw `
  --vnet-name vnet-openclaw --name snet-aca --query "id" -o tsv)
$LAW_ID = (az monitor log-analytics workspace show --resource-group rg-openclaw `
  --workspace-name law-openclaw --query "customerId" -o tsv)
$LAW_KEY = (az monitor log-analytics workspace get-shared-keys --resource-group rg-openclaw `
  --workspace-name law-openclaw --query "primarySharedKey" -o tsv)

az containerapp env create --name cae-openclaw --resource-group rg-openclaw `
  --location swedencentral --infrastructure-subnet-resource-id $SUBNET_ID `
  --logs-workspace-id $LAW_ID --logs-workspace-key $LAW_KEY

az extension add -n containerapp --upgrade
$STORAGE_KEY = (az storage account keys list --account-name <your-storage-name> `
  --resource-group rg-openclaw --query "[0].value" -o tsv)

az containerapp env storage set --name cae-openclaw --resource-group rg-openclaw `
  --storage-name openclawstorage --storage-type NfsAzureFile `
  --server <your-storage-name>.file.core.windows.net `
  --azure-file-share-name /<your-storage-name>/openclaw-state `
  --azure-file-account-name <your-storage-name> --azure-file-account-key $STORAGE_KEY `
  --access-mode ReadWrite
```

### Step 7: Create Container App

```powershell
$bytes = New-Object byte[] 32
[System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
$GATEWAY_TOKEN = [BitConverter]::ToString($bytes).Replace('-','').ToLower()

$ACR_USERNAME = (az acr credential show --name <your-acr-name> --query "username" -o tsv)
$ACR_PASSWORD = (az acr credential show --name <your-acr-name> --query "passwords[0].value" -o tsv)

az containerapp create --name ca-openclaw --resource-group rg-openclaw `
  --environment cae-openclaw --image <your-acr-name>.azurecr.io/openclaw:latest `
  --registry-server <your-acr-name>.azurecr.io `
  --registry-username $ACR_USERNAME --registry-password $ACR_PASSWORD `
  --target-port 18789 --ingress external --min-replicas 1 --max-replicas 1 `
  --cpu 2.0 --memory 4Gi `
  --env-vars "OPENCLAW_GATEWAY_TOKEN=$GATEWAY_TOKEN" "NODE_ENV=production" "HOME=/home/node" "TERM=xterm-256color"
```

Then add NFS volume mount via YAML update (see deploy script for exact structure).

### Step 8: Configure OpenClaw

```powershell
az containerapp exec --name ca-openclaw --resource-group rg-openclaw
```

Inside the container:

```sh
node openclaw.mjs onboard --non-interactive --accept-risk --mode local --flow manual \
  --auth-choice skip --gateway-port 18789 --gateway-bind lan --gateway-auth token \
  --gateway-token $OPENCLAW_GATEWAY_TOKEN --skip-channels --skip-skills --skip-daemon --skip-health
node openclaw.mjs models set github-copilot/claude-opus-4.6
node openclaw.mjs config set gateway.controlUi.allowInsecureAuth true
node openclaw.mjs models auth login-github-copilot
exit
```

</details>

---

## Cleanup

```powershell
az group delete --name rg-openclaw --yes --no-wait
```

## Related

- [OpenClaw Secure Docker Setup](https://github.com/spiroskon/openclaw-secure-docker) — run OpenClaw locally on Windows with Docker
- [OpenClaw Official Docs](https://docs.openclaw.ai)
- [OpenClaw GitHub](https://github.com/openclaw/openclaw)

## Tested With

| Component | Version |
|-----------|--------|
| OpenClaw | Latest from `main` branch (Feb 2026) |
| Azure CLI | 2.80+ |
| Bicep | Built-in with Azure CLI |
| Region | Sweden Central |
| LLM | `github-copilot/claude-opus-4.6` |

## License

MIT
