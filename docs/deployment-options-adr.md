## ADR-001: Azure deployment target for OpenClaw

- Status: Accepted
- Date: 2026-02-13
- Decision owner: Project maintainers

## Context

This project deploys OpenClaw on Azure with container isolation and GitHub Copilot as the LLM provider. The selected hosting target must support a practical deployment path, secure ingress, manageable operations, and a strong demo story.

OpenClaw upstream guidance confirms Docker as an optional but supported deployment path (`docs/install/docker.md`), with a default gateway/control surface at port `18789` and token-based dashboard pairing workflows. OpenClaw security guidance emphasizes strict exposure controls, authenticated access, and sandboxing options.

## Requirements that shaped the decision

- Containerized runtime with predictable networking and TLS posture
- Practical security baseline without building many surrounding components first
- Low operations burden for a small team and demo timeline
- IaC-friendly path with Azure-native templates/Bicep
- Ability to evolve toward production-style architecture

## Options considered

### 1) Azure Container Instances (ACI)

Pros:
- Fastest path to run a container group
- Minimal service complexity

Cons:
- Microsoft docs position ACI as a lower-level building block; app-level features like built-in scale/load-balancing/certificates are not provided in the same way as ACA
- Scaling is not built in as a service primitive for an app abstraction; scaling generally means creating more container groups
- Networking constraints and extra considerations for production-like setups (for example, VNet outbound NAT gateway requirements)

### 2) Azure Container Apps (ACA)

Pros:
- Serverless container platform with managed ingress; HTTPS/TLS termination and revision/traffic features are native
- Autoscaling with KEDA and scale-to-zero support for many workloads
- Better fit for “production-like but low-ops” architecture
- Strong support for Bicep/ARM-based deployment workflows

Cons:
- More moving parts than ACI
- Slightly steeper learning/setup curve

### 3) Azure VM + Docker Compose

Pros:
- Closest mental model to local Docker Compose operations
- Maximum host-level control and compatibility flexibility

Cons:
- Highest operations burden (OS patching, host hardening, lifecycle management)
- TLS, load balancing, and scaling patterns require additional Azure resources and manual design
- Less aligned with serverless/container-native Azure direction for this project goal

## Decision

Choose Azure Container Apps (ACA) as the primary deployment target.

## Rationale

ACA provides the best balance for this project: strong container-native capabilities, secure managed ingress, lower operational overhead than VM-based hosting, and a better production-style story than raw ACI building blocks.

This aligns with:

- OpenClaw’s containerized deployment path and security posture guidance
- The project objective to get a working Azure deployment first, then build documentation/demo assets on top
- The need for an architecture that can be explained credibly in enterprise demos

## Consequences

### Positive

- Faster path to a secure default web endpoint and revisioned deployments
- Cleaner story for autoscaling, traffic management, and future hardening
- Better foundation for follow-on Bicep artifacts and architecture diagrams

### Trade-offs

- Requires learning ACA environment/resource model earlier
- Slightly higher upfront setup effort than ACI

## Implementation notes

- Use Bicep under `bicep/` for ACA environment, app, ingress, and configuration
- Keep Azure VM + Compose as fallback option for troubleshooting or parity testing only
- Keep ACI as a quick experimental path, not primary architecture

## Sources

Azure (Microsoft Learn):

- Comparing Container Apps with other Azure container options: https://learn.microsoft.com/azure/container-apps/compare-options
- Azure Container Apps overview: https://learn.microsoft.com/azure/container-apps/overview
- Ingress in Azure Container Apps: https://learn.microsoft.com/azure/container-apps/ingress-overview
- Set scaling rules in Azure Container Apps: https://learn.microsoft.com/azure/container-apps/scale-app
- ACI best practices and considerations: https://learn.microsoft.com/azure/container-instances/container-instances-best-practices-and-considerations
- ACI networking concepts and unsupported scenarios: https://learn.microsoft.com/azure/container-instances/container-instances-virtual-network-concepts
- Azure Virtual Machines overview: https://learn.microsoft.com/azure/virtual-machines/overview
- Hosting applications on Azure (control vs management responsibility): https://learn.microsoft.com/azure/developer/intro/hosting-apps-on-azure

OpenClaw upstream:

- OpenClaw README: https://github.com/openclaw/openclaw/blob/main/README.md
- OpenClaw Docker install guide: https://github.com/openclaw/openclaw/blob/main/docs/install/docker.md
- OpenClaw security guidance: https://docs.openclaw.ai/gateway/security