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

[NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell) is an open-source sandbox runtime for AI agents. It runs containers inside a policy-enforced isolation boundary with controlled network egress and filesystem constraints — think of it as a lightweight VM alternative where the OpenShell supervisor intercepts all I/O and enforces security policies.

This section walks through installing an OpenShell gateway on OpenShift via Helm, building the OpenCode sandbox image, creating a sandbox, and running OpenCode against a vLLM model endpoint.

> Tested on: OpenShell gateway v0.0.86, CLI v0.0.58, OpenShift 4.21 (July 2026), OpenCode 1.17.1.

#### What you'll set up

```text
┌─ Your namespace ──────────────────────────────────────────────┐
│                                                               │
│  openshell-0 (gateway)         opencode (sandbox pod)         │
│  ┌─────────────────────┐       ┌─────────────────────────┐   │
│  │ Manages sandbox      │──────▶│ OpenShell supervisor     │   │
│  │ lifecycle, auth,     │       │ (PID 1, runs as root)   │   │
│  │ policy enforcement   │       │                         │   │
│  └─────────────────────┘       │ OpenCode (user sandbox)  │   │
│                                 │ ┌─────────────────────┐ │   │
│                                 │ │ npm opencode-ai      │ │   │
│                                 │ │ connects to vLLM     │─┼───┼──▶ vLLM endpoint
│                                 │ └─────────────────────┘ │   │
│                                 └─────────────────────────┘   │
└───────────────────────────────────────────────────────────────┘
```

#### Prerequisites

- OpenShift 4.17+ cluster with `oc` CLI authenticated
- [Helm](https://helm.sh/) 3+ installed locally
- [OpenShell CLI](https://docs.nvidia.com/openshell/latest/installation) installed locally (`openshell --version` should print `0.0.58` or later)
- The Kubernetes Agent Sandbox CRD must be installed on the cluster. Verify with `oc get crd sandboxes.agents.x-k8s.io`. If not installed, follow the [Red Hat build of Agent Sandbox](https://docs.redhat.com/en/documentation/red_hat_build_of_agent_sandbox) instructions or the [upstream k8s sandbox operator](https://github.com/kubernetes-sigs/agent-sandbox) installation
- A vLLM model serving endpoint reachable from within the cluster

#### Step 1: Create a namespace

```bash
oc new-project <your-namespace>
```

All subsequent commands assume you are working in this namespace.

#### Step 2: Grant the privileged SCC

The OpenShell sandbox service account needs the `privileged` SCC. The Helm chart creates the service account with the name `<release-name>-sandbox` — since we'll use `openshell` as the release name, the SA will be `openshell-sandbox`:

```bash
oc adm policy add-scc-to-user privileged -z openshell-sandbox -n <your-namespace>
```

> **Important:** This must be done **before** installing the Helm chart. If the SCC binding is missing, sandbox pods will fail with `unable to validate against any security context constraint`.

#### Step 3: Install the OpenShell gateway via Helm

```bash
helm install openshell oci://ghcr.io/nvidia/openshell/helm-chart \
  --version 0.0.86 \
  --namespace <your-namespace> \
  --set podSecurityContext.fsGroup=null \
  --set securityContext.runAsUser=null \
  --set server.auth.allowUnauthenticatedUsers=true
```

> **Shared clusters:** If the cluster already has an OpenShell installation in another namespace, the Helm install may fail with a `ClusterRole "openshell-node-reader" already exists` error. Add `--set nodeReader.enabled=false` to skip creating the cluster-scoped resource.

Wait for the gateway to be ready:

```bash
oc rollout status statefulset/openshell -n <your-namespace> --timeout=120s
```

#### Step 4: Connect the OpenShell CLI

The Helm chart auto-generates mTLS certificates for secure gateway communication. Extract them to your local machine:

```bash
mkdir -p ~/.config/openshell/gateways/openshift/mtls

oc -n <your-namespace> get secret openshell-client-tls \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > ~/.config/openshell/gateways/openshift/mtls/ca.crt

oc -n <your-namespace> get secret openshell-client-tls \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > ~/.config/openshell/gateways/openshift/mtls/tls.crt

oc -n <your-namespace> get secret openshell-client-tls \
  -o jsonpath='{.data.tls\.key}' | base64 -d > ~/.config/openshell/gateways/openshift/mtls/tls.key
```

Start a port-forward and register the gateway:

```bash
oc port-forward svc/openshell 8080:8080 -n <your-namespace> &

openshell gateway add https://127.0.0.1:8080 --local --name openshift
```

Verify the connection:

```bash
openshell status
```

Expected output:

```text
Server Status

  Gateway: openshift
  Server: https://127.0.0.1:8080
  Status: Connected
  Version: 0.0.86
```

#### Step 5: Build the OpenCode sandbox image

The image must be built inside the cluster so the internal registry can serve it to sandbox pods:

```bash
cd agents/opencode/deployment

oc create imagestream opencode-sandbox -n <your-namespace>

cat <<'EOF' | oc apply -n <your-namespace> -f -
apiVersion: build.openshift.io/v1
kind: BuildConfig
metadata:
  name: opencode-sandbox
spec:
  output:
    to:
      kind: ImageStreamTag
      name: opencode-sandbox:latest
  source:
    type: Binary
  strategy:
    dockerStrategy:
      dockerfilePath: Containerfile.openshell
    type: Docker
EOF

oc start-build opencode-sandbox --from-dir=. --follow -n <your-namespace>
```

#### Step 6: Create a sandbox

```bash
openshell sandbox create \
  --name opencode \
  --from image-registry.openshift-image-registry.svc:5000/<your-namespace>/opencode-sandbox:latest \
  -- sleep infinity
```

The CLI may show a supervisor relay timeout during creation — this is a timing issue and can be ignored. Verify the sandbox reached `Ready` state:

```bash
openshell sandbox list
```

Expected output:

```text
NAME      CREATED              PHASE
opencode  2026-07-24 18:45:00  Ready
```

#### Step 7: Configure OpenCode and test

The sandbox supervisor runs as root (PID 1). OpenCode runs as the `sandbox` user. You need to prepare the home directory, write the OpenCode provider config, and initialize a git workspace.

Replace `<vllm-service>`, `<vllm-namespace>`, and `<model-name>` with your vLLM endpoint details:

```bash
oc exec -n <your-namespace> opencode -c agent -- /bin/bash -c '
# Determine the sandbox user UID (assigned by OpenShift namespace range)
SANDBOX_UID=$(id -u sandbox 2>/dev/null || id -g sandbox)

# Prepare home directory
mkdir -p /home/sandbox/.local /home/sandbox/.cache /home/sandbox/.config/opencode
chown -R $SANDBOX_UID:$SANDBOX_UID /home/sandbox

# Write OpenCode provider configuration
cat > /home/sandbox/.config/opencode/opencode.json << '\''CONF'\''
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "vllm": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "vLLM",
      "options": {
        "baseURL": "http://<vllm-service>.<vllm-namespace>.svc.cluster.local/v1",
        "apiKey": "token"
      },
      "models": {
        "<model-name>": {
          "name": "<model-name>"
        }
      }
    }
  },
  "model": "vllm/<model-name>",
  "small_model": "vllm/<model-name>",
  "enabled_providers": ["vllm"]
}
CONF
chown $SANDBOX_UID:$SANDBOX_UID /home/sandbox/.config/opencode/opencode.json

# Initialize git workspace (OpenCode requires a git repo)
cd /workspace
git init
git config user.email "opencode@openshift.local"
git config user.name "OpenCode"
chown -R $SANDBOX_UID:$SANDBOX_UID /workspace
echo "Setup complete"
'
```

Test that OpenCode can reach the model:

```bash
oc exec -n <your-namespace> opencode -c agent -- su -s /bin/bash sandbox -c \
  'cd /workspace && HOME=/home/sandbox opencode run "What is 2+2? Reply with just the number."'
```

Expected output:

```text
> build · <model-name>

4
```

To start an interactive session:

```bash
oc exec -it -n <your-namespace> opencode -c agent -- su -s /bin/bash sandbox -c \
  'cd /workspace && HOME=/home/sandbox opencode'
```

#### Cleanup

```bash
# Delete the sandbox
openshell sandbox delete opencode

# Uninstall the OpenShell gateway
helm uninstall openshell -n <your-namespace>

# Clean up the SCC binding
oc adm policy remove-scc-from-user privileged -z openshell-sandbox -n <your-namespace>

# Delete build resources
oc delete buildconfig opencode-sandbox -n <your-namespace>
oc delete imagestream opencode-sandbox -n <your-namespace>

# Delete the namespace (removes everything)
oc delete project <your-namespace>
```

#### Troubleshooting

**Sandbox pod fails with SCC error:** The `openshell-sandbox` service account needs the `privileged` SCC. Run the SCC binding command from Step 2. The SCC must be granted **before** creating the sandbox.

**Sandbox stuck in `Provisioning`:** Check the sandbox status for errors:

```bash
oc get sandbox opencode -n <your-namespace> -o yaml | grep -A5 conditions
```

Common causes: SCC not granted, image pull failure, or the Sandbox CRD controller not running.

**`EACCES: permission denied, mkdir '/home/sandbox/.local'`:** The sandbox user UID is assigned by OpenShift's namespace UID range (not a fixed 1001). You must create and `chown` the home directory before running OpenCode (Step 7).

**OpenCode errors with `not in a git directory`:** OpenCode requires a git repository in the working directory. Run `git init` in `/workspace` (Step 7).

**Helm install fails with `ClusterRole already exists`:** Another OpenShell installation on the cluster already created the `openshell-node-reader` ClusterRole. Add `--set nodeReader.enabled=false` to the Helm install command.

**CLI shows `supervisor relay failed` during sandbox creation:** This is a timing issue — the CLI tries to SSH before the supervisor is fully connected. Check `openshell sandbox list` — if the sandbox shows `Ready`, it is working.

**Image pull errors:** The sandbox image must be in the cluster's internal registry. Build it via `oc start-build` (Step 5), not with local `podman build`.

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
