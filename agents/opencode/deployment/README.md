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

Builds from UBI 10 minimal (`registry.access.redhat.com/ubi10/ubi-minimal:10.1`) and installs:

- Node.js and npm (from UBI repos)
- OpenCode via npm (version pinned, MIT)
- `sandbox` user with GID=0 (required by OpenShell and OpenShift arbitrary-UID)
- `iproute` and `tar` packages (required by OpenShell's supervisor and network isolation)
- `/workspace` directory with group-writable permissions

## Notes

- OpenShell's supervisor takes over as PID 1 and does not automatically run OpenCode. Start it manually inside the sandbox.
- Build with `--platform linux/amd64` when targeting x86_64 clusters from Apple Silicon machines.
- Tested on OpenShell v0.0.58, OpenShift 4.21 (June 2026). OpenCode version 1.17.1.
