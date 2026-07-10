# Codex on OpenShift

A guide to deploying [OpenAI Codex CLI](https://github.com/openai/codex) as a containerized coding agent on Red Hat OpenShift. Connects to a vLLM inference endpoint via the OpenAI Responses API (`/v1/responses`).

## Table of Contents

- [Licensing](#licensing)
- [Prerequisites](#prerequisites)
- [Step 1: Build the Container Image](#step-1-build-the-container-image)
- [Step 2: Create an OpenShift Project](#step-2-create-an-openshift-project)
- [Step 3: Deploy](#step-3-deploy)
- [Local Test (Optional)](#local-test-optional)
- [Using Codex](#using-codex)
  - [Interactive Mode](#interactive-mode)
  - [Headless Execution](#headless-execution)
  - [Retrieving Files from the Container](#retrieving-files-from-the-container)
- [Configuration](#configuration)
  - [Session Persistence](#session-persistence)
  - [config.toml Overrides](#configtoml-overrides)
  - [MCP Servers](#mcp-servers)
  - [Extending the Container Image](#extending-the-container-image)
- [Security Considerations](#security-considerations)
- [Troubleshooting](#troubleshooting)
- [Cleanup](#cleanup)
- [Known Limitations](#known-limitations)

---

## Licensing

Codex CLI is released under the [Apache 2.0 license](https://github.com/openai/codex/blob/main/LICENSE). The Containerfiles in this directory and the resulting images are freely redistributable. No proprietary components are included.

---

## Prerequisites

- `podman` installed locally (on macOS, also run `podman machine init` and `podman machine start`)
- `oc` CLI installed and logged into your OpenShift cluster
- A vLLM endpoint serving the OpenAI Responses API at `/v1/responses` (vLLM v0.10.0+)

Codex CLI uses the **Responses API exclusively**. It does not use the Chat Completions API (`/v1/chat/completions`). Your vLLM server must support `/v1/responses`. See [Responses API Compatibility](#responses-api-compatibility) in Troubleshooting if you encounter errors.

All shell commands in this guide assume you are in the `deployment/` subdirectory, where the Containerfile and deployment manifests live:

```bash
cd deployment/
```

---

## Step 1: Build the Container Image

Codex uses a two-stage image build: a **base image** containing the Codex Rust binary on UBI 9 minimal, and a **flavor image** that extends it with the RHOAI entrypoint, MCP injection, and session persistence.

### Build the base image

The base image uses a multi-stage Dockerfile. The builder stage compiles Codex and bubblewrap (`bwrap`) from the upstream Apache 2.0 source using the official Rust toolchain, producing auditable binaries with no opaque pre-built artifacts. Only the compiled binaries are copied into the clean UBI 9 minimal runtime. The runtime stage installs Node.js 16 and npm from UBI repos for npx-based MCP servers.

#### Build requirements

| Resource | Minimum | Notes |
|----------|---------|-------|
| RAM | 32 GB | Podman VM must be configured with `podman machine set --memory 32768`. The Rust linker requires this during the final linking step of the 130+ crate workspace. |
| Disk | 50 GB | The builder stage downloads ~1.5 GB of Rust crate sources and produces ~20 GB of intermediate compilation artifacts. These are cleaned up before the layer is committed, but the space is needed during the build. |
| Time | ~12 min | Cross-compiling from ARM64 to x86_64. Native x86_64 builds are faster. |
| Network | Required | The builder clones the Codex source from GitHub and downloads the Rust toolchain + crate registry. Not needed once the image is built. |

On Apple Silicon Macs, the builder uses cross-compilation (not QEMU emulation) to produce an x86_64 binary. This avoids the SIGSEGV crashes that occur when running `rustc` under QEMU, but requires more RAM than a native build. The upstream release profile's thin LTO is disabled during cross-compilation to stay within memory limits — the binary is functionally identical, just slightly larger.

Native x86_64 builds (e.g., on the cluster via `oc start-build` or in CI) do not have the 32 GB RAM constraint and can use the default podman/Docker settings.

#### Podman machine setup (macOS only)

```bash
# First time
podman machine init --memory 32768 --disk-size 100

# Or update an existing machine
podman machine stop
podman machine set --memory 32768
podman machine start
```

#### Build commands

```bash
podman build --platform linux/amd64 \
  -t codex-base:latest \
  -f Containerfile.base .

# Build with a specific version (use rust-v* git tags)
podman build --platform linux/amd64 \
  --build-arg CODEX_VERSION=rust-v0.144.0 \
  -t codex-base:0.144.0 \
  -f Containerfile.base .
```

### Build the RHOAI flavor image

The flavor image extends the base with the RHOAI entrypoint. This is a fast build (~5 seconds) since it only adds shell scripts.

```bash
podman build --platform linux/amd64 \
  -t codex:latest \
  -f Containerfile \
  --build-arg BASE_IMAGE=codex-base:latest .
```

### Version pinning

The `CODEX_VERSION` build arg controls which git tag to build from. It defaults to `rust-v0.144.0`. Pin it explicitly for reproducible builds:

```bash
podman build --platform linux/amd64 \
  --build-arg CODEX_VERSION=rust-v0.144.0 \
  -t codex-base:0.144.0 \
  -f Containerfile.base .
```

Available tags are listed at [github.com/openai/codex/releases](https://github.com/openai/codex/releases). Use the `rust-v*` tags.

### Image sizes

| Image | Approximate Size | Contents |
|-------|-----------------|----------|
| `codex-base` | ~579 MB | UBI 9 minimal + Codex + bwrap (compiled from source) + git, jq, tar, nodejs, npm |
| `codex` (flavor) | ~579 MB | Base + entrypoint.sh, codex-run wrapper |

The flavor image adds only shell scripts, so its size is effectively the same as the base.

---

## Step 2: Create an OpenShift Project

```bash
oc new-project my-codex-project
```

---

## Step 3: Deploy

### Configure the vLLM endpoint

Edit `deployment.yaml` and update the placeholder values in the Deployment env section:

| Variable | Purpose | Example |
|----------|---------|---------|
| `OPENAI_BASE_URL` | vLLM server base URL (must serve `/v1/responses`) | `http://vllm-svc.namespace.svc.cluster.local/v1` |
| `OPENAI_API_KEY` | API key for the vLLM endpoint (use `"dummy"` if none required) | `dummy` |
| `OPENAI_MODEL` | Model ID as reported by `GET /v1/models` | `your-model-id` |

The entrypoint automatically generates a `[model_providers.vllm]` block in `config.toml` from these environment variables. You do not need to write TOML configuration manually for the basic case.

### Apply manifests and build

The deployment manifest contains all required resources: ImageStream, BuildConfig, ConfigMaps (config.toml and MCP), a 1Gi PVC, and the Deployment.

```bash
# Apply all resources (ImageStream, BuildConfig, ConfigMaps, PVC, Deployment)
oc apply -f deployment.yaml

# Option A: Build on the cluster (requires internet for docker.io/rust:1-bookworm)
#
# Create a BuildConfig for the base image
oc new-build --strategy=docker --binary --name=codex-base
oc start-build codex-base --from-dir=. --follow
#
# Then build the RHOAI flavor
oc start-build codex --from-dir=. --follow

# Option B: Build locally and push (recommended — avoids Docker Hub rate limits)
#
# Build locally (see Step 1), then push to the internal registry:
REGISTRY=$(oc get route -n openshift-image-registry image-registry -o jsonpath='{.spec.host}')
podman login "${REGISTRY}" -u $(oc whoami) -p $(oc whoami -t) --tls-verify=false
podman tag codex:latest "${REGISTRY}/$(oc project -q)/codex:latest"
podman push "${REGISTRY}/$(oc project -q)/codex:latest" --tls-verify=false
#
# Import into the ImageStream
oc tag --source=docker \
  image-registry.openshift-image-registry.svc:5000/$(oc project -q)/codex:latest \
  codex:latest

# Wait for rollout
oc rollout status deployment/codex
```

### Verify the deployment

```bash
# Check the pod is running and the entrypoint configured correctly
oc exec deployment/codex -- bash -c 'codex --version && cat ~/.codex/config.toml'

# Test connectivity to the vLLM endpoint
oc exec deployment/codex -- bash -c \
  'curl -s http://vllm-svc.your-namespace.svc.cluster.local/v1/models | jq .'
```

---

## Local Test (Optional)

Test the image locally with podman before deploying to OpenShift:

```bash
# Headless execution
podman run --rm \
  -e OPENAI_BASE_URL="http://YOUR_VLLM_ENDPOINT/v1" \
  -e OPENAI_API_KEY="dummy" \
  -e OPENAI_MODEL="YOUR_MODEL_ID" \
  codex:latest \
  codex exec "What is 2+2?"

# Interactive mode
podman run -it --rm \
  -e OPENAI_BASE_URL="http://YOUR_VLLM_ENDPOINT/v1" \
  -e OPENAI_API_KEY="dummy" \
  -e OPENAI_MODEL="YOUR_MODEL_ID" \
  -v $(pwd):/workspace/projects:z \
  codex:latest \
  codex
```

For interactive mode, both `-i` (stdin) and `-t` (tty) flags are required.

---

## Using Codex

The deployment runs `sleep infinity` so the pod stays alive for `oc exec` sessions. All examples below use `codex` as the deployment name.

### The codex-run Wrapper

The entrypoint generates a `codex-run` wrapper script at `~/.codex/codex-run` that includes all container-configured arguments (model, sandbox mode, provider config). Use it for all `oc exec` sessions:

```bash
oc exec deployment/codex -- bash -c '
  codex-run exec "Your prompt here"
'
```

You can also source the environment directly:

```bash
oc exec deployment/codex -- bash -c '
  source ~/.codex/env.sh
  codex ${CODEX_EXTRA_ARGS} exec "Your prompt here"
'
```

### Interactive Mode

For multi-turn conversations with a TTY:

```bash
oc exec -it deployment/codex -- bash -c '
  codex-run
'
```

Interactive mode requires the `-it` flags on `oc exec`. Without them, the TUI will not render and Codex will exit immediately.

### Headless Execution

The `codex exec` subcommand runs a prompt non-interactively and exits when complete. This is the recommended mode for scripted or automated usage:

```bash
# Single prompt
oc exec deployment/codex -- bash -c '
  codex-run exec "Explain the structure of this project"
'

# With a specific working directory
oc exec deployment/codex -- bash -c '
  cd /workspace/projects/my-repo && codex-run exec "Run the tests and fix any failures"
'
```

`codex exec` requires `CODEX_API_KEY` to be set. The entrypoint automatically propagates `OPENAI_API_KEY` to `CODEX_API_KEY` if only the former is set.

### Retrieving Files from the Container

When Codex generates files (reports, patches, code) that you want locally without pushing to Git, use `oc cp`:

```bash
# Copy a single file
oc cp <pod-name>:/workspace/projects/report.md ./report.md

# Copy a directory
oc cp <pod-name>:/workspace/projects/output/ ./output/

# Find the pod name
oc get pods -l app=codex -o name

# List files in the container
oc exec deployment/codex -- ls -la /workspace/projects/
```

### Rebuilding the Image

After modifying the Containerfile or entrypoint, rebuild locally and push:

```bash
podman build --platform linux/amd64 -t codex:latest -f Containerfile \
  --build-arg BASE_IMAGE=codex-base:latest .

REGISTRY=$(oc get route -n openshift-image-registry image-registry -o jsonpath='{.spec.host}')
podman tag codex:latest "${REGISTRY}/$(oc project -q)/codex:latest"
podman push "${REGISTRY}/$(oc project -q)/codex:latest" --tls-verify=false

oc import-image codex:latest --confirm
oc rollout restart deployment/codex
oc rollout status deployment/codex
```

---

## Configuration

### Session Persistence

Session history and configuration persist across pod restarts via the workspace PVC. The `CODEX_HOME` environment variable defaults to `/workspace/.codex`.

**Directory structure:**

```text
/workspace/                      <- PVC mount (persistent)
|-- .codex/                     <- Codex config (CODEX_HOME)
|   |-- config.toml             <- Model provider, MCP, preferences
|   |-- env.sh                  <- Generated env for oc exec sessions
|   |-- codex-run               <- Wrapper script
|   +-- instructions.md         <- Persisted project instructions
+-- projects/                   <- WORKDIR (where users run Codex)
```

The entrypoint creates a symlink `~/.codex` -> `/workspace/.codex` so that standard `~/.codex/` paths work as expected.

**What persists:**

| Data | Location | Persisted? |
|------|----------|------------|
| Configuration | `/workspace/.codex/config.toml` | Yes |
| Project instructions | `/workspace/.codex/instructions.md` | Yes |
| Working files | `/workspace/projects/` | Yes |
| Codex CLI args | `/workspace/.codex/env.sh` | Regenerated on each restart |
| Wrapper script | `/workspace/.codex/codex-run` | Regenerated on each restart |

**Disabling persistence:** Set `CODEX_HOME` to a non-PVC path:

```yaml
env:
  - name: CODEX_HOME
    value: "/tmp/.codex"
```

### config.toml Overrides

Codex CLI uses TOML configuration at `$CODEX_HOME/config.toml`. The deployment manifest includes a ConfigMap (`codex-config`) that is staged at `/etc/codex-config/config.toml`. On first start, the entrypoint copies it to `${CODEX_HOME}/config.toml` on the writable PVC. On subsequent restarts, the existing file is preserved so that runtime changes survive.

The entrypoint auto-generates model provider configuration from the `OPENAI_BASE_URL` and `OPENAI_MODEL` environment variables. Use the ConfigMap only for settings beyond what the entrypoint generates.

**Generated config.toml example** (produced by entrypoint.sh when `OPENAI_BASE_URL` and `OPENAI_MODEL` are set):

```toml
# Auto-configured by entrypoint.sh
model = "your-model-id"
model_provider = "vllm"

[model_providers.vllm]
name = "vLLM"
base_url = "http://vllm-svc.namespace.svc.cluster.local/v1"
env_key = "OPENAI_API_KEY"
wire_api = "responses"
```

**Manual config.toml example** (for advanced setups, place in the ConfigMap):

```toml
model = "granite-3.3-8b-instruct"
model_provider = "my-provider"

[model_providers.my-provider]
name = "Custom Provider"
base_url = "https://inference.example.com/v1"
env_key = "OPENAI_API_KEY"
wire_api = "responses"
```

To update the ConfigMap after deployment:

```bash
oc patch configmap codex-config -p '{
  "data": {
    "config.toml": "model = \"my-model\"\nmodel_provider = \"vllm\"\n\n[model_providers.vllm]\nname = \"vLLM\"\nbase_url = \"http://my-vllm-endpoint/v1\"\nenv_key = \"OPENAI_API_KEY\"\nwire_api = \"responses\"\n"
  }
}'
```

To force a config reset (pick up ConfigMap changes), delete the file from the PVC before restarting:

```bash
oc exec deployment/codex -- rm /workspace/.codex/config.toml
oc rollout restart deployment/codex
```

### MCP Servers

MCP (Model Context Protocol) servers extend Codex with additional tools. Codex uses TOML-native MCP configuration with `[mcp_servers.*]` blocks in `config.toml`. The entrypoint supports three injection methods:

#### Method 1: Mounted ConfigMap (recommended)

The deployment manifest mounts a ConfigMap at `/etc/codex-mcp/mcp-servers.toml`. The entrypoint appends its contents to `config.toml` at startup if the file contains `[mcp_servers.*]` blocks.

**TOML format:**

```toml
[mcp_servers.github]
url = "https://api.githubcopilot.com/mcp/"

[mcp_servers.local-tool]
command = "npx"
args = ["-y", "@some/mcp-server"]
```

Update the ConfigMap:

```bash
oc patch configmap codex-mcp-config -p '{
  "data": {
    "mcp-servers.toml": "[mcp_servers.my-api]\nurl = \"https://mcp.example.com/v1\"\n"
  }
}'
oc rollout restart deployment/codex
```

#### Method 2: TOML file path (MCP_CONFIG_TOML)

Point to a TOML file containing `[mcp_servers.*]` blocks. The entrypoint appends its contents to `config.toml`.

```yaml
env:
  - name: MCP_CONFIG_TOML
    value: "/etc/codex-mcp/mcp-servers.toml"
```

This is useful when you have a TOML file mounted from a Secret or other volume.

#### Method 3: Inline JSON (MCP_CONFIG_JSON)

For compatibility with the Claude Code `MCP_CONFIG_JSON` pattern, the entrypoint accepts inline JSON and converts it to TOML automatically using `jq`:

```yaml
env:
  - name: MCP_CONFIG_JSON
    value: '{"mcpServers":{"my-api":{"url":"https://mcp.example.com/v1"},"local-tool":{"command":"npx","args":["-y","@some/mcp-server"]}}}'
```

The JSON-to-TOML conversion supports `url`, `command`, and `args` fields. For MCP servers requiring environment variable references (e.g., `bearer_token_env_var`), use Method 1 or 2 with native TOML instead.

#### MCP server types

| Type | TOML field | Use case | Requirements |
|------|-----------|----------|--------------|
| Remote HTTP | `url` | Remote MCP servers | Network access to endpoint |
| Local process | `command` + `args` | Process-based MCP servers | Executable must exist in container |

The base image includes `git`, `curl-minimal`, `jq`, `tar`, `nodejs`, and `npm`. Command-based MCP servers using `npx` work out of the box. For servers requiring other runtimes, see [Extending the Container Image](#extending-the-container-image).

### Extending the Container Image

The base image includes `git`, `curl-minimal`, `jq`, `tar`, `nodejs`, `npm`, and `bash`. For real coding workflows, add language runtimes so the agent can run tests, lint, and build. Including the runtimes your project uses significantly improves agent output quality since the agent can run tests and catch its own mistakes.

```dockerfile
# In the "System dependencies" section of Containerfile.base
RUN microdnf install -y --nodocs \
        git \
        jq \
        tar \
        nodejs \
        npm \
        # Build tools
        make \
        gcc \
        diffutils \
        which \
        # Python
        python3.12 \
        python3.12-pip \
        # Go
        golang \
        # Java
        java-21-openjdk-devel \
        maven \
    && microdnf clean all \
    && rm -rf /var/cache/yum
```

The GitHub CLI (`gh`) is not available in UBI repos and must be installed separately:

```dockerfile
# Install GitHub CLI
ARG GH_VERSION=2.74.1
RUN curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz" \
    | tar -xz -C /usr/local/bin --strip-components=2 "gh_${GH_VERSION}_linux_amd64/bin/gh"
```

---

## Security Considerations

### Sandbox Mode

The deployment manifest sets `CODEX_SANDBOX=danger-full-access` by default, passing `--sandbox danger-full-access` to the Codex CLI. This disables Codex's built-in sandboxing (which uses bubblewrap on Linux).

**Why it is set this way:**

- The container itself is the isolation boundary, running as non-root (UID 1001) under OpenShift's restricted-v2 SCC
- The pod security context drops all capabilities and enforces `allowPrivilegeEscalation: false` with a `RuntimeDefault` seccomp profile
- Codex only has access to the isolated `/workspace` PVC, not host filesystems
- The bubblewrap sandbox inside a container-in-a-container creates unnecessary complexity and can conflict with OpenShift security policies

**Tradeoffs:** Running in an isolated container removes much of the reason you would normally keep Codex's built-in sandbox enabled. However, `danger-full-access` also means the agent has unrestricted access to external services it can reach via the network (e.g., Git remotes, MCP endpoints). Rely on repository safeguards (branch protection, required reviews, limited PAT scopes) to mitigate risks from automated operations.

To use a different sandbox mode:

```yaml
env:
  - name: CODEX_SANDBOX
    value: "read-only-fs"
```

### Credential Isolation

When credentials such as GitHub PATs or API keys are passed as environment variables, the agent can read them directly. This means the agent could inadvertently expose credentials in conversation output, commit messages, or through MCP server calls.

For many use cases, this risk is acceptable when combined with standard safeguards: limiting PAT scope to the minimum required permissions, protecting branches, and requiring PR reviews. For environments with strict security requirements, consider evaluating container isolation solutions that separate the agent from the credentials it depends on.

### Repository Safeguards

When an AI agent has push access to a Git repository, ensure the repository has protections against mistakes:

- **Branch protection rules**: Protect your main/default branch so direct pushes are blocked
- **Required pull request reviews**: Require at least one approval before merging
- **Limit PAT scope**: Grant only the minimum permissions needed
- **Status checks**: Require CI checks to pass before a PR can be merged

---

## Troubleshooting

### Responses API Compatibility

Codex CLI uses the OpenAI Responses API (`/v1/responses`), not the Chat Completions API (`/v1/chat/completions`). If you see errors like "404 Not Found" or "endpoint not found", verify your vLLM server supports the Responses API:

```bash
# Check if /v1/responses endpoint exists
curl -s -o /dev/null -w "%{http_code}" \
  -X POST "http://YOUR_VLLM_ENDPOINT/v1/responses" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "YOUR_MODEL_ID",
    "input": "What is 2+2?"
  }'
```

The Responses API requires vLLM v0.10.0 or later. Full tool calling support (including namespace tool types used by Codex) may require newer versions — check [vLLM releases](https://github.com/vllm-project/vllm/releases) for the latest compatibility.

### Network Connectivity

If the vLLM server is outside the cluster (e.g., on EC2 or another cloud), verify the pod can reach it:

```bash
# Find the cluster's egress IP
oc exec deployment/codex -- curl -s ifconfig.me

# Test connectivity to the vLLM server
oc exec deployment/codex -- curl -s -o /dev/null -w "%{http_code}" \
  http://YOUR_HOST:8000/v1/models
```

Common causes of connection failure include security group rules, network policies, and firewalls. If the server uses IP-based access rules, add the cluster egress IP to the allow list.

### Testing Endpoints Directly

Verify the vLLM server is reachable and serving the expected model:

```bash
# Health check
curl -s "http://YOUR_VLLM_ENDPOINT/health"

# Model listing
curl -s "http://YOUR_VLLM_ENDPOINT/v1/models"

# Non-streaming Responses API request
curl -s -X POST "http://YOUR_VLLM_ENDPOINT/v1/responses" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer dummy" \
  -d '{
    "model": "YOUR_MODEL_ID",
    "input": "What is 2+2? Reply with just the number."
  }'

# Streaming Responses API request
curl -s -X POST "http://YOUR_VLLM_ENDPOINT/v1/responses" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer dummy" \
  -d '{
    "model": "YOUR_MODEL_ID",
    "input": "Say hello",
    "stream": true
  }'
```

### Config Debugging

To inspect the generated `config.toml` and verify model provider and MCP configuration:

```bash
# View the generated config
oc exec deployment/codex -- cat /workspace/.codex/config.toml

# View entrypoint logs
oc logs deployment/codex | grep "\[entrypoint\]"

# Check env.sh (generated CLI args and environment)
oc exec deployment/codex -- cat ~/.codex/env.sh

# Verify Codex version
oc exec deployment/codex -- codex --version
```

### CODEX_API_KEY Missing

`codex exec` (headless mode) requires `CODEX_API_KEY` to be set. The entrypoint automatically propagates `OPENAI_API_KEY` to `CODEX_API_KEY` if only the former is set. If you see authentication errors in headless mode, verify both are set:

```bash
oc exec deployment/codex -- bash -c 'echo "OPENAI_API_KEY=${OPENAI_API_KEY:+set}" && echo "CODEX_API_KEY=${CODEX_API_KEY:+set}"'
```

### Pod Restart Loop

If the pod enters a CrashLoopBackOff, check the entrypoint logs:

```bash
oc logs deployment/codex --previous
```

Common causes:

- `CODEX_HOME` directory not writable (PVC not mounted or permissions issue)
- Invalid TOML in ConfigMap (syntax error in config.toml or mcp-servers.toml)
- Missing base image (flavor Containerfile references a base image that has not been built)

---

## Cleanup

```bash
oc delete deployment codex
oc delete buildconfig codex codex-base 2>/dev/null
oc delete imagestream codex codex-base 2>/dev/null
oc delete configmap codex-config codex-mcp-config
oc delete pvc codex-workspace
oc delete project my-codex-project
```

---

## Known Limitations

### Responses API Only

Codex CLI uses the OpenAI Responses API (`/v1/responses`) exclusively. It does not support the Chat Completions API (`/v1/chat/completions`) or the Anthropic Messages API (`/v1/messages`). Your vLLM server must be v0.10.0+ with Responses API support enabled. Full tool calling support may require newer versions.

### Open Source Model Quality

Codex CLI is designed for OpenAI's models. Open source models may produce lower quality results, particularly for complex multi-step tasks and tool use chains. Including language runtimes in the container helps because the agent can run tests and iterate on its own output.

### No Built-in Permission System

Unlike Claude Code, Codex CLI does not have a granular permission system for file operations or shell commands. The `--sandbox` flag controls the sandbox mode, but `danger-full-access` grants unrestricted access within the container. Rely on OpenShift's container isolation and repository safeguards for security.

### TOML Configuration Only

Codex CLI uses TOML for all configuration (`config.toml`). There is no JSON settings file equivalent. The entrypoint's `MCP_CONFIG_JSON` support converts JSON to TOML at startup for compatibility, but only a subset of fields (`url`, `command`, `args`) are converted. For full MCP server configuration (e.g., `bearer_token_env_var`, `env` blocks), use native TOML.

### OpenShell Sandbox Variant

The `Containerfile.openshell` builds a separate image for the OpenShell sandbox environment. This variant uses a different base image (`openshell-base`), installs Codex via npm (not the extracted Rust binary), and does not include the RHOAI entrypoint or session persistence. It is intended for ephemeral sandbox sessions, not persistent OpenShift deployments.
