# ── cac docker — runtime, subcommands, and dispatcher ───────────────
# shellcheck disable=SC2154  # globals are defined in cmd_docker_common.sh before concatenation

_dk_run_cac_check() {
  local out="/tmp/cac-docker-check.out"
  local rc="/tmp/cac-docker-check.rc"
  local status="" printed_lines=0 line_count=""

  _dk_compose exec -T "$_dk_service" sh -lc "rm -f '$out' '$rc'; (cac-check >'$out' 2>&1; printf '%s' \$? >'$rc') &" >/dev/null

  for _ in $(seq 1 60); do
    line_count="$(
      _dk_compose exec -T "$_dk_service" sh -lc "test -f '$out' && wc -l < '$out'" 2>/dev/null |
        tr -d '\r\n'
    )"
    if [[ "$line_count" =~ ^[0-9]+$ ]] && (( line_count > printed_lines )); then
      _dk_compose exec -T "$_dk_service" sh -lc "sed -n '$((printed_lines + 1)),${line_count}p' '$out'" 2>/dev/null || true
      printed_lines=$line_count
    fi
    status=$(_dk_compose exec -T "$_dk_service" sh -lc "test -f '$rc' && cat '$rc'" 2>/dev/null || true)
    [[ -n "$status" ]] && break
    sleep 1
  done

  line_count="$(
    _dk_compose exec -T "$_dk_service" sh -lc "test -f '$out' && wc -l < '$out'" 2>/dev/null |
      tr -d '\r\n'
  )"
  if [[ "$line_count" =~ ^[0-9]+$ ]] && (( line_count > printed_lines )); then
    _dk_compose exec -T "$_dk_service" sh -lc "sed -n '$((printed_lines + 1)),${line_count}p' '$out'" 2>/dev/null || true
  fi
  [[ -n "$status" ]] || { _err "cac-check did not finish"; return 1; }
  [[ "$status" == "0" ]]
}

_dk_probe_mount_writable() {
  local target_path="$1" runtime_user
  runtime_user="${CAC_FAKE_USER:-$(_dk_runtime_user_name)}"
  _dk_compose exec -T -u "$runtime_user" -e CAC_MOUNT_TARGET="$target_path" "$_dk_service" sh -lc '
    test -d "$CAC_MOUNT_TARGET" || exit 1
    probe_file="$CAC_MOUNT_TARGET/.cac-mount-probe-$$"
    : > "$probe_file"
    rm -f "$probe_file"
  ' >/dev/null 2>&1
}

_dk_print_mounts() {
  local lines host_path target_path mode
  lines="$(_dk_mounts_list_tsv)"
  if [[ -z "$lines" ]]; then
    _info "No extra Docker mounts configured."
    return 0
  fi

  while IFS=$'\t' read -r host_path target_path mode; do
    [[ -n "$target_path" ]] || continue
    printf '  %s -> %s (%s)\n' "$host_path" "$target_path" "${mode:-rw}"
  done <<< "$lines"
}

_dk_direct_keywords_update() {
  local action="$1" current="$2"
  shift 2
  python3 - "$action" "$current" "$@" <<'PY'
import re
import sys

action = sys.argv[1]
current = sys.argv[2]
inputs = sys.argv[3:]
allowed = re.compile(r"^[A-Za-z0-9._-]+$")


def split(values):
    out = []
    for value in values:
        for item in value.split(","):
            item = item.strip().lower()
            if item:
                if not allowed.match(item):
                    raise SystemExit(f"invalid direct domain keyword: {item}")
                out.append(item)
    return out


items = []
seen = set()
for item in split([current]):
    if item not in seen:
        items.append(item)
        seen.add(item)

targets = split(inputs)
if action == "add":
    for item in targets:
        if item not in seen:
            items.append(item)
            seen.add(item)
elif action == "rm":
    remove = set(targets)
    items = [item for item in items if item not in remove]
else:
    raise SystemExit(f"unknown action: {action}")

print(",".join(items))
PY
}

_dk_direct_keywords_print() {
  local raw="$1"
  python3 - "$raw" <<'PY'
import sys

items = []
seen = set()
for item in sys.argv[1].split(","):
    item = item.strip()
    if item and item not in seen:
        items.append(item)
        seen.add(item)

for item in items:
    print(item)
PY
}

_dk_refresh_mihomo_chain_configs() {
  local proxy_chain_yaml="${1:-}" control_subnet="${2:-}" proxy_kind converter chain_policy chain_internal_cidrs chain_internal_domains chain_direct_keywords chain_direct_dns bridge_user bridge_password bridge_port dns_server tun_address tun_mtu main_cfg bridge_cfg main_b64 bridge_b64
  local -a chain_extra_args=()

  proxy_kind="${CAC_PROXY_CONFIG_KIND:-$(_dk_read_env CAC_PROXY_CONFIG_KIND)}"
  [[ "$proxy_kind" == "mihomo-chain" ]] || return 0

  proxy_chain_yaml="${proxy_chain_yaml:-${CAC_PROXY_CHAIN_SOURCE:-$(_dk_read_env CAC_PROXY_CHAIN_SOURCE)}}"
  if [[ -z "$proxy_chain_yaml" || ! -f "$proxy_chain_yaml" ]]; then
    _err "Cannot refresh Mihomo chain config because CAC_PROXY_CHAIN_SOURCE is missing or unreadable."
    _info "Run \033[1mcac docker setup\033[0m again with the original YAML file, then retry."
    return 1
  fi

  converter="$(_dk_chain_converter_script)"
  [[ -f "$converter" ]] || {
    _err "Cannot find Mihomo-to-sing-box converter: $converter"
    return 1
  }

  control_subnet="${control_subnet:-${CAC_DOCKER_CONTROL_SUBNET:-$(_dk_read_env CAC_DOCKER_CONTROL_SUBNET)}}"
  control_subnet="${control_subnet:-172.31.255.0/24}"
  chain_policy="${CAC_PROXY_CHAIN_POLICY:-$(_dk_read_env CAC_PROXY_CHAIN_POLICY)}"
  chain_policy="${chain_policy:-Claude-专用链路}"
  chain_internal_cidrs="${CAC_PROXY_CHAIN_INTERNAL_CIDRS:-$(_dk_read_env CAC_PROXY_CHAIN_INTERNAL_CIDRS)}"
  chain_internal_domains="${CAC_PROXY_CHAIN_INTERNAL_DOMAINS:-$(_dk_read_env CAC_PROXY_CHAIN_INTERNAL_DOMAINS)}"
  chain_direct_keywords="${CAC_DIRECT_DOMAIN_KEYWORDS:-$(_dk_read_env CAC_DIRECT_DOMAIN_KEYWORDS)}"
  chain_direct_dns="${CAC_DIRECT_DNS_SERVER:-$(_dk_read_env CAC_DIRECT_DNS_SERVER)}"
  dns_server="${DNS_SERVER:-$(_dk_read_env DNS_SERVER)}"
  dns_server="${dns_server:-https://1.1.1.1/dns-query}"
  tun_address="${TUN_ADDRESS:-$(_dk_read_env TUN_ADDRESS)}"
  tun_address="${tun_address:-172.19.0.1/30}"
  tun_mtu="${TUN_MTU:-$(_dk_read_env TUN_MTU)}"
  tun_mtu="${tun_mtu:-9000}"
  bridge_user="${CAC_CHILD_PROXY_BRIDGE_USER:-$(_dk_read_env CAC_CHILD_PROXY_BRIDGE_USER)}"
  bridge_user="${bridge_user:-cacbridge}"
  bridge_password="${CAC_CHILD_PROXY_BRIDGE_PASSWORD:-$(_dk_read_env CAC_CHILD_PROXY_BRIDGE_PASSWORD)}"
  bridge_port="${CAC_CHILD_PROXY_BRIDGE_PORT:-$(_dk_read_env CAC_CHILD_PROXY_BRIDGE_PORT)}"
  bridge_port="${bridge_port:-17891}"

  [[ -n "$chain_internal_cidrs" ]] && chain_extra_args+=(--internal-cidr "$chain_internal_cidrs")
  [[ -n "$chain_internal_domains" ]] && chain_extra_args+=(--internal-domain "$chain_internal_domains")
  [[ -n "$chain_direct_keywords" ]] && chain_extra_args+=(--direct-domain-keyword "$chain_direct_keywords")
  [[ -n "$chain_direct_dns" ]] && chain_extra_args+=(--direct-dns-server "$chain_direct_dns")

  main_cfg="$(mktemp)"
  bridge_cfg="$(mktemp)"
  if ! python3 "$converter" "$proxy_chain_yaml" \
    --policy "$chain_policy" \
    --dns-server "$dns_server" \
    --tun-address "$tun_address" \
    --tun-mtu "$tun_mtu" \
    --internal-cidr "$control_subnet" \
    ${chain_extra_args[@]+"${chain_extra_args[@]}"} \
    --verify-no-bypass \
    -o "$main_cfg"; then
    rm -f "$main_cfg" "$bridge_cfg"
    _err "Failed to convert Mihomo YAML to sing-box TUN config"
    return 1
  fi
  if ! python3 "$converter" "$proxy_chain_yaml" \
    --policy "$chain_policy" \
    --dns-server "$dns_server" \
    --inbound-mode mixed \
    --listen 0.0.0.0 \
    --listen-port "$bridge_port" \
    --listen-user "$bridge_user" \
    --listen-password "$bridge_password" \
    --internal-cidr "$control_subnet" \
    ${chain_extra_args[@]+"${chain_extra_args[@]}"} \
    --verify-no-bypass \
    -o "$bridge_cfg"; then
    rm -f "$main_cfg" "$bridge_cfg"
    _err "Failed to convert Mihomo YAML to proxy-bridge sing-box config"
    return 1
  fi
  main_b64="$(_dk_file_b64 "$main_cfg")"
  bridge_b64="$(_dk_file_b64 "$bridge_cfg")"
  rm -f "$main_cfg" "$bridge_cfg"
  _dk_write_env CAC_SINGBOX_CONFIG_B64 "$main_b64"
  _dk_write_env CAC_PROXY_BRIDGE_CONFIG_B64 "$bridge_b64"
  _dk_write_env CAC_PROXY_CHAIN_POLICY "$chain_policy"
  _dk_write_env CAC_PROXY_CHAIN_SOURCE "$proxy_chain_yaml"
}

_dk_cmd_mount() {
  _dk_init || return 1
  local action="${1:-}"
  shift 2>/dev/null || true

  case "$action" in
    add)
      local host_input="${1:-}" target_input="${2:-}" host_path="" target_path="" current_state existing_host recreate_workspace=""
      if [[ -z "$host_input" ]]; then
        _err "Usage: cac docker mount add <host_dir> [container_path]"
        return 1
      fi

      host_path="$(_dk_mount_host_abs "$host_input" 2>/dev/null)" || {
        _err "Host directory does not exist or is not a directory: $host_input"
        return 1
      }

      if [[ -n "$target_input" ]]; then
        target_path="$(_dk_mount_target_normalize "$target_input" 2>/dev/null)" || {
          _err "Container path must be an absolute path"
          return 1
        }
      else
        target_path="$(_dk_mount_default_target "$host_path")"
      fi

      if _dk_mount_target_reserved "$target_path"; then
        _err "Refusing to mount into reserved container path: $target_path"
        return 1
      fi

      existing_host="$(_dk_mounts_get_host_for_target "$target_path")"
      current_state="$(_dk_container_state)"

      echo ""
      printf "\033[1mcac docker mount add\033[0m\n"
      echo ""
      _warn "This will add a read-write host bind mount to the protected main container."
      _info "Host path: \033[1m${host_path}\033[0m"
      _info "Container path: \033[1m${target_path}\033[0m"
      _info "Access: \033[1mrw\033[0m"
      _info "Applies to: \033[1mmain container only\033[0m"
      _info "Container state: \033[1m${current_state}\033[0m"
      [[ -n "$existing_host" ]] && _warn "An existing mount for ${target_path} will be replaced: ${existing_host}"
      if ! _dk_prompt_yes_no "Save this mount?" "N"; then
        _warn "Aborted."
        return 1
      fi

      _dk_mounts_upsert "$host_path" "$target_path"
      _dk_mounts_refresh_compose
      _ok "Mount saved"

      if [[ "$current_state" == "running" ]]; then
        echo ""
        _warn "A Docker container is already running for this install."
        if _dk_prompt_yes_no "Recreate the running Docker container now to apply this mount?" "N"; then
          recreate_workspace="$(_dk_workspace_host_current 2>/dev/null || _dk_workspace_host_abs)"
          CAC_WORKSPACE_HOST="$recreate_workspace" _dk_compose up -d --force-recreate || return 1
          if ! _dk_wait_runtime_ready; then
            _dk_abort_startup
            _err "Container did not become ready after applying mount changes"
            return 1
          fi
          if _dk_probe_mount_writable "$target_path"; then
            _ok "Mount is writable for the Claude runtime user at \033[1m${target_path}\033[0m"
          else
            _warn "Mount applied, but the Claude runtime user could not write to \033[1m${target_path}\033[0m"
            _info "Check host-directory ownership/permissions and retry."
            return 1
          fi
        else
          _info "Saved only. Restart or recreate the Docker container later to apply the mount."
        fi
      else
        _info "Saved only. The mount will apply on the next create/start/restart."
      fi
      ;;
    ls)
      echo ""
      printf "\033[1mcac docker mount ls\033[0m\n"
      echo ""
      _dk_print_mounts
      ;;
    rm)
      local target_input="${1:-}" target_path="" host_path="" current_state recreate_workspace=""
      if [[ -z "$target_input" ]]; then
        _err "Usage: cac docker mount rm <container_path>"
        return 1
      fi
      target_path="$(_dk_mount_target_normalize "$target_input" 2>/dev/null)" || {
        _err "Container path must be an absolute path"
        return 1
      }
      host_path="$(_dk_mounts_get_host_for_target "$target_path")"
      if [[ -z "$host_path" ]]; then
        _err "No mount is configured for ${target_path}"
        return 1
      fi
      current_state="$(_dk_container_state)"

      echo ""
      printf "\033[1mcac docker mount rm\033[0m\n"
      echo ""
      _info "Host path: \033[1m${host_path}\033[0m"
      _info "Container path: \033[1m${target_path}\033[0m"
      _info "Container state: \033[1m${current_state}\033[0m"
      if ! _dk_prompt_yes_no "Remove this mount?" "N"; then
        _warn "Aborted."
        return 1
      fi

      _dk_mounts_remove "$target_path" || {
        _err "Failed to remove mount for ${target_path}"
        return 1
      }
      _dk_mounts_refresh_compose
      _ok "Mount removed"

      if [[ "$current_state" == "running" ]]; then
        echo ""
        _warn "A Docker container is already running for this install."
        if _dk_prompt_yes_no "Recreate the running Docker container now to apply this removal?" "N"; then
          recreate_workspace="$(_dk_workspace_host_current 2>/dev/null || _dk_workspace_host_abs)"
          CAC_WORKSPACE_HOST="$recreate_workspace" _dk_compose up -d --force-recreate || return 1
          if ! _dk_wait_runtime_ready; then
            _dk_abort_startup
            _err "Container did not become ready after removing the mount"
            return 1
          fi
          _ok "Running container recreated"
        else
          _info "Saved only. Restart or recreate the Docker container later to remove the mount."
        fi
      else
        _info "Saved only. The removal will apply on the next create/start/restart."
      fi
      ;;
    ""|help|-h|--help)
      cat <<'EOF'
Usage: cac docker mount <subcommand>

  add <host_dir> [container_path]   Add a read-write host bind mount
  ls                                List configured extra mounts
  rm <container_path>               Remove a configured extra mount

Notes:
  - If container_path is omitted, the default is /mnt/<host_dir_basename>
  - Mounts apply only to the main container
  - Mount targets like /, /root, /home, and /workspace are rejected
EOF
      ;;
    *)
      _err "Unknown docker mount subcommand: $action"
      _info "Use: cac docker mount help"
      return 1
      ;;
  esac
}

_dk_cmd_direct() {
  _dk_init || return 1
  local action="${1:-}" current="" updated="" dns_server="" state="" changed=0
  shift 2>/dev/null || true
  _dk_load_env

  case "$action" in
    add)
      if [[ "$#" -lt 1 ]]; then
        _err "Usage: cac docker direct add <keyword> [keyword...]"
        return 1
      fi
      current="$(_dk_read_env CAC_DIRECT_DOMAIN_KEYWORDS)"
      updated="$(_dk_direct_keywords_update add "$current" "$@")" || return 1
      if [[ "$updated" == "$current" ]]; then
        _ok "Direct domain keywords unchanged"
      else
        _dk_write_env CAC_DIRECT_DOMAIN_KEYWORDS "$updated"
        _dk_load_env
        _dk_refresh_mihomo_chain_configs || return 1
        _ok "Direct domain keyword(s) saved"
        changed=1
      fi
      ;;
    ls|list)
      current="$(_dk_read_env CAC_DIRECT_DOMAIN_KEYWORDS)"
      dns_server="$(_dk_read_env CAC_DIRECT_DNS_SERVER)"
      dns_server="${dns_server:-$(_dk_read_env DNS_SERVER)}"
      dns_server="${dns_server:-https://1.1.1.1/dns-query}"
      echo ""
      printf "\033[1mcac docker direct ls\033[0m\n"
      echo ""
      _info "Direct DNS: \033[1m${dns_server}\033[0m"
      if [[ -z "$current" ]]; then
        _info "No direct domain keywords configured."
      else
        _info "Direct domain keywords:"
        _dk_direct_keywords_print "$current" | sed 's/^/  - /'
      fi
      return 0
      ;;
    rm|remove|del|delete)
      if [[ "$#" -lt 1 ]]; then
        _err "Usage: cac docker direct rm <keyword> [keyword...]"
        return 1
      fi
      current="$(_dk_read_env CAC_DIRECT_DOMAIN_KEYWORDS)"
      updated="$(_dk_direct_keywords_update rm "$current" "$@")" || return 1
      if [[ "$updated" == "$current" ]]; then
        _ok "Direct domain keywords unchanged"
      else
        if [[ -n "$updated" ]]; then
          _dk_write_env CAC_DIRECT_DOMAIN_KEYWORDS "$updated"
        else
          _dk_delete_env_keys CAC_DIRECT_DOMAIN_KEYWORDS
        fi
        _dk_load_env
        _dk_refresh_mihomo_chain_configs || return 1
        _ok "Direct domain keyword(s) removed"
        changed=1
      fi
      ;;
    ""|help|-h|--help)
      cat <<'EOF'
Usage: cac docker direct <subcommand>

  add <keyword> [keyword...]   Add domain keywords that use direct DNS and direct route
  ls                           List direct domain keywords
  rm <keyword> [keyword...]    Remove direct domain keywords

Examples:
  cac docker direct add akamai-access.com timeresearch rockbund
  cac docker direct ls
  cac docker direct rm timeresearch
EOF
      return 0
      ;;
    *)
      _err "Unknown docker direct subcommand: $action"
      _info "Use: cac docker direct help"
      return 1
      ;;
  esac

  _dk_cmd_direct ls
  if [[ "$changed" -eq 0 ]]; then
    return 0
  fi
  state="$(_dk_container_state)"
  if [[ "$state" == "running" ]]; then
    echo ""
    _warn "The running container still uses its current sing-box runtime config."
    if _dk_prompt_yes_no "Restart now to apply direct domain changes?" "N"; then
      _dk_cmd_restart || return 1
      _info "Next: \033[1mcac docker check\033[0m"
    else
      _info "Saved only. Apply later with: \033[1mcac docker restart\033[0m"
    fi
  else
    _info "Changes will apply on the next create/start/restart."
  fi
}

# ── Docker subcommands ───────────────────────────────────────────────

_dk_cmd_setup() {
  _dk_init || return 1
  echo ""
  printf "\033[1mcac docker setup\033[0m\n"
  echo ""

  local proxy prompt_proxy_default mode detected_mode docker_dir data_dir prior_data_dir data_dir_abs prior_data_dir_abs data_state_summary container_name runtime_hostname gateway_name child_proxy child_no_proxy image_ref ssh_enabled ssh_bind ssh_port ssh_password web_enabled web_port web_bind current_state prior_proxy prior_proxy_kind proxy_kind="uri" proxy_chain_yaml="" proxy_changed=0 proxy_probe_ok=0 running_workspace new_workspace preferred_shell shell_choice shell_changed=0 data_dir_changed=0 restart_reason="saved settings" control_subnet proxy_ip client_ip bridge_ip cleanup_tmp
  prior_proxy="$(_dk_read_env PROXY_URI)"
  prior_proxy_kind="$(_dk_read_env CAC_PROXY_CONFIG_KIND)"
  current_state="$(_dk_container_state)"
  prompt_proxy_default="$prior_proxy"
  [[ "$prior_proxy_kind" == "mihomo-chain" ]] && prompt_proxy_default=""
  proxy=$(_dk_prompt_value "Proxy URI (host:port, http:// / socks5h://, YAML path, or share links socks:// / ss:// / vmess:// / vless:// / trojan://)" "$prompt_proxy_default" 1) || return 1

  detected_mode=$(_dk_detect_mode)
  mode="$detected_mode"
  if proxy_chain_yaml="$(_dk_yaml_file_abs "$proxy" 2>/dev/null)"; then
    proxy_kind="mihomo-chain"
    proxy="$proxy_chain_yaml"
    _info "Mihomo YAML detected; generating a sing-box TUN chain config"
  else
    proxy_chain_yaml=""
    proxy="$(_dk_normalize_proxy_uri "$mode" "$proxy")"
  fi
  if [[ "$proxy" != "$prior_proxy" || "$proxy_kind" != "${prior_proxy_kind:-uri}" ]]; then
    proxy_changed=1
    if [[ "$proxy_kind" == "uri" ]]; then
      case "$proxy" in
        host.docker.internal:*|*://*host.docker.internal:*)
          _info "Local Docker mode detected, using \033[1m${proxy}\033[0m for host-side proxy access"
          ;;
      esac
    fi
  fi
  if [[ "$proxy_kind" == "mihomo-chain" ]]; then
    _dk_write_env PROXY_URI "mihomo-chain://generated"
  else
    _dk_write_env PROXY_URI "$proxy"
  fi
  _dk_write_env CAC_PROXY_CONFIG_KIND "$proxy_kind"
  _dk_write_env DEPLOY_MODE "$mode"

  echo ""
  if [[ "$mode" == "local" ]]; then
    _info "Detected: \033[1mlocal laptop\033[0m (Docker Desktop)"
    _info "Mode: bridge network — main container isolated, child containers use host Docker"
    _dk_delete_env_keys HOST_INTERFACE MACVLAN_SUBNET MACVLAN_GATEWAY MACVLAN_IP SHIM_IP
  else
    _info "Detected: \033[1mremote server\033[0m (native Linux Docker)"
    _info "Mode: macvlan — main container isolated from host, child containers use host Docker"
    echo ""
    _info "Detecting network..."
    if ! _dk_detect_network; then
      _warn "Auto-detect failed, enter the required remote network values"
      _dk_write_env HOST_INTERFACE "$(_dk_prompt_value "Host interface" "$(_dk_read_env HOST_INTERFACE)" 1)" || return 1
      _dk_write_env MACVLAN_SUBNET "$(_dk_prompt_value "Macvlan subnet (CIDR)" "$(_dk_read_env MACVLAN_SUBNET)" 1)" || return 1
      _dk_write_env MACVLAN_GATEWAY "$(_dk_prompt_value "Macvlan gateway" "$(_dk_read_env MACVLAN_GATEWAY)" 1)" || return 1
      _dk_write_env MACVLAN_IP "$(_dk_prompt_value "Container IP" "$(_dk_read_env MACVLAN_IP)" 1)" || return 1
      _dk_write_env SHIM_IP "$(_dk_prompt_value "Shim IP" "$(_dk_read_env SHIM_IP)" 1)" || return 1
    fi
  fi

  echo ""
  prior_data_dir="$(_dk_read_env CAC_DATA)"
  prior_data_dir="${prior_data_dir:-./data}"
  data_dir="${CAC_DATA:-$prior_data_dir}"
  data_dir="${data_dir:-./data}"
  prior_data_dir_abs="$(_dk_data_dir_abs "$prior_data_dir")"
  data_dir_abs="$(_dk_data_dir_abs "$data_dir")"
  if [[ "$data_dir_abs" != "$prior_data_dir_abs" ]]; then
    data_dir_changed=1
    echo ""
    _warn "Changing \033[1mCAC_DATA\033[0m switches the persisted Claude state location."
    _info "Current data path: \033[1m${prior_data_dir_abs}\033[0m"
    _info "Requested data path: \033[1m${data_dir_abs}\033[0m"
    if _dk_claude_state_detected "$prior_data_dir_abs"; then
      _warn "Existing Claude login/session data was detected in the current data directory."
    else
      _info "No Claude state was detected in the current data directory."
    fi
    if _dk_claude_state_detected "$data_dir_abs"; then
      _warn "Claude state was also detected in the requested data directory."
    else
      _info "No Claude state was detected in the requested data directory yet."
    fi
    if ! _dk_prompt_yes_no "Switch Docker data storage to the new directory?" "N"; then
      _warn "Aborted to avoid switching Claude state directories implicitly."
      return 1
    fi
  fi
  data_state_summary="$(_dk_claude_state_summary "$data_dir_abs")"
  container_name="${CAC_CONTAINER_NAME:-$(_dk_read_env CAC_CONTAINER_NAME)}"
  container_name="${container_name:-boris-main}"
  runtime_hostname="${CAC_CONTAINER_RUNTIME_HOSTNAME:-$(_dk_read_env CAC_CONTAINER_RUNTIME_HOSTNAME)}"
  runtime_hostname="${runtime_hostname:-$container_name}"
  gateway_name="${CAC_DOCKER_PROXY_NAME:-$(_dk_read_env CAC_DOCKER_PROXY_NAME)}"
  gateway_name="${gateway_name:-boris-gateway}"
  ssh_enabled="${CAC_ENABLE_SSH:-$(_dk_read_env CAC_ENABLE_SSH)}"
  ssh_enabled="${ssh_enabled:-1}"
  ssh_bind="${CAC_HOST_SSH_BIND:-$(_dk_read_env CAC_HOST_SSH_BIND)}"
  ssh_bind="${ssh_bind:-127.0.0.1}"
  ssh_port="${CAC_HOST_SSH_PORT:-$(_dk_read_env CAC_HOST_SSH_PORT)}"
  ssh_port="${ssh_port:-2222}"
  web_enabled="${CAC_ENABLE_WEB:-$(_dk_read_env CAC_ENABLE_WEB)}"
  web_enabled="${web_enabled:-1}"
  web_port="${CAC_HOST_WEB_PORT:-$(_dk_read_env CAC_HOST_WEB_PORT)}"
  web_port="${web_port:-3001}"
  web_bind="${CAC_HOST_WEB_BIND:-$(_dk_read_env CAC_HOST_WEB_BIND)}"
  web_bind="${web_bind:-127.0.0.1}"
  ssh_password="${CAC_SSH_PASSWORD:-$(_dk_read_env CAC_SSH_PASSWORD)}"
  if [[ -z "$ssh_password" || "$ssh_password" == "cherny" ]]; then
    ssh_password="$(_dk_random_secret)"
  fi
  preferred_shell="${CAC_FAKE_SHELL:-$(_dk_read_env CAC_FAKE_SHELL)}"
  preferred_shell="${preferred_shell:-/bin/zsh}"
  shell_choice="$(_dk_prompt_value "Default interactive shell (bash or zsh)" "${preferred_shell##*/}" 1)" || return 1
  case "$shell_choice" in
    bash|zsh)
      preferred_shell="/bin/${shell_choice}"
      ;;
    *)
      _err "Unsupported shell choice: ${shell_choice}"
      return 1
      ;;
  esac
  if [[ "$preferred_shell" != "$(_dk_read_env CAC_FAKE_SHELL)" ]]; then
    shell_changed=1
  fi
  image_ref="${CAC_DOCKER_IMAGE:-$(_dk_read_env CAC_DOCKER_IMAGE)}"
  if [[ -z "$image_ref" ]]; then
    image_ref="$(_dk_default_image_ref)"
  elif [[ -z "${CAC_DOCKER_IMAGE:-}" ]] && _dk_is_legacy_default_image_ref "$image_ref"; then
    _warn "Migrating old default Docker image ref '$image_ref' to '$(_dk_default_image_ref)'"
    image_ref="$(_dk_default_image_ref)"
  elif ! _dk_is_pinned_image_ref "$image_ref"; then
    if [[ -n "${CAC_DOCKER_IMAGE:-}" ]]; then
      _err "CAC_DOCKER_IMAGE must be pinned to an exact tag or digest, not '$image_ref'"
      return 1
    fi
    _warn "Replacing mutable Docker image ref '$image_ref' with pinned default '$(_dk_default_image_ref)'"
    image_ref="$(_dk_default_image_ref)"
  fi
  _dk_prepare_child_proxy_bridge_env
  _dk_load_env
  control_subnet="${CAC_DOCKER_CONTROL_SUBNET:-$(_dk_read_env CAC_DOCKER_CONTROL_SUBNET)}"
  control_subnet="${control_subnet:-172.31.255.0/24}"
  proxy_ip="${CAC_DOCKER_PROXY_IP:-$(_dk_read_env CAC_DOCKER_PROXY_IP)}"
  proxy_ip="${proxy_ip:-$(_dk_control_ip_from_subnet "$control_subnet" 2)}"
  client_ip="${CAC_DOCKER_CLIENT_IP:-$(_dk_read_env CAC_DOCKER_CLIENT_IP)}"
  client_ip="${client_ip:-$(_dk_control_ip_from_subnet "$control_subnet" 3)}"
  bridge_ip="${CAC_CHILD_PROXY_BRIDGE_IP:-$(_dk_read_env CAC_CHILD_PROXY_BRIDGE_IP)}"
  bridge_ip="${bridge_ip:-$(_dk_control_ip_from_subnet "$control_subnet" 4)}"
  child_proxy="${CAC_CHILD_CONTAINER_PROXY_URL:-$(_dk_read_env CAC_CHILD_CONTAINER_PROXY_URL)}"
  child_no_proxy="${CAC_CHILD_CONTAINER_NO_PROXY:-$(_dk_read_env CAC_CHILD_CONTAINER_NO_PROXY)}"
  child_no_proxy="${child_no_proxy:-$(_dk_default_child_no_proxy "$mode")}"

  if [[ "$proxy_kind" == "mihomo-chain" ]]; then
    _dk_write_env CAC_PROXY_CHAIN_SOURCE "$proxy_chain_yaml"
    _dk_refresh_mihomo_chain_configs "$proxy_chain_yaml" "$control_subnet" || return 1
  else
    _dk_delete_env_keys CAC_SINGBOX_CONFIG_B64 CAC_PROXY_BRIDGE_CONFIG_B64 CAC_PROXY_CHAIN_SOURCE CAC_PROXY_CHAIN_POLICY
  fi

  docker_dir=$(_docker_dir)
  if [[ "$data_dir" == /* ]]; then
    mkdir -p "${data_dir}/root" "${data_dir}/home"
  else
    mkdir -p "${docker_dir}/${data_dir#./}/root" "${docker_dir}/${data_dir#./}/home"
  fi

  local build_local
  build_local="${CAC_DOCKER_BUILD_LOCAL:-$(_dk_read_env CAC_DOCKER_BUILD_LOCAL)}"
  build_local="${build_local:-$(_dk_default_build_local)}"

  _dk_write_env CAC_DATA "$data_dir"
  _dk_write_env CAC_CONTAINER_NAME "$container_name"
  _dk_write_env CAC_CONTAINER_RUNTIME_HOSTNAME "$runtime_hostname"
  _dk_write_env CAC_DOCKER_IMAGE "$image_ref"
  _dk_write_env CAC_DOCKER_BUILD_LOCAL "$build_local"
  _dk_write_env CAC_CHILD_CONTAINER_NETWORK_MODE "bridge"
  _dk_write_env CAC_DOCKER_PROXY_NAME "$gateway_name"
  _dk_write_env CAC_DOCKER_PROXY_IP "$proxy_ip"
  _dk_write_env CAC_DOCKER_CLIENT_IP "$client_ip"
  _dk_write_env CAC_CHILD_PROXY_BRIDGE_IP "$bridge_ip"
  _dk_write_env CAC_DOCKER_CONTROL_SUBNET "$control_subnet"
  _dk_write_env CAC_CONTAINER_DOCKER_HOST "tcp://${gateway_name}:2375"
  _dk_write_env CAC_CHILD_CONTAINER_PROXY_URL "$child_proxy"
  _dk_write_env CAC_CHILD_CONTAINER_NO_PROXY "$child_no_proxy"
  _dk_write_env CAC_ENABLE_SSH "$ssh_enabled"
  _dk_write_env CAC_HOST_SSH_BIND "$ssh_bind"
  _dk_write_env CAC_HOST_SSH_PORT "$ssh_port"
  _dk_write_env CAC_SSH_PASSWORD "$ssh_password"
  _dk_write_env CAC_ENABLE_WEB "$web_enabled"
  _dk_write_env CAC_HOST_WEB_BIND "$web_bind"
  _dk_write_env CAC_HOST_WEB_PORT "$web_port"
  _dk_write_env CAC_FAKE_SHELL "$preferred_shell"
  [[ -n "${CAC_DIRECT_DOMAIN_KEYWORDS:-$(_dk_read_env CAC_DIRECT_DOMAIN_KEYWORDS)}" ]] && \
    _dk_write_env CAC_DIRECT_DOMAIN_KEYWORDS "${CAC_DIRECT_DOMAIN_KEYWORDS:-$(_dk_read_env CAC_DIRECT_DOMAIN_KEYWORDS)}"
  [[ -n "${CAC_DIRECT_DNS_SERVER:-$(_dk_read_env CAC_DIRECT_DNS_SERVER)}" ]] && \
    _dk_write_env CAC_DIRECT_DNS_SERVER "${CAC_DIRECT_DNS_SERVER:-$(_dk_read_env CAC_DIRECT_DNS_SERVER)}"
  if [[ -f "$_dk_env_file" ]]; then
    cleanup_tmp=$(mktemp)
    grep -v -E '^(DOCKER_HOST|CAC_WORKSPACE_HOST)=' "$_dk_env_file" > "$cleanup_tmp" && mv "$cleanup_tmp" "$_dk_env_file"
  fi

  _ok "Config saved"
  echo ""
  if [[ "$proxy_kind" == "mihomo-chain" ]]; then
    _info "Proxy: \033[1mMihomo YAML chain\033[0m"
  else
    _info "Proxy: \033[1m${proxy}\033[0m"
  fi
  _info "Mode: \033[1m${mode}\033[0m"
  _info "Data dir: \033[1m${data_dir}\033[0m"
  _info "Data dir abs: \033[1m${data_dir_abs}\033[0m"
  _info "Claude state: \033[1m${data_state_summary}\033[0m"
  _info "Image: \033[1m${image_ref}\033[0m"
  if _dk_wants_local_build; then
    _info "Build mode: \033[1mlocal source build\033[0m"
  else
    _info "Build mode: \033[1mpinned image pull\033[0m"
  fi
  _info "Container: \033[1m${container_name}\033[0m (hostname: ${runtime_hostname})"
  _info "Shell: \033[1m${preferred_shell}\033[0m"
  [[ -n "$child_proxy" ]] && _info "Child proxy: \033[1m$(_dk_mask_proxy_display "$child_proxy")\033[0m"
  if [[ "$ssh_enabled" != "0" ]]; then
    _info "SSH: \033[1mssh -p ${ssh_port} ${CAC_FAKE_USER:-cherny}@127.0.0.1\033[0m"
  fi
  if [[ "$web_enabled" != "0" ]]; then
    _info "Web UI: \033[1mhttp://127.0.0.1:${web_port}\033[0m (bind: ${web_bind})"
  fi
  _info "Workspace mount: \033[1m$(_dk_workspace_host_abs)\033[0m → /workspace (current directory at start time)"
  _info "Container Docker API: \033[1mtcp://${gateway_name}:2375\033[0m (via docker-proxy sidecar)"
  _dk_warn_web_exposure
  echo ""
  if [[ "$proxy_kind" == "mihomo-chain" ]]; then
    proxy_probe_ok=1
    _info "Proxy probe skipped for Mihomo YAML chain mode; validate runtime with \033[1mcac docker check\033[0m."
  elif _dk_probe_proxy_uri "$proxy" "$mode"; then
    proxy_probe_ok=1
  else
    _warn "The new proxy was saved, but the quick probe failed."
    _info "The final runtime validation is still \033[1mcac docker check\033[0m."
  fi

  if [[ "$current_state" == "running" && ( "$proxy_changed" -eq 1 || "$shell_changed" -eq 1 || "$data_dir_changed" -eq 1 ) ]]; then
    echo ""
    running_workspace="$(_dk_workspace_host_current 2>/dev/null || true)"
    new_workspace="$(_dk_workspace_host_abs)"
    _warn "A Docker container is already running for this install."
    [[ -n "$running_workspace" ]] && _info "Current running workspace: \033[1m${running_workspace}\033[0m"
    _info "If you restart now from this shell, /workspace will mount: \033[1m${new_workspace}\033[0m"
    if [[ "$proxy_changed" -eq 1 && "$proxy_probe_ok" -eq 0 ]]; then
      _warn "Skipping automatic restart because the new proxy did not pass the quick check."
      _info "Saved only. Fix or verify the proxy first, then restart manually."
      return 0
    fi

    if [[ "$proxy_changed" -eq 1 && "$shell_changed" -eq 1 && "$data_dir_changed" -eq 1 ]]; then
      restart_reason="saved proxy, shell, and data directory"
    elif [[ "$proxy_changed" -eq 1 && "$data_dir_changed" -eq 1 ]]; then
      restart_reason="saved proxy and data directory"
    elif [[ "$shell_changed" -eq 1 && "$data_dir_changed" -eq 1 ]]; then
      restart_reason="saved shell and data directory"
    elif [[ "$proxy_changed" -eq 1 ]]; then
      restart_reason="saved proxy"
    elif [[ "$shell_changed" -eq 1 ]]; then
      restart_reason="saved shell"
    elif [[ "$data_dir_changed" -eq 1 ]]; then
      restart_reason="saved data directory"
    fi
    if _dk_prompt_yes_no "Restart the running Docker container now to apply the ${restart_reason}?" "N"; then
      _warn "Restarting now so the saved settings take effect..."
      _dk_cmd_restart || return 1
      echo ""
      _info "Next: \033[1mcac docker check\033[0m"
      return 0
    fi

    _info "Saved only. The running container keeps its current runtime state until you restart it manually."
    return 0
  fi

  _info "Next: \033[1mcac docker create\033[0m"
}

_dk_cmd_create() {
  _dk_init || return 1
  [[ ! -f "$_dk_env_file" ]] && { _warn "No config found, running setup first..."; _dk_cmd_setup; }
  _dk_load_env
  _dk_prepare_child_proxy_bridge_env
  echo ""
  if _dk_should_build_local; then
    _dk_build_runtime_image_locally || return 1
  else
    _dk_prepare_pinned_runtime_image || return 1
  fi
  echo ""
  _dk_assert_docker_cli_compat || return 1
  _ok "Image ready"
  _info "Start with: \033[1mcac docker start\033[0m"
}

_dk_cmd_start() {
  _dk_init || return 1
  local ssh_enabled ssh_port web_port current_state running_workspace requested_workspace
  [[ ! -f "$_dk_env_file" ]] && { _warn "No config found, running setup first..."; _dk_cmd_setup; }
  _dk_load_env
  current_state="$(_dk_container_state)"
  if [[ "$current_state" == "running" ]]; then
    running_workspace="$(_dk_workspace_host_current 2>/dev/null || echo "")"
    requested_workspace="$(_dk_workspace_host_abs 2>/dev/null || echo "")"
    _ok "Container already running"
    [[ -n "$running_workspace" ]] && _info "Workspace:    \033[1m/workspace\033[0m (host: ${running_workspace})"
    if [[ -n "$requested_workspace" && -n "$running_workspace" && "$requested_workspace" != "$running_workspace" ]]; then
      _info "Current directory would mount as /workspace after restart: \033[1m${requested_workspace}\033[0m"
      _info "Use: \033[1mcac docker restart\033[0m"
    fi
    _info "Enter with:   \033[1mcac docker enter\033[0m"
    _info "Check with:   \033[1mcac docker check\033[0m"
    return 0
  fi
  _dk_prepare_host_ports "$current_state" || return 1
  _dk_maybe_migrate_child_proxy
  _dk_assert_docker_cli_compat || return 1
  _info "Starting container..."
  if _dk_should_build_local; then
    if _dk_force_local_rebuild; then
      _info "Rebuilding local images first..."
      _dk_compose up -d --build
    elif ! _dk_host_docker image inspect "$_dk_image" >/dev/null 2>&1; then
      _info "Local image missing, building first..."
      _dk_compose up -d --build
    else
      _dk_compose up -d
    fi
  else
    if ! _dk_host_docker image inspect "$_dk_image" >/dev/null 2>&1; then
      _dk_prepare_pinned_runtime_image || return 1
    fi
    _dk_compose up -d
  fi
  _dk_shim_up

  local state
  if _dk_wait_runtime_ready; then
    state="$(_dk_container_state)"
    ssh_enabled="${CAC_ENABLE_SSH:-$(_dk_read_env CAC_ENABLE_SSH)}"
    ssh_enabled="${ssh_enabled:-1}"
    ssh_port="${CAC_HOST_SSH_PORT:-$(_dk_read_env CAC_HOST_SSH_PORT)}"
    ssh_port="${ssh_port:-2222}"
    _ok "Container running"
    _info "Enter with:   \033[1mcac docker enter\033[0m"
    _info "Check with:   \033[1mcac docker check\033[0m"
    if [[ "$ssh_enabled" != "0" ]]; then
      _info "SSH with:     \033[1mssh -p ${ssh_port} ${CAC_FAKE_USER:-cherny}@127.0.0.1\033[0m"
    fi
    if _dk_web_enabled; then
      web_port="$(_dk_web_port)"
      _info "Web UI:       \033[1mhttp://127.0.0.1:${web_port}\033[0m"
    fi
    _dk_warn_web_exposure
    _info "Forward port: \033[1mcac docker port <port>\033[0m"
    _info "Workspace:    \033[1m/workspace\033[0m (host: $(_dk_workspace_host_current 2>/dev/null || echo unset))"
  else
    state="$(_dk_container_state)"
    _err "Container state: $state"
    _dk_abort_startup
    _info "Logs: cac docker logs"
    return 1
  fi
}

_dk_cmd_stop() {
  _dk_init || return 1
  _dk_port_stop_all
  _dk_shim_down
  _info "Stopping container..."
  _dk_compose down
  _ok "Stopped"
}

_dk_cmd_restart() {
  local workspace_host
  workspace_host="$(_dk_workspace_host_abs 2>/dev/null || echo "")"
  [[ -n "$workspace_host" ]] && _info "Restarting with workspace: \033[1m${workspace_host}\033[0m → /workspace"
  _dk_cmd_stop || return 1
  _dk_cmd_start
}

_dk_project_image_cleanup_candidates() {
  local current_id protected_file images_file repo
  protected_file="$(mktemp)"
  images_file="$(mktemp)"

  current_id="$(_dk_host_docker image inspect -f '{{.Id}}' "$_dk_image" 2>/dev/null || true)"
  [[ -n "$current_id" ]] && printf '%s\n' "$current_id" >> "$protected_file"

  for repo in \
    "$_dk_image" \
    "docker-docker-proxy:latest" \
    "docker-proxy-bridge:latest"
  do
    _dk_host_docker image inspect -f '{{.Id}}' "$repo" 2>/dev/null >> "$protected_file" || true
  done

  while IFS= read -r container_id; do
    [[ -n "$container_id" ]] || continue
    _dk_host_docker inspect -f '{{.Image}}' "$container_id" 2>/dev/null >> "$protected_file" || true
  done < <(_dk_host_docker ps -aq 2>/dev/null || true)

  _dk_host_docker image ls --no-trunc --filter "label=com.cac-docker-claude.project=true" \
    --format '{{.ID}}\t{{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}' 2>/dev/null >> "$images_file" || true
  for repo in \
    "ghcr.io/zmk112/cac-docker-claude" \
    "ghcr.io/zmk112/cac-docker" \
    "ghcr.io/nmhjklnm/cac-docker"
  do
    _dk_host_docker image ls --no-trunc "$repo" \
      --format '{{.ID}}\t{{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}' 2>/dev/null >> "$images_file" || true
  done

  awk -F '\t' '
    NR == FNR {
      if ($1 != "") protected[$1] = 1
      next
    }
    {
      id=$1; repo=$2; tag=$3; size=$4; created=$5
      if (id == "" || seen[id "|" repo "|" tag]++) next
      if (id in protected) next
      if (repo == "<none>" || tag == "<none>") ref=id
      else ref=repo ":" tag
      print ref "\t" repo "\t" tag "\t" size "\t" created
    }
  ' "$protected_file" "$images_file"

  rm -f "$protected_file" "$images_file"
}

_dk_prompt_cleanup_project_images() {
  local candidates ref size created removed=0 failed=0
  candidates="$(_dk_project_image_cleanup_candidates)"
  [[ -n "$candidates" ]] || return 0

  echo ""
  _warn "Found old cac-docker-claude images that are not used by current containers."
  while IFS=$'\t' read -r ref _repo _tag size created; do
    [[ -n "$ref" ]] || continue
    printf '  %s  %s  %s\n' "$ref" "${size:-unknown-size}" "${created:-unknown-age}"
  done <<< "$candidates"

  if ! _dk_prompt_yes_no "Remove these old project images now?" "N"; then
    _info "Skipped old image cleanup."
    return 0
  fi

  while IFS=$'\t' read -r ref _repo _tag _size _created; do
    [[ -n "$ref" ]] || continue
    if _dk_host_docker image rm "$ref"; then
      removed=$((removed + 1))
    else
      failed=$((failed + 1))
    fi
  done <<< "$candidates"

  if [[ "$failed" -eq 0 ]]; then
    _ok "Removed ${removed} old project image(s)"
  else
    _warn "Removed ${removed} old project image(s); ${failed} image(s) could not be removed"
  fi
}

_dk_cmd_rebuild() {
  _dk_init || return 1
  local state="not created"
  state="$(_dk_container_state)"

  CAC_DOCKER_REBUILD=1 _dk_cmd_create || return 1

  echo ""
  if [[ "$state" == "running" || "$state" == "exited" || "$state" == "created" || "$state" == "restarting" ]]; then
    _dk_load_env
    _dk_prepare_host_ports "$state" || return 1
    _dk_maybe_migrate_child_proxy
    _info "Recreating existing container to use the rebuilt image..."
    _dk_compose up -d --force-recreate || return 1
    if _dk_wait_runtime_ready; then
      _ok "Container recreated with rebuilt image"
      _info "Next: \033[1mcac docker check\033[0m"
    else
      _err "Container did not finish initialization after rebuild"
      _dk_abort_startup
      _info "Logs: \033[1mcac docker logs\033[0m"
      return 1
    fi
  else
    _info "Next: \033[1mcac docker start\033[0m"
  fi
  _dk_prompt_cleanup_project_images
}

_dk_cmd_enter() {
  _dk_init || return 1
  local shell_path
  shell_path="${CAC_FAKE_SHELL:-$(_dk_read_env CAC_FAKE_SHELL)}"
  shell_path="${shell_path:-/bin/bash}"
  _dk_compose exec -u "${CAC_FAKE_USER:-cherny}" "$_dk_service" "$shell_path" -l
}

_dk_cmd_check() {
  _dk_init || return 1
  local rc=0 ssh_enabled ssh_port web_port
  _dk_run_cac_check || rc=1
  ssh_enabled="${CAC_ENABLE_SSH:-$(_dk_read_env CAC_ENABLE_SSH)}"
  ssh_enabled="${ssh_enabled:-1}"
  ssh_port="${CAC_HOST_SSH_PORT:-$(_dk_read_env CAC_HOST_SSH_PORT)}"
  ssh_port="${ssh_port:-2222}"

  if [[ "$ssh_enabled" != "0" ]]; then
    printf "\033[1mHost Access\033[0m\n"
    if command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "${ssh_port}" >/dev/null 2>&1; then
      _ok "SSH: \033[1mssh -p ${ssh_port} ${CAC_FAKE_USER:-cherny}@127.0.0.1\033[0m"
    elif python3 - "$ssh_port" <<'PY' >/dev/null 2>&1
import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=3)
s.close()
PY
    then
      _ok "SSH: \033[1mssh -p ${ssh_port} ${CAC_FAKE_USER:-cherny}@127.0.0.1\033[0m"
    else
      _err "SSH port 127.0.0.1:${ssh_port} is not reachable"
      rc=1
    fi
    echo ""
  fi

  if _dk_web_enabled; then
    web_port="$(_dk_web_port)"
    if command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "${web_port}" >/dev/null 2>&1; then
      _ok "Web UI: \033[1mhttp://127.0.0.1:${web_port}\033[0m"
    elif python3 - "$web_port" <<'PY' >/dev/null 2>&1
import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=3)
s.close()
PY
    then
      _ok "Web UI: \033[1mhttp://127.0.0.1:${web_port}\033[0m"
    else
      _err "Web UI port 127.0.0.1:${web_port} is not reachable"
      rc=1
    fi
    echo ""
  fi

  echo ""
  printf "\033[1mExit IP Comparison\033[0m\n"
  echo ""

  local container_ip
  container_ip=$(_dk_compose exec -T "$_dk_service" timeout 10 curl -sf https://ifconfig.me 2>/dev/null || echo "")
  if [[ -n "$container_ip" ]]; then
    _ok "Container exit: \033[1m${container_ip}\033[0m"
  else
    _err "Container cannot reach ifconfig.me"
  fi

  local host_ip
  host_ip=$(timeout 10 curl -sf https://ifconfig.me 2>/dev/null || echo "")
  if [[ -n "$host_ip" ]]; then
    _ok "Host exit:      \033[1m${host_ip}\033[0m"
  else
    _info "Host cannot reach ifconfig.me (blocked or no proxy — this is fine)"
  fi

  echo ""
  if [[ -n "$container_ip" && -n "$host_ip" ]]; then
    if [[ "$container_ip" != "$host_ip" ]]; then
      _ok "Exit IPs differ — container uses a different network path than host"
    else
      _info "Exit IPs are the same — verify \033[1m${container_ip}\033[0m is your proxy's exit IP"
    fi
  elif [[ -n "$container_ip" && -z "$host_ip" ]]; then
    _ok "Container can reach internet, host cannot — proxy is working"
  fi
  echo ""
  return "$rc"
}

_dk_cmd_port() {
  _dk_init || return 1
  local subcmd="${1:-}" port="${2:-}"
  case "$subcmd" in
    ""|ls|list)   _dk_port_list ;;
    stop)
      if [[ -z "$port" ]]; then
        _dk_port_stop_all; _ok "All port forwarders stopped"
      else
        _dk_port_stop "$port"
      fi ;;
    [0-9]*)       _dk_port_forward "$subcmd" ;;
    *)
      echo "Usage:"
      echo "  cac docker port <port>       Forward localhost:port to container"
      echo "  cac docker port list         List active forwarders"
      echo "  cac docker port stop [port]  Stop forwarder(s)" ;;
  esac
}

_dk_cmd_logs() {
  _dk_init || return 1
  _dk_compose logs --tail=50 -f "$_dk_service"
}

_dk_cmd_status() {
  _dk_init || return 1
  _dk_load_env
  local web_enabled web_port
  echo ""
  printf "\033[1mcac docker status\033[0m\n"
  echo ""

  printf "  Mode:       %s\n" "$(_dk_get_mode)"

  local proxy
  proxy=$(_dk_read_env PROXY_URI)
  if [[ -n "$proxy" ]]; then
    local dp
    if [[ "$proxy" == *"://"* ]]; then dp="${proxy%%://*}://***"
    else IFS=: read -r _h _p _rest <<< "$proxy"; dp="${_h}:${_p}:***"; fi
    printf "  Proxy:      %s\n" "$dp"
  else
    printf "  Proxy:      \033[33mnot configured\033[0m\n"
  fi

  if [[ "$(_dk_get_mode)" == "remote" ]]; then
    local cip; cip=$(_dk_read_env MACVLAN_IP)
    [[ -n "$cip" ]] && printf "  Container:  %s\n" "$cip"
  fi
  local workspace_host child_net docker_host child_proxy ssh_enabled ssh_port data_dir_raw data_dir_abs data_state_summary
  workspace_host=$(_dk_workspace_host_current 2>/dev/null || echo "")
  child_net=$(_dk_read_env CAC_CHILD_CONTAINER_NETWORK_MODE)
  docker_host=$(_dk_read_env CAC_CONTAINER_DOCKER_HOST)
  child_proxy=$(_dk_read_env CAC_CHILD_CONTAINER_PROXY_URL)
  ssh_enabled=$(_dk_read_env CAC_ENABLE_SSH)
  ssh_enabled="${ssh_enabled:-1}"
  ssh_port=$(_dk_read_env CAC_HOST_SSH_PORT)
  ssh_port="${ssh_port:-2222}"
  web_enabled=$(_dk_read_env CAC_ENABLE_WEB)
  web_enabled="${web_enabled:-1}"
  web_port=$(_dk_read_env CAC_HOST_WEB_PORT)
  web_port="${web_port:-3001}"
  data_dir_raw="$(_dk_data_dir_raw)"
  data_dir_abs="$(_dk_data_dir_abs "$data_dir_raw")"
  data_state_summary="$(_dk_claude_state_summary "$data_dir_abs")"
  printf "  Data dir:   %s\n" "$data_dir_raw"
  printf "  Data path:  %s\n" "$data_dir_abs"
  printf "  Claude:     %s\n" "$data_state_summary"
  [[ -n "$workspace_host" ]] && printf "  Workspace:  %s -> /workspace\n" "$workspace_host"
  [[ -n "$docker_host" ]] && printf "  Container Docker API: %s\n" "$docker_host"
  [[ -n "$child_net" ]] && printf "  Child net:  %s\n" "$child_net"
  [[ -n "$child_proxy" ]] && printf "  Child proxy:%s\n" " $(_dk_mask_proxy_display "$child_proxy")"
  local mount_lines
  mount_lines="$(_dk_mounts_list_tsv)"
  if [[ -n "$mount_lines" ]]; then
    printf "  Extra mounts:\n"
    while IFS=$'\t' read -r host_path target_path mode; do
      [[ -n "$target_path" ]] || continue
      printf "    %s -> %s (%s)\n" "$host_path" "$target_path" "${mode:-rw}"
    done <<< "$mount_lines"
  fi
  [[ "$ssh_enabled" != "0" ]] && printf "  SSH:        ssh -p %s %s@127.0.0.1\n" "$ssh_port" "${CAC_FAKE_USER:-cherny}"
  [[ "$web_enabled" != "0" ]] && printf "  Web UI:     http://127.0.0.1:%s\n" "$web_port"

  local state
  state="$(_dk_container_state)"
  case "$state" in
    running) printf "  Status:     \033[32mrunning\033[0m\n" ;;
    *)       printf "  Status:     \033[33m%s\033[0m\n" "$state" ;;
  esac

  local health
  health=$(_dk_compose ps --format '{{.Health}}' "$_dk_service" 2>/dev/null || echo "")
  [[ -n "$health" ]] && printf "  Health:     %s\n" "$health"

  echo ""
  _dk_warn_web_exposure
  echo ""
  printf "\033[1mPorts\033[0m\n"
  _dk_port_list
  echo ""
}

_dk_cmd_destroy() {
  _dk_init || return 1
  read -rp "Remove container and image? [y/N]: " confirm
  if [[ "$confirm" == [yY] ]]; then
    _dk_port_stop_all
    _dk_shim_down
    _dk_compose down --rmi local --volumes 2>/dev/null || true
    _ok "Removed"
  fi
}

_dk_cmd_update() {
  local repo="" force=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)
        repo="${2:-}"
        [[ -n "$repo" ]] || {
          _err "Usage: cac docker update [--force] [--repo owner/repo]"
          return 1
        }
        shift 2
        ;;
      --repo=*)
        repo="${1#--repo=}"
        [[ -n "$repo" ]] || {
          _err "Usage: cac docker update [--force] [--repo owner/repo]"
          return 1
        }
        shift
        ;;
      --force)
        force=1
        shift
        ;;
      *)
        _err "Usage: cac docker update [--force] [--repo owner/repo]"
        return 1
        ;;
    esac
  done
  _self_cmd_update_stable "$repo" "$force"
}

# ── Docker command dispatcher ────────────────────────────────────────

cmd_docker() {
  local subcmd="${1:-}"
  shift 2>/dev/null || true

  case "$subcmd" in
    setup)    _dk_cmd_setup ;;
    create)   _dk_cmd_create ;;
    rebuild)  _dk_cmd_rebuild ;;
    start)    _dk_cmd_start ;;
    stop)     _dk_cmd_stop ;;
    restart)  _dk_cmd_restart ;;
    enter)    _dk_cmd_enter ;;
    mount)    _dk_cmd_mount "$@" ;;
    direct)   _dk_cmd_direct "$@" ;;
    check)    _dk_cmd_check ;;
    port)     _dk_cmd_port "$@" ;;
    status)   _dk_cmd_status ;;
    logs)     _dk_cmd_logs ;;
    update)   _dk_cmd_update "$@" ;;
    destroy)  _dk_cmd_destroy ;;
    ""|help|-h|--help)
      cat <<'EOF'
Usage: cac docker <subcommand>

  setup      Configure proxy and network (interactive)
  create     Build or pull the image
  rebuild    Force rebuild, recreate if needed, then offer old-image cleanup
  start      Start the container; no-op if already running
  stop       Stop the container
  restart    Restart and remount the current directory as /workspace
  enter      Shell into the container
  mount      Manage extra host-directory mounts
  direct     Manage domain keywords that use direct DNS and direct route
  check      Diagnostics (network + identity)
  port       Forward a localhost port to the container
  status     Show current status
  logs       Follow container logs
  update     Update to the latest stable release with rollback; skips when current
  destroy    Remove container/network/images
EOF
      ;;
    *)
      _err "Unknown docker subcommand: $subcmd"
      _info "Use: cac docker help"
      return 1 ;;
  esac
}
