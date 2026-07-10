#!/usr/bin/env bash
# =============================================================================
# Codex CLI Container Entrypoint
# =============================================================================
#
# Sets up the runtime environment for Codex CLI inside a container.
# Handles authentication, model provider configuration, MCP injection,
# and workspace setup before executing the provided command.
#
# Supported environment variables:
#
#   Authentication:
#     OPENAI_API_KEY          API key for OpenAI or compatible endpoint
#     CODEX_API_KEY           API key for codex exec (overrides OPENAI_API_KEY)
#
#   Model / Provider:
#     OPENAI_BASE_URL         Custom API endpoint (vLLM, OpenRouter, etc.)
#     OPENAI_MODEL            Model name (e.g., granite-3.3-8b-instruct)
#
#   MCP Configuration:
#     MCP_CONFIG_TOML         Path to a TOML file with [mcp_servers.*] tables
#     MCP_CONFIG_JSON         Inline JSON with MCP server definitions
#                             (converted to TOML automatically)
#
#   Git Credentials:
#     GITHUB_PAT              GitHub Personal Access Token
#     GIT_USER_NAME           Git commit author (default: codex-agent)
#     GIT_USER_EMAIL          Git commit email (default: codex-agent@noreply.github.com)
#
#   Session Persistence:
#     CODEX_HOME              Codex config directory (default: /workspace/.codex)
#
#   Sandbox:
#     CODEX_SANDBOX           Sandbox mode (default: danger-full-access)
#
# =============================================================================

set -euo pipefail

# Temp files to clean up on exit
TEMP_FILES=()

cleanup_temp_files() {
    for f in "${TEMP_FILES[@]}"; do
        rm -f "$f" 2>/dev/null || true
    done
}

trap cleanup_temp_files EXIT

# =============================================================================
# Helper Functions
# =============================================================================

log_info()  { echo "[entrypoint] $*" >&2; }
log_warn()  { echo "[entrypoint] WARNING: $*" >&2; }
log_error() { echo "[entrypoint] ERROR: $*" >&2; }

# =============================================================================
# Environment Validation
# =============================================================================

validate_environment() {
    local has_auth=false

    if [[ -n "${OPENAI_API_KEY:-}" ]]; then
        log_info "OPENAI_API_KEY is set"
        has_auth=true
    fi

    if [[ -n "${CODEX_API_KEY:-}" ]]; then
        log_info "CODEX_API_KEY is set"
        has_auth=true
    fi

    if [[ "${has_auth}" != "true" ]]; then
        log_warn "No API key found. Set OPENAI_API_KEY or CODEX_API_KEY."
        log_warn "Codex may not be able to connect to an inference endpoint."
    fi

    if [[ -n "${OPENAI_BASE_URL:-}" ]]; then
        log_info "Custom endpoint: ${OPENAI_BASE_URL}"
    fi

    if [[ -n "${OPENAI_MODEL:-}" ]]; then
        log_info "Model: ${OPENAI_MODEL}"
    fi
}

# =============================================================================
# Git Credentials
# =============================================================================

setup_git_credentials() {
    if [[ -z "${GITHUB_PAT:-}" ]]; then
        return
    fi

    log_info "Configuring git credentials"
    git config --global credential.helper store
    echo "https://x-access-token:${GITHUB_PAT}@github.com" > "${HOME}/.git-credentials"
    chmod 600 "${HOME}/.git-credentials"

    git config --global user.name "${GIT_USER_NAME:-codex-agent}"
    git config --global user.email "${GIT_USER_EMAIL:-codex-agent@noreply.github.com}"
}

# =============================================================================
# Codex Home / Config Directory
# =============================================================================

setup_codex_home() {
    CODEX_HOME="${CODEX_HOME:-/workspace/.codex}"
    export CODEX_HOME

    mkdir -p "${CODEX_HOME}" 2>/dev/null || true
    chmod g+w "${CODEX_HOME}" 2>/dev/null || true

    mkdir -p /workspace/projects 2>/dev/null || true

    # Symlink ~/.codex -> CODEX_HOME for PVC-backed persistence
    local target="${HOME}/.codex"
    if [[ -L "${target}" ]]; then
        local current
        current=$(readlink -f "${target}")
        if [[ "${current}" != "$(readlink -f "${CODEX_HOME}")" ]]; then
            rm -f "${target}"
            ln -s "${CODEX_HOME}" "${target}"
            log_info "Updated symlink: ~/.codex -> ${CODEX_HOME}"
        fi
    elif [[ -d "${target}" ]]; then
        log_warn "~/.codex is a directory, replacing with symlink"
        rm -rf "${target}"
        ln -s "${CODEX_HOME}" "${target}"
    else
        ln -s "${CODEX_HOME}" "${target}"
        log_info "Created symlink: ~/.codex -> ${CODEX_HOME}"
    fi

    # Copy staged config from read-only ConfigMap mount (if it exists
    # and destination is empty or missing)
    local staged="/etc/codex-config/config.toml"
    local config_file="${CODEX_HOME}/config.toml"
    if [[ -f "${staged}" && ! -s "${config_file}" ]]; then
        cp "${staged}" "${config_file}"
        chmod 660 "${config_file}"
        log_info "Copied config from ${staged}"
    fi

    # Ensure config.toml exists (even if empty)
    touch "${config_file}"
}

# =============================================================================
# Model Provider Configuration
# =============================================================================

setup_model_provider() {
    local config_file="${CODEX_HOME}/config.toml"

    # Skip if no custom endpoint is specified
    if [[ -z "${OPENAI_BASE_URL:-}" ]]; then
        # Just set the model if specified
        if [[ -n "${OPENAI_MODEL:-}" ]]; then
            if ! grep -q '^model\s*=' "${config_file}" 2>/dev/null; then
                echo "model = \"${OPENAI_MODEL}\"" >> "${config_file}"
            fi
        fi
        return
    fi

    # Skip if provider config already exists (e.g., from staged ConfigMap)
    if grep -q 'model_provider' "${config_file}" 2>/dev/null; then
        log_info "Provider config already exists in config.toml, skipping"
        return
    fi

    local model="${OPENAI_MODEL:-default}"

    cat >> "${config_file}" <<EOF

# Auto-configured by entrypoint.sh
model = "${model}"
model_provider = "vllm"

[model_providers.vllm]
name = "vLLM"
base_url = "${OPENAI_BASE_URL}"
env_key = "OPENAI_API_KEY"
wire_api = "responses"
EOF

    log_info "Configured vLLM provider: ${OPENAI_BASE_URL} (model: ${model})"
}

# =============================================================================
# MCP Server Configuration
# =============================================================================

setup_mcp() {
    local config_file="${CODEX_HOME}/config.toml"

    # Method 1: TOML file path (preferred — native Codex format)
    if [[ -n "${MCP_CONFIG_TOML:-}" ]]; then
        if [[ -f "${MCP_CONFIG_TOML}" ]]; then
            log_info "Appending MCP config from: ${MCP_CONFIG_TOML}"
            echo "" >> "${config_file}"
            cat "${MCP_CONFIG_TOML}" >> "${config_file}"
        else
            log_error "MCP_CONFIG_TOML file not found: ${MCP_CONFIG_TOML}"
        fi
    fi

    # Method 2: Inline JSON (converted to TOML for compatibility with
    # the Claude Code MCP_CONFIG_JSON pattern)
    if [[ -n "${MCP_CONFIG_JSON:-}" ]]; then
        log_info "Converting MCP JSON config to TOML"
        local toml_block
        toml_block=$(echo "${MCP_CONFIG_JSON}" | jq -r '
            .mcpServers // {} | to_entries[] |
            "\n[mcp_servers.\(.key)]",
            (if .value.url then "url = \"\(.value.url)\"" else empty end),
            (if .value.command then "command = \"\(.value.command)\"" else empty end),
            (if .value.args then "args = [\(.value.args | map("\"" + . + "\"") | join(", "))]" else empty end),
            ""
        ' 2>/dev/null) || {
            log_warn "Failed to convert MCP JSON to TOML. Check MCP_CONFIG_JSON format."
            return
        }

        if [[ -n "${toml_block}" ]]; then
            echo "${toml_block}" >> "${config_file}"
            log_info "Appended MCP config from MCP_CONFIG_JSON"
        fi
    fi

    # Method 3: Mounted ConfigMap (TOML file at well-known path)
    local mounted_mcp="/etc/codex-mcp/mcp-servers.toml"
    if [[ -f "${mounted_mcp}" ]]; then
        # Only append if the file has actual content (not just comments)
        if grep -qE '^\[mcp_servers\.' "${mounted_mcp}" 2>/dev/null; then
            log_info "Loading MCP config from: ${mounted_mcp}"
            echo "" >> "${config_file}"
            cat "${mounted_mcp}" >> "${config_file}"
        fi
    fi
}

# =============================================================================
# Build CLI Arguments
# =============================================================================

build_codex_args() {
    local args=()

    # Model selection
    if [[ -n "${OPENAI_MODEL:-}" ]]; then
        args+=("--model" "${OPENAI_MODEL}")
    fi

    # Sandbox mode — container itself is the isolation boundary
    local sandbox="${CODEX_SANDBOX:-danger-full-access}"
    args+=("--sandbox" "${sandbox}")

    # Skip git repo check — workspace may not be a git repo initially
    args+=("--skip-git-repo-check")

    export CODEX_EXTRA_ARGS="${args[*]:-}"

    # Persist args for oc exec sessions
    local codex_dir="${HOME}/.codex"
    mkdir -p "${codex_dir}" 2>/dev/null || true

    cat > "${codex_dir}/env.sh" <<EOF
# Generated by entrypoint.sh — source this in oc exec sessions
export CODEX_HOME="${CODEX_HOME}"
export CODEX_EXTRA_ARGS="${args[*]:-}"
$([ -n "${OPENAI_API_KEY:-}" ] && echo "export OPENAI_API_KEY=\"${OPENAI_API_KEY}\"")
$([ -n "${CODEX_API_KEY:-}" ] && echo "export CODEX_API_KEY=\"${CODEX_API_KEY}\"")
$([ -n "${OPENAI_BASE_URL:-}" ] && echo "export OPENAI_BASE_URL=\"${OPENAI_BASE_URL}\"")
$([ -n "${OPENAI_MODEL:-}" ] && echo "export OPENAI_MODEL=\"${OPENAI_MODEL}\"")
EOF

    # Create wrapper script for oc exec convenience
    cat > "${codex_dir}/codex-run" <<'WRAPPER'
#!/bin/bash
# Wrapper for running Codex with pre-configured args.
# Usage: codex-run [codex arguments...]
#   codex-run exec "fix the bug in main.py"
#   codex-run    (interactive mode)
source "${HOME}/.codex/env.sh" 2>/dev/null || true
exec codex ${CODEX_EXTRA_ARGS} "$@"
WRAPPER
    chmod +x "${codex_dir}/codex-run"

    # Add to PATH via .bashrc for oc exec sessions
    if ! grep -q 'codex/env.sh' "${HOME}/.bashrc" 2>/dev/null; then
        cat >> "${HOME}/.bashrc" <<'BASHRC'
# Codex agent configuration
source "${HOME}/.codex/env.sh" 2>/dev/null || true
export PATH="${HOME}/.codex:${PATH}"
BASHRC
    fi

    log_info "CLI args: ${args[*]:-<none>}"
}

# =============================================================================
# Main
# =============================================================================

main() {
    log_info "Starting Codex container"
    log_info "Codex version: $(codex --version 2>/dev/null || echo 'unknown')"

    validate_environment
    setup_git_credentials
    setup_codex_home
    setup_model_provider
    setup_mcp
    build_codex_args

    # Propagate OPENAI_API_KEY to CODEX_API_KEY for codex exec
    if [[ -n "${OPENAI_API_KEY:-}" && -z "${CODEX_API_KEY:-}" ]]; then
        export CODEX_API_KEY="${OPENAI_API_KEY}"
    fi

    if [[ $# -eq 0 ]]; then
        log_info "No command provided. Running: codex --help"
        exec codex --help
    fi

    if [[ "$1" == "codex" ]]; then
        shift
        log_info "Running: codex ${CODEX_EXTRA_ARGS} $*"
        exec codex ${CODEX_EXTRA_ARGS} "$@"
    fi

    log_info "Running: $*"
    exec "$@"
}

main "$@"
