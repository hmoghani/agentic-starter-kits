# Codex Deployment Files

> **Disclaimer:** The Codex CLI binary installed in this image is a pre-built
> artifact published by [OpenAI](https://github.com/openai/codex) via npm
> (`@openai/codex`), **not by Red Hat**. It has not been built, scanned, or
> validated according to Red Hat standards. Use it at your own discretion.
> To build from source instead, see `Containerfile.base`.

This directory contains Containerfiles, entrypoint, and deployment manifests for running [OpenAI Codex CLI](https://github.com/openai/codex) on OpenShift.

For the full deployment guide, see the [Codex on OpenShift README](../README.md).

## Files

| File | Description |
|------|-------------|
| `Containerfile` | RHOAI image (UBI 9 minimal, Codex via npm, entrypoint, MCP, session persistence) |
| `Containerfile.base` | Alternative: compiles Codex from source (Rust cross-compilation) |
| `Containerfile.openshell` | OpenShell sandbox variant (RHEL 10, extends `quay.io/aipcc/agentic-ci/openshell`) |
| `entrypoint.sh` | Container entrypoint (auth, model provider, MCP, git credential setup) |
| `deployment.yaml` | OpenShift manifests (ImageStream, BuildConfig, ConfigMaps, PVC, Deployment) |

## Quick Reference

| Setting | Environment Variable | Default |
|---------|---------------------|---------|
| API key | `OPENAI_API_KEY` | (required) |
| Inference endpoint | `OPENAI_BASE_URL` | (required for vLLM) |
| Model | `OPENAI_MODEL` | (required for vLLM) |
| Config directory | `CODEX_HOME` | `/workspace/.codex` |
| Sandbox mode | `CODEX_SANDBOX` | `danger-full-access` |
| MCP config (TOML file) | `MCP_CONFIG_TOML` | (none) |
| MCP config (inline JSON) | `MCP_CONFIG_JSON` | (none) |
| GitHub PAT | `GITHUB_PAT` | (none) |

## Build

```bash
podman build --platform linux/amd64 -t codex:latest -f Containerfile .
```

## Comparison: RHOAI vs Source vs OpenShell

| | RHOAI (Containerfile) | Source (Containerfile.base) | OpenShell (Containerfile.openshell) |
|--|----------------------|---------------------------|-------------------------------------|
| **Base** | UBI 9 minimal | UBI 9 minimal (multi-stage) | RHEL 10 (OpenShell) |
| **Codex install** | npm (pre-built binary) | Compiled from source (Rust) | npm install in image |
| **Build time** | ~1 min | ~12 min (32GB RAM required) | ~1 min |
| **Runtime** | Standalone pod, `oc exec` | Standalone pod, `oc exec` | OpenShell gateway sandbox |
| **Auth** | Env vars, entrypoint setup | Env vars, entrypoint setup | Manual inside sandbox |
| **Use case** | Production RHOAI deployment | Supply chain auditable build | Sandboxed experimentation |
