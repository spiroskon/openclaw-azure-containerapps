# Deploying OpenClaw on Azure Container Apps

> Step-by-step guide for deploying OpenClaw on Azure using Azure Container Apps, Azure Container Registry, and GitHub Copilot as the LLM provider.
>
> **Recommended**: Use the [Bicep template](#deploy-with-bicep-recommended) for the fastest path — two commands + one script, ~20 minutes.
>
> This guide also includes the full [manual CLI reference](#manual-cli-reference) documenting every resource individually — useful for understanding each component or customizing the deployment.

## Prerequisites

### Required tools

| Tool | Minimum version | Check with |
|------|----------------|------------|
| Azure CLI | 2.80+ | `az version` |
| Git | Any recent | `git --version` |
| Active Azure subscription | — | `az account show` |

Docker Desktop is **not required** — we use `az acr build` (cloud build) to build the container image remotely in Azure.

### Azure subscription setup

Before creating resources, verify your subscription has the required resource providers registered:

```powershell
# Check which providers are registered
az provider show --namespace Microsoft.App --query "registrationState" -o tsv
az provider show --namespace Microsoft.ContainerRegistry --query "registrationState" -o tsv
az provider show --namespace Microsoft.Storage --query "registrationState" -o tsv
az provider show --namespace Microsoft.OperationalInsights --query "registrationState" -o tsv
az provider show --namespace Microsoft.ManagedIdentity --query "registrationState" -o tsv
```

All five should return `Registered`. If any show `NotRegistered`, register them:

```powershell
az provider register --namespace Microsoft.App
az provider register --namespace Microsoft.ContainerRegistry
az provider register --namespace Microsoft.Storage
az provider register --namespace Microsoft.OperationalInsights
az provider register --namespace Microsoft.ManagedIdentity
```

Registration can take a few minutes. Poll with the `az provider show` commands above until all return `Registered`.

### Clone the OpenClaw source

OpenClaw has no public container registry. You must build the image from source.

```powershell
git clone https://github.com/openclaw/openclaw.git upstream/repo
```

This guide assumes the cloned repo is at `upstream/repo/` relative to your working directory.

---

## Architecture overview

```
┌─────────────────────────────────────────────────────────────────┐
│ Azure Resource Group: rg-openclaw                               │
│                                                                 │
│  ┌──────────────────── VNet (10.1.0.0/26) ───────────────────┐  │
│  │                                                            │  │
│  │  ┌─ ACA subnet (10.1.0.0/27) ───────────────────────────┐ │  │
│  │  │  Container Apps Environment                           │ │  │
│  │  │                                                       │ │  │
│  │  │  ┌─────────────────────────────────────────────────┐  │ │  │
│  │  │  │ Container App: ca-openclaw                      │  │ │  │
│  │  │  │ • 2 vCPU / 4 GiB  • Port 18789  • HTTPS ingress│  │ │  │
│  │  │  └───────────────────────┬─────────────────────────┘  │ │  │
│  │  │                         │ NFS mount                    │ │  │
│  │  └─────────────────────────┼──────────────────────────────┘ │  │
│  │                            │                                │  │
│  │  ┌─ PE subnet (10.1.0.32/28) ────────────────────────────┐ │  │
│  │  │  Private Endpoint → Storage Account                    │ │  │
│  │  └───────────────────────────────────────────────────────┘ │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                 │
│  ┌──────────────┐  ┌──────────────────┐  ┌───────────────────┐  │
│  │ ACR           │  │ Storage (NFS)    │  │ Log Analytics     │  │
│  └──────────────┘  └──────────────────┘  └───────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

**Key design decisions:**

- **Azure Container Apps** — managed ingress with auto-TLS, no cluster to operate, consumption-based pricing. See [deployment-options-adr.md](deployment-options-adr.md) for the full evaluation.
- **NFS Azure Files** — real filesystem mount required because OpenClaw hot-reloads config via file watching. NFS chosen over SMB because some Azure tenants enforce `allowSharedKeyAccess: false`, blocking ACA's SMB mount. NFS authenticates via network rules (private endpoint), bypassing the restriction.
- **Custom VNet** — required for NFS mounts on ACA. Right-sized to `/26` (64 IPs) with two subnets.
- **Min/Max replicas: 1** — OpenClaw enforces single-instance via exclusive TCP port bind.
- **GitHub Copilot as LLM provider** — built-in `github-copilot` provider with device flow auth. One-time interactive setup post-deploy.

---

## Deploy with Bicep (Recommended)

The manual CLI steps have been codified into two artifacts:

1. **`bicep/main.bicep`** — deploys all infrastructure + a placeholder container (Microsoft ACA quickstart)
2. **`bicep/deploy-openclaw.ps1`** — builds OpenClaw image, generates gateway token, updates the container app

This two-phase split exists because Bicep is declarative (what should exist) while image builds are imperative (do this action). The image can't exist in ACR before ACR itself is created by the template.

### Step 1: Deploy infrastructure

No configuration needed — resource names (ACR, Storage) are auto-generated with unique suffixes.

```powershell
# Create resource group
az group create --name rg-openclaw --location swedencentral

# Deploy all infrastructure + placeholder container (~5-10 min)
az deployment group create `
  --resource-group rg-openclaw `
  --template-file bicep/main.bicep `
  --parameters bicep/main.bicepparam
```

When complete, the output includes `appUrl`, `acrName`, and `appName`. Open `appUrl` to see the ACA quickstart page.

### What Bicep creates

| Resource | Type |
|----------|------|
| VNet + 2 subnets | `Microsoft.Network/virtualNetworks` |
| Premium FileStorage account | `Microsoft.Storage/storageAccounts` |
| NFS file share (100 GiB) | `Microsoft.Storage/.../shares` |
| Private endpoint | `Microsoft.Network/privateEndpoints` |
| Private DNS zone | `Microsoft.Network/privateDnsZones` |
| DNS zone VNet link | `Microsoft.Network/privateDnsZones/virtualNetworkLinks` |
| DNS zone group | `Microsoft.Network/privateEndpoints/privateDnsZoneGroups` |
| Azure Container Registry | `Microsoft.ContainerRegistry/registries` |
| Log Analytics Workspace | `Microsoft.OperationalInsights/workspaces` |
| ACA Environment + NFS storage | `Microsoft.App/managedEnvironments` + `/storages` |
| Container App (placeholder) | `Microsoft.App/containerApps` |

### Step 2: Deploy OpenClaw

```powershell
.\bicep\deploy-openclaw.ps1 -ResourceGroup rg-openclaw
```

The script auto-discovers the ACR and App names from the Bicep deployment outputs, then:
1. Builds the OpenClaw image from source and pushes to ACR (~6 min)
2. Generates a secure gateway token
3. Updates the Container App with the full OpenClaw configuration (ACR auth, NFS volume mount, startup command, environment variables)
4. Outputs the Control UI URL with the token

### Step 3: Configure OpenClaw

Connect to the running container and configure the gateway, then authenticate GitHub Copilot.

```powershell
az containerapp exec --name ca-openclaw --resource-group rg-openclaw
```

Inside the container shell, run these commands in order:

```sh
# 1. Configure gateway (non-interactive — uses the token already set by deploy script)
node openclaw.mjs onboard \
  --non-interactive \
  --accept-risk \
  --mode local \
  --flow manual \
  --auth-choice skip \
  --gateway-port 18789 \
  --gateway-bind lan \
  --gateway-auth token \
  --gateway-token $OPENCLAW_GATEWAY_TOKEN \
  --skip-channels \
  --skip-skills \
  --skip-daemon \
  --skip-health

# 2. Authenticate GitHub Copilot (interactive — opens device flow)
node openclaw.mjs models auth login-github-copilot
```

The Copilot auth command shows a URL and code. Open `https://github.com/login/device` in your browser, enter the code, and authorize. Then continue:

```sh
# 3. Set model
node openclaw.mjs models set github-copilot/claude-opus-4.6

# 4. Enable Control UI token access
node openclaw.mjs config set gateway.controlUi.allowInsecureAuth true

# 5. Exit
exit
```

> **Gotcha**: Model IDs use dots not hyphens: `claude-opus-4.6` works, `claude-opus-4-6` gives "Unknown model".

Restart the container to apply `allowInsecureAuth`:

```powershell
$rev = az containerapp show --name ca-openclaw --resource-group rg-openclaw `
  --query "properties.latestRevisionName" -o tsv
az containerapp revision restart --revision $rev --resource-group rg-openclaw
```

Wait ~30 seconds for the restart.

<details>
<summary>Alternative: interactive wizard (if you prefer manual control)</summary>

```sh
node openclaw.mjs onboard
```

| Prompt | Choose | Why |
|--------|--------|-----|
| Security warning | **Yes** | |
| Onboarding mode | **Manual** | NOT QuickStart — QuickStart defaults to loopback, which breaks ACA |
| Gateway location | **Local gateway** | Running inside the container |
| Workspace directory | **Enter** (default) | |
| Gateway port | **Enter** (18789) | |
| Gateway bind | **LAN (0.0.0.0)** | **CRITICAL** — ACA ingress requires non-loopback bind |
| Gateway auth | **Token** | |
| Tailscale | **Off** | |
| Gateway token | **Paste `$OPENCLAW_GATEWAY_TOKEN`** | Must match the env var from deploy script |
| Channels | **No** | |
| Skills | **Yes** → **Skip** dependencies | |
| Hooks | **Skip for now** | |
| How to hatch | **Do this later** | No model configured yet |

Then run the Copilot auth and remaining commands as above.

</details>

### Step 4: Access the Control UI and verify

Open in your browser:

```
https://<your-app-fqdn>/#token=<your-gateway-token>
```

Both values were printed by the deploy script output. The Control UI should show **Health OK** and **Connected**. Send a message — the assistant should respond via GitHub Copilot's Claude Opus 4.6.

---

## Manual CLI Reference

The following steps document how each Azure resource was originally configured during the manual deployment. Every gotcha discovered here is already handled in the Bicep template. Use this reference to understand individual resources or to deploy without Bicep.

### Step 1: Create the Resource Group

```powershell
az group create --name rg-openclaw --location swedencentral
```

Choose any [region where ACA is available](https://azure.microsoft.com/explore/global-infrastructure/products-by-region/?products=container-apps).

### Step 2: Create Azure Container Registry

```powershell
az acr create `
  --name <your-acr-name> `
  --resource-group rg-openclaw `
  --sku Basic `
  --admin-enabled true `
  --location swedencentral
```

| Parameter | Why |
|-----------|-----|
| `--sku Basic` | Single image, cheapest tier |
| `--admin-enabled true` | Required for `--registry-username`/`--registry-password` when creating the Container App |

**Gotcha**: ACR names must be globally unique. Use `az acr check-name --name <name>` to verify.

### Step 3: Build and push the OpenClaw image

```powershell
az acr build `
  --registry <your-acr-name> `
  --image openclaw:latest `
  --file upstream/repo/Dockerfile `
  upstream/repo/
```

| Parameter | Why |
|-----------|-----|
| `--file` path | Relative to your **current working directory**, not to the build context |
| positional | Build context directory — this gets uploaded to ACR |

**Build time**: ~6 minutes. No local Docker needed.

### Step 4: Create networking and persistent storage (NFS)

OpenClaw stores config, credentials, and session state in `/home/node/.openclaw`. This must persist across container restarts.

> **Why NFS instead of SMB?** Some Azure tenants enforce `allowSharedKeyAccess: false` on storage accounts. ACA's SMB mount requires a storage account key, which is blocked by this policy. NFS authenticates via network rules (private endpoint), bypassing the restriction.

NFS on ACA requires:
1. A **custom VNet** for the ACA environment
2. A **Premium FileStorage** account (NFS only works on Premium)
3. A **private endpoint** connecting the storage account to the VNet

#### 4a: Create Virtual Network

```powershell
# VNet with /26 address space (64 IPs)
az network vnet create `
  --resource-group rg-openclaw `
  --name vnet-openclaw `
  --location swedencentral `
  --address-prefix 10.1.0.0/26

# ACA subnet (/27 = 32 IPs, minimum for workload profiles)
az network vnet subnet create `
  --resource-group rg-openclaw `
  --vnet-name vnet-openclaw `
  --name snet-aca `
  --address-prefixes 10.1.0.0/27 `
  --delegations Microsoft.App/environments `
  --service-endpoints Microsoft.Storage

# Private endpoint subnet (/28 = 16 IPs)
az network vnet subnet create `
  --resource-group rg-openclaw `
  --vnet-name vnet-openclaw `
  --name snet-pe `
  --address-prefixes 10.1.0.32/28
```

**Gotcha**: Check existing VNets (`az network vnet list`) to avoid address space overlaps.

#### 4b: Create Premium FileStorage with NFS share

```powershell
# Premium FileStorage account (required for NFS)
az storage account create `
  --name <your-storage-name> `
  --resource-group rg-openclaw `
  --location swedencentral `
  --sku Premium_LRS `
  --kind FileStorage `
  --enable-large-file-share `
  --https-only false

# NFS file share (100 GiB minimum on Premium)
az storage share-rm create `
  --storage-account <your-storage-name> `
  --resource-group rg-openclaw `
  --name openclaw-state `
  --quota 100 `
  --enabled-protocols NFS
```

| Parameter | Why |
|-----------|-----|
| `--kind FileStorage` | NFS requires FileStorage kind |
| `--sku Premium_LRS` | NFS requires Premium tier |
| `--quota 100` | 100 GiB minimum for Premium FileStorage |
| `--https-only false` | NFS uses plain TCP (port 2049). Without this, NFS mount fails with `access denied`. |

#### 4c: Create private endpoint + DNS

```powershell
$storageId = (az storage account show `
  --name <your-storage-name> `
  --resource-group rg-openclaw `
  --query "id" --output tsv)

az network private-endpoint create `
  --resource-group rg-openclaw `
  --name pep-storage `
  --vnet-name vnet-openclaw `
  --subnet snet-pe `
  --private-connection-resource-id $storageId `
  --group-id file `
  --connection-name connection-storage `
  --location swedencentral

az network private-dns zone create `
  --resource-group rg-openclaw `
  --name "privatelink.file.core.windows.net"

az network private-dns link vnet create `
  --resource-group rg-openclaw `
  --zone-name "privatelink.file.core.windows.net" `
  --name link-vnet `
  --virtual-network vnet-openclaw `
  --registration-enabled false

az network private-endpoint dns-zone-group create `
  --resource-group rg-openclaw `
  --endpoint-name pep-storage `
  --name dnsgroup-storage `
  --private-dns-zone "privatelink.file.core.windows.net" `
  --zone-name file
```

### Step 5: Create Log Analytics Workspace

```powershell
az monitor log-analytics workspace create `
  --resource-group rg-openclaw `
  --workspace-name law-openclaw `
  --location swedencentral
```

### Step 6: Create Container Apps Environment with VNet and NFS storage

```powershell
$SUBNET_ID = (az network vnet subnet show `
  --resource-group rg-openclaw `
  --vnet-name vnet-openclaw `
  --name snet-aca `
  --query "id" --output tsv)

$LAW_ID = (az monitor log-analytics workspace show `
  --resource-group rg-openclaw `
  --workspace-name law-openclaw `
  --query "customerId" --output tsv)

$LAW_KEY = (az monitor log-analytics workspace get-shared-keys `
  --resource-group rg-openclaw `
  --workspace-name law-openclaw `
  --query "primarySharedKey" --output tsv)

az containerapp env create `
  --name cae-openclaw `
  --resource-group rg-openclaw `
  --location swedencentral `
  --infrastructure-subnet-resource-id $SUBNET_ID `
  --logs-workspace-id $LAW_ID `
  --logs-workspace-key $LAW_KEY
```

Then link NFS storage:

```powershell
az extension add -n containerapp --upgrade

$STORAGE_KEY = (az storage account keys list `
  --account-name <your-storage-name> `
  --resource-group rg-openclaw `
  --query "[0].value" --output tsv)

az containerapp env storage set `
  --name cae-openclaw `
  --resource-group rg-openclaw `
  --storage-name openclawstorage `
  --storage-type NfsAzureFile `
  --server <your-storage-name>.file.core.windows.net `
  --azure-file-share-name /<your-storage-name>/openclaw-state `
  --azure-file-account-name <your-storage-name> `
  --azure-file-account-key $STORAGE_KEY `
  --access-mode ReadWrite
```

**Gotcha**: The `--azure-file-account-key` is required by the CLI even for NFS. The key is used by the ACA control plane to verify ownership. NFS data plane uses network rules.

### Step 7: Create the Container App

```powershell
# Generate a secure gateway token
$bytes = New-Object byte[] 32
[System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
$GATEWAY_TOKEN = [BitConverter]::ToString($bytes).Replace('-','').ToLower()

# Get ACR credentials
$ACR_USERNAME = (az acr credential show --name <your-acr-name> --query "username" --output tsv)
$ACR_PASSWORD = (az acr credential show --name <your-acr-name> --query "passwords[0].value" --output tsv)

# Create the app
az containerapp create `
  --name ca-openclaw `
  --resource-group rg-openclaw `
  --environment cae-openclaw `
  --image <your-acr-name>.azurecr.io/openclaw:latest `
  --registry-server <your-acr-name>.azurecr.io `
  --registry-username $ACR_USERNAME `
  --registry-password $ACR_PASSWORD `
  --target-port 18789 `
  --ingress external `
  --min-replicas 1 `
  --max-replicas 1 `
  --cpu 2.0 `
  --memory 4Gi `
  --env-vars "OPENCLAW_GATEWAY_TOKEN=$GATEWAY_TOKEN" "NODE_ENV=production" "HOME=/home/node" "TERM=xterm-256color"
```

**Save the gateway token** — you'll need it for the Control UI.

> **Security note**: The token value is never committed to this repository. All references use placeholders.

Then add the NFS volume mount via YAML update:

```powershell
az containerapp show --name ca-openclaw --resource-group rg-openclaw --output yaml > app.yaml
```

Edit `app.yaml` to add `command`, `volumeMounts`, and `volumes` sections (see the Bicep deploy script for the exact YAML structure), then apply:

```powershell
az containerapp update --name ca-openclaw --resource-group rg-openclaw --yaml app.yaml
Remove-Item app.yaml
```

### Step 8: Configure OpenClaw

Follow [Step 3 from the Bicep section](#step-3-configure-openclaw-interactive) — the interactive configuration steps are the same whether you deployed via Bicep or manual CLI.

---

## Security Audit

After configuration, run the built-in security audit:

```sh
# Inside the container (via az containerapp exec)
node openclaw.mjs security audit
```

**Expected findings and verdicts:**

| Finding | Severity | Verdict |
|---------|----------|---------|
| `allowInsecureAuth` enabled | CRITICAL | **By design** — ACA terminates TLS; the token travels over HTTPS from browser to ACA ingress. The "insecure" flag refers to the internal ACA→container hop, which is inside the managed environment. |
| State dir world-writable (777) | CRITICAL | **Cosmetic** — only the NFS mount root is 777 (`root:root`). All files inside are owned by `node` with correct permissions. The NFS share is reachable only within the VNet via private endpoint. |
| No auth rate limiting | WARN | **Accepted** — the gateway token is 256-bit; brute force is computationally infeasible. |

---

## Cleanup

```powershell
az group delete --name rg-openclaw --yes --no-wait
```

This deletes the resource group and everything inside it.
