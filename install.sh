#!/usr/bin/env bash
# install.sh — cac-docker-claude installer
set -euo pipefail

REPO_BASE_URL="${CAC_REPO_BASE_URL:-https://raw.githubusercontent.com/ZMK112/claude-docker/main}"
BIN_DIR="${HOME}/bin"
DIST_DIR="${HOME}/.cac-dist"
CAC_HOME="${HOME}/.cac"
SOURCE_DIR="${CAC_HOME}/source"

INSTALL_MODE="auto"
AUTO_YES=false
SKIP_IDENTITY=false
FORCE_IDENTITY=false
NO_BUILD=false

green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red() { printf '\033[31m%s\033[0m\n' "$*" >&2; }
cyan() { printf '\033[36m%s\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || pwd)"

wait_with_progress() {
    local label="$1" pid="$2" interval="${CAC_INSTALL_PROGRESS_INTERVAL:-5}" elapsed=0 rc=0
    [[ "$interval" =~ ^[0-9]+$ ]] || interval=5
    [[ "$interval" -gt 0 ]] || interval=5

    while kill -0 "$pid" 2>/dev/null; do
        sleep 1
        if ! kill -0 "$pid" 2>/dev/null; then
            break
        fi
        elapsed=$((elapsed + 1))
        if (( elapsed % interval == 0 )); then
            cyan "  ${label} still running (${elapsed}s)"
        fi
    done

    if wait "$pid"; then
        green "✓ ${label}"
        return 0
    fi
    rc=$?
    red "✗ ${label}"
    return "$rc"
}

usage() {
    cat <<'EOF'
Usage: bash install.sh [options]

Install cac-docker-claude either from the current local source tree or from
GitHub raw files.

Options:
  --local           Force install from the current local repo
  --remote          Force install from GitHub raw files
  --yes             Non-interactive install; accept defaults
  --skip-identity   Accepted for compatibility; ignored
  --force-identity  Accepted for compatibility; ignored
  --no-build        Skip running build.sh in local mode
  -h, --help        Show this help

Local install layout:
  ~/.cac-dist/cac
  ~/.cac/source
  ~/.cac/docker -> ~/.cac/source/docker
  ~/bin/cac -> ~/.cac-dist/cac
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --local) INSTALL_MODE="local"; shift ;;
            --remote) INSTALL_MODE="remote"; shift ;;
            --yes) AUTO_YES=true; shift ;;
            --skip-identity) SKIP_IDENTITY=true; shift ;;
            --force-identity) FORCE_IDENTITY=true; shift ;;
            --no-build) NO_BUILD=true; shift ;;
            -h|--help) usage; exit 0 ;;
            *)
                red "error: unknown argument: $1"
                usage
                exit 1
                ;;
        esac
    done
}

is_local_repo() {
    [[ -f "${SCRIPT_DIR}/build.sh" ]] &&
    [[ -d "${SCRIPT_DIR}/src" ]] &&
    [[ -f "${SCRIPT_DIR}/src/cmd_docker.sh" ]] &&
    [[ -d "${SCRIPT_DIR}/docker" ]]
}

resolve_install_mode() {
    if [[ "$INSTALL_MODE" == "auto" ]]; then
        if is_local_repo; then
            INSTALL_MODE="local"
        else
            INSTALL_MODE="remote"
        fi
    fi

    if [[ "$INSTALL_MODE" == "local" ]] && ! is_local_repo; then
        red "error: --local was requested but this script is not running inside a valid cac repo"
        exit 1
    fi
}

check_existing_install() {
    if command -v cac >/dev/null 2>&1; then
        local local_cac
        local_cac="$(command -v cac)"
        if [[ "$local_cac" == *"node_modules"* ]] || [[ -f "$(dirname "$local_cac" 2>/dev/null)/package.json" ]]; then
            red "⚠ detected an npm-installed cac package; do not mix npm and bash installs"
            printf '  uninstall the npm package first, then retry this installer\n'
            exit 1
        fi
    fi
}

run_local_build() {
    [[ "$INSTALL_MODE" == "local" ]] || return 0
    [[ "$NO_BUILD" == "true" ]] && return 0

    echo "Building local cac ..."
    (
        cd "$SCRIPT_DIR"
        bash build.sh >/dev/null
    ) &
    wait_with_progress "Building local cac" "$!"
}

download_remote_asset() {
    local name="$1" output="${2:-${DIST_DIR}/${name}}"
    if ! curl -fsSL "${REPO_BASE_URL}/${name}" -o "$output"; then
        red "error: failed to download ${name} from ${REPO_BASE_URL}/${name}"
        red "hint: if you extracted a release/source archive, run this installer from that directory so it uses local mode instead of remote mode"
        exit 1
    fi
}

install_assets() {
    local tmp_cac="${DIST_DIR}/.cac.$$.new"
    mkdir -p "$DIST_DIR"

    if [[ "$INSTALL_MODE" == "local" ]]; then
        echo "Installing from local repo ..."
        cp "${SCRIPT_DIR}/cac" "$tmp_cac" &
        wait_with_progress "Installing from local repo" "$!"
    else
        echo "Downloading cac assets ..."
        download_remote_asset "cac" "$tmp_cac" &
        wait_with_progress "Downloading cac assets" "$!"
    fi

    chmod +x "$tmp_cac"
    mv -f "$tmp_cac" "${DIST_DIR}/cac"
}

link_entrypoint() {
    mkdir -p "$BIN_DIR"
    ln -sfn "${DIST_DIR}/cac" "${BIN_DIR}/cac"
}

safe_rm_path() {
    local path="$1"
    [[ -e "$path" || -L "$path" ]] || return 0
    if [[ ! -L "$path" ]]; then
        chmod -R u+rwX "$path" 2>/dev/null || true
    fi
    rm -rf "$path" 2>/dev/null
}

normalize_copy_permissions() {
    local path="$1"
    [[ -e "$path" || -L "$path" ]] || return 0
    [[ -L "$path" ]] && return 0
    chmod -R u+rwX "$path" 2>/dev/null || true
}

cleanup_state_dir() {
    local path="$1"
    [[ -n "$path" ]] || return 0
    if ! safe_rm_path "$path"; then
        yellow "Preserved Docker state backup: ${path}"
        yellow "Cleanup skipped because some migrated files are not removable by the current user."
    fi
}

copy_if_present() {
    local src="$1" dst="$2"
    local parent base tmp
    [[ -e "$src" || -L "$src" ]] || return 0
    parent="$(dirname "$dst")"
    base="$(basename "$dst")"
    tmp="${parent}/.${base}.$$.new"
    mkdir -p "$parent"
    safe_rm_path "$tmp" || return 1
    if ! cp -R "$src" "$tmp"; then
        safe_rm_path "$tmp" || true
        return 1
    fi
    normalize_copy_permissions "$tmp"
    safe_rm_path "$dst" || return 1
    mv "$tmp" "$dst"
}

copy_if_present_with_progress() {
    local src="$1" dst="$2" label="$3"
    local parent base tmp
    [[ -e "$src" || -L "$src" ]] || return 0
    parent="$(dirname "$dst")"
    base="$(basename "$dst")"
    tmp="${parent}/.${base}.$$.new"
    mkdir -p "$parent"
    safe_rm_path "$tmp" || return 1
    echo "$label ..."
    cp -R "$src" "$tmp" &
    if ! wait_with_progress "$label" "$!"; then
        safe_rm_path "$tmp" || true
        return 1
    fi
    normalize_copy_permissions "$tmp"
    safe_rm_path "$dst" || return 1
    mv "$tmp" "$dst"
}

docker_state_exists() {
    local dir="$1"
    [[ -e "${dir}/.env" || -L "${dir}/.env" ]] && return 0
    [[ -e "${dir}/data" || -L "${dir}/data" ]] && return 0
    [[ -e "${dir}/mounts.json" || -L "${dir}/mounts.json" ]] && return 0
    [[ -e "${dir}/docker-compose.mounts.yml" || -L "${dir}/docker-compose.mounts.yml" ]] && return 0
    return 1
}

source_tree_available() {
    [[ "$INSTALL_MODE" == "local" ]] || return 1
    [[ -f "${SCRIPT_DIR}/build.sh" ]] || return 1
    [[ -d "${SCRIPT_DIR}/src" ]] || return 1
    [[ -d "${SCRIPT_DIR}/docker" ]] || return 1
    [[ -f "${SCRIPT_DIR}/docker/docker-compose.yml" ]] || return 1
}

install_source_tree() {
    source_tree_available || return 0

    local src_real dst_real=""
    src_real="$(cd "$SCRIPT_DIR" && pwd -P)"
    if [[ -d "$SOURCE_DIR" ]]; then
        dst_real="$(cd "$SOURCE_DIR" && pwd -P)"
    fi
    if [[ "$src_real" == "$dst_real" ]]; then
        cyan "Using existing source tree at ${SOURCE_DIR}"
        return 0
    fi

    mkdir -p "$CAC_HOME"
    echo "Installing full source tree ..."
    rsync -a --delete \
        --exclude '.git/' \
        --exclude '.cac/' \
        --exclude '.cac-dist/' \
        --exclude 'dist/' \
        --exclude 'release/' \
        --exclude 'docker/.env' \
        --exclude 'docker/mounts.json' \
        --exclude 'docker/docker-compose.mounts.yml' \
        --exclude 'docker/data/' \
        --exclude '__pycache__/' \
        --exclude '*.pyc' \
        --exclude '*.pyo' \
        --exclude '.DS_Store' \
        "${SCRIPT_DIR}/" "${SOURCE_DIR}/" &
    wait_with_progress "Installing full source tree" "$!"
}

sync_docker_resources() {
    local source_dir="$1" target_dir="$2" state_dir="" old_link_backup="" old_link_target=""
    state_dir="$(mktemp -d "${CAC_HOME}/.docker-state.XXXXXX")"

    if [[ -e "$target_dir" || -L "$target_dir" ]]; then
        if [[ -L "$target_dir" ]]; then
            old_link_target="$(readlink "$target_dir" || true)"
            if [[ ! -e "$target_dir" ]]; then
                yellow "Existing ${target_dir} symlink target is missing; no old Docker state can be migrated from it."
            fi
        fi
        copy_if_present "${target_dir}/.env" "${state_dir}/.env"
        copy_if_present_with_progress "${target_dir}/data" "${state_dir}/data" "Backing up Docker data"
        copy_if_present "${target_dir}/mounts.json" "${state_dir}/mounts.json"
        copy_if_present "${target_dir}/docker-compose.mounts.yml" "${state_dir}/docker-compose.mounts.yml"
    fi

    if [[ -L "$target_dir" ]]; then
        old_link_backup="${target_dir}.old-link.$$"
        mv "$target_dir" "$old_link_backup"
    fi
    mkdir -p "$target_dir"

    echo "Syncing Docker resources ..."
    rsync -a --delete \
        --exclude '.env' \
        --exclude 'data/' \
        --exclude 'mounts.json' \
        --exclude 'docker-compose.mounts.yml' \
        --exclude '__pycache__/' \
        --exclude '*.pyc' \
        --exclude '*.pyo' \
        "${source_dir}/" "${target_dir}/" &
    if ! wait_with_progress "Syncing Docker resources" "$!"; then
        if [[ -n "$old_link_backup" && -L "$old_link_backup" ]]; then
            safe_rm_path "$target_dir" || true
            mv "$old_link_backup" "$target_dir"
            yellow "Docker resource install failed; restored old ${target_dir} symlink."
        fi
        yellow "Preserved Docker state backup: ${state_dir}"
        return 1
    fi

    if ! {
        copy_if_present "${state_dir}/.env" "${target_dir}/.env" &&
        copy_if_present_with_progress "${state_dir}/data" "${target_dir}/data" "Restoring Docker data" &&
        copy_if_present "${state_dir}/mounts.json" "${target_dir}/mounts.json" &&
        copy_if_present "${state_dir}/docker-compose.mounts.yml" "${target_dir}/docker-compose.mounts.yml"
    }; then
        if [[ -n "$old_link_backup" && -L "$old_link_backup" ]]; then
            safe_rm_path "$target_dir" || true
            mv "$old_link_backup" "$target_dir"
            yellow "Docker state restore failed; restored old ${target_dir} symlink."
        fi
        yellow "Preserved Docker state backup: ${state_dir}"
        return 1
    fi
    if docker_state_exists "$state_dir"; then
        cyan "Migrated existing Docker state into ${target_dir}"
        if [[ -n "$old_link_target" ]]; then
            cyan "Previous Docker resource link target: ${old_link_target}"
        fi
    fi
    [[ -n "$old_link_backup" ]] && rm -f "$old_link_backup"
    cleanup_state_dir "$state_dir"
}

link_source_docker_resources() {
    local source_dir="$1" target_dir="$2"
    local source_abs state_dir old_link_target="" old_backup="" target_abs=""

    source_abs="$(cd "$source_dir" && pwd -P)"
    state_dir="$(mktemp -d "${CAC_HOME}/.docker-state.XXXXXX")"

    if [[ -e "$target_dir" || -L "$target_dir" ]]; then
        if [[ -L "$target_dir" ]]; then
            old_link_target="$(readlink "$target_dir" || true)"
        fi
        copy_if_present "${target_dir}/.env" "${state_dir}/.env"
        copy_if_present_with_progress "${target_dir}/data" "${state_dir}/data" "Backing up Docker data"
        copy_if_present "${target_dir}/mounts.json" "${state_dir}/mounts.json"
        copy_if_present "${target_dir}/docker-compose.mounts.yml" "${state_dir}/docker-compose.mounts.yml"
        target_abs="$(cd "$target_dir" 2>/dev/null && pwd -P || true)"
    fi

    if [[ "$target_abs" != "$source_abs" ]]; then
        if [[ -e "$target_dir" || -L "$target_dir" ]]; then
            old_backup="${target_dir}.old.$$"
            mv "$target_dir" "$old_backup"
        fi
        mkdir -p "$(dirname "$target_dir")"
        if ! ln -s "$source_abs" "$target_dir"; then
            rm -f "$target_dir"
            if [[ -n "$old_backup" && ( -e "$old_backup" || -L "$old_backup" ) ]]; then
                mv "$old_backup" "$target_dir"
            fi
            yellow "Preserved Docker state backup: ${state_dir}"
            return 1
        fi
    fi

    if ! {
        copy_if_present "${state_dir}/.env" "${source_abs}/.env" &&
        copy_if_present_with_progress "${state_dir}/data" "${source_abs}/data" "Restoring Docker data" &&
        copy_if_present "${state_dir}/mounts.json" "${source_abs}/mounts.json" &&
        copy_if_present "${state_dir}/docker-compose.mounts.yml" "${source_abs}/docker-compose.mounts.yml"
    }; then
        if [[ -n "$old_backup" && ( -e "$old_backup" || -L "$old_backup" ) ]]; then
            rm -f "$target_dir"
            mv "$old_backup" "$target_dir"
            yellow "Docker state restore failed; restored old ${target_dir}."
        fi
        yellow "Preserved Docker state backup: ${state_dir}"
        return 1
    fi
    if docker_state_exists "$state_dir"; then
        cyan "Migrated existing Docker state into ${target_dir}"
        if [[ -n "$old_link_target" ]]; then
            cyan "Previous Docker resource link target: ${old_link_target}"
        fi
    fi
    [[ -n "$old_backup" ]] && safe_rm_path "$old_backup" || true
    cleanup_state_dir "$state_dir"
}

install_docker_resources() {
    mkdir -p "$CAC_HOME"

    if [[ -d "${SOURCE_DIR}/docker" ]] && [[ -f "${SOURCE_DIR}/docker/docker-compose.yml" ]]; then
        link_source_docker_resources "${SOURCE_DIR}/docker" "${CAC_HOME}/docker"
        green "✓ installed Docker resources → ${CAC_HOME}/docker"
        cyan "Docker local source builds are available from ${SOURCE_DIR}"
        return 0
    fi

    if [[ "$INSTALL_MODE" == "local" ]] && [[ -d "${SCRIPT_DIR}/docker" ]] && [[ -f "${SCRIPT_DIR}/docker/docker-compose.yml" ]]; then
        sync_docker_resources "${SCRIPT_DIR}/docker" "${CAC_HOME}/docker"
        green "✓ installed Docker resources → ${CAC_HOME}/docker"
        return 0
    fi

    if [[ ! -e "${CAC_HOME}/docker" ]]; then
        yellow "Docker resources were not installed automatically in remote install mode."
        yellow "To use 'cac docker', install from a local repo or source release that includes docker/."
    fi
}

detect_rc_file() {
    if [[ -f "${HOME}/.zshrc" ]]; then
        printf '%s\n' "${HOME}/.zshrc"
    elif [[ -f "${HOME}/.bashrc" ]]; then
        printf '%s\n' "${HOME}/.bashrc"
    elif [[ -f "${HOME}/.bash_profile" ]]; then
        printf '%s\n' "${HOME}/.bash_profile"
    else
        printf '%s\n' ""
    fi
}

install_shell_path_config() {
    local rc_file tmp
    rc_file="$(detect_rc_file)"
    if [[ -z "$rc_file" ]]; then
        yellow "Shell config file not found; add this manually if cac is not in PATH:"
        printf '  export PATH="$HOME/bin:$PATH"\n'
        return 0
    fi

    tmp="${rc_file}.cac-docker-claude.$$.tmp"
    awk '
        /# >>> cac/ { skip=1; next }
        /# <<< cac/ { skip=0; next }
        skip { next }
        /\.cac\/bin/ { next }
        /# cac .*Claude Code Cloak/ { next }
        /# cac 命令/ { next }
        /# claude wrapper/ { next }
        { print }
    ' "$rc_file" > "$tmp"
    cat -s "$tmp" > "$rc_file"
    rm -f "$tmp"

    if ! grep -q '# >>> cac-docker-claude >>>' "$rc_file" 2>/dev/null; then
        cat >> "$rc_file" <<'CACEOF'

# >>> cac-docker-claude >>>
PATH=$(printf '%s\n' "$PATH" | tr ':' '\n' | awk -v home="$HOME" '$0 != home"/bin" && $0 != home"/.cac/bin" && !seen[$0]++' | paste -sd ':' -)
export PATH="$HOME/bin:$PATH"
# <<< cac-docker-claude <<<
CACEOF
        green "✓ PATH written to $rc_file"
    else
        green "✓ PATH already configured in $rc_file"
    fi
}

read_kv_file() {
    local file="$1" key="$2"
    [[ -f "$file" ]] || return 1
    grep -m1 "^${key}=" "$file" 2>/dev/null | cut -d= -f2-
}

docker_cli_available() {
    command -v docker >/dev/null 2>&1 && docker version >/dev/null 2>&1
}

docker_data_dir_from_env() {
    local env_file="$1" raw base
    raw="$(read_kv_file "$env_file" CAC_DATA || true)"
    raw="${raw:-./data}"
    base="$(cd "$(dirname "$env_file")" && pwd -P)"
    python3 - "$base" "$raw" <<'PY'
import os
import sys

base = sys.argv[1]
raw = sys.argv[2]
if os.path.isabs(raw):
    print(os.path.realpath(raw))
else:
    print(os.path.realpath(os.path.join(base, raw)))
PY
}

docker_runtime_user_from_env() {
    local env_file="$1" user
    user="$(read_kv_file "$env_file" CAC_FAKE_USER || true)"
    printf '%s\n' "${user:-cherny}"
}

docker_claude_state_exists() {
    local data_dir="$1" runtime_user="$2"
    [[ -d "${data_dir}/home/${runtime_user}/.cac" ]] && return 0
    [[ -d "${data_dir}/home/${runtime_user}/.claude" ]] && return 0
    [[ -f "${data_dir}/home/${runtime_user}/.claude.json" ]] && return 0
    [[ -d "${data_dir}/root/.cac" ]] && return 0
    [[ -d "${data_dir}/root/.claude" ]] && return 0
    [[ -f "${data_dir}/root/.claude.json" ]] && return 0
    return 1
}

print_docker_data_preserve_notice() {
    [[ -e "${CAC_HOME}/docker" ]] || return 0

    local env_file="${CAC_HOME}/docker/.env"
    [[ -f "$env_file" ]] || return 0

    local data_dir runtime_user
    data_dir="$(docker_data_dir_from_env "$env_file")"
    runtime_user="$(docker_runtime_user_from_env "$env_file")"

    cyan "Docker Claude state mode: preserve"
    printf '  data dir: %s\n' "$data_dir"

    if docker_claude_state_exists "$data_dir" "$runtime_user"; then
        yellow "Existing Claude login/session data detected and will be preserved."
    else
        cyan "No existing Claude login/session data detected yet."
    fi

    yellow "Install/update leave existing containers running by default; explicit rebuilds do not delete this data directory."
    yellow "A full reset must be done manually after backup if you really want to erase Claude credentials/history."
}

refresh_existing_docker_stack() {
    [[ "$INSTALL_MODE" == "local" ]] || return 0
    [[ -e "${CAC_HOME}/docker" ]] || return 0

    local env_file="${CAC_HOME}/docker/.env"
    [[ -f "$env_file" ]] || return 0

    local proxy_uri
    proxy_uri="$(read_kv_file "$env_file" PROXY_URI || true)"
    [[ -n "$proxy_uri" ]] || return 0

    if ! docker_cli_available; then
        yellow "Skipping Docker refresh: docker is unavailable"
        return 0
    fi

    local container_name proxy_name workspace_dir stack_exists stack_running
    container_name="$(read_kv_file "$env_file" CAC_CONTAINER_NAME || true)"
    proxy_name="$(read_kv_file "$env_file" CAC_DOCKER_PROXY_NAME || true)"
    container_name="${container_name:-boris-main}"
    proxy_name="${proxy_name:-boris-gateway}"
    stack_exists=false
    stack_running=false

    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Fxq "$container_name"; then
        stack_exists=true
    elif docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Fxq "$proxy_name"; then
        stack_exists=true
    fi

    [[ "$stack_exists" == "true" ]] || return 0

    if docker ps --format '{{.Names}}' 2>/dev/null | grep -Fxq "$container_name"; then
        stack_running=true
    elif docker ps --format '{{.Names}}' 2>/dev/null | grep -Fxq "$proxy_name"; then
        stack_running=true
    fi

    if [[ "$stack_running" != "true" ]]; then
        yellow "Skipping automatic Docker refresh: existing stack is not running"
        yellow "Run setup/start manually after confirming the proxy on this machine:"
        printf '  cac docker setup\n'
        printf '  cac docker create\n'
        printf '  cac docker start\n'
        return 0
    fi

    workspace_dir="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/workspace"}}{{.Source}}{{end}}{{end}}' "$container_name" 2>/dev/null || true)"
    [[ -d "$workspace_dir" ]] || workspace_dir="$SCRIPT_DIR"

    cyan "Refreshing existing Docker deployment ..."
    (
        cd "$workspace_dir"
        "${BIN_DIR}/cac" docker stop >/dev/null 2>&1 || true
        CAC_DOCKER_REBUILD=1 "${BIN_DIR}/cac" docker create >/dev/null
        "${BIN_DIR}/cac" docker start >/dev/null
    ) && {
        green "✓ refreshed Docker deployment"
        return 0
    }

    yellow "Docker install completed, but automatic stack refresh failed"
    yellow "Retry manually from your workspace:"
    printf '  cd %s\n' "$workspace_dir"
    printf '  CAC_DOCKER_REBUILD=1 cac docker create && cac docker start\n'
    return 1
}

write_identity_files() {
    mkdir -p "$CAC_HOME"
    printf '%s\n' "$IDENTITY_MODEL" > "${CAC_HOME}/host_model"
    printf '%s\n' "$IDENTITY_SERIAL" > "${CAC_HOME}/host_serial_number"
    printf '%s\n' "$IDENTITY_MANUFACTURER" > "${CAC_HOME}/host_manufacturer"
}

load_existing_identity() {
    EXISTING_MODEL=""
    EXISTING_SERIAL=""
    EXISTING_MANUFACTURER=""
    if [[ -f "${CAC_HOME}/host_model" ]]; then
        EXISTING_MODEL="$(tr -d '\r\n' < "${CAC_HOME}/host_model")"
    fi
    if [[ -f "${CAC_HOME}/host_serial_number" ]]; then
        EXISTING_SERIAL="$(tr -d '\r\n' < "${CAC_HOME}/host_serial_number")"
    fi
    if [[ -f "${CAC_HOME}/host_manufacturer" ]]; then
        EXISTING_MANUFACTURER="$(tr -d '\r\n' < "${CAC_HOME}/host_manufacturer")"
    fi
}

show_identity_values() {
    printf '  model: %s\n' "${IDENTITY_MODEL:-—}"
    printf '  serial: %s\n' "${IDENTITY_SERIAL:-—}"
    printf '  manufacturer: %s\n' "${IDENTITY_MANUFACTURER:-—}"
}

prompt_identity_field() {
    local field_key="$1"
    local field_label="$2"
    local detected_value="$3"
    local existing_value="$4"
    local current_value="$5"
    local choice prompt default_choice entered_value next_value

    while true; do
        printf '\n%s:\n' "$field_label"
        printf '  detected: %s\n' "${detected_value:-—}"
        printf '  existing: %s\n' "${existing_value:-—}"
        printf '  current:  %s\n' "${current_value:-—}"

        if [[ -n "$existing_value" ]]; then
            prompt='Choose [k]eep existing, [d]etected, or [e]nter custom'
            default_choice="k"
        else
            prompt='Choose [d]etected or [e]nter custom'
            default_choice="d"
        fi

        printf '%s [%s]: ' "$prompt" "$default_choice"
        read -r choice
        case "${choice:-$default_choice}" in
            k|K)
                if [[ -n "$existing_value" ]]; then
                    next_value="$existing_value"
                    break
                fi
                yellow "No existing value is available for ${field_label}."
                ;;
            d|D)
                next_value="$detected_value"
                break
                ;;
            e|E)
                printf 'Enter %s: ' "$field_label"
                read -r entered_value
                next_value="$entered_value"
                break
                ;;
            *)
                yellow "Please choose a valid option."
                ;;
        esac
    done

    case "$field_key" in
        model) IDENTITY_MODEL="$next_value" ;;
        serial) IDENTITY_SERIAL="$next_value" ;;
        manufacturer) IDENTITY_MANUFACTURER="$next_value" ;;
    esac
}

review_identity_fields() {
    while true; do
        prompt_identity_field "model" "Model" "$DETECTED_MODEL" "$EXISTING_MODEL" "${IDENTITY_MODEL:-$DETECTED_MODEL}"
        prompt_identity_field "serial" "Serial Number" "$DETECTED_SERIAL" "$EXISTING_SERIAL" "${IDENTITY_SERIAL:-$DETECTED_SERIAL}"
        prompt_identity_field "manufacturer" "Manufacturer" "$DETECTED_MANUFACTURER" "$EXISTING_MANUFACTURER" "${IDENTITY_MANUFACTURER:-$DETECTED_MANUFACTURER}"

        printf '\nFinal macOS host identity values:\n'
        show_identity_values
        printf '\nWrite these values to ~/.cac? [Y/n]: '
        read -r answer
        case "${answer:-y}" in
            y|Y|yes|YES|"")
                write_identity_files
                return 0
                ;;
            n|N|no|NO)
                yellow "Restarting field-by-field review."
                ;;
            *)
                yellow "Please answer y or n."
                ;;
        esac
    done
}

scan_macos_identity() {
    local hw
    hw="$(system_profiler SPHardwareDataType 2>/dev/null || true)"
    [[ -n "$hw" ]] || {
        yellow "Skipping macOS host identity scan: system_profiler returned no hardware data"
        return 1
    }

    DETECTED_MODEL="$(printf '%s\n' "$hw" | sed -n 's/^ *Model Identifier: //p' | head -1)"
    DETECTED_SERIAL="$(printf '%s\n' "$hw" | sed -n 's/^ *Serial Number (system): //p' | head -1)"
    DETECTED_MANUFACTURER="Apple Inc."

    [[ -n "$DETECTED_MODEL" && -n "$DETECTED_SERIAL" ]] || {
        yellow "Skipping macOS host identity scan: failed to parse model/serial"
        return 1
    }
    return 0
}

setup_identity() {
    return 0
}

initialize_cac() {
    export PATH="${BIN_DIR}:$PATH"
    "${BIN_DIR}/cac" docker help >/dev/null
}

print_completion() {
    local rc_file
    rc_file="$(detect_rc_file)"

    echo
    green "✓ install complete"
    echo
    printf 'Install mode: %s\n' "$INSTALL_MODE"
    printf 'Entry: %s\n' "${BIN_DIR}/cac"
    printf 'Runtime files: %s\n' "$DIST_DIR"
    if [[ -d "$SOURCE_DIR" ]]; then
        printf 'Source tree: %s\n' "$SOURCE_DIR"
    fi
    if [[ -e "${CAC_HOME}/docker" ]]; then
        printf 'Docker resources: %s\n' "${CAC_HOME}/docker"
    fi
    echo

    if [[ -n "$rc_file" ]]; then
        echo "Run this to refresh PATH now, or open a new terminal:"
        echo "  source $rc_file"
        echo
    fi

    echo "Next:"
    echo "  cac docker setup"
    echo "  cac docker create"
    echo "  cac docker start"
}

main() {
    parse_args "$@"

    echo "=== cac-docker-claude installer ==="
    echo

    resolve_install_mode
    check_existing_install
    run_local_build
    setup_identity
    install_source_tree
    install_assets
    link_entrypoint
    install_shell_path_config
    install_docker_resources
    print_docker_data_preserve_notice
    initialize_cac
    if [[ "${CAC_INSTALL_REFRESH_STACK:-0}" == "1" ]]; then
        refresh_existing_docker_stack
    else
        cyan "Skipping automatic Docker stack refresh; existing containers are left untouched."
    fi
    print_completion
}

main "$@"
