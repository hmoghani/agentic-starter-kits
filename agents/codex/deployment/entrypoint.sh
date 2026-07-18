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

sanitize_value() {
    # Strip characters that could cause shell or TOML injection
    printf '%s' "$1" | tr -d '"'"'"'`$\\' | tr -d '\n'
}

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

    if [[ -z "${OPENAI_MODEL:-}" ]]; then
        log_error "OPENAI_BASE_URL is set but OPENAI_MODEL is not. Set OPENAI_MODEL to the model name served by vLLM (check GET /v1/models)."
        return
    fi

    local model
    local base_url
    model=$(sanitize_value "${OPENAI_MODEL}")
    base_url=$(sanitize_value "${OPENAI_BASE_URL}")

    # Remove any existing model/provider lines so env vars always win
    sed -i '/^model\s*=/d; /^model_provider\s*=/d' "${config_file}" 2>/dev/null || true
    sed -i '/^\[model_providers\./,/^$/d' "${config_file}" 2>/dev/null || true

    cat >> "${config_file}" <<EOF
model = "${model}"

# Auto-configured by entrypoint.sh
model_provider = "vllm"

[model_providers.vllm]
name = "vLLM"
base_url = "${base_url}"
env_key = "OPENAI_API_KEY"
wire_api = "responses"
EOF

    log_info "Configured vLLM provider: ${base_url} (model: ${model})"
}

# =============================================================================
# MCP Server Configuration
# =============================================================================

setup_mcp() {
    local config_file="${CODEX_HOME}/config.toml"

    # Method 1: TOML file path (preferred — native Codex format)
    if [[ -n "${MCP_CONFIG_TOML:-}" ]]; then
        if [[ -f "${MCP_CONFIG_TOML}" ]]; then
            while IFS= read -r server_name; do
                if ! grep -q "^\[mcp_servers\.${server_name}\]" "${config_file}" 2>/dev/null; then
                    log_info "Adding MCP server from MCP_CONFIG_TOML: ${server_name}"
                    sed -n "/^\[mcp_servers\.${server_name}\]/,/^\[/{ /^\[mcp_servers\.${server_name}\]/p; /^\[mcp_servers\./!{ /^\[/!p; }; }" "${MCP_CONFIG_TOML}" >> "${config_file}"
                    echo "" >> "${config_file}"
                fi
            done < <(grep -oP '^\[mcp_servers\.\K[^\]]+' "${MCP_CONFIG_TOML}" 2>/dev/null)
        else
            log_error "MCP_CONFIG_TOML file not found: ${MCP_CONFIG_TOML}"
        fi
    fi

    # Method 2: Inline JSON (converted to TOML for compatibility with
    # the Claude Code MCP_CONFIG_JSON pattern)
    if [[ -n "${MCP_CONFIG_JSON:-}" ]]; then
        log_info "Converting MCP JSON config to TOML"
        local server_names
        server_names=$(echo "${MCP_CONFIG_JSON}" | jq -r '.mcpServers // {} | keys[]' 2>/dev/null) || {
            log_warn "Failed to parse MCP_CONFIG_JSON. Check format."
            return
        }

        for server_name in ${server_names}; do
            if grep -q "^\[mcp_servers\.${server_name}\]" "${config_file}" 2>/dev/null; then
                log_info "MCP server '${server_name}' already in config.toml, skipping"
                continue
            fi
            local server_toml
            server_toml=$(echo "${MCP_CONFIG_JSON}" | jq -r --arg name "$server_name" '
                .mcpServers[$name] |
                "\n[mcp_servers.\($name)]",
                (if .url then "url = \"\(.url)\"" else empty end),
                (if .command then "command = \"\(.command)\"" else empty end),
                (if .args then "args = [\(.args | map("\"" + . + "\"") | join(", "))]" else empty end),
                ""
            ' 2>/dev/null)
            if [[ -n "${server_toml}" ]]; then
                echo "${server_toml}" >> "${config_file}"
                log_info "Added MCP server from MCP_CONFIG_JSON: ${server_name}"
            fi
        done
    fi

    # Method 3: Mounted ConfigMap (TOML file at well-known path)
    local mounted_mcp="/etc/codex-mcp/mcp-servers.toml"
    if [[ -f "${mounted_mcp}" ]]; then
        # Only append servers that aren't already in config.toml
        while IFS= read -r server_name; do
            if ! grep -q "^\[mcp_servers\.${server_name}\]" "${config_file}" 2>/dev/null; then
                log_info "Adding MCP server from ConfigMap: ${server_name}"
                sed -n "/^\[mcp_servers\.${server_name}\]/,/^\[/{ /^\[mcp_servers\.${server_name}\]/p; /^\[mcp_servers\./!{ /^\[/!p; }; }" "${mounted_mcp}" >> "${config_file}"
                echo "" >> "${config_file}"
            fi
        done < <(grep -oP '^\[mcp_servers\.\K[^\]]+' "${mounted_mcp}" 2>/dev/null)
    fi
}

# =============================================================================
# Build CLI Arguments
# =============================================================================

build_codex_args() {
    local args=()
    local exec_args=()

    # Model selection (global — works with all subcommands)
    if [[ -n "${OPENAI_MODEL:-}" ]]; then
        args+=("--model" "${OPENAI_MODEL}")
    fi

    # Sandbox mode — container itself is the isolation boundary (global)
    local sandbox="${CODEX_SANDBOX:-danger-full-access}"
    args+=("--sandbox" "${sandbox}")

    # Skip git repo check — only valid for `codex exec`, not interactive mode
    exec_args+=("--skip-git-repo-check")

    export CODEX_EXTRA_ARGS="${args[*]:-}"
    export CODEX_EXEC_ARGS="${exec_args[*]:-}"

    # Persist args for oc exec sessions
    local codex_dir="${HOME}/.codex"
    mkdir -p "${codex_dir}" 2>/dev/null || true

    {
        echo '# Generated by entrypoint.sh — source this in oc exec sessions'
        echo '# API keys are available via container env vars, not persisted to PVC'
        printf "export CODEX_HOME='%s'\n" "${CODEX_HOME}"
        printf "export CODEX_EXTRA_ARGS='%s'\n" "${args[*]:-}"
        printf "export CODEX_EXEC_ARGS='%s'\n" "${exec_args[*]:-}"
        [ -n "${OPENAI_BASE_URL:-}" ] && printf "export OPENAI_BASE_URL='%s'\n" "$(sanitize_value "${OPENAI_BASE_URL}")"
        [ -n "${OPENAI_MODEL:-}" ] && printf "export OPENAI_MODEL='%s'\n" "$(sanitize_value "${OPENAI_MODEL}")"
    } > "${codex_dir}/env.sh"

    # Create wrapper script for oc exec convenience
    cat > "${codex_dir}/codex-run" <<'WRAPPER'
#!/bin/bash
# Wrapper for running Codex with pre-configured args.
# Usage: codex-run [codex arguments...]
#   codex-run exec "fix the bug in main.py"
#   codex-run    (interactive mode)
source "${HOME}/.codex/env.sh" 2>/dev/null || true
# Add exec-only args when the subcommand is "exec"
if [[ "${1:-}" == "exec" ]]; then
    exec codex ${CODEX_EXTRA_ARGS} "$1" ${CODEX_EXEC_ARGS} "${@:2}"
else
    exec codex ${CODEX_EXTRA_ARGS} "$@"
fi
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
        if [[ "${1:-}" == "exec" ]]; then
            log_info "Running: codex ${CODEX_EXTRA_ARGS} exec ${CODEX_EXEC_ARGS} ${*:2}"
            exec codex ${CODEX_EXTRA_ARGS} "$1" ${CODEX_EXEC_ARGS} "${@:2}"
        else
            log_info "Running: codex ${CODEX_EXTRA_ARGS} $*"
            exec codex ${CODEX_EXTRA_ARGS} "$@"
        fi
    fi

    log_info "Running: $*"
    exec "$@"
}

main "$@"
