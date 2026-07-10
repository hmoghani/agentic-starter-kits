# Codex Deployment Files

This directory contains Containerfiles, entrypoint, and deployment manifests for running [OpenAI Codex CLI](https://github.com/openai/codex) on OpenShift.

For the full deployment guide, see the [Codex on OpenShift README](../README.md).

## Files

| File | Description |
|------|-------------|
| `Containerfile.base` | Base image build (multi-stage: compiles Codex from source, UBI 9 minimal runtime) |
| `Containerfile` | RHOAI flavor (extends base with entrypoint, MCP injection, session persistence) |
| `Containerfile.openshell` | OpenShell sandbox variant (extends openshell-base) |
| `entrypoint.sh` | Container entrypoint (auth, model provider, MCP, git credential setup) |
| `deployment.yaml` | OpenShift manifests (ImageStream, BuildConfig, ConfigMaps, PVC, Deployment) |

## Quick Reference

| Setting | Environment Variable | Default |
|---------|---------------------|---------|
| API key | `OPENAI_API_KEY` | (required) |
| Inference endpoint | `OPENAI_BASE_URL` | (required for vLLM) |
| Model | `OPENAI_MODEL` | (provider default) |
| Config directory | `CODEX_HOME` | `/workspace/.codex` |
| Sandbox mode | `CODEX_SANDBOX` | `danger-full-access` |
| MCP config (TOML file) | `MCP_CONFIG_TOML` | (none) |
| MCP config (inline JSON) | `MCP_CONFIG_JSON` | (none) |
| GitHub PAT | `GITHUB_PAT` | (none) |

## Build Order

```bash
# 1. Build base image
podman build --platform linux/amd64 -t codex-base:latest -f Containerfile.base .

# 2. Build RHOAI flavor
podman build --platform linux/amd64 -t codex:latest -f Containerfile \
  --build-arg BASE_IMAGE=codex-base:latest .
```

## Comparison: RHOAI vs OpenShell

| | RHOAI (Containerfile) | OpenShell (Containerfile.openshell) |
|--|----------------------|-------------------------------------|
| **Base** | UBI 9 minimal (multi-stage) | openshell-base |
| **Codex install** | Compiled from source (Rust) | npm install in image |
| **Runtime** | Standalone pod, `oc exec` | OpenShell gateway sandbox |
| **Auth** | Env vars, entrypoint setup | Manual inside sandbox |
| **Use case** | Production RHOAI deployment | Sandboxed experimentation |
