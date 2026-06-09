# OpenShell Sandbox Evaluation for Agent Runtimes

**Jira:** RHAIENG-5448
**Spike Owner:** TBD
**Date Started:** 2026-06-04
**Status:** Phase 1 — Desk research complete (2 minor items remaining). Ready for Phase 2.

---

## Background

### What is OpenShell?

[OpenShell](https://github.com/NVIDIA/OpenShell-Community) is NVIDIA's open-source project for creating secure, isolated sandboxes for AI agents. Think of it as a security wrapper around a container: it adds network filtering, filesystem restrictions, and identity verification on top of what a normal container provides. An agent running inside an OpenShell sandbox can only access the network endpoints, files, and binaries that its security policy explicitly allows.

### What are we evaluating?

Our team ships **validated agent images** — pre-built, security-audited container images for AI coding agents like Claude Code, Codex, OpenCode, and OpenClaw. These images are built on Red Hat's Universal Base Image (UBI), signed, scanned, and published to our container registry. They need to run on Red Hat OpenShift AI (RHOAI).

This spike evaluates whether OpenShell can serve as the sandbox runtime for these images, and if so, what changes are needed to make them compatible.

### Why does this matter?

Today our agent images run as regular containers on OpenShift with standard security policies. OpenShell would add a deeper layer of protection — controlling exactly which network endpoints each agent can reach, which files it can read/write, and verifying that binaries haven't been tampered with. This is especially important for coding agents that execute arbitrary code on behalf of users.

### How does this relate to Kagenti?

[Kagenti](https://github.com/kagenti/kagenti) is the Kubernetes operator that manages agent lifecycle on our platform — handling discovery, tracing, tool/skill wiring, and fleet configuration. OpenShell and Kagenti solve different problems: **OpenShell secures the sandbox**, **Kagenti connects the agent to platform services**. This spike evaluates OpenShell specifically; the related spike RHAIENG-5245 covers the Kagenti side.

---

## Questions to Answer

1. What security isolation does OpenShell provide beyond what OpenShift already gives us?
2. Can our agents run both with and without OpenShell installed?
3. Does `openshell sandbox create` work with our per-agent container images?
4. How does OpenShell's startup process interact with our agent-specific startup scripts?
5. How mature is the OpenShell Technology Preview? Is it usable for our follow-up work?
6. How does OpenShell interact with Kagenti's agent management?
7. Can we define one sandbox pattern for all four agents, or does each need its own?

---

## Glossary

| Term | Definition |
|------|-----------|
| **ARC** | Agent Runtime Contract — a versioned specification of file paths and environment variables that every agent image can expect from the platform at startup |
| **CDN** | Content Delivery Network — a distributed server network for fast file downloads (e.g., Anthropic's servers for installing Claude Code) |
| **CR / CRD** | Custom Resource / Custom Resource Definition — a way to extend Kubernetes with new object types (e.g., `AgentRuntime` is a CR managed by Kagenti) |
| **Entrypoint** | The startup script that runs when a container launches — determines what the container does on boot |
| **Flavor image** | A container image tailored for a specific agent (e.g., `openshell-claude` for Claude Code) |
| **Kagenti** | Red Hat's Kubernetes operator for managing AI agent lifecycle — discovery, tracing, skills, and fleet config |
| **Konflux** | Red Hat's build system for producing signed, scanned, compliant container images |
| **L7 proxy** | A Layer 7 (application-level) network proxy that can inspect HTTP requests and filter by URL, method, and path — not just IP/port |
| **Landlock** | A Linux kernel security module that restricts filesystem access per-process without requiring root privileges |
| **MCP** | Model Context Protocol — a standard for connecting AI agents to external tools and data sources |
| **MVP** | Minimum Viable Product — the smallest useful first release |
| **OTEL** | OpenTelemetry — an open standard for distributed tracing and observability |
| **Pod** | The smallest deployable unit in Kubernetes — one or more containers running together |
| **Privileged SCC** | A Security Context Constraint that gives a container full host access (root, devices, kernel modules) — the least restrictive security level on OpenShift |
| **restricted-v2 SCC** | The default, most restrictive Security Context Constraint on OpenShift — non-root, no host access, read-only filesystem |
| **SBOM** | Software Bill of Materials — a list of all components in a software artifact, used for security auditing |
| **SCC** | Security Context Constraint — OpenShift's mechanism for controlling what containers are allowed to do (network, filesystem, privilege level) |
| **seccomp** | Secure computing mode — a Linux kernel feature that restricts which system calls a process can make |
| **Sidecar** | An additional container that runs alongside the main container in the same pod, providing supporting services (e.g., tracing, identity) |
| **SPIFFE** | Secure Production Identity Framework for Everyone — a standard for workload identity using X.509 certificates |
| **TP** | Technology Preview — a pre-GA (General Availability) release with limited support, used for early validation |
| **UBI** | Universal Base Image — Red Hat's freely redistributable base container image, required for all Red Hat validated images |

---

## Phase 1 Findings

### 1. OpenShell Architecture

OpenShell is split into two repositories: **NVIDIA/OpenShell** (private, written in Rust — the core engine) and **NVIDIA/OpenShell-Community** (public, Apache-2.0 license — sandbox images, skills, and integrations). **Current maturity: Alpha / single-player mode.**

#### Command-Line Interface

A developer creates a sandbox with:

```
openshell sandbox create --from <source>
```

The `--from` flag accepts a catalog name (`--from ollama`), a local directory containing a Dockerfile, or a container image reference. The command also supports port forwarding (`--forward <port>`) and environment variable injection (`-e KEY=VALUE`). Credentials are injected as environment variables and are never written to the filesystem. Note: the design proposals also reference `--image` as a flag — both may be valid, but `--from` is confirmed in the upstream CLI today.

OpenShell supports multiple compute backends: Docker, Podman, MicroVM, and Kubernetes.

#### How It Deploys on OpenShift (from prior POC — needs re-validation)

On OpenShift, OpenShell runs as two components:
- **Gateway** — An API server that manages sandbox lifecycle (handles requests over gRPC/HTTP, stores state in a SQLite database, listens on port 8080)
- **Cluster** — A nested K3s (lightweight Kubernetes) cluster that provides the isolated execution environment for agent workloads

```
┌─────────────────────────────────────────┐
│         OpenShift Cluster               │
│  ┌───────────────────────────────────┐  │
│  │  Namespace: openshell-poc         │  │
│  │  ┌─────────────┐ ┌─────────────┐ │  │
│  │  │ Gateway Pod  │ │ Cluster Pod │ │  │
│  │  │ Port 8080    │ │ Nested K3s  │ │  │
│  │  │              │ │ PRIVILEGED  │ │  │
│  │  └─────────────┘ └─────────────┘ │  │
│  └───────────────────────────────────┘  │
└─────────────────────────────────────────┘
```

**Critical: Both components require privileged access** — they run as root (`runAsUser: 0`) and mount host directories (`/dev` and `/lib/modules`). This means OpenShell's infrastructure pods need the most permissive security level on OpenShift (privileged SCC), even though the agent workloads running inside the sandbox use an unprivileged `sandbox` user. The Linux kernel's Landlock security module was confirmed active on OCP 4.19 with kernel 5.14.

**Prior POC test environment:** OpenShift 4.19.18 on AWS (ROSA), 4 worker nodes. Deployment manifests are attached to RHAIENG-3926. A separate Engineering Harness POC (on Confluence) also tested Claude and Gemini agents on Podman successfully.

**Kubernetes deployment options:** An experimental Helm chart exists for deploying on Kubernetes. There is no upstream operator or custom resource definitions. RHAIENG-5189 references a Red Hat-built "OpenShell Operator" planned for RHOAI 3.5 Technology Preview, but that documentation epic has not started yet.

#### Technology Preview Maturity (answers Q5)

- **Upstream status:** Alpha / single-player mode. The core engine is in a private repository. The community repo is public but early-stage.
- **Red Hat productization:** An OpenShell Operator TP is planned for RHOAI 3.5. The documentation epic (RHAIENG-5189) has not started. There is no Konflux build pipeline, no validated images, and no operator built yet.
- **For our follow-up work:** Usable for proof-of-concept demos today (proven on Podman and OpenShift). Not production-ready due to the privileged SCC requirement, lack of operator lifecycle management, and no SBOM/signing. The validated images MVP (estimated 2-3 week build timeline) is the critical path item before real integration work can begin.

#### Upstream Base Image

The upstream `sandboxes/base/` Dockerfile builds from Ubuntu and bundles Claude Code, Codex, OpenCode, Copilot, GitHub CLI, Node.js 22, Python 3.14, and uv into a single 2.81 GB image. This is **not usable for Red Hat** — it uses the wrong base OS (we require UBI), includes proprietary binaries without redistribution rights, and is too large for production use.

### 2. Security Isolation Capabilities (answers Q1)

OpenShell provides several layers of isolation, all configured through a declarative `policy.yaml` file:

| Layer | What It Does | Status |
|-------|-------------|--------|
| **Filesystem (Landlock)** | Restricts which files and directories each process can read or write, using Linux kernel-level enforcement | Implemented |
| **Network (L7 proxy)** | Intercepts all outbound network connections and checks them against per-binary allowlists. Can filter by host, port, HTTP method, and URL path (e.g., allows `git clone` but blocks `git push`) | Implemented |
| **Binary identity** | Verifies the SHA256 hash of every binary that makes network calls, using a trust-on-first-use model. Detects if a binary has been replaced or tampered with | Implemented |
| **Process separation** | Agent workloads run as an unprivileged `sandbox` user. A separate `supervisor` user (with no login shell) manages system processes | Implemented |
| **Inference routing** | A privacy router that intercepts model API calls, strips the caller's credentials, and injects backend-managed credentials instead. Prevents agents from seeing real API keys | Implemented |
| **System call filtering (seccomp)** | Implied in documentation ("blocks dangerous syscalls") but not explicitly configured or named | Unclear |

The upstream `policy.yaml` already includes named network policies for several of our target agents: `claude_code`, `codex`, `opencode`, `copilot`, plus policies for common services like `pypi`, `github_rest_api`, and `vscode`.

**What this adds beyond standard OpenShift security:** OpenShift's default security policy (restricted-v2 SCC) provides non-root execution, no privilege escalation, a basic seccomp profile, and a read-only root filesystem. OpenShell adds significantly more: per-binary network allowlists (not just IP/port filtering), fine-grained filesystem sandboxing via Landlock, binary integrity verification, and inference credential routing. These are the security features that make OpenShell valuable for coding agents that execute arbitrary code.

### 3. Running With and Without OpenShell (answers Q2)

**Requirement source:** RHAISTRAT-1349 — the strategy ticket that defines runtime compatibility requirements for our validated agent images.

The requirement states that agent images must work in three modes: `docker run`, `podman run`, and `openshell sandbox create`. The same container image is used in all cases — the agent does not need to know whether it is running inside an OpenShell sandbox.

- **Without OpenShell**: The agent runs as a regular container under OpenShift's default security policy (restricted-v2 SCC) or plain container isolation on a developer's laptop.
- **With OpenShell**: OpenShell wraps the container with Landlock filesystem restrictions, L7 network policy enforcement, binary identity verification, and inference privacy routing. The OpenShell infrastructure pods run with elevated privileges, but the agent workload itself remains unprivileged.
- **The security policy file (`policy.yaml`) is included in the image** at `/etc/openshell/policy.yaml`. It is only read and enforced when OpenShell is present — otherwise it is ignored.

### 4. Validated Image Architecture (answers Q3, Q4, Q7)

**Source:** [Validated Sandbox Images Design Proposal](https://docs.google.com/document/d/1AK3bIAfE_OJeVnR8cgSpier4V-So8SbDEZFTWe7_BuI/edit?tab=t.0)

#### Thin Base + Agent Flavor Images

Rather than one large image with everything installed, the proposed architecture uses a layered approach:

- **Base image** (target 150-200 MB): Built on UBI 10-minimal with only system-level dependencies (certificates, curl, git, etc.), two users (`supervisor` and `sandbox`), a default `policy.yaml`, and a startup script. No programming language runtimes and no agents.
- **Flavor images** (target 300-450 MB each): Each flavor extends the base with only the runtime its agent needs. A Python-based agent never downloads Node.js. A JavaScript-based agent never downloads Python.

#### Agent Licensing Determines How Each Agent Is Packaged

Some agents can be pre-installed ("baked") into the image; others must be downloaded at first boot due to licensing restrictions:

| Agent | License | Pre-installed? | First Boot Time |
|-------|---------|----------------|-----------------|
| Codex | Apache 2.0 | Yes — safe to redistribute | Instant |
| OpenCode | MIT | Yes — safe to redistribute | Instant |
| OpenClaw | MIT | Yes — safe to redistribute | Instant |
| **Claude Code** | **Proprietary ("All rights reserved")** | **No — must be downloaded from Anthropic's servers** | **10-20 seconds** |

#### MVP: 3 Flavor Images

The first release targets three images covering the primary runtime categories:

| Flavor | Language Runtime | Agent Pre-installed? | Registry Path |
|--------|-----------------|---------------------|---------------|
| `openshell-claude` | Node.js 22 | No (downloaded at first boot) | `quay.io/redhat-ai/openshell-claude` |
| `openshell-codex` | Node.js 22 | Yes | `quay.io/redhat-ai/openshell-codex` |
| `openshell-adk` | Python 3.13 + uv | Yes | `quay.io/redhat-ai/openshell-adk` |

**None of these images have been built yet.** The design proposal estimates a 2-3 week timeline to build the MVP once alignment is reached.

#### Startup Script Pattern (answers Q4)

Each flavor image includes a smart startup script (entrypoint) that:
1. Accepts the agent name as a command-line argument
2. Checks if the agent binary is already installed (using `command -v`)
3. If not installed (proprietary agents only), downloads it from the vendor's servers
4. Launches the agent process

The entrypoint also uses `tini` as the process manager (PID 1) so that shutdown signals propagate correctly to child processes like MCP tool subprocesses and language servers. A startup probe marker file (`/tmp/agent-ready`) is written after the agent is ready, which prevents Kubernetes from killing the container before a runtime-installed agent finishes downloading.

#### One Contract, Per-Agent Images (answers Q7)

Yes — all agents share one common contract (the ARC, described below) that defines standard file paths and environment variables. Each flavor image has its own translation layer in its entrypoint that converts these platform-standard values to the format its specific agent expects. Adding support for a new agent means publishing one new flavor image — no changes to the platform or operators.

### 5. Agent Runtime Contract (ARC)

The ARC is the agreement between the platform and the container image about what the agent can expect at startup. It defines standard file locations and environment variables that are the same regardless of which agent is running. This is consolidated from three design proposals.

#### Image Conventions

| Convention | Value |
|-----------|-------|
| Sandbox user | `sandbox`, home directory `/sandbox` |
| Supervisor user | `supervisor`, no login shell |
| Security policy location | `/etc/openshell/policy.yaml` |
| PATH | `/sandbox/.venv/bin:/sandbox/.local/bin:/usr/local/bin:/usr/bin:/bin` |
| Startup probe marker | `/tmp/agent-ready` |
| OCI metadata labels | `io.openshell.sandbox.harness`, `io.openshell.sandbox.runtime` |

#### Platform-Provisioned Mount Points

These directories are populated by the platform before the agent starts:

| Path | Contents | Who Populates It |
|------|----------|-----------------|
| `/mnt/skills/` | Skill artifacts — one subdirectory per skill (prompts, config, tools) | Kagenti init container or the image's own startup script |
| `/mnt/mcp/` | MCP server connection metadata (endpoints, transport config) | Kagenti controller |
| `/opt/spiffe/certs/` | Workload identity certificates (X.509) for secure service-to-service communication | SPIFFE helper sidecar |

#### Platform-Provisioned Environment Variables

| Variable | Contents | Who Sets It |
|----------|----------|------------|
| `PLATFORM_MCP_SERVERS` | JSON list of MCP server configurations (names, URLs, auth) | Kagenti controller |
| `SKILLS_DIR` | Filesystem path to mounted skills | Kagenti controller |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | URL of the tracing collector for observability data | Kagenti sidecar |
| `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, etc. | API keys for inference providers — either real values or placeholder tokens that OpenShell's proxy resolves at request time | Kubernetes Secrets or OpenShell credential proxy |

#### Path Ownership (to avoid conflicts)

- **Image-owned paths** (the startup script and agent write here): `/sandbox/.local/bin`, `/sandbox/.venv`, `/sandbox/.config/[agent]/`
- **Sidecar-owned paths** (Kagenti injects certificates and telemetry config here): `/etc/openshell/spiffe/`, `/etc/openshell/otel/`
- **Open question:** There may be conflicts between image-owned and sidecar-owned paths that haven't been fully resolved yet.

### 6. OpenShell and Kagenti Composition (answers Q6)

**Sources:** [Composition Doc](https://docs.google.com/document/d/15RP9OLnz7_7H18UUYvfv-zEgLyP-gpY5aY6aJPGC_lI/edit?tab=t.0) (2026-05-12) and [Harness Spec](https://docs.google.com/document/d/1Uam3aEM4knpHP5rfOpg49EsuclZSU3wStK02i8TxQv8/edit?tab=t.0) (2026-05-27)

#### The Intended Model

OpenShell handles day-1 sandbox security (isolation, network filtering, credential protection). Kagenti handles day-2 platform connection (service discovery, tracing, tool/skill wiring, fleet management). They are designed to work on the same agent workload through a single integration point: a Kubernetes label (`kagenti.io/type: agent`) that OpenShell sets and Kagenti's webhook detects.

| Concern | OpenShell Owns | Kagenti Owns |
|---------|---------------|-------------|
| Sandbox isolation (Landlock, seccomp, L7 network) | Yes | - |
| Credential proxy, inference routing, bypass detection | Yes | - |
| Workload identity (SPIFFE, OIDC, token exchange) | Yes | Reads identity for verification |
| Security event logging | Yes | - |
| Agent discovery, fleet config, workload classification | - | Yes |
| Declarative harness (skills, MCP servers, credentials) | - | Yes |
| Distributed tracing | Emits trace data | Configures where traces are sent |

Three composition paths are envisioned: **A** (developer starts with OpenShell, Kagenti auto-enrolls — the primary experience), **B** (developer deploys a regular container and adds Kagenti — enterprise path, no sandbox), **C** (developer uses both for full security + full platform — power user path).

#### The Reality: This Composition Is Not Yet Settled

The later design document (the Harness Spec from May 27) is significantly more cautious than the earlier Composition Doc (May 12). Several real technical conflicts have been identified:

- **Sidecar injection conflict:** Kagenti works by modifying a pod's specification to add sidecar containers (for tracing, identity, etc.). This modification triggers Kubernetes to restart the pod. OpenShell assumes it is the sole manager of the sandbox's lifecycle and may not handle unexpected restarts gracefully. **Derek Wang, the OpenShell maintainer, has explicitly flagged this conflict.**
- **Sandbox custom resource as a Kagenti target is unproven.** Pointing Kagenti's `AgentRuntime` resource at an OpenShell `Sandbox` resource has never been tested and may not work.
- **Pod structure is under active debate.** The OpenShell community ([issue #981](https://github.com/NVIDIA/OpenShell/issues/981)) is debating whether the supervisor process and the agent should run in the same pod or separate pods. This decision directly affects whether Kagenti's sidecar injection model is even feasible.
- **Four speculative approaches** have been proposed for future composition (OpenShell gateway resolves platform capabilities itself / OpenShell provider config becomes declarative / Kagenti acts as a pre-stage resolver / shared contract with independent provisioning) — **none have been proven or implemented.**

**Current recommendation:** The safest integration path today is the **validated container image itself**. The image understands the ARC contract. OpenShell provides security. Platform capabilities (skills, MCP server configs, credentials) reach the sandbox through environment variables and volume mounts, without any coupling between Kagenti and OpenShell at the Kubernetes API level. The question of how those capabilities get injected in an OpenShell-first deployment is explicitly unresolved.

---

## Gap Analysis

### Critical Gaps

| # | Gap | Impact | Current Status |
|---|-----|--------|----------------|
| 1 | **Image base mismatch** — upstream uses Ubuntu, Red Hat requires UBI 10-minimal | All agent images need a full rebuild from scratch | Design proposal exists; implementation has not started |
| 2 | **OpenShell infrastructure requires privileged access** — both gateway and cluster pods need root and host device mounts | Customers must accept privileged workloads on their cluster to use OpenShell | Architectural constraint inherent to the nested K3s approach; needs re-validation on current OpenShift |
| 3 | **No upstream operator** — OpenShell deploys via Helm charts only | No automated lifecycle management (install, upgrade, monitoring) | Red Hat is building an operator for RHOAI 3.5 TP, but the docs epic has not started |
| 4 | **Startup scripts not built** — the entrypoint design and example code exist but no actual images | Cannot test the "with and without OpenShell" pattern end-to-end | Estimated 2-3 week build timeline once alignment is reached |
| 5 | **Security policy portability** — upstream policies reference Ubuntu binary paths | Rebuilding on UBI will change binary locations, requiring policy updates | Straightforward but needs to be done for each agent |
| 6 | **OpenShell + Kagenti composition is contentious** — sidecar injection conflicts with sandbox lifecycle management | Integration path is unclear beyond "use the image as the contract surface" | Needs a proof-of-concept; active upstream debate |
| 7 | **OpenClaw has no network policy** — the upstream `policy.yaml` lacks a named policy for OpenClaw | OpenClaw cannot run in an OpenShell sandbox until a policy is defined | Straightforward to add |

### What Works Today

- `openshell sandbox create --from <image>` accepts any container image, including pre-built ones
- Security policy files are declarative YAML and can be bundled with images or applied at runtime
- Claude and Gemini agents have been proven working in OpenShell sandboxes (Podman-based POC)
- Named network policies already exist for 3 of our 4 target agents (Claude Code, Codex, OpenCode)

### Compatibility Matrix

| Agent | License | Pre-installed in Image? | Network Policy Exists? | MVP Flavor | Key Blocker |
|-------|---------|------------------------|----------------------|------------|-------------|
| Claude Code | Proprietary | No (downloaded at first boot) | Yes (`claude_code`) | `openshell-claude` | Licensing prevents pre-installation; air-gapped deployments need a pre-populated cache volume |
| Codex | Apache 2.0 | Yes | Yes (`codex`) | `openshell-codex` | None |
| OpenCode | MIT | Yes | Yes (`opencode`) | Post-MVP | None |
| OpenClaw | MIT | Yes | **Missing — needs to be created** | Post-MVP | No network policy definition exists yet |

---

## Open Questions

**Image and Build:**
1. Should the MVP ship 3 flavors (Claude Code, Codex, ADK) or expand to include OpenCode and OpenClaw from the start?
2. How often should the base image be rebuilt — weekly, on upstream release tags, or only when security vulnerabilities are found?
3. If Anthropic grants redistribution rights for Claude Code, should we switch from runtime download to pre-installation?

**Contract and Integration:**
4. Could there be filesystem path conflicts between what the image's startup script writes and what Kagenti's sidecars write?
5. When both OpenShell and Kagenti are installed, who is responsible for setting which environment variables and mount points?
6. Should the ARC specification live in its own repository (contributed to by both projects) or be embedded in one project?

**OpenShell and Kagenti Composition:**
7. Does OpenShell's Kubernetes compute driver create workloads in a way that Kagenti's webhook can detect and act on? **This needs a proof-of-concept.**
8. Should the OpenShell supervisor process and the agent run in the same pod or separate pods? (Active upstream debate in [OpenShell #981](https://github.com/NVIDIA/OpenShell/issues/981))
9. Which of the four proposed composition approaches should be pursued first?

**Platform:**
10. When a developer writes a bare skill name (e.g., `skills: [doc-coauthoring]`) without specifying a registry, which registry should the platform check first?
11. When an MCP server requires authentication, who handles the token exchange — the MCP Gateway, OpenShell's credential proxy, or the agent harness itself?

---

## Remaining Work

### Still Open from Phase 1

- [ ] Check RHAIENG-5245 for Kagenti crossover findings (assigned to Sam Schifman — currently In Progress with no published findings)
- [ ] Identify OpenShell team contacts beyond the AgentOps team (Varsha Prasad Narsing, Dimitri Saridakis)

### Finalization

- [ ] Write input for follow-up strategy tickets (RHAISTRAT-1838, RHAISTRAT-1840, RHAISTRAT-1841) — extract actionable items from the gap analysis
- [ ] Post final version to the agentic-starter-kits repo and link back to the Jira ticket

---

## References

**Jira Tickets:**
- [RHAIENG-5448](https://redhat.atlassian.net/browse/RHAIENG-5448) — This spike
- [RHAIENG-5245](https://redhat.atlassian.net/browse/RHAIENG-5245) — Kagenti crossover investigation (Sam Schifman, In Progress)
- [RHAIENG-5189](https://redhat.atlassian.net/browse/RHAIENG-5189) — OpenShell Operator TP documentation (Chris Tyler, New)
- [RHAIENG-3926](https://redhat.atlassian.net/browse/RHAIENG-3926) — OpenShell on OpenShift POC (deployment manifests attached)
- [RHAISTRAT-1349](https://redhat.atlassian.net/browse/RHAISTRAT-1349) — Runtime compatibility requirements for validated agent images
- [RHAIRFE-2309](https://redhat.atlassian.net/browse/RHAIRFE-2309) — Platform binding for agent runtimes (Approved) — sandbox security is explicitly out of scope
- [RHAIRFE-2310](https://redhat.atlassian.net/browse/RHAIRFE-2310) — Declarative agent deployment (Approved) — does not create OpenShell sandboxes

**Design Proposals:**
- [Validated Sandbox Images for OpenShell and Agent Runtimes](https://docs.google.com/document/d/1AK3bIAfE_OJeVnR8cgSpier4V-So8SbDEZFTWe7_BuI/edit?tab=t.0) — Image architecture, ARC contract, MVP scope
- [Declarative Runtime Harness & OpenShell Composition](https://docs.google.com/document/d/15RP9OLnz7_7H18UUYvfv-zEgLyP-gpY5aY6aJPGC_lI/edit?tab=t.0) — OpenShell/Kagenti ownership split and composition paths
- [Declarative Agent Harness Spec](https://docs.google.com/document/d/1Uam3aEM4knpHP5rfOpg49EsuclZSU3wStK02i8TxQv8/edit?tab=t.0) — Developer experience, skills/MCP resolution, composition challenges

**Repositories and Prior Art:**
- [NVIDIA/OpenShell-Community](https://github.com/NVIDIA/OpenShell-Community) — Public repository (sandbox images, skills, integrations)
- [NVIDIA/OpenShell](https://github.com/NVIDIA/OpenShell) — Core engine (private repository, Rust)
- [Engineering Harness OpenShell POC](https://redhat.atlassian.net/wiki/spaces/~712020dec8710c8d744e5493a17d2fdd2157af/pages/412189700) — Podman-based POC demonstrating Claude and Gemini in OpenShell sandboxes
