# ── cac docker — common defs and helper functions ───────────────────

_info()  { printf '\033[36m▸\033[0m %b\n' "$*"; }
_ok()    { printf '\033[32m✓\033[0m %b\n' "$*"; }
_warn()  { printf '\033[33m!\033[0m %b\n' "$*"; }
_err()   { printf '\033[31m✗\033[0m %b\n' "$*" >&2; }

_dk_script_dir() {
  local ref target
  ref="${BASH_SOURCE[0]:-$0}"
  [[ "$ref" == /* ]] || ref="$(pwd)/$ref"
  while [[ -L "$ref" ]]; do
    target="$(readlink "$ref")" || break
    [[ "$target" == /* ]] || target="$(cd "$(dirname "$ref")" && pwd -P)/$target"
    ref="$target"
  done
  (cd "$(dirname "$ref")" && pwd -P)
}

_docker_dir() {
  local script_dir
  script_dir="$(_dk_script_dir)"

  for d in \
    "$script_dir/docker" \
    "$script_dir/../docker" \
    "$HOME/.cac/docker"
  do
    if [[ -d "$d" && -f "$d/docker-compose.yml" ]]; then
      (cd "$d" && pwd -P)
      return 0
    fi
  done

  echo ""
}

_dk_env_file=""
_dk_compose_base=()
_dk_service="cac"
_dk_shim_if="cac-docker-shim"
_dk_port_dir="/tmp/cac-docker-ports"
_dk_image="${CAC_DOCKER_IMAGE_REPO}:${CAC_DOCKER_IMAGE_TAG}"
_dk_build_file="docker-compose.build.yml"

_dk_host_port_available() {
  local bind_addr="$1" port="$2"
  python3 - "$bind_addr" "$port" <<'PY'
import socket, sys
host = sys.argv[1] or "0.0.0.0"
port = int(sys.argv[2])
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind((host, port))
except OSError:
    print("0")
else:
    print("1")
finally:
    s.close()
PY
}

_dk_next_free_host_port() {
  local bind_addr="$1" start_port="$2"
  shift 2
  local -a reserved=("$@")
  local port="$start_port" limit=$((start_port + 100)) skip reserved_port
  while [[ "$port" -le "$limit" ]]; do
    skip=0
    for reserved_port in "${reserved[@]:-}"; do
      if [[ -n "$reserved_port" && "$port" == "$reserved_port" ]]; then
        skip=1
        break
      fi
    done
    if [[ "$skip" -eq 0 ]] && [[ "$(_dk_host_port_available "$bind_addr" "$port")" == "1" ]]; then
      printf '%s\n' "$port"
      return 0
    fi
    port=$((port + 1))
  done
  return 1
}

_dk_random_secret() {
  python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(18))
PY
}

_dk_child_proxy_bridge_host() {
  printf '%s\n' "host.docker.internal"
}

_dk_child_proxy_bridge_http_url() {
  local user="$1" password="$2" port="$3" host
  host="$(_dk_child_proxy_bridge_host)"
  printf 'http://%s:%s@%s:%s\n' "$user" "$password" "$host" "$port"
}

_dk_child_proxy_bridge_all_url() {
  local user="$1" password="$2" port="$3" host
  host="$(_dk_child_proxy_bridge_host)"
  printf 'socks5h://%s:%s@%s:%s\n' "$user" "$password" "$host" "$port"
}

_dk_data_dir_raw() {
  local raw
  raw="${CAC_DATA:-$(_dk_read_env CAC_DATA)}"
  printf '%s\n' "${raw:-./data}"
}

_dk_mounts_state_file() {
  local docker_dir
  docker_dir="$(_docker_dir)"
  printf '%s\n' "${docker_dir}/mounts.json"
}

_dk_mounts_compose_file() {
  local docker_dir
  docker_dir="$(_docker_dir)"
  printf '%s\n' "${docker_dir}/docker-compose.mounts.yml"
}

_dk_mount_host_abs() {
  python3 - "$1" <<'PY'
import os
import sys

raw = sys.argv[1]
path = os.path.realpath(raw)
if not os.path.isdir(path):
    raise SystemExit(1)
print(path)
PY
}

_dk_mount_default_target() {
  python3 - "$1" <<'PY'
import os
import re
import sys

name = os.path.basename(os.path.normpath(sys.argv[1])) or "root"
name = re.sub(r"[^A-Za-z0-9._-]+", "-", name).strip("-") or "root"
print(f"/mnt/{name}")
PY
}

_dk_mount_target_normalize() {
  python3 - "$1" <<'PY'
import posixpath
import sys

raw = sys.argv[1].strip()
if not raw or not raw.startswith("/"):
    raise SystemExit(1)
print(posixpath.normpath(raw))
PY
}

_dk_mount_target_reserved() {
  case "$1" in
    /|/root|/root/*|/home|/home/*|/workspace|/workspace/*|/proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/run|/run/*|/etc|/etc/*|/usr|/usr/*|/var|/var/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

_dk_mounts_list_tsv() {
  local state_file
  state_file="$(_dk_mounts_state_file)"
  python3 - "$state_file" <<'PY'
import json
import os
import sys

path = sys.argv[1]
if not os.path.exists(path):
    raise SystemExit(0)
with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)
if not isinstance(data, list):
    raise SystemExit("mounts.json must contain a list")
for item in sorted(data, key=lambda x: x["container_path"]):
    print(f'{item["host_path"]}\t{item["container_path"]}\t{item.get("mode", "rw")}')
PY
}

_dk_mounts_get_host_for_target() {
  local target="$1" state_file
  state_file="$(_dk_mounts_state_file)"
  python3 - "$state_file" "$target" <<'PY'
import json
import os
import sys

path, target = sys.argv[1:3]
if not os.path.exists(path):
    raise SystemExit(0)
with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)
for item in data:
    if item.get("container_path") == target:
        print(item.get("host_path", ""))
        raise SystemExit(0)
PY
}

_dk_mounts_upsert() {
  local host_path="$1" target_path="$2" state_file
  state_file="$(_dk_mounts_state_file)"
  python3 - "$state_file" "$host_path" "$target_path" <<'PY'
import json
import os
import sys

path, host_path, target_path = sys.argv[1:4]
data = []
if os.path.exists(path):
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
updated = False
for item in data:
    if item.get("container_path") == target_path:
        item["host_path"] = host_path
        item["mode"] = "rw"
        updated = True
        break
if not updated:
    data.append({
        "host_path": host_path,
        "container_path": target_path,
        "mode": "rw",
    })
data = sorted(data, key=lambda x: x["container_path"])
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
PY
}

_dk_mounts_remove() {
  local target_path="$1" state_file
  state_file="$(_dk_mounts_state_file)"
  python3 - "$state_file" "$target_path" <<'PY'
import json
import os
import sys

path, target_path = sys.argv[1:3]
if not os.path.exists(path):
    raise SystemExit(1)
with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)
new_data = [item for item in data if item.get("container_path") != target_path]
if len(new_data) == len(data):
    raise SystemExit(1)
if new_data:
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(sorted(new_data, key=lambda x: x["container_path"]), fh, indent=2)
        fh.write("\n")
else:
    os.remove(path)
PY
}

_dk_mounts_refresh_compose() {
  local state_file compose_file
  state_file="$(_dk_mounts_state_file)"
  compose_file="$(_dk_mounts_compose_file)"
  python3 - "$state_file" "$compose_file" <<'PY'
import json
import os
import sys

state_path, compose_path = sys.argv[1:3]
items = []
if os.path.exists(state_path):
    with open(state_path, "r", encoding="utf-8") as fh:
        items = json.load(fh)
    if not isinstance(items, list):
        raise SystemExit("mounts.json must contain a list")

if not items:
    if os.path.exists(compose_path):
        os.remove(compose_path)
    raise SystemExit(0)

with open(compose_path, "w", encoding="utf-8") as fh:
    fh.write("# Generated by `cac docker mount`; do not edit by hand.\n")
    fh.write("services:\n")
    fh.write("  cac:\n")
    fh.write("    volumes:\n")
    for item in sorted(items, key=lambda x: x["container_path"]):
        fh.write("      - type: bind\n")
        fh.write(f"        source: {json.dumps(item['host_path'])}\n")
        fh.write(f"        target: {json.dumps(item['container_path'])}\n")
        fh.write("        read_only: false\n")
PY
}

_dk_data_dir_abs() {
  local raw="${1:-$(_dk_data_dir_raw)}" docker_dir
  docker_dir="$(_docker_dir)"
  python3 - "$docker_dir" "$raw" <<'PY'
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

_dk_yaml_file_abs() {
  python3 - "$1" <<'PY'
import os
import sys

path = os.path.realpath(os.path.expanduser(sys.argv[1]))
if not os.path.isfile(path):
    raise SystemExit(1)
if not path.lower().endswith((".yaml", ".yml")):
    raise SystemExit(1)
print(path)
PY
}

_dk_chain_converter_script() {
  local docker_dir repo_root
  docker_dir="$(_docker_dir)"
  repo_root="${docker_dir%/docker}"
  printf '%s\n' "${repo_root}/scripts/mihomo_chain_to_singbox.py"
}

_dk_file_b64() {
  python3 - "$1" <<'PY'
import base64
import sys

with open(sys.argv[1], "rb") as fh:
    print(base64.b64encode(fh.read()).decode("ascii"))
PY
}

_dk_runtime_user_name() {
  local user
  user="${CAC_FAKE_USER:-$(_dk_read_env CAC_FAKE_USER)}"
  printf '%s\n' "${user:-cherny}"
}

_dk_claude_state_detected() {
  local data_dir="${1:-$(_dk_data_dir_abs)}" runtime_user="${2:-$(_dk_runtime_user_name)}"
  [[ -d "${data_dir}/home/${runtime_user}/.cac" ]] && return 0
  [[ -d "${data_dir}/home/${runtime_user}/.claude" ]] && return 0
  [[ -f "${data_dir}/home/${runtime_user}/.claude.json" ]] && return 0
  [[ -d "${data_dir}/root/.cac" ]] && return 0
  [[ -d "${data_dir}/root/.claude" ]] && return 0
  [[ -f "${data_dir}/root/.claude.json" ]] && return 0
  return 1
}

_dk_claude_state_summary() {
  local data_dir="${1:-$(_dk_data_dir_abs)}" runtime_user="${2:-$(_dk_runtime_user_name)}"
  if _dk_claude_state_detected "$data_dir" "$runtime_user"; then
    printf '%s\n' "detected — rebuild/recreate preserves Claude login, credentials, memory, and session history under ${data_dir}"
  else
    printf '%s\n' "not detected yet — future Claude login/session data will be stored under ${data_dir}"
  fi
}

_dk_control_ip_from_subnet() {
  local subnet="$1" host_offset="$2"
  python3 - "$subnet" "$host_offset" <<'PY'
import ipaddress, sys

network = ipaddress.ip_network(sys.argv[1], strict=False)
host_offset = int(sys.argv[2])
print(str(network.network_address + host_offset))
PY
}

_dk_prepare_child_proxy_bridge_env() {
  local container_name bridge_name bridge_bind bridge_port bridge_user bridge_password bridge_ip control_subnet
  local all_proxy_url http_proxy_url changed=0

  container_name="${CAC_CONTAINER_NAME:-$(_dk_read_env CAC_CONTAINER_NAME)}"
  container_name="${container_name:-boris-main}"
  control_subnet="${CAC_DOCKER_CONTROL_SUBNET:-$(_dk_read_env CAC_DOCKER_CONTROL_SUBNET)}"
  control_subnet="${control_subnet:-172.31.255.0/24}"
  bridge_name="${CAC_CHILD_PROXY_BRIDGE_NAME:-$(_dk_read_env CAC_CHILD_PROXY_BRIDGE_NAME)}"
  bridge_name="${bridge_name:-${container_name}-child-proxy}"
  bridge_ip="${CAC_CHILD_PROXY_BRIDGE_IP:-$(_dk_read_env CAC_CHILD_PROXY_BRIDGE_IP)}"
  bridge_ip="${bridge_ip:-$(_dk_control_ip_from_subnet "$control_subnet" 4)}"
  bridge_bind="${CAC_CHILD_PROXY_BRIDGE_BIND:-$(_dk_read_env CAC_CHILD_PROXY_BRIDGE_BIND)}"
  bridge_bind="${bridge_bind:-0.0.0.0}"
  bridge_port="${CAC_CHILD_PROXY_BRIDGE_PORT:-$(_dk_read_env CAC_CHILD_PROXY_BRIDGE_PORT)}"
  bridge_port="${bridge_port:-17891}"
  bridge_user="${CAC_CHILD_PROXY_BRIDGE_USER:-$(_dk_read_env CAC_CHILD_PROXY_BRIDGE_USER)}"
  bridge_user="${bridge_user:-cacbridge}"
  bridge_password="${CAC_CHILD_PROXY_BRIDGE_PASSWORD:-$(_dk_read_env CAC_CHILD_PROXY_BRIDGE_PASSWORD)}"
  if [[ -z "$bridge_password" ]]; then
    bridge_password="$(_dk_random_secret)"
    changed=1
  fi

  all_proxy_url="$(_dk_child_proxy_bridge_all_url "$bridge_user" "$bridge_password" "$bridge_port")"
  http_proxy_url="$(_dk_child_proxy_bridge_http_url "$bridge_user" "$bridge_password" "$bridge_port")"

  for kv in \
    "CAC_CHILD_PROXY_BRIDGE_NAME=$bridge_name" \
    "CAC_CHILD_PROXY_BRIDGE_IP=$bridge_ip" \
    "CAC_CHILD_PROXY_BRIDGE_BIND=$bridge_bind" \
    "CAC_CHILD_PROXY_BRIDGE_PORT=$bridge_port" \
    "CAC_CHILD_PROXY_BRIDGE_USER=$bridge_user" \
    "CAC_CHILD_PROXY_BRIDGE_PASSWORD=$bridge_password" \
    "CAC_CHILD_CONTAINER_PROXY_URL=$all_proxy_url" \
    "CAC_CHILD_CONTAINER_ALL_PROXY_URL=$all_proxy_url" \
    "CAC_CHILD_CONTAINER_HTTP_PROXY_URL=$http_proxy_url" \
    "CAC_CHILD_CONTAINER_ADD_HOST_GATEWAY=1"
  do
    local key="${kv%%=*}" value="${kv#*=}"
    if [[ "$(_dk_read_env "$key")" != "$value" ]]; then
      _dk_write_env "$key" "$value"
      changed=1
    fi
  done

  if [[ "$changed" -eq 1 ]]; then
    _dk_load_env
  fi
}

_dk_prepare_host_ports() {
  local current_state="${1:-}"

  if [[ "$current_state" == "running" ]]; then
    return 0
  fi

  local ssh_enabled ssh_bind ssh_port web_enabled web_bind web_port bridge_bind bridge_port next_port changed=0
  ssh_enabled="${CAC_ENABLE_SSH:-$(_dk_read_env CAC_ENABLE_SSH)}"
  ssh_enabled="${ssh_enabled:-1}"
  ssh_bind="${CAC_HOST_SSH_BIND:-$(_dk_read_env CAC_HOST_SSH_BIND)}"
  ssh_bind="${ssh_bind:-0.0.0.0}"
  ssh_port="${CAC_HOST_SSH_PORT:-$(_dk_read_env CAC_HOST_SSH_PORT)}"
  ssh_port="${ssh_port:-2222}"

  web_enabled="${CAC_ENABLE_WEB:-$(_dk_read_env CAC_ENABLE_WEB)}"
  web_enabled="${web_enabled:-1}"
  web_bind="${CAC_HOST_WEB_BIND:-$(_dk_read_env CAC_HOST_WEB_BIND)}"
  web_bind="${web_bind:-0.0.0.0}"
  web_port="${CAC_HOST_WEB_PORT:-$(_dk_read_env CAC_HOST_WEB_PORT)}"
  web_port="${web_port:-3001}"
  bridge_bind="${CAC_CHILD_PROXY_BRIDGE_BIND:-$(_dk_read_env CAC_CHILD_PROXY_BRIDGE_BIND)}"
  bridge_bind="${bridge_bind:-0.0.0.0}"
  bridge_port="${CAC_CHILD_PROXY_BRIDGE_PORT:-$(_dk_read_env CAC_CHILD_PROXY_BRIDGE_PORT)}"
  bridge_port="${bridge_port:-17891}"

  if [[ "$ssh_enabled" != "0" ]] && [[ "$(_dk_host_port_available "$ssh_bind" "$ssh_port")" != "1" ]]; then
    next_port="$(_dk_next_free_host_port "$ssh_bind" "$ssh_port")" || {
      _err "No free SSH port found starting from ${ssh_port}"
      return 1
    }
    _warn "SSH port ${ssh_bind}:${ssh_port} is occupied, switching to ${next_port}"
    _dk_write_env CAC_HOST_SSH_PORT "$next_port"
    ssh_port="$next_port"
    changed=1
  fi

  if [[ "$web_enabled" != "0" ]] && [[ "$(_dk_host_port_available "$web_bind" "$web_port")" != "1" ]]; then
    next_port="$(_dk_next_free_host_port "$web_bind" "$web_port" "$ssh_port")" || {
      _err "No free Web UI port found starting from ${web_port}"
      return 1
    }
    _warn "Web UI port ${web_bind}:${web_port} is occupied, switching to ${next_port}"
    _dk_write_env CAC_HOST_WEB_PORT "$next_port"
    web_port="$next_port"
    changed=1
  fi

  if [[ "$(_dk_host_port_available "$bridge_bind" "$bridge_port")" != "1" ]]; then
    next_port="$(_dk_next_free_host_port "$bridge_bind" "$bridge_port" "$ssh_port" "$web_port")" || {
      _err "No free child proxy bridge port found starting from ${bridge_port}"
      return 1
    }
    _warn "Child proxy bridge port ${bridge_bind}:${bridge_port} is occupied, switching to ${next_port}"
    _dk_write_env CAC_CHILD_PROXY_BRIDGE_PORT "$next_port"
    bridge_port="$next_port"
    changed=1
  fi

  if [[ "$changed" -eq 1 ]]; then
    _dk_load_env
  fi
}

_dk_web_enabled() {
  local web_enabled
  web_enabled="${CAC_ENABLE_WEB:-$(_dk_read_env CAC_ENABLE_WEB)}"
  web_enabled="${web_enabled:-1}"
  [[ "$web_enabled" != "0" ]]
}

_dk_web_port() {
  local web_port
  web_port="${CAC_HOST_WEB_PORT:-$(_dk_read_env CAC_HOST_WEB_PORT)}"
  printf '%s\n' "${web_port:-3001}"
}

_dk_mask_proxy_display() {
  local proxy="${1:-}"
  [[ -n "$proxy" ]] || return 0

  if [[ "$proxy" == *"://"*"@"* ]]; then
    printf '%s\n' "$proxy" | sed 's|://[^@]*@|://***@|'
    return 0
  fi

  if [[ "$proxy" == *:*:*:* ]]; then
    local host="" port=""
    IFS=: read -r host port _ _ <<< "$proxy"
    printf '%s:%s:***\n' "$host" "$port"
    return 0
  fi

  printf '%s\n' "$proxy"
}

_dk_is_localhost_bind() {
  case "${1:-}" in
    127.0.0.1|localhost) return 0 ;;
    *) return 1 ;;
  esac
}

_dk_print_local_only_snippet() {
  printf '  CAC_HOST_WEB_BIND=127.0.0.1\n'
  printf '  CAC_HOST_SSH_BIND=127.0.0.1\n'
}

_dk_warn_web_exposure() {
  local web_enabled web_bind ssh_enabled ssh_bind ssh_password
  web_enabled="${CAC_ENABLE_WEB:-$(_dk_read_env CAC_ENABLE_WEB)}"
  web_enabled="${web_enabled:-1}"
  web_bind="${CAC_HOST_WEB_BIND:-$(_dk_read_env CAC_HOST_WEB_BIND)}"
  web_bind="${web_bind:-0.0.0.0}"
  ssh_enabled="${CAC_ENABLE_SSH:-$(_dk_read_env CAC_ENABLE_SSH)}"
  ssh_enabled="${ssh_enabled:-1}"
  ssh_bind="${CAC_HOST_SSH_BIND:-$(_dk_read_env CAC_HOST_SSH_BIND)}"
  ssh_bind="${ssh_bind:-0.0.0.0}"
  ssh_password="${CAC_SSH_PASSWORD:-$(_dk_read_env CAC_SSH_PASSWORD)}"
  ssh_password="${ssh_password:-cherny}"

  if [[ "$web_enabled" != "0" ]] && ! _dk_is_localhost_bind "$web_bind"; then
    _warn "Web UI is LAN-reachable and Docker Web mode bypasses the CloudCLI login screen."
    _warn "Use only on trusted networks, or lock it down with:"
    _dk_print_local_only_snippet
    printf '  # or disable it entirely\n'
    printf '  CAC_ENABLE_WEB=0\n'
  fi

  if [[ "$ssh_enabled" != "0" ]] && ! _dk_is_localhost_bind "$ssh_bind" && [[ "$ssh_password" == "cherny" ]]; then
    _warn "SSH is also LAN-reachable with the default password."
    _warn "At minimum, change CAC_SSH_PASSWORD or lock SSH down with:"
    printf '  CAC_HOST_SSH_BIND=127.0.0.1\n'
  fi
}

_dk_maybe_migrate_child_proxy() {
  local before after
  before="$(_dk_read_env CAC_CHILD_CONTAINER_PROXY_URL)"
  _dk_prepare_child_proxy_bridge_env
  after="$(_dk_read_env CAC_CHILD_CONTAINER_PROXY_URL)"
  if [[ -n "$before" && "$before" != "$after" ]]; then
    _warn "Refreshing child proxy settings to use the local proxy-bridge."
  fi
}
