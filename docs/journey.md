# The Journey: Deploying OpenClaw on Azure with GitHub Copilot

> How we went from zero to a fully deployed, reproducible Azure infrastructure — with GitHub Copilot driving the entire process.

---

## Why this matters

This isn't just a deployment guide. It's proof that GitHub Copilot is more than a code completion tool. Every artifact in this repository — the deployment guide, the Bicep templates, the architecture decisions, the documentation — was created collaboratively between a human engineer and Copilot.

The journey itself is the message: **Copilot reads docs, understands infrastructure, creates IaC, deploys to Azure, troubleshoots blockers, and documents everything along the way.**

---

## Chapter 1: Understanding the problem

**Goal**: Deploy OpenClaw (an open-source AI assistant with 190K+ GitHub stars) on Azure for enterprise use.

**The challenge**: OpenClaw runs locally on developer machines — powerful but uncontained. For enterprise adoption, we need it containerized, deployed to managed infrastructure, with GitHub Copilot as the LLM provider. No rogue installations.

**What Copilot did**:
- Read OpenClaw's upstream documentation (14 curated docs, ~90KB) to understand container requirements, networking model, authentication, and configuration
- Used Microsoft Learn MCP tools to evaluate Azure deployment options (ACI vs ACA vs VM vs AKS)
- Produced an Architectural Decision Record (ADR) selecting Azure Container Apps — balancing managed ingress/TLS, scaling, and low operational overhead
- Synthesized everything into `requirements-summary.md` — a single source of truth for deployment requirements

**Key finding**: OpenClaw has a built-in `github-copilot` provider with device flow auth. No VS Code needed, no API keys — just an interactive one-time login. This discovery shaped the entire deployment approach.

---

## Chapter 2: Manual deployment — discover the gotchas

**Goal**: Deploy manually via Azure CLI first. Don't write Bicep from imagination — write it from experience.

**Methodology**: Create each resource one at a time. Verify. Document. Move to the next. Every command, every parameter choice, every gotcha goes straight into the deployment guide — a primary deliverable, not an afterthought.

**What Copilot did**:
- Verified Azure subscription prerequisites (resource providers, policies)
- Researched each Azure CLI command via Microsoft Learn MCP before execution
- Executed commands in the terminal, verified outputs, and documented each step in `docs/deployment-guide.md` in real-time

**The SMB blocker** (the best kind of gotcha — one you can only find by doing):
- Plan: use SMB Azure Files for persistent storage. Simple, standard.
- Reality: The Azure tenant enforces `allowSharedKeyAccess: false` on all storage accounts. ACA's SMB mount requires a storage account key. Blocked.
- Discovery process: Copilot tested the data plane, confirmed the error (`KeyBasedAuthenticationNotPermitted`), checked Microsoft docs confirming ACA has no identity-based Azure Files alternative, and pivoted to NFS.
- Solution: NFS Azure Files authenticates via network rules (private endpoint), not shared keys. Required Premium FileStorage + custom VNet + private endpoint + DNS — more complex, but it works.
- This is exactly why we deploy manually first. A Bicep template would have failed with a cryptic error. Manual deployment let us isolate the issue, understand it, and document the workaround.

**The wizard incident**:
- The OpenClaw onboarding wizard (`openclaw onboard`) in QuickStart mode overwrote the gateway configuration with localhost defaults — breaking the ACA deployment (which requires LAN bind).
- Fix: Run in Manual mode, select LAN bind explicitly, sync the wizard-generated token to the ACA environment variable.
- This gotcha would be invisible in docs. Only hands-on deployment reveals it.

**Result**: 11 manual steps, all documented. OpenClaw running on ACA with GitHub Copilot's Claude Opus 4.6. End-to-end verified.

---

## Chapter 3: From manual to Bicep — codify the proven path

**Goal**: Turn the working manual deployment into reproducible Infrastructure as Code.

**What Copilot did**:
- Researched all 12 Azure resource type schemas via Microsoft Learn MCP tools
- Verified stable API versions for every resource (no preview APIs — NFS is GA at `Microsoft.App@2025-01-01`)
- Checked Azure Verified Modules (AVM) — available but unnecessary overhead for 12 resources
- Wrote `main.bicep` (12 resources, ~300 lines) and `main.bicepparam` in one pass
- Applied Bicep best practices: `environment()` for cloud-portable URLs, `listCredentials()` to derive ACR admin credentials at deploy time, `@secure()` decorators, symbolic resource references
- Zero errors from `az bicep build`, `az bicep lint`, and MCP diagnostics on the first validated build

**The naming fix** (another gotcha, caught during test deployment):
- Storage account names can't have hyphens. The Bicep template derives names from `projectName` — if someone uses `openclaw-bcp` as the project name, the storage account would be `openclaw-bcpst` (invalid).
- Fix: `replace(projectName, '-', '')` for storage-derived names. Caught on the first test deploy, fixed in minutes.

**What-if validation**: Ran `az deployment group what-if` against the existing resource group. Result: 8 "modify" (all server-side defaults — noise), 4 "no change", 3 "ignored" (auto-generated resources). Zero real problems.

---

## Chapter 4: Deploy with Bicep — prove reproducibility

**Goal**: Deploy the Bicep template to a fresh resource group. If it works, the infrastructure is truly reproducible.

**The first attempts failed — and that's the point.** Four failures in a row, each revealing a different gap between "Bicep compiles" and "Bicep deploys":

1. **Storage account name invalid** — `openclaw-bcpst` has a hyphen. Azure storage names are lowercase alphanumeric only. Fix: `replace(projectName, '-', '')` for storage-derived names.
2. **ACA subnet too small** — consumption-only ACA requires `/23` (512 IPs). Our `/27` (32 IPs) works only with workload profiles mode. Fix: add explicit `workloadProfiles` section. The CLI auto-sets this; Bicep needs it stated.
3. **NFS storage not found** — the Container App deployed before the NFS storage link completed. ARM doesn't infer the dependency from string references. Fix: explicit `dependsOn`.
4. **Image not found** — ACR is empty at deploy time; can't pull an image that hasn't been built yet. This is a **fundamental architecture issue**, not a bug.

**The architecture insight**: Bicep is *declarative* (what should exist). Image builds are *imperative* (do this action). They can't live in the same template. This is standard practice — even production CI/CD pipelines separate "deploy infra" from "build and push image."

**The solution — two clean steps**:

```powershell
# Step 1: Deploy all infrastructure + placeholder container (2 commands)
az group create --name rg-openclaw-test --location swedencentral
az deployment group create --resource-group rg-openclaw-test `
  --template-file bicep/main.bicep --parameters bicep/main-test.bicepparam

# Step 2: Build OpenClaw image + update the app (1 command)
.\bicep\deploy-openclaw.ps1 -ResourceGroup rg-openclaw-test `
  -AcrName <test-acr-name> -AppName ca-openclaw-test
```

The Bicep template deploys infrastructure with Microsoft's ACA quickstart container — a working HTTPS URL from minute one. The PowerShell script builds the OpenClaw image, generates a gateway token, and updates the Container App with the full configuration (ACR auth, NFS mount, startup command, environment variables).

**Result**: Both steps succeeded. Test resource group deployed with 10 resources. OpenClaw gateway running at its auto-generated HTTPS URL. From zero to a fully deployed OpenClaw on Azure — two commands, no manual resource creation.

**The deploy script worked on the first try.** Every piece transferred correctly from the old Bicep Container App resource: ACR registry auth, secrets, NFS volume mount, startup command, environment variables, target port, CPU/memory. The YAML update approach — proven during manual deployment (Step 7c) — carried over cleanly.

**Total time**: ~15 minutes (5-10 min Bicep deploy + 6 min image build). Reproducible by anyone with an Azure subscription and the OpenClaw source code.

**What the failures taught us**: A template that compiles and lints clean can still fail in four different ways. Each failure took minutes to diagnose and fix with Copilot — researching the error, understanding the constraint, applying the fix, and re-deploying. Without Copilot, each would have been a Stack Overflow deep-dive. The iterative process *is* the value.

---

## Chapter 5: Clean production deployment — the payoff

**Goal**: Delete everything. Deploy from scratch. Prove it's reproducible.

Previous test deployments were learning artifacts — resources created manually, patched iteratively, accumulated gotchas. For the production deployment, we deleted all previous resources and started from zero with the proven Bicep template and deploy script.

**The process — exactly as documented**:

```powershell
# Infrastructure (3m58s)
az group create --name rg-openclaw --location swedencentral
az deployment group create --resource-group rg-openclaw `
  --template-file bicep/main.bicep --parameters bicep/main.bicepparam

# OpenClaw image + deploy (~6 min)
.\bicep\deploy-openclaw.ps1 -ResourceGroup rg-openclaw `
  -AcrName <your-acr-name> -AppName ca-openclaw

# Interactive configuration (inside container, ~5 min)
az containerapp exec --name ca-openclaw --resource-group rg-openclaw
# → onboard (Manual, LAN, token) → models auth → models set → allowInsecureAuth → exit
```

**Zero gotchas.** Every issue discovered during the manual deployment (Phase 2a) and Bicep iteration (Phase 2b) — SMB blocked by tenant policy, NFS HTTPS-only flag, wizard localhost defaults, subnet sizing, ARM dependency ordering — was already baked into the template and documentation. The clean deployment was uneventful. That's the point.

**Result**: OpenClaw running on Azure Container Apps in ~20 minutes. Health OK, Connected, chat responding via `claude-opus-4.6` through GitHub Copilot.

**The narrative arc completes**: manual exploration → discover gotchas → document everything → codify into Bicep → prove reproducibility. The deployment guide, the Bicep template, the deploy script, and this narrative — all created collaboratively with GitHub Copilot, all verified against reality.

---

## Chapter 6: The tools that made this possible

| Tool | How it was used |
|------|-----------------|
| **GitHub Copilot (VS Code)** | Every artifact: deployment guide, Bicep, ADR, narrative. Terminal commands. Troubleshooting. |
| **Microsoft Learn MCP** | Azure resource schemas, API versions, Bicep best practices, CLI syntax verification |
| **Azure CLI** | All infrastructure operations — create, verify, deploy, troubleshoot |
| **GitHub Repository** | Public artifact — traceable history of every decision and iteration |

---

## What this proves

1. **Copilot is a full engineering productivity multiplier** — not just code completion. It read docs, created IaC, deployed infrastructure, troubleshot blockers, and documented everything.
2. **Manual-first methodology works** — the SMB blocker and wizard incident would have been opaque Bicep deployment failures. Manual deployment made them understandable and fixable.
3. **The deployment guide is a primary deliverable** — written in parallel with execution, not after. Commands, explanations, gotchas — all captured while the context is fresh.
4. **Bicep from proven steps, not imagination** — every resource in the template was deployed manually first. The Bicep codifies reality, not theory.
5. **The recursive proof** — this narrative, the Bicep, the deployment guide, the repo structure — all created by the tool being demonstrated.

---

*This document is updated as the journey continues. Each chapter is written when the milestone happens, not retroactively.*
