#!/usr/bin/env bash
set -euo pipefail

DEFAULT_REPO="ZMK112/cac-docker-claude"
REPO="${CAC_STABLE_REPO:-${CAC_RELEASE_REPO:-$DEFAULT_REPO}}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cac-install-stable.XXXXXX")"
INSTALL_ARGS=()

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

log() { printf '[cac-install] %s\n' "$*" >&2; }
die() { printf '[cac-install] error: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: bash install-stable.sh [options]

Download and install the latest stable cac-docker-claude source release.

Options:
  --repo owner/repo   GitHub release repo (default: ZMK112/cac-docker-claude)
  --yes               Non-interactive install; accepted for compatibility
  --skip-identity     Skip macOS host identity scan/review
  --force-identity    Overwrite existing macOS host identity files
  --no-build          Skip rebuilding files inside the unpacked release
  -h, --help          Show this help

Public stable releases need no authentication. For private mirrors, authenticate
with either:
  gh auth login
  GH_TOKEN=... bash install-stable.sh
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo)
                shift
                [[ $# -gt 0 && -n "$1" ]] || die "--repo requires owner/repo"
                REPO="$1"
                shift
                ;;
            --repo=*)
                REPO="${1#--repo=}"
                [[ -n "$REPO" ]] || die "--repo requires owner/repo"
                shift
                ;;
            --yes)
                shift
                ;;
            --skip-identity|--force-identity|--no-build)
                INSTALL_ARGS+=("$1")
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "unknown argument: $1"
                ;;
        esac
    done
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

github_token() {
    local token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
    if [[ -z "$token" ]] && command -v gh >/dev/null 2>&1; then
        token="$(gh auth token 2>/dev/null || true)"
    fi
    printf '%s\n' "$token"
}

curl_github() {
    local url="$1" output="$2" accept="$3" token
    token="$(github_token)"

    local -a args=(-fsSL -H "Accept: ${accept}" -H "X-GitHub-Api-Version: 2022-11-28")
    [[ -n "$token" ]] && args+=(-H "Authorization: Bearer ${token}")

    if ! curl "${args[@]}" -o "$output" "$url"; then
        die "failed to download ${url}; if the repo is private, run 'gh auth login' or set GH_TOKEN"
    fi
}

latest_asset_info() {
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
source_assets = [
    item for item in assets
    if re.match(r"^cac-docker-claude-source-.+\.zip$", str(item.get("name", "")))
]
portable_assets = [
    item for item in assets
    if re.match(r"^cac-source-.+\.zip$", str(item.get("name", "")))
]
zip_assets = source_assets or portable_assets
if not zip_assets:
    raise SystemExit("stable release has no cac-docker-claude source zip asset")

zip_asset = sorted(zip_assets, key=lambda item: str(item.get("name", "")))[-1]
expected_sha_name = str(zip_asset.get("name", ""))[:-4] + ".sha256"
sha_asset = next((item for item in assets if item.get("name") == expected_sha_name), None)

print(data.get("tag_name") or "")
print(zip_asset.get("name") or "")
print(zip_asset.get("url") or "")
print(sha_asset.get("name") if sha_asset else "")
print(sha_asset.get("url") if sha_asset else "")
print("source" if source_assets else "portable")
PY
}

download_latest_stable() {
    local release_json="$TMP_DIR/release.json"
    local info_file="$TMP_DIR/asset-info"
    local tag zip_name zip_url sha_name sha_url zip_path sha_path package_kind

    log "Fetching latest stable release from ${REPO}"
    curl_github "https://api.github.com/repos/${REPO}/releases/latest" "$release_json" "application/vnd.github+json"
    latest_asset_info "$release_json" > "$info_file" || die "latest release is not a usable stable source release"

    tag="$(sed -n '1p' "$info_file")"
    zip_name="$(sed -n '2p' "$info_file")"
    zip_url="$(sed -n '3p' "$info_file")"
    sha_name="$(sed -n '4p' "$info_file")"
    sha_url="$(sed -n '5p' "$info_file")"
    package_kind="$(sed -n '6p' "$info_file")"
    [[ -n "$tag" && -n "$zip_name" && -n "$zip_url" ]] || die "stable release metadata is incomplete"

    zip_path="$TMP_DIR/$zip_name"
    log "Downloading ${zip_name} (${tag}, ${package_kind:-source})"
    curl_github "$zip_url" "$zip_path" "application/octet-stream"

    if [[ -n "$sha_name" && -n "$sha_url" ]]; then
        sha_path="$TMP_DIR/$sha_name"
        curl_github "$sha_url" "$sha_path" "application/octet-stream"
        (cd "$TMP_DIR" && shasum -a 256 -c "$sha_name") >/dev/null || die "checksum verification failed for ${zip_name}"
        log "Checksum OK"
    else
        log "No .sha256 asset found; skipping checksum verification"
    fi

    printf '%s\n' "$zip_path"
}

install_release_zip() {
    local zip_path="$1"
    local unpack_dir="$TMP_DIR/unpack"
    local install_file install_dir

    mkdir -p "$unpack_dir"
    unzip -q "$zip_path" -d "$unpack_dir"

    install_file="$(find "$unpack_dir" -maxdepth 3 -type f -name install.sh -print -quit 2>/dev/null || true)"
    [[ -n "$install_file" ]] || die "could not find install.sh in source release"
    install_dir="$(cd "$(dirname "$install_file")" && pwd -P)"

    log "Installing from ${install_dir}"
    (
        cd "$install_dir"
        if [[ "${#INSTALL_ARGS[@]}" -gt 0 ]]; then
            bash install.sh --local --yes "${INSTALL_ARGS[@]}"
        else
            bash install.sh --local --yes
        fi
    )
}

main() {
    parse_args "$@"
    require_cmd curl
    require_cmd python3
    require_cmd unzip
    require_cmd shasum

    local zip_path
    zip_path="$(download_latest_stable)"
    install_release_zip "$zip_path"

    log "Installed stable cac-docker-claude. Installer files were removed."
}

main "$@"
