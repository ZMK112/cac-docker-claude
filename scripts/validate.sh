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
if ./cac env ls >/tmp/cac-docker-claude-local.out 2>&1; then
    printf 'local env command unexpectedly succeeded\n' >&2
    exit 1
fi
pass "docker-only-cli"

if [[ "$suite" == "full" ]]; then
    command -v docker >/dev/null 2>&1 || { printf 'docker is required for --suite full\n' >&2; exit 1; }
    docker compose version >/dev/null
    pass "docker-client"
fi

printf '\nValidation summary\n'
printf '  suite:    %s\n' "$suite"
printf '  failures: 0\n'
