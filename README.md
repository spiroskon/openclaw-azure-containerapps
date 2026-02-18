# OpenClaw on Azure Container Apps

Deploy [OpenClaw](https://github.com/openclaw/openclaw) on Azure Container Apps — containerized, with GitHub Copilot as the LLM provider.

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

## Quick Deploy

Three phases, ~20 minutes total. Run from the repo root in a standalone terminal (Windows Terminal — the wizard needs arrow keys).

```powershell
# 0. Clone OpenClaw source (needed for image build)
git clone https://github.com/openclaw/openclaw.git upstream/repo

# 1. Infrastructure (~5 min) — names are auto-generated, nothing to configure
az group create --name rg-openclaw --location swedencentral
az deployment group create --resource-group rg-openclaw `
  --template-file bicep/main.bicep --parameters bicep/main.bicepparam

# 2. Build OpenClaw image + deploy (~6 min) — save the token from output
.\bicep\deploy-openclaw.ps1 -ResourceGroup rg-openclaw

# 3. Configure (interactive, ~5 min)
az containerapp exec --name ca-openclaw --resource-group rg-openclaw
# Inside the container:
#   node openclaw.mjs onboard                             → Manual, LAN, paste token
#   node openclaw.mjs models auth login-github-copilot    → device flow in browser
#   node openclaw.mjs models set github-copilot/claude-opus-4.6
#   node openclaw.mjs config set gateway.controlUi.allowInsecureAuth true
#   exit
```

See [docs/deployment-guide.md](docs/deployment-guide.md) for the complete walkthrough with every parameter explained.

## What's in this repo

| Path | Description |
|------|-------------|
| [`bicep/`](bicep/) | Bicep template + deploy script — all infrastructure as code |
| [`docs/deployment-guide.md`](docs/deployment-guide.md) | Full deployment guide with manual CLI reference |
| [`docs/deployment-options-adr.md`](docs/deployment-options-adr.md) | ADR: why Azure Container Apps |
| [`docs/journey.md`](docs/journey.md) | How we built this — the narrative arc |

## The Story

Every artifact in this repository — the Bicep templates, the deployment guide, the architecture decisions, this README — was created collaboratively between a human engineer and GitHub Copilot in VS Code.

The methodology: manual CLI deployment first (discover the gotchas), document everything in parallel, codify into Bicep (proven, not imagined), then verify with a clean from-scratch deployment. Nine sessions over four days, from zero to a fully deployed, reproducible Azure infrastructure.

Read the full narrative in [docs/journey.md](docs/journey.md).

## Prerequisites

- Azure CLI 2.80+
- Active Azure subscription
- Git

Docker Desktop is **not required** — images are built remotely via `az acr build`.

## Key Design Decisions

- **Azure Container Apps** over ACI/VM — managed ingress, auto-TLS, consumption pricing
- **NFS over SMB** — NFS authenticates via network rules (private endpoint), bypassing `allowSharedKeyAccess: false` tenant policies
- **Two-phase deploy** — Bicep (infrastructure + placeholder) then script (image build + app update)
- **Manual CLI first, then Bicep** — discover gotchas before codifying
- **GitHub Copilot as LLM provider** — built-in provider with device flow auth, no API keys needed

## Related

- [OpenClaw Secure Docker Setup](https://github.com/spiroskon/openclaw-secure-docker) — run OpenClaw locally on Windows with Docker
- [OpenClaw Official Docs](https://docs.openclaw.ai)
- [OpenClaw GitHub](https://github.com/openclaw/openclaw)

## Cleanup

```powershell
az group delete --name rg-openclaw --yes --no-wait
```

## License

MIT
