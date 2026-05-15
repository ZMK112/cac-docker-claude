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
./cac docker help | grep -q "direct     Manage domain keywords that use direct DNS and direct route"
./cac docker help | grep -q "update     Update to the latest stable release with rollback; skips when current"
./cac docker direct help >/dev/null
if ./cac env ls >/tmp/cac-docker-claude-local.out 2>&1; then
    printf 'local env command unexpectedly succeeded\n' >&2
    exit 1
fi
pass "docker-only-cli"

tmp_direct="$(mktemp -d "${TMPDIR:-/tmp}/cac-direct-cli.XXXXXX")"
mkdir -p "${tmp_direct}/docker"
cp docker/docker-compose.yml "${tmp_direct}/docker/docker-compose.yml"
cp cac "${tmp_direct}/cac"
cat > "${tmp_direct}/docker/.env" <<'EOF'
PROXY_URI=socks5h://host.docker.internal:17890
CAC_PROXY_CONFIG_KIND=uri
CAC_CONTAINER_NAME=cac-direct-test-missing
CAC_DIRECT_DOMAIN_KEYWORDS=akamai-access.com,timeresearch
EOF
(
    cd "$tmp_direct"
    CAC_DOCKER_BUILD_LOCAL=0 ./cac docker direct add rockbund timeresearch >/tmp/cac-direct-add.out
    grep -q 'CAC_DIRECT_DOMAIN_KEYWORDS=akamai-access.com,timeresearch,rockbund' docker/.env
    CAC_DOCKER_BUILD_LOCAL=0 ./cac docker direct rm timeresearch >/tmp/cac-direct-rm.out
    grep -q 'CAC_DIRECT_DOMAIN_KEYWORDS=akamai-access.com,rockbund' docker/.env
    CAC_DOCKER_BUILD_LOCAL=0 ./cac docker direct ls >/tmp/cac-direct-ls.out
    grep -q 'Direct DNS: .*127.0.0.11' /tmp/cac-direct-ls.out
    grep -q 'akamai-access.com' /tmp/cac-direct-ls.out
    grep -q 'rockbund' /tmp/cac-direct-ls.out
)
rm -rf "$tmp_direct"
pass "docker-direct-cli"

python3 - <<'PY'
import json
import os
import sys
sys.path.insert(0, os.path.abspath("docker"))
from lib.protocols import parse
from lib.singbox import render

cfg = render(
    parse("socks5://127.0.0.1:1080"),
    dns_server="https://1.1.1.1/dns-query",
    direct_dns_server="127.0.0.11",
    direct_domain_keywords=["timeresearch"],
    tun_address="172.19.0.1/30",
    tun_mtu=9000,
)
servers = cfg["dns"]["servers"]
direct = next(item for item in servers if item["tag"] == "direct-dns")
assert direct["address"] == "127.0.0.11", json.dumps(direct)
assert cfg["dns"]["rules"][0]["domain_keyword"] == ["timeresearch"]
assert any(rule.get("domain_keyword") == ["timeresearch"] and rule.get("outbound") == "direct" for rule in cfg["route"]["rules"])
PY
pass "direct-dns-default"

tmp_chain="$(mktemp -d "${TMPDIR:-/tmp}/cac-chain-direct-dns.XXXXXX")"
cat > "${tmp_chain}/chain.yaml" <<'EOF'
proxies:
  - name: jump
    type: socks5
    server: 127.0.0.1
    port: 1080
proxy-groups:
  - name: Claude-专用链路
    type: select
    proxies:
      - jump
rules:
  - MATCH,Claude-专用链路
EOF
python3 scripts/mihomo_chain_to_singbox.py "${tmp_chain}/chain.yaml" \
    --direct-domain-keyword timeresearch \
    -o "${tmp_chain}/sing-box.json" >/dev/null
python3 - "${tmp_chain}/sing-box.json" <<'PY'
import json
import sys
cfg = json.load(open(sys.argv[1]))
direct = next(item for item in cfg["dns"]["servers"] if item["tag"] == "direct-dns")
assert direct["address"] == "127.0.0.11", json.dumps(direct)
PY
rm -rf "$tmp_chain"
pass "mihomo-direct-dns-default"

python3 - <<'PY'
import json
import os
import sys
sys.path.insert(0, os.path.abspath("docker"))
from lib.protocols import parse
from lib.singbox import render

uri = (
    "vless://00000000-0000-0000-0000-000000000000@example.com:443"
    "?encryption=none&security=tls&type=grpc&host=edge.example.com"
    "&serviceName=grpc-service#tag"
)
proxy = parse(uri)
assert proxy.type == "vless"
assert proxy.server == "example.com"
assert proxy.port == 443
assert proxy.uuid == "00000000-0000-0000-0000-000000000000"
assert proxy.tls is True
assert proxy.sni == "edge.example.com"
assert proxy.extra["transport"] == "grpc"
assert proxy.extra["service_name"] == "grpc-service"
cfg = render(
    proxy,
    dns_server="https://1.1.1.1/dns-query",
    direct_dns_server="127.0.0.11",
    direct_domain_keywords=[],
    tun_address="172.19.0.1/30",
    tun_mtu=9000,
)
outbound = cfg["outbounds"][0]
assert outbound["type"] == "vless", json.dumps(outbound)
assert outbound["server"] == "example.com", json.dumps(outbound)
assert outbound["domain_resolver"] == "direct-dns", json.dumps(outbound)
assert outbound["tls"]["server_name"] == "edge.example.com", json.dumps(outbound)
assert outbound["transport"] == {
    "type": "grpc",
    "service_name": "grpc-service",
}, json.dumps(outbound)
PY
pass "vless-grpc-share-link"

PROXY_URI='vless://00000000-0000-0000-0000-000000000000@example.com:443?encryption=none&security=tls&type=grpc&host=edge.example.com&serviceName=grpc-service#tag' \
DNS_SERVER='https://1.1.1.1/dns-query' \
CAC_DIRECT_DNS_SERVER='127.0.0.11' \
PYTHONPATH="${PWD}/docker" \
python3 -m lib > /tmp/cac-vless-config.json
python3 - /tmp/cac-vless-config.json <<'PY'
import json
import sys
cfg = json.load(open(sys.argv[1]))
outbound = cfg["outbounds"][0]
assert outbound["server"] == "example.com", json.dumps(outbound)
assert outbound["domain_resolver"] == "direct-dns", json.dumps(outbound)
assert outbound["tls"]["server_name"] == "edge.example.com", json.dumps(outbound)
assert outbound["transport"]["service_name"] == "grpc-service", json.dumps(outbound)
assert any(server["tag"] == "direct-dns" for server in cfg["dns"]["servers"])
PY
rm -f /tmp/cac-vless-config.json
pass "vless-config-preserves-server-name"

[[ "$(bash -c 'set -- help; source ./cac >/dev/null 2>&1 || true; _normalize_release_version v0.1.20')" == "0.1.20" ]]
[[ "$(bash -c 'set -- help; source ./cac >/dev/null 2>&1 || true; _normalize_release_version 0.1.20')" == "0.1.20" ]]
pass "version-normalization"

tmp_upgrade_zip="$(mktemp -d "${TMPDIR:-/tmp}/cac-upgrade-zip.XXXXXX")"
mkdir -p "${tmp_upgrade_zip}/release-root"
printf '#!/usr/bin/env bash\nexit 0\n' > "${tmp_upgrade_zip}/release-root/install.sh"
chmod +x "${tmp_upgrade_zip}/release-root/install.sh"
(
    cd "$tmp_upgrade_zip"
    zip -qr release.zip release-root
)
upgrade_stdout="$(
    bash -c 'source ./src/utils.sh; source ./src/cmd_self.sh; _self_find_install_dir "$1" "$2"' \
        _ "${tmp_upgrade_zip}/release.zip" "${tmp_upgrade_zip}/unpacked" \
        2>"${tmp_upgrade_zip}/stderr"
)"
[[ "$upgrade_stdout" == "${tmp_upgrade_zip}/unpacked/release-root" ]]
grep -q "Unpacking release archive" "${tmp_upgrade_zip}/stderr"
rm -rf "$tmp_upgrade_zip"
pass "upgrade-zip-stdout"

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

tmp_perm_home="$(mktemp -d "${TMPDIR:-/tmp}/cac-install-perms.XXXXXX")"
trap 'rm -rf "$tmp_home" "$tmp_perm_home"' EXIT
mkdir -p "${tmp_perm_home}/.cac/docker/data/home/cherny/.claude/agents"
printf 'legacy agent data\n' > "${tmp_perm_home}/.cac/docker/data/home/cherny/.claude/agents/example.txt"
chmod 500 "${tmp_perm_home}/.cac/docker/data/home/cherny/.claude/agents"
chmod 500 "${tmp_perm_home}/.cac/docker/data/home/cherny/.claude"
HOME="$tmp_perm_home" bash install.sh --local --no-build >/tmp/cac-docker-claude-install-perms.out
[[ -e "${tmp_perm_home}/.cac/docker/data/home/cherny/.claude/agents/example.txt" ]]
if find "${tmp_perm_home}/.cac" -maxdepth 1 -name '.docker-state.*' -print | grep -q .; then
    printf 'installer left temporary Docker state backups behind\n' >&2
    find "${tmp_perm_home}/.cac" -maxdepth 1 -name '.docker-state.*' -print >&2
    exit 1
fi
rm -rf "$tmp_perm_home"
pass "installer-docker-state-permissions"

if [[ "$suite" == "full" ]]; then
    command -v docker >/dev/null 2>&1 || { printf 'docker is required for --suite full\n' >&2; exit 1; }
    docker compose version >/dev/null
    pass "docker-client"
fi

printf '\nValidation summary\n'
printf '  suite:    %s\n' "$suite"
printf '  failures: 0\n'
