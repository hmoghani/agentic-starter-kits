# OpenCode Deployment Files

This directory contains the Containerfiles, entrypoints, and deployment manifests for running OpenCode on OpenShift.

For the full deployment guide, see the [OpenCode on RHOAI README](../README.md).

## Files

| File | Description |
|------|-------------|
| `manifests/` | Base kustomize manifests (web mode + OAuth proxy) |
| `overlays/cli/` | CLI mode overlay (headless, no OAuth, `oc exec`) |
| `overlays/example/` | Template for custom environments |
| `overlays/mlflow-tracing/` | MLflow tracing overlay |
| `Containerfile.openshell` | OpenShell sandbox image variant |
| `Containerfile.mlflow` | MLflow tracing image variant |
| `Containerfile.a2a` | A2A / Kagenti agent discovery variant |
| `entrypoint-a2a.sh` | Entrypoint for A2A variant (runs opencode serve + opencode-a2a) |
| `kagenti-agent.yaml` | OpenShift Template for Kagenti-compatible deployment |
| `README-a2a.md` | A2A / Kagenti deployment guide |
| `docs/` | MLflow tracing schema, benchmarks, and screenshots |
