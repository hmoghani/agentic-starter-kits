# OpenCode — OpenShell Sandbox Deployment

This directory contains an OpenShell-compatible Containerfile for running [OpenCode](https://github.com/sst/opencode) inside an OpenShell sandbox.

## Prerequisites

- [Podman](https://podman.io/) or Docker installed
- [OpenShell CLI](https://github.com/NVIDIA/OpenShell-Community) installed
- An OpenShell gateway running

## Build and Run

```bash
podman build --platform linux/amd64 -t opencode-sandbox:latest -f Containerfile.openshell .
openshell sandbox create --from opencode-sandbox:latest
```

## What `Containerfile.openshell` does

Wraps the community OpenCode image (`ghcr.io/pilinux/opencode:latest`) and adds:

- `sandbox` user and group (required by OpenShell)
- `iproute2` and `tar` packages (required by OpenShell's supervisor and network isolation)

## Notes

- OpenShell's supervisor takes over as PID 1 and does not automatically run OpenCode. Start it manually inside the sandbox.
- Build with `--platform linux/amd64` when targeting x86_64 clusters from Apple Silicon machines.
- Tested on OpenShell v0.0.58, OpenShift 4.21 (June 2026). OpenCode version 1.16.2.
