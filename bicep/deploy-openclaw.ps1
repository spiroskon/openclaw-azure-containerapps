# ---------------------------------------------------------------------------
# deploy-openclaw.ps1 — Build and deploy OpenClaw to an existing ACA environment
#
# Prerequisites: infrastructure deployed via main.bicep (placeholder container running)
# What this does:
#   1. Auto-discovers ACR and App names from the Bicep deployment outputs
#   2. Builds OpenClaw image from source and pushes to ACR
#   3. Generates a gateway auth token
#   4. Updates the Container App with OpenClaw image, NFS mount, and full config
#
# Usage (no names needed — auto-discovered from Bicep outputs):
#   .\bicep\deploy-openclaw.ps1 -ResourceGroup rg-openclaw
# ---------------------------------------------------------------------------

param(
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [string] $SourcePath = "upstream/repo",
    [string] $Cpu = "2.0",
    [string] $Memory = "4Gi"
)

$ErrorActionPreference = "Stop"

# Auto-discover resource names from Bicep deployment outputs
Write-Host "`n=== Discovering resources from Bicep deployment ===" -ForegroundColor Cyan
$AcrName = az deployment group show --resource-group $ResourceGroup --name main `
    --query "properties.outputs.acrName.value" -o tsv 2>$null
$AppName = az deployment group show --resource-group $ResourceGroup --name main `
    --query "properties.outputs.appName.value" -o tsv 2>$null

if (-not $AcrName -or -not $AppName) {
    throw "Could not discover ACR or App name from deployment outputs. Was main.bicep deployed to '$ResourceGroup'?"
}
Write-Host "  ACR:  $AcrName" -ForegroundColor Green
Write-Host "  App:  $AppName" -ForegroundColor Green

Write-Host "`n=== Step 1/3: Building OpenClaw image in ACR ===" -ForegroundColor Cyan
Write-Host "This uploads source to Azure and builds remotely (~6 min)..."
az acr build `
    --registry $AcrName `
    --image openclaw:latest `
    --file "$SourcePath/Dockerfile" `
    $SourcePath

if ($LASTEXITCODE -ne 0) { throw "Image build failed" }
Write-Host "Image built and pushed to $AcrName.azurecr.io/openclaw:latest" -ForegroundColor Green

Write-Host "`n=== Step 2/3: Generating gateway token ===" -ForegroundColor Cyan
$bytes = New-Object byte[] 32
[System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
$GatewayToken = [BitConverter]::ToString($bytes).Replace('-', '').ToLower()
Write-Host "Token generated (save this for Control UI access):"
Write-Host "  $GatewayToken" -ForegroundColor Yellow

Write-Host "`n=== Step 3/3: Updating Container App with OpenClaw ===" -ForegroundColor Cyan

$AcrServer = "$AcrName.azurecr.io"
$AcrCreds = az acr credential show --name $AcrName 2>$null | ConvertFrom-Json
if (-not $AcrCreds) { throw "Failed to get ACR credentials for $AcrName" }
$AcrUsername = $AcrCreds.username
$AcrPassword = $AcrCreds.passwords[0].value

# Get environment name and storage name from the Container App
$envId = az containerapp show --name $AppName --resource-group $ResourceGroup `
    --query "properties.managedEnvironmentId" -o tsv 2>$null
if (-not $envId) { throw "Failed to get environment ID for $AppName" }
$envName = $envId.Split("/")[-1]

$StorageName = az containerapp env storage list `
    --name $envName --resource-group $ResourceGroup `
    --query "[0].name" -o tsv 2>$null
if (-not $StorageName) { throw "No NFS storage found on environment $envName. Was main.bicep deployed?" }

# Volume name for the YAML — this is a local alias, not an Azure resource name
$volumeName = "openclaw-state"

# Build the updated YAML for the Container App
$yamlPath = [System.IO.Path]::GetTempFileName() + ".yaml"

$updatedYaml = @"
properties:
  managedEnvironmentId: $envId
  configuration:
    ingress:
      external: true
      targetPort: 18789
      transport: http
    registries:
    - server: $AcrServer
      username: $AcrUsername
      passwordSecretRef: acr-password
    secrets:
    - name: acr-password
      value: $AcrPassword
    - name: gateway-token
      value: $GatewayToken
  template:
    containers:
    - name: $AppName
      image: $AcrServer/openclaw:latest
      command:
      - node
      - openclaw.mjs
      - gateway
      - --allow-unconfigured
      - --bind
      - lan
      - --port
      - "18789"
      resources:
        cpu: $Cpu
        memory: $Memory
      env:
      - name: OPENCLAW_GATEWAY_TOKEN
        secretRef: gateway-token
      - name: NODE_ENV
        value: production
      - name: HOME
        value: /home/node
      - name: TERM
        value: xterm-256color
      volumeMounts:
      - volumeName: $volumeName
        mountPath: /home/node/.openclaw
    scale:
      minReplicas: 1
      maxReplicas: 1
    volumes:
    - name: $volumeName
      storageType: NfsAzureFile
      storageName: $StorageName
"@

$updatedYaml | Set-Content $yamlPath -Encoding utf8

az containerapp update --name $AppName --resource-group $ResourceGroup --yaml $yamlPath

if ($LASTEXITCODE -ne 0) { throw "Container App update failed" }

Remove-Item $yamlPath -ErrorAction SilentlyContinue

Write-Host "`n=== Deployment complete ===" -ForegroundColor Green
$fqdn = az containerapp show --name $AppName --resource-group $ResourceGroup `
    --query "properties.configuration.ingress.fqdn" -o tsv 2>$null
$rev = az containerapp show --name $AppName --resource-group $ResourceGroup `
    --query "properties.latestRevisionName" -o tsv 2>$null
Write-Host ""
Write-Host "  ┌─────────────────────────────────────────────────────────────────┐" -ForegroundColor Yellow
Write-Host "  │  GATEWAY TOKEN (use in wizard step 3 and browser step 4):      │" -ForegroundColor Yellow
Write-Host "  │  $GatewayToken  │" -ForegroundColor Yellow
Write-Host "  └─────────────────────────────────────────────────────────────────┘" -ForegroundColor Yellow
Write-Host ""
Write-Host "OpenClaw URL: https://$fqdn"
Write-Host "Control UI:   https://$fqdn/#token=$GatewayToken"
Write-Host ""
Write-Host "=== Next: Configure OpenClaw (interactive) ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "1. Connect to container:" -ForegroundColor Yellow
Write-Host "   az containerapp exec --name $AppName --resource-group $ResourceGroup"
Write-Host ""
Write-Host "2. Inside the container, run these commands in order:" -ForegroundColor Yellow
Write-Host "   node openclaw.mjs onboard                  # wizard (choices below)"
Write-Host "   node openclaw.mjs models auth login-github-copilot"
Write-Host "   node openclaw.mjs models set github-copilot/claude-opus-4.6"
Write-Host "   node openclaw.mjs config set gateway.controlUi.allowInsecureAuth true"
Write-Host "   exit"
Write-Host ""
Write-Host "3. Wizard choices (node openclaw.mjs onboard):" -ForegroundColor Yellow
Write-Host "   Security warning      -> Yes"
Write-Host "   Onboarding mode       -> Manual (NOT QuickStart)"
Write-Host "   Gateway location      -> Local gateway"
Write-Host "   Workspace directory   -> Enter (default)"
Write-Host "   Gateway port          -> Enter (18789)"
Write-Host "   Gateway bind          -> LAN (0.0.0.0)  ** CRITICAL **"
Write-Host "   Gateway auth          -> Token"
Write-Host "   Tailscale             -> Off"
Write-Host "   Gateway token         -> " -NoNewline -ForegroundColor White
Write-Host "PASTE THE TOKEN FROM THE BOX ABOVE" -ForegroundColor Red
Write-Host "   Channels              -> No"
Write-Host "   Skills                -> Yes, then Skip dependencies"
Write-Host "   All API key prompts   -> No"
Write-Host "   Hooks                 -> Skip"
Write-Host "   How to hatch          -> Do this later"
Write-Host "   Zsh completion        -> No"
Write-Host ""
Write-Host "4. Restart + verify:" -ForegroundColor Yellow
Write-Host "   az containerapp revision restart --revision $rev --resource-group $ResourceGroup"
Write-Host "   Wait 30s, then open Control UI URL above. Health OK = done."
