# ── cmd: self (cac self-management, like "uv self") ──────────────

_SELF_REPO="https://raw.githubusercontent.com/ZMK112/cac-docker-claude/main"
_SELF_STABLE_REPO="${CAC_STABLE_REPO:-${CAC_RELEASE_REPO:-ZMK112/cac-docker-claude}}"

_self_copy_if_present() {
    local src="$1" dst="$2"
    [[ -e "$src" || -L "$src" ]] || return 0
    rm -rf "$dst"
    cp -pR "$src" "$dst"
}

_self_copy_docker_state_if_present() {
    local src="$1" dst="$2"
    [[ -e "$src" || -L "$src" ]] || return 0
    mkdir -p "$dst"
    _self_copy_if_present "${src}/.env" "${dst}/.env"
    _self_copy_if_present "${src}/data" "${dst}/data"
    _self_copy_if_present "${src}/mounts.json" "${dst}/mounts.json"
    _self_copy_if_present "${src}/docker-compose.mounts.yml" "${dst}/docker-compose.mounts.yml"
}

_self_restore_docker_state_if_present() {
    local state_dir="$1" dst="$2"
    [[ -d "$state_dir" ]] || return 0
    _self_copy_if_present "${state_dir}/.env" "${dst}/.env"
    _self_copy_if_present "${state_dir}/data" "${dst}/data"
    _self_copy_if_present "${state_dir}/mounts.json" "${dst}/mounts.json"
    _self_copy_if_present "${state_dir}/docker-compose.mounts.yml" "${dst}/docker-compose.mounts.yml"
}

_self_backup_current_install() {
    local backup_dir="$1" dist_dir="$HOME/.cac-dist" bin_entry="$HOME/bin/cac" docker_dir="$HOME/.cac/docker" source_dir="$HOME/.cac/source"
    mkdir -p "$backup_dir"
    _self_copy_if_present "$dist_dir" "${backup_dir}/cac-dist"
    _self_copy_if_present "$bin_entry" "${backup_dir}/cac-entry"
    _self_copy_if_present "$source_dir" "${backup_dir}/source"
    if [[ -L "$docker_dir" ]]; then
        readlink "$docker_dir" > "${backup_dir}/docker-link-target" 2>/dev/null || true
        _self_copy_docker_state_if_present "$docker_dir" "${backup_dir}/docker-state"
    elif [[ -e "$docker_dir" ]]; then
        _self_copy_if_present "$docker_dir" "${backup_dir}/docker-dir"
    fi
}

_self_restore_install_backup() {
    local backup_dir="$1" dist_dir="$HOME/.cac-dist" bin_entry="$HOME/bin/cac" docker_dir="$HOME/.cac/docker" source_dir="$HOME/.cac/source"

    rm -rf "$dist_dir"
    if [[ -e "${backup_dir}/cac-dist" ]]; then
        cp -pR "${backup_dir}/cac-dist" "$dist_dir"
    fi

    mkdir -p "$HOME/bin"
    rm -rf "$bin_entry"
    if [[ -e "${backup_dir}/cac-entry" || -L "${backup_dir}/cac-entry" ]]; then
        cp -pR "${backup_dir}/cac-entry" "$bin_entry"
    fi

    rm -rf "$source_dir"
    if [[ -e "${backup_dir}/source" ]]; then
        mkdir -p "$(dirname "$source_dir")"
        cp -pR "${backup_dir}/source" "$source_dir"
    fi

    rm -rf "$docker_dir"
    if [[ -f "${backup_dir}/docker-link-target" ]]; then
        local target
        target="$(cat "${backup_dir}/docker-link-target")"
        [[ -n "$target" ]] && ln -s "$target" "$docker_dir"
        if [[ -e "$docker_dir" ]]; then
            _self_restore_docker_state_if_present "${backup_dir}/docker-state" "$docker_dir"
        fi
    elif [[ -e "${backup_dir}/docker-dir" ]]; then
        mkdir -p "$(dirname "$docker_dir")"
        cp -pR "${backup_dir}/docker-dir" "$docker_dir"
    fi
}

_self_find_install_dir() {
    local source="$1" tmp_dir="$2" candidate=""
    if [[ -d "$source" ]]; then
        if [[ -f "${source}/install.sh" ]]; then
            (cd "$source" && pwd -P)
            return 0
        fi
        candidate="$(find "$source" -maxdepth 2 -type f -name install.sh 2>/dev/null | head -n1)"
        [[ -n "$candidate" ]] || return 1
        (cd "$(dirname "$candidate")" && pwd -P)
        return 0
    fi

    if [[ -f "$source" ]]; then
        case "$source" in
            *.zip)
                command -v unzip >/dev/null 2>&1 || _die "unzip is required to upgrade from a zip archive"
                unzip -q "$source" -d "$tmp_dir" || return 1
                candidate="$(find "$tmp_dir" -maxdepth 2 -type f -name install.sh 2>/dev/null | head -n1)"
                [[ -n "$candidate" ]] || return 1
                (cd "$(dirname "$candidate")" && pwd -P)
                return 0
                ;;
        esac
    fi
    return 1
}

_self_validate_upgraded_install() {
    local bin_entry="$HOME/bin/cac" dist_bin="$HOME/.cac-dist/cac" docker_dir="$HOME/.cac/docker"
    [[ -x "$dist_bin" ]] || return 1
    [[ -x "$bin_entry" ]] || return 1
    "$dist_bin" --help >/dev/null || return 1
    "$bin_entry" --help >/dev/null || return 1
    if [[ -f "${docker_dir}/docker-compose.yml" ]]; then
        "$bin_entry" docker help >/dev/null || return 1
    fi
}

_self_validate_preserved_state() {
    local backup_dir="$1" docker_dir="$HOME/.cac/docker"
    [[ ! -e "${backup_dir}/docker-state/.env" && ! -e "${backup_dir}/docker-dir/.env" ]] || [[ -e "${docker_dir}/.env" ]] || return 1
    [[ ! -e "${backup_dir}/docker-state/data" && ! -e "${backup_dir}/docker-dir/data" ]] || [[ -e "${docker_dir}/data" ]] || return 1
    [[ ! -e "${backup_dir}/docker-state/mounts.json" && ! -e "${backup_dir}/docker-dir/mounts.json" ]] || [[ -e "${docker_dir}/mounts.json" ]] || return 1
    [[ ! -e "${backup_dir}/docker-state/docker-compose.mounts.yml" && ! -e "${backup_dir}/docker-dir/docker-compose.mounts.yml" ]] || [[ -e "${docker_dir}/docker-compose.mounts.yml" ]] || return 1
}

_self_restore_state_from_backup() {
    local backup_dir="$1" target_dir="$2"
    if [[ -d "${backup_dir}/docker-state" ]]; then
        _self_restore_docker_state_if_present "${backup_dir}/docker-state" "$target_dir"
    elif [[ -d "${backup_dir}/docker-dir" ]]; then
        _self_restore_docker_state_if_present "${backup_dir}/docker-dir" "$target_dir"
    fi
}

_self_finalize_docker_resources_after_upgrade() {
    local install_dir="$1" backup_dir="$2" install_docker_dir="${install_dir}/docker" target_dir="$HOME/.cac/docker" installed_source_dir="$HOME/.cac/source" installed_docker_dir="$HOME/.cac/source/docker"
    local new_dir="" installed_docker_abs="" target_abs=""

    if [[ -d "$installed_docker_dir" && -f "${installed_docker_dir}/docker-compose.yml" ]]; then
        installed_docker_abs="$(cd "$installed_docker_dir" && pwd -P)"
        target_abs="$(cd "$target_dir" 2>/dev/null && pwd -P || true)"
        if [[ "$target_abs" != "$installed_docker_abs" ]]; then
            rm -rf "$target_dir"
            mkdir -p "$(dirname "$target_dir")"
            ln -s "$installed_docker_abs" "$target_dir"
        fi
        _self_restore_state_from_backup "$backup_dir" "$target_dir"
        return 0
    fi

    local source_dir="$install_docker_dir"
    [[ -d "$source_dir" && -f "${source_dir}/docker-compose.yml" ]] || return 0

    mkdir -p "$HOME/.cac"
    new_dir="$(mktemp -d "$HOME/.cac/.docker-new.XXXXXX")"
    if ! rsync -a --delete \
        --exclude '.env' \
        --exclude 'data/' \
        --exclude 'mounts.json' \
        --exclude 'docker-compose.mounts.yml' \
        --exclude '__pycache__/' \
        --exclude '*.pyc' \
        --exclude '*.pyo' \
        "${source_dir}/" "${new_dir}/"; then
        rm -rf "$new_dir"
        return 1
    fi

    _self_restore_state_from_backup "$backup_dir" "$new_dir"
    rm -rf "$target_dir"
    mv "$new_dir" "$target_dir"
}

_self_curl_github() {
    local url="$1" output="$2" token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
    local -a args=(-fsSL -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")
    if [[ -z "$token" ]] && command -v gh >/dev/null 2>&1; then
        token="$(gh auth token 2>/dev/null || true)"
    fi
    [[ -n "$token" ]] && args+=(-H "Authorization: Bearer ${token}")
    if [[ -n "$output" ]]; then
        curl "${args[@]}" -o "$output" "$url"
    else
        curl "${args[@]}" "$url"
    fi
}

_self_latest_stable_asset_info() {
    local release_json="$1"
    python3 - "$release_json" <<'PY'
import json
import re
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)

if data.get("draft") or data.get("prerelease"):
    raise SystemExit("latest release is not stable")

assets = data.get("assets") or []
zip_assets = [
    item for item in assets
    if re.match(r"^cac-docker-claude-source-.+\.zip$", str(item.get("name", "")))
]
portable_assets = [
    item for item in assets
    if re.match(r"^cac-source-.+\.zip$", str(item.get("name", "")))
]
zip_assets = zip_assets or portable_assets
if not zip_assets:
    raise SystemExit("stable release has no cac-docker-claude source zip asset")

zip_asset = sorted(zip_assets, key=lambda item: str(item.get("name", "")))[-1]
sha_asset = None
expected_sha_name = str(zip_asset.get("name", ""))[:-4] + ".sha256"
for item in assets:
    if item.get("name") == expected_sha_name:
        sha_asset = item
        break

print(data.get("tag_name") or "")
print(zip_asset.get("name") or "")
print(zip_asset.get("browser_download_url") or "")
print(sha_asset.get("name") if sha_asset else "")
print(sha_asset.get("browser_download_url") if sha_asset else "")
PY
}

_self_download_latest_stable_release() {
    local repo="${1:-$_SELF_STABLE_REPO}" tmp_dir="$2" release_json="$tmp_dir/release.json"
    local api_url info_file tag zip_name zip_url sha_name sha_url zip_path sha_path
    [[ -n "$repo" ]] || _die "stable release repo is empty"
    api_url="https://api.github.com/repos/${repo}/releases/latest"

    echo "  Stable release repo: $(_cyan "$repo")" >&2
    _self_curl_github "$api_url" "$release_json" || _die "failed to fetch latest stable release metadata from $repo"

    info_file="$tmp_dir/stable-asset-info"
    _self_latest_stable_asset_info "$release_json" > "$info_file" || _die "latest release is not a usable stable source release"
    tag="$(sed -n '1p' "$info_file")"
    zip_name="$(sed -n '2p' "$info_file")"
    zip_url="$(sed -n '3p' "$info_file")"
    sha_name="$(sed -n '4p' "$info_file")"
    sha_url="$(sed -n '5p' "$info_file")"
    [[ -n "$tag" && -n "$zip_name" && -n "$zip_url" ]] || _die "stable release metadata is incomplete"

    zip_path="$tmp_dir/$zip_name"
    echo "  Stable release: $(_cyan "$tag")" >&2
    echo "  Downloading: $zip_name" >&2
    _self_curl_github "$zip_url" "$zip_path" || _die "failed to download $zip_name"

    if [[ -n "$sha_name" && -n "$sha_url" ]]; then
        sha_path="$tmp_dir/$sha_name"
        _self_curl_github "$sha_url" "$sha_path" || _die "failed to download $sha_name"
        (cd "$tmp_dir" && shasum -a 256 -c "$sha_name") >/dev/null || _die "checksum verification failed for $zip_name"
        echo "  Checksum: $(_green "OK")" >&2
    else
        echo "$(_yellow "warning:") stable release has no .sha256 asset; skipping checksum verification" >&2
    fi

    printf '%s\n' "$zip_path"
}

_self_cmd_update() {
    _self_cmd_update_stable ""
}

_self_cmd_upgrade() {
    local source="${1:-}" tmp_dir="" backup_dir="" install_dir="" elapsed cleanup_package=0
    [[ -n "$source" ]] || _die "missing release path\n  usage: cac self upgrade <release-dir-or-zip>"

    source="$(python3 - "$source" <<'PY'
import os
import sys
print(os.path.realpath(os.path.expanduser(sys.argv[1])))
PY
)"
    [[ -e "$source" ]] || _die "release path not found: $source"
    if [[ -f "$source" && ( "$(basename "$source")" == cac-docker-claude-source-*.zip || "$(basename "$source")" == cac-source-*.zip ) ]]; then
        cleanup_package=1
    fi

    tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/cac-upgrade.XXXXXX")"
    backup_dir="$(mktemp -d "${TMPDIR:-/tmp}/cac-upgrade-backup.XXXXXX")"
    install_dir="$(_self_find_install_dir "$source" "$tmp_dir")" || {
        rm -rf "$tmp_dir" "$backup_dir"
        _die "could not find install.sh in release path: $source"
    }

    echo "Upgrading cac from $(_cyan "$install_dir") ..."
    _timer_start
    _self_backup_current_install "$backup_dir"

    if (
        cd "$install_dir" || exit 1
        bash install.sh --local --yes --skip-identity
    ) && _self_finalize_docker_resources_after_upgrade "$install_dir" "$backup_dir" && _self_validate_upgraded_install && _self_validate_preserved_state "$backup_dir"; then
        rm -rf "$tmp_dir" "$backup_dir"
        elapsed=$(_timer_elapsed)
        echo "$(_green_bold "Upgraded") cac $(_dim "in $elapsed")"
        if [[ "$cleanup_package" -eq 1 ]]; then
            rm -f "$source"
            echo "$(_dim "Removed installer package: $source")"
        fi
        echo "$(_dim "Source is installed under ~/.cac/source and Docker resources are available via ~/.cac/docker.")"
        return 0
    fi

    echo "$(_yellow "warning:") upgrade failed; rolling back previous install" >&2
    _self_restore_install_backup "$backup_dir"
    rm -rf "$tmp_dir" "$backup_dir"
    _die "upgrade failed and previous install was restored"
}

_self_cmd_update_stable() {
    local repo="${1:-$_SELF_STABLE_REPO}" tmp_dir="" zip_path=""
    tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/cac-stable-update.XXXXXX")"
    echo "Updating cac Docker install to latest stable release ..."
    zip_path="$(_self_download_latest_stable_release "$repo" "$tmp_dir")" || {
        rm -rf "$tmp_dir"
        return 1
    }
    _self_cmd_upgrade "$zip_path"
    rm -rf "$tmp_dir"
}

cmd_self() {
    case "${1:-help}" in
        update)          _self_cmd_update ;;
        upgrade)         _self_cmd_upgrade "${@:2}" ;;
        update-stable)   _self_cmd_update_stable "${2:-}" ;;
        delete|remove)   _die "delete is not exposed in cac-docker-claude; remove ~/.cac/source, ~/.cac/docker, ~/.cac-dist, and ~/bin/cac manually after backing up data" ;;
        help|-h|--help)
            echo "$(_bold "cac self") — cac self-management"
            echo
            echo "  $(_bold "update")    Update cac to the latest version"
            echo "  $(_bold "upgrade")   Upgrade from a downloaded release dir/zip with rollback"
            echo "  $(_bold "update-stable") Update from the latest stable GitHub release"
            echo "  $(_bold "delete")    Uninstall cac completely"
            ;;
        *) _die "unknown: cac self $1" ;;
    esac
}
