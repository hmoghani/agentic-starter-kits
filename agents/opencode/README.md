# OpenCode on Red Hat OpenShift AI

Deploy [OpenCode](https://opencode.ai), an open-source terminal-based coding agent, on Red Hat OpenShift AI. OpenCode provides AI-assisted code generation, code review, and multi-file editing capabilities, powered by models served on the platform through vLLM or OGX inference backends.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Container Image and Variants](#container-image-and-variants)
- [Deployment Modes](#deployment-modes)
  - [Web Mode with OAuth](#web-mode-with-oauth)
  - [CLI Mode](#cli-mode)
  - [Custom Environment](#custom-environment)
  - [OpenShell Sandbox](#openshell-sandbox)
- [Configuration](#configuration)
  - [Model Endpoint](#model-endpoint)
  - [Small Model](#small-model)
  - [Session Persistence](#session-persistence)
  - [Skills Injection](#skills-injection)
  - [MCP Server Configuration](#mcp-server-configuration)
- [MLflow Tracing](#mlflow-tracing)
  - [Setup (Kustomize Deployment)](#setup-kustomize-deployment)
  - [Verify](#verify-tracing)
  - [View Traces](#view-traces)
  - [Key Notes](#key-notes)
  - [OpenShell + MLflow Tracing](#openshell--mlflow-tracing)
- [A2A / Kagenti Discovery](#a2a--kagenti-discovery)
- [Security](#security)
- [Architecture](#architecture)
- [Troubleshooting](#troubleshooting)
- [Project Structure](#project-structure)
- [Related Resources](#related-resources)

---

## Prerequisites

- OpenShift 4.17+ cluster with `oc` CLI authenticated
- A model serving endpoint (vLLM, KServe, RHOAI model serving, or OGX) exposing an OpenAI-compatible API on a cluster-internal Service
- Block storage class (gp3-csi, managed-csi, thin-csi) for the workspace PVC

## Quick Start

The quick start deploys OpenCode in **web mode** using the pre-built container image with OAuth-secured browser access. No image build is required.

```bash
cd agents/opencode/deployment

# Edit manifests/kustomization.yaml — set BASE_URL, API_KEY, and MODEL_NAME
# (For production, use Sealed Secrets or External Secrets Operator instead of inline literals)
oc apply -k manifests/

oc -n opencode rollout status deployment/opencode-web
oc -n opencode get route opencode-web -o jsonpath='https://{.spec.host}{"\n"}'
```

Open the route URL in your browser. OpenShift OAuth handles authentication.

---

## Container Image and Variants

The quick start uses a **pre-built image** — no Containerfile or image build is needed. The Containerfiles in this kit are for extended variants that add capabilities on top of the base image.

| Variant | Image / Containerfile | Use when | Build required? |
|---------|----------------------|----------|-----------------|
| **Base (quick start)** | `quay.io/opendatahub/odh-opencode-rhel9:20260619-194847e` | Standard web or CLI deployment | No — pre-built |
| **MLflow tracing** | [`Containerfile.mlflow`](deployment/Containerfile.mlflow) | You need agent execution traces exported to MLflow | Yes |
| **A2A / Kagenti** | [`Containerfile.a2a`](deployment/Containerfile.a2a) | You want Kagenti agent discovery via the A2A protocol (agent card and discovery available; task execution pending RHAIENG-5826) | Yes |
| **OpenShell sandbox** | [`Containerfile.openshell`](deployment/Containerfile.openshell) | Sandboxed experimentation inside an OpenShell gateway | Yes |

The base image is built from [opendatahub-io/opencode](https://github.com/opendatahub-io/opencode) (UBI 9 minimal, non-root, `restricted-v2` SCC). Each Containerfile extends this base with additional dependencies — they are separate because each variant has different runtime requirements and not all users need every capability.

### Building a Variant

```bash
cd agents/opencode/deployment

# MLflow tracing
podman build --platform linux/amd64 -t opencode-mlflow:latest -f Containerfile.mlflow .

# A2A / Kagenti
podman build --platform linux/amd64 -t opencode-a2a:latest -f Containerfile.a2a .

# OpenShell sandbox
podman build --platform linux/amd64 -t opencode-sandbox:latest -f Containerfile.openshell .
```

---

## Deployment Modes

All deployment modes use [Kustomize](https://kustomize.io/) with a shared base and per-mode overlays:

```text
deployment/manifests/          # Base: web mode with OAuth proxy
deployment/overlays/cli/       # Overlay: headless CLI mode (no OAuth, no Route)
deployment/overlays/example/   # Overlay: template for custom environments
deployment/overlays/mlflow-tracing/  # Overlay: MLflow tracing integration
```

Edit `manifests/kustomization.yaml` to configure the model endpoint, API key, model name, and storage class. Apply overlays with `oc apply -k overlays/<mode>`.

### Web Mode with OAuth

This is the default deployment mode, covered in the [Quick Start](#quick-start) above.

The web mode runs a two-container pod with an OAuth proxy sidecar for browser-based access. See [Architecture](#architecture) for details.

### CLI Mode

Headless deployment for interactive terminal sessions or CI pipelines. No OAuth proxy or Route is created.

```bash
cd agents/opencode/deployment

oc apply -k overlays/cli

oc -n opencode rollout status deployment/opencode-web
oc -n opencode exec -it deployment/opencode-web -c opencode-web -- opencode
```

#### Resuming Sessions (CLI Mode)

```bash
# List previous sessions
oc exec deployment/opencode-web -c opencode-web -- opencode session list

# Resume the most recent session
oc exec -it deployment/opencode-web -c opencode-web -- opencode --continue

# Resume a specific session
oc exec -it deployment/opencode-web -c opencode-web -- opencode --session <session-id>
```

### Custom Environment

```bash
cp -r deployment/overlays/example deployment/overlays/my-env
# Edit overlays/my-env/kustomization.yaml — namespace, model, storage class
oc apply -k deployment/overlays/my-env
```

### OpenShell Sandbox

Run OpenCode inside an [NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell) sandbox with policy-enforced network isolation.

#### Prerequisites

- [Podman](https://podman.io/) or Docker installed
- [OpenShell CLI](https://github.com/NVIDIA/OpenShell-Community) installed and connected to a gateway
- An OGX-compatible inference endpoint reachable from the sandbox

#### Build

```bash
cd agents/opencode/deployment

podman build --platform linux/amd64 -t opencode-sandbox:latest -f Containerfile.openshell .
```

Build with `--platform linux/amd64` when targeting x86_64 clusters from Apple Silicon machines.

#### Run

OpenShell's sandbox supervisor replaces the image's CMD/ENTRYPOINT at runtime. Start OpenCode manually inside the sandbox:

```bash
openshell sandbox create \
  --name opencode \
  --from opencode-sandbox:latest
```

> **Note:** OpenShell's supervisor takes over as PID 1 and does not automatically run OpenCode. Start it manually inside the sandbox.

#### OpenShell on RHOAI

<!-- TODO(RHAIENG-6261): This section needs cluster testing before it can be completed.
     The following areas need to be validated:
     1. Registering the OpenShell image with an RHOAI-hosted OpenShell gateway
     2. Passing model endpoint env vars into the sandbox
     3. Network/egress configuration for reaching vLLM/OGX endpoints
     4. Whether Containerfile.openshell works as-is on RHOAI

     Reference materials:
     - "OpenShell on OpenShift with mTLS" deployment guide (see RHAIENG-6261 Jira comments)
     - NVIDIA OpenShell GitHub: https://github.com/NVIDIA/OpenShell
     - ADK OpenShell guide: agents/google/templates/adk/OPENSHELL.md
-->

Deploying OpenCode in OpenShell **on an RHOAI cluster** is being validated. This section will be updated with verified steps once cluster testing is complete. See [RHAIENG-6261](https://redhat.atlassian.net/browse/RHAIENG-6261) for status.

Tested on: OpenShell v0.0.58, OpenShift 4.21 (June 2026). OpenCode version 1.17.1.

---

## Configuration

| Setting | Where to change | Notes |
|---------|----------------|-------|
| Model endpoint URL | `manifests/kustomization.yaml` (`BASE_URL`) | Cluster-internal DNS, e.g. `http://vllm-svc.vllm.svc.cluster.local/v1` |
| API key | `manifests/kustomization.yaml` (`API_KEY`) | Use `"token"` if auth is disabled |
| Model name | `manifests/kustomization.yaml` (`MODEL_NAME`) | Must match the model loaded in vLLM |
| Storage class | `manifests/kustomization.yaml` (patch section) | Default PVC is 10Gi |
| MCP servers | ConfigMap `opencode-web-mcp` | Optional; merged into config at startup |
| Provider (vLLM vs OGX) | `manifests/config-template.json` (`enabled_providers`) | Both enabled by default |

### Small Model

To use a lighter model for summarization, commit messages, and other quick tasks, set `SMALL_MODEL_NAME` in the deployment environment. If not set, it defaults to `MODEL_NAME`. Both models must be reachable through the configured provider endpoint.

### Session Persistence

OpenCode session history and workspace files persist across pod restarts. The container's working directory is set to the PVC mount (`/opt/app-root/workspace`), so files created during a session are stored on persistent storage. The entrypoint additionally redirects OpenCode's internal data directories to PVC-backed paths.

#### How It Works

| Default Path               | Redirected To                                       | Purpose                   |
|----------------------------|-----------------------------------------------------|---------------------------|
| `~/.config/opencode/`      | `/opt/app-root/workspace/.opencode/config/opencode/`| Configuration, settings   |
| `~/.local/share/opencode/` | `/opt/app-root/workspace/.opencode/data/opencode/`  | Session history, database |
| `~/.local/state/opencode/` | `/opt/app-root/workspace/.opencode/state/opencode/` | Locks, runtime state      |

The entrypoint creates symlinks from default XDG locations to PVC-backed paths and exports `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, and `XDG_STATE_HOME` to point at the persistent directories.

> **Note**: The container image creates `~/.local/state/` with 755 permissions, which prevents symlink creation under OpenShift's random UID (the root group cannot write to 755 directories). The entrypoint's `XDG_STATE_HOME` export works around this. If this is fixed upstream in the container image (by using 775 permissions), the workaround can be removed.

#### Customizing the Data Directory

Override the default location by setting the `OPENCODE_DATA_DIR` environment variable in the deployment:

```yaml
env:
  - name: OPENCODE_DATA_DIR
    value: /opt/app-root/workspace/my-custom-dir
```

The entrypoint creates `config/opencode/`, `data/opencode/`, and `state/opencode/` subdirectories within this path.

### Skills Injection

Skills extend OpenCode with custom instructions. No skills are included by default — you create and inject your own.

Skills are auto-discovered from `~/.config/opencode/skills/`. The skills ConfigMap is mounted at `/etc/opencode-skills/` and the entrypoint symlinks it into the config directory. Each skill must be in a subdirectory containing a `SKILL.md` file with YAML frontmatter.

#### Example: Creating a Code Review Skill

**1. Create a `SKILL.md` file:**

```markdown
---
name: code-review
description: Analyze code for correctness, security, and performance issues
---

# Code Review

When reviewing code, analyze for:

1. **Correctness** - Logic errors, edge cases, off-by-one errors
2. **Security** - Input validation, injection risks, hardcoded secrets
3. **Performance** - Unnecessary loops, N+1 queries, missing indexes
```

**2. Create a ConfigMap from your skill files:**

```bash
oc create configmap opencode-web-skills \
  --from-file=code-review-skill=./skills/code-review/SKILL.md
```

**3. Add an `items` mapping to the skills volume in your deployment manifest:**

The `items` mapping creates the subdirectory structure OpenCode expects:

```yaml
volumes:
  - name: skills
    configMap:
      name: opencode-web-skills
      optional: true
      items:
        - key: code-review-skill
          path: code-review/SKILL.md
```

**4. Restart the deployment:**

```bash
oc rollout restart deployment/opencode-web
```

### MCP Server Configuration

MCP (Model Context Protocol) servers extend OpenCode with additional tools. Inject MCP server configuration at startup via ConfigMap (`opencode-web-mcp`), extending the agent with additional tools without rebuilding the image.

The entrypoint merges the MCP config into the OpenCode configuration at startup:

```bash
# Create the ConfigMap
oc create configmap opencode-web-mcp \
  --from-file=mcp-servers.json=./mcp-servers.json

# Restart to pick up the config
oc rollout restart deployment/opencode-web
```

---

## MLflow Tracing

Enable MLflow tracing for OpenCode on Red Hat OpenShift AI. Works in both web and CLI modes.

For trace schema, backend comparisons, and latency benchmarks, see [deployment/docs/mlflow-tracing.md](deployment/docs/mlflow-tracing.md).

### Setup (Kustomize Deployment)

#### 1. Build the image

Use [`Containerfile.mlflow`](deployment/Containerfile.mlflow) instead of the base image. It extends the base OpenCode image with `mlflow[kubernetes]` and the pre-built `@mlflow/opencode` plugin.

```bash
cd agents/opencode/deployment
podman build --platform linux/amd64 -t opencode-mlflow:latest -f Containerfile.mlflow .
```

#### 2. Grant RBAC

Grant the `edit` role to the service account used by the deployment. Check your deployment's `serviceAccountName` — it may be `default` or a named account like `opencode-web`:

```bash
oc adm policy add-role-to-user edit -z <service-account-name> -n <your-namespace>
```

#### 3. Configure MLflow env vars

Find your MLflow tracking URI:

```bash
oc get svc -A | grep mlflow
# Use the service name, namespace, and port to construct:
# https://<service-name>.<namespace>.svc:<port>/mlflow
```

Set these env vars on the deployment:

| Env var | What to set |
|---|---|
| `MLFLOW_TRACKING_URI` | The URI from the command above |
| `MLFLOW_WORKSPACE` | Your namespace / project name |
| `MLFLOW_EXPERIMENT_NAME` | Name for your experiment (e.g., `opencode-traces`) |
| `MLFLOW_TRACKING_INSECURE_TLS` | `true` for dev/test, remove for production with proper TLS |
| `NODE_TLS_REJECT_UNAUTHORIZED` | `0` for dev/test, remove for production with proper TLS |
| `OPENCODE_MODE` | `web` (default) or `cli` for terminal mode |

#### 4. Deploy

**If deploying for the first time:** Add the env vars above and the MLflow entrypoint block from [`overlays/mlflow-tracing/entrypoint-patch.yaml`](deployment/overlays/mlflow-tracing/entrypoint-patch.yaml) to your deployment manifests before applying.

**If OpenCode is already deployed:** Make sure the deployment is using the MLflow image. Then apply the overlay:

```bash
cd agents/opencode/deployment
oc apply -k overlays/mlflow-tracing/
oc rollout restart deployment/<your-deployment-name>
```

### Verify Tracing

```bash
# Check startup logs
oc logs deployment/<your-deployment-name> | grep -i mlflow

# CLI mode
oc exec deployment/<your-deployment-name> -- bash -c '
  source $HOME/.mlflow-env 2>/dev/null
  cd /opt/app-root/workspace
  opencode run "What is 2+2?"
'

# Web mode: send a message in the browser, then check MLflow
```

### View Traces

```bash
oc get consolelink mlflow -o jsonpath='{.spec.href}'
```

Navigate to your workspace and experiment name to see traces.

### Key Notes

- The image must be built with [`Containerfile.mlflow`](deployment/Containerfile.mlflow)
- `MLFLOW_TRACKING_TOKEN` is read from the pod's SA token automatically
- The entrypoint handles plugin install, experiment creation, and auth — no manual plugin setup needed
- Until the next `@mlflow/opencode` npm release includes the workspace header fix, the entrypoint replaces the cached plugin with a build from the v3.14.0 release tag

> **TLS note:** `NODE_TLS_REJECT_UNAUTHORIZED=0` disables TLS verification for all Node.js connections in the container, not just MLflow. For production, use `NODE_EXTRA_CA_CERTS` instead. Upstream work is in progress to support `MLFLOW_TRACKING_INSECURE_TLS` and `MLFLOW_TRACKING_SERVER_CERT_PATH` scoped to MLflow connections only ([mlflow#24140](https://github.com/mlflow/mlflow/issues/24140)). Kubernetes-native auth (`MLFLOW_TRACKING_AUTH`) is also being added to the TypeScript SDK ([mlflow#24141](https://github.com/mlflow/mlflow/issues/24141)).

### OpenShell + MLflow Tracing

<!-- TODO(RHAIENG-6261): This section needs cluster testing before it can be completed.
     Areas to validate:
     1. OpenShell sandbox egress to MLflow service (network/sandbox policy)
     2. Environment variable injection for MLFLOW_TRACKING_URI, etc.
     3. Whether a combined Containerfile.openshell-mlflow is needed
     4. End-to-end: OpenCode in OpenShell on RHOAI with traces to RHOAI MLflow
-->

MLflow tracing for the OpenShell deployment path is being validated. This section will be updated once cluster testing confirms the egress configuration and environment variable injection needed for OpenShell sandboxes to reach an RHOAI MLflow instance. See [RHAIENG-6261](https://redhat.atlassian.net/browse/RHAIENG-6261) for status.

---

## A2A / Kagenti Discovery

OpenCode can be deployed as a Kagenti-discoverable agent using the Agent-to-Agent (A2A) protocol. This enables service discovery via the Kagenti agent catalog.

**Current state:**
- Agent card server is implemented and running
- Agent discovery works in Kagenti UI
- Health checks are proxied
- A2A task execution is not yet implemented (tracked in RHAIENG-5826)

For full A2A deployment instructions, see [deployment/README-a2a.md](deployment/README-a2a.md).

---

## Security

- **SCC**: Runs under `restricted-v2` — `runAsNonRoot`, drop all capabilities, seccomp RuntimeDefault. No special SCC grants required.
- **TLS**: Reencrypt termination end-to-end; serving certificate auto-generated by OpenShift.
- **RBAC**: OAuth proxy enforces Subject Access Review — users must have `get` on `services` in the deployment namespace.
- **Secrets**: Inline secrets in `kustomization.yaml` are for convenience only. For production, use Sealed Secrets, External Secrets Operator, or Secrets Store CSI Driver.

---

## Architecture

The web mode deployment runs a two-container pod:

1. **oauth-proxy** — OpenShift OAuth proxy sidecar handling authentication via TLS on port 8443
2. **opencode-web** — OpenCode application serving the web UI on port 8003

The entrypoint script (`manifests/entrypoint.sh`) handles:

- Persistence — working directory is `/opt/app-root/workspace` (PVC mount), so workspace files survive pod restarts
- Session data redirection — symlinks OpenCode's config, data, and state directories from default XDG locations to PVC-backed paths under `.opencode/`
- Git workspace initialization
- Config template variable substitution (BASE_URL, API_KEY, MODEL_NAME)
- Skills injection — symlinks ConfigMap-mounted skills into the config directory
- Optional MCP server config injection from a ConfigMap
- Mode switching between web and CLI

### Comparison: OpenShell Sandbox vs Kustomize Deployment

| | OpenShell sandbox | Kustomize deployment |
|--|-------------------|---------------------|
| **Image** | `openshell-base` + npm flavor | `odh-opencode-rhel9` (Go binary) |
| **Runtime** | Inside OpenShell gateway | Standalone pod on OpenShift |
| **Auth** | OpenShell gateway | OpenShift OAuth proxy |
| **Use case** | Sandboxed experimentation | Production RHOAI deployment |
| **Manifests** | N/A (OpenShell manages lifecycle) | `manifests/` in this directory |

---

## Troubleshooting

### Container Image

| Field | Value |
|-------|-------|
| Image | `quay.io/opendatahub/odh-opencode-rhel9:20260619-194847e` |
| OpenCode version | Built from [opendatahub-io/opencode](https://github.com/opendatahub-io/opencode) |
| Base | UBI 9 minimal |
| License | MIT (OpenCode), Apache 2.0 (deployment manifests) |

### What the Image Contains

| Layer | Purpose |
|-------|---------|
| UBI 9 minimal | RHEL-compatible base |
| OpenCode | Go binary built from source |
| git, jq, make, vim-minimal, diffutils, findutils, openssh-clients, patch, procps-ng, tar, gzip, which | CLI tools for development workflows |
| Python 3 + [uv](https://github.com/astral-sh/uv) | Python environment and package manager |

### Version Pinning Strategy

- **OpenCode**: pinned to a tagged release in the Containerfile `ARG`. Upgrades require a new image build and manifest update.
- **Go runtime**: build-time only; not present in the final image (multi-stage build).
- **Base image**: `registry.access.redhat.com/ubi9/ubi-minimal`, pulled at build time. Pin to a specific tag for reproducible builds.
- **Image tag in manifests**: pin to a specific tag or digest in production. Avoid `:latest`.

---

## Project Structure

```text
agents/opencode/
├── README.md                         # This file — unified deployment guide
├── templates/opencode_agent/
│   ├── agent.yaml                    # Agent metadata for catalog
│   └── README.md                     # Catalog README
└── deployment/
    ├── README.md                     # File index
    ├── manifests/                    # Base kustomize manifests (web mode + OAuth)
    │   ├── kustomization.yaml        # Kustomize entrypoint
    │   ├── namespace.yaml
    │   ├── serviceaccount.yaml
    │   ├── deployment.yaml           # Two-container pod (oauth-proxy + opencode)
    │   ├── service.yaml
    │   ├── route.yaml
    │   ├── pvc.yaml
    │   ├── entrypoint.sh             # Container entrypoint (config, MCP, mode switching)
    │   └── config-template.json      # OpenCode provider config (vLLM + OGX)
    ├── overlays/
    │   ├── cli/                      # CLI mode overlay
    │   ├── example/                  # Template for custom environments
    │   └── mlflow-tracing/           # MLflow tracing overlay
    ├── Containerfile.openshell       # OpenShell sandbox variant
    ├── Containerfile.mlflow          # MLflow tracing image variant
    ├── Containerfile.a2a             # A2A / Kagenti agent discovery variant
    ├── entrypoint-a2a.sh             # Entrypoint for A2A variant
    ├── kagenti-agent.yaml            # OpenShift Template for Kagenti deployment
    ├── README-a2a.md                 # A2A / Kagenti deployment guide
    └── docs/                         # MLflow tracing schema and benchmarks
```

---

## Related Resources

- [deployment/README-a2a.md](deployment/README-a2a.md) — A2A / Kagenti agent discovery deployment
- [deployment/docs/mlflow-tracing.md](deployment/docs/mlflow-tracing.md) — tracing schema, backend comparisons, latency benchmarks
- [opendatahub-io/opencode](https://github.com/opendatahub-io/opencode) — container image source and CI
- [OpenCode upstream](https://github.com/sst/opencode) — upstream project
