#!/usr/bin/env bash
set -euo pipefail

suite="fast"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --suite)
            shift
            suite="${1:-fast}"
            shift
            ;;
        --suite=*)
            suite="${1#--suite=}"
            shift
            ;;
        --keep-workdir)
            shift
            ;;
        -h|--help)
            printf 'Usage: bash scripts/validate.sh [--suite fast|full]\n'
            exit 0
            ;;
        *)
            printf 'unknown argument: %s\n' "$1" >&2
            exit 1
            ;;
    esac
done

pass() { printf '[PASS] %s\n' "$1"; }

bash -n build.sh install.sh scripts/install-stable.sh scripts/package-source.sh
bash -n src/utils.sh src/cmd_self.sh src/cmd_docker_common.sh src/cmd_docker_runtime.sh src/cmd_docker_ports.sh src/cmd_docker.sh src/cmd_version.sh src/cmd_help.sh src/main.sh
pass "shell-syntax"

bash build.sh >/dev/null
bash -n cac
pass "build"

./cac --help >/dev/null
./cac --version >/dev/null
./cac docker help >/dev/null
./cac docker help | grep -q "start      Start the container; no-op if already running"
./cac docker help | grep -q "restart    Restart and remount the current directory as /workspace"
./cac docker help | grep -q "update     Update to the latest stable release with rollback; skips when current"
if ./cac env ls >/tmp/cac-docker-claude-local.out 2>&1; then
    printf 'local env command unexpectedly succeeded\n' >&2
    exit 1
fi
pass "docker-only-cli"

[[ "$(bash -c 'set -- help; source ./cac >/dev/null 2>&1 || true; _normalize_release_version v0.1.14')" == "0.1.14" ]]
[[ "$(bash -c 'set -- help; source ./cac >/dev/null 2>&1 || true; _normalize_release_version 0.1.14')" == "0.1.14" ]]
pass "version-normalization"

tmp_home="$(mktemp -d "${TMPDIR:-/tmp}/cac-install-path.XXXXXX")"
trap 'rm -rf "$tmp_home"' EXIT
cat > "${tmp_home}/.zshrc" <<'EOF'
export PATH="$HOME/.cac/bin:$PATH"
# >>> cac — Claude Code Cloak >>>
export PATH="$HOME/bin:$HOME/.cac/bin:$PATH"
alias claude="$HOME/.cac/bin/claude"
# <<< cac — Claude Code Cloak <<<
export KEEP_ME=1
EOF
HOME="$tmp_home" bash install.sh --local --no-build >/tmp/cac-docker-claude-install-path.out
if bash -lc "HOME='$tmp_home'; source '$tmp_home/.zshrc'; printf '%s\n' \"\$PATH\"" | tr ':' '\n' | grep -Fxq "${tmp_home}/.cac/bin"; then
    printf 'installer left ~/.cac/bin active in shell PATH\n' >&2
    cat "${tmp_home}/.zshrc" >&2
    exit 1
fi
grep -q 'export PATH="$HOME/bin:$PATH"' "${tmp_home}/.zshrc"
grep -q 'export KEEP_ME=1' "${tmp_home}/.zshrc"
pass "installer-path-cleanup"

if [[ "$suite" == "full" ]]; then
    command -v docker >/dev/null 2>&1 || { printf 'docker is required for --suite full\n' >&2; exit 1; }
    docker compose version >/dev/null
    pass "docker-client"
fi

printf '\nValidation summary\n'
printf '  suite:    %s\n' "$suite"
printf '  failures: 0\n'
