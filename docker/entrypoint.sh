#!/usr/bin/env bash
set -euo pipefail

SINGBOX_ENABLE="${SINGBOX_ENABLE:-1}"
DISABLE_IPV6="${DISABLE_IPV6:-1}"
HEALTHCHECK="${HEALTHCHECK:-1}"
CAC_PROFILE="${CAC_PROFILE:-default}"
CAC_ENABLE_WEB="${CAC_ENABLE_WEB:-1}"
CAC_WEB_PORT="${CAC_WEB_PORT:-3001}"
CHERNY_TEMPLATE_DIR="${CHERNY_TEMPLATE_DIR:-/usr/local/share/cherny}"
CHERNY_IDENTITY_JSON="${CHERNY_TEMPLATE_DIR}/cherny.identity.json"
CHERNY_ENV_JSON="${CHERNY_TEMPLATE_DIR}/cherny.env.json"
CHERNY_PROMPT_JSON="${CHERNY_TEMPLATE_DIR}/cherny.prompt.json"
CHERNY_TELEMETRY_JSON="${CHERNY_TEMPLATE_DIR}/cherny.telemetry.json"
CAC_ENABLE_SSH="${CAC_ENABLE_SSH:-1}"
CAC_SSH_PASSWORD="${CAC_SSH_PASSWORD:-}"
CAC_SSH_CONTAINER_PORT="${CAC_SSH_CONTAINER_PORT:-22}"
CAC_FAKE_USER="${CAC_FAKE_USER:-cherny}"
CAC_FAKE_UID="${CAC_FAKE_UID:-1001}"
CAC_FAKE_GID="${CAC_FAKE_GID:-1001}"
CAC_FAKE_HOME="${CAC_FAKE_HOME:-/home/${CAC_FAKE_USER}}"
CAC_FAKE_SHELL="${CAC_FAKE_SHELL:-/bin/bash}"
CAC_FAKE_OS_TYPE="${CAC_FAKE_OS_TYPE:-Linux}"
CAC_FAKE_OS_RELEASE="${CAC_FAKE_OS_RELEASE:-6.6.31-boris}"
CAC_FAKE_OS_VERSION="${CAC_FAKE_OS_VERSION:-Debian GNU/Linux 12}"
CAC_FAKE_OS_PRETTY_NAME="${CAC_FAKE_OS_PRETTY_NAME:-Debian GNU/Linux 12 (bookworm)}"
CAC_FAKE_DISTRO_ID="${CAC_FAKE_DISTRO_ID:-debian}"
CAC_FAKE_DISTRO_VERSION="${CAC_FAKE_DISTRO_VERSION:-12}"
CAC_FAKE_PROC_VERSION="${CAC_FAKE_PROC_VERSION:-Linux version ${CAC_FAKE_OS_RELEASE} (builder@${CAC_FAKE_USER}) #1 SMP PREEMPT_DYNAMIC}"
CAC_FAKE_TERM="${CAC_FAKE_TERM:-xterm-256color}"
CAC_FAKE_CGROUP_TEXT="${CAC_FAKE_CGROUP_TEXT:-0::/}"
CAC_FAKE_MOUNTINFO_TEXT="${CAC_FAKE_MOUNTINFO_TEXT:-24 23 0:1 / / rw,relatime - ext4 /dev/root rw}"
PROFILE_HOME="$CAC_FAKE_HOME"
CAC_RUNTIME_ENV_FILE="${PROFILE_HOME}/.cac-env"
PROFILE_BASHRC="${PROFILE_HOME}/.bashrc"
PROFILE_PROFILE="${PROFILE_HOME}/.profile"
PROFILE_BASH_PROFILE="${PROFILE_HOME}/.bash_profile"
PROFILE_ZSHRC="${PROFILE_HOME}/.zshrc"
PROFILE_ZPROFILE="${PROFILE_HOME}/.zprofile"
CAC_CLOUDCLI_ENV_FILE="/etc/cac-cloudcli.env"

unset ALL_PROXY HTTP_PROXY HTTPS_PROXY all_proxy http_proxy https_proxy \
      NO_PROXY no_proxy 2>/dev/null || true

mkdir -p /workspace

append_runtime_export() {
  printf 'export %s="%s"\n' "$1" "${2//\"/\\\"}" >> "$CAC_RUNTIME_ENV_FILE"
}

append_runtime_unset() {
  printf 'unset %s\n' "$1" >> "$CAC_RUNTIME_ENV_FILE"
}

normalize_proxy_for_cac() {
  local raw="${1:-}"
  [[ -n "$raw" ]] || return 0

  if [[ "$raw" != *"://"* ]]; then
    local h="" p="" u="" pw=""
    IFS=: read -r h p u pw <<< "$raw"
    if [[ -n "$h" && -n "$p" ]]; then
      if [[ -n "$u" ]]; then
        printf 'socks5://%s:%s@%s:%s\n' "$u" "$pw" "$h" "$p"
      else
        printf 'socks5://%s:%s\n' "$h" "$p"
      fi
    fi
    return 0
  fi

  printf '%s\n' "$raw"
}

proxy_env_url_for_disabled_singbox() {
  local raw="${1:-}"
  [[ -n "$raw" ]] || return 1

  if [[ "$raw" == *"://"* ]]; then
    case "$raw" in
      socks5://*|socks5h://*|http://*|https://*)
        printf '%s\n' "$raw"
        return 0
        ;;
      *)
        return 1
        ;;
    esac
  fi

  local h="" p="" u="" pw=""
  IFS=: read -r h p u pw <<< "$raw"
  [[ -n "$h" && -n "$p" ]] || return 1
  printf 'socks5h://%s%s:%s\n' "${u:+$u:$pw@}" "$h" "$p"
}

ensure_profile_home() {
  mkdir -p "$PROFILE_HOME" "$PROFILE_HOME/.local/bin"
  touch "$PROFILE_BASHRC" "$PROFILE_PROFILE" "$PROFILE_BASH_PROFILE" "$PROFILE_ZSHRC" "$PROFILE_ZPROFILE"
}

migrate_root_state() {
  [[ "$PROFILE_HOME" == "/root" ]] && return 0

  if [[ -d /root/.cac && ! -e "$PROFILE_HOME/.cac" ]]; then
    mv /root/.cac "$PROFILE_HOME/.cac"
  fi
  if [[ -f /root/.claude.json && ! -e "$PROFILE_HOME/.claude.json" ]]; then
    mv /root/.claude.json "$PROFILE_HOME/.claude.json"
  fi
  if [[ -f /root/.cac-env && ! -e "$CAC_RUNTIME_ENV_FILE" ]]; then
    mv /root/.cac-env "$CAC_RUNTIME_ENV_FILE"
  fi

  [[ -e "$PROFILE_HOME/.cac" ]] && ln -sfn "$PROFILE_HOME/.cac" /root/.cac 2>/dev/null || true
  [[ -e "$PROFILE_HOME/.claude.json" ]] && ln -sfn "$PROFILE_HOME/.claude.json" /root/.claude.json 2>/dev/null || true
  ln -sfn "$CAC_RUNTIME_ENV_FILE" /root/.cac-env 2>/dev/null || true
}

sync_shell_rc() {
  local rc
  for rc in \
    "$PROFILE_BASHRC" \
    "$PROFILE_PROFILE" \
    "$PROFILE_BASH_PROFILE" \
    "$PROFILE_ZSHRC" \
    "$PROFILE_ZPROFILE" \
    /root/.bashrc \
    /root/.profile \
    /root/.zshrc \
    /root/.zprofile
  do
    touch "$rc"
    grep -q 'cac-env' "$rc" 2>/dev/null || \
      echo '[ -f ~/.cac-env ] && . ~/.cac-env' >> "$rc"
  done
  grep -q 'docker-real' "$PROFILE_BASHRC" 2>/dev/null || \
    echo 'alias docker-real=/usr/local/bin/docker-real' >> "$PROFILE_BASHRC"
  grep -q 'docker-real' "$PROFILE_ZSHRC" 2>/dev/null || \
    echo 'alias docker-real=/usr/local/bin/docker-real' >> "$PROFILE_ZSHRC"
  grep -q 'docker-real' /root/.bashrc 2>/dev/null || \
    echo 'alias docker-real=/usr/local/bin/docker-real' >> /root/.bashrc
  grep -q 'docker-real' /root/.zshrc 2>/dev/null || \
    echo 'alias docker-real=/usr/local/bin/docker-real' >> /root/.zshrc
  printf '[ -f "%s" ] && . "%s"\n' "$CAC_RUNTIME_ENV_FILE" "$CAC_RUNTIME_ENV_FILE" > /etc/profile.d/cac-env.sh
}

write_default_tmux_conf() {
  local target="$1"
  if [[ -f "$target" ]] && ! grep -q 'cac-docker-claude default tmux' "$target" 2>/dev/null; then
    return 0
  fi
  cat > "$target" <<'EOF'
# cac-docker-claude default tmux

# =========================
# 基础
# =========================

set -g default-shell /usr/bin/zsh
set -g mouse on
set -g history-limit 100000

# 窗口/Pane 从 1 开始
set -g base-index 1
setw -g pane-base-index 1

# 自动重新编号
set -g renumber-windows on

# 更快 ESC 响应
set -sg escape-time 0

# =========================
# Terminal / 颜色
# =========================

set -g default-terminal "screen-256color"

# true color
set-option -sa terminal-overrides ",xterm-256color:Tc"
set-option -ga terminal-overrides ",*256col*:Tc"

# =========================
# Prefix
# =========================

unbind C-b
set -g prefix C-a
bind C-a send-prefix

# =========================
# 分屏
# =========================

unbind '"'
unbind %

bind | split-window -h
bind - split-window -v

# =========================
# Vim 风格 Pane 移动
# =========================

bind h select-pane -L
bind j select-pane -D
bind k select-pane -U
bind l select-pane -R

# =========================
# Vim 风格 Resize
# =========================

bind -r H resize-pane -L 5
bind -r J resize-pane -D 5
bind -r K resize-pane -U 5
bind -r L resize-pane -R 5

# =========================
# Reload Config
# =========================

bind r source-file ~/.tmux.conf \; display-message "tmux.conf reloaded"

# =========================
# Copy Mode
# =========================

setw -g mode-keys vi

bind-key -T copy-mode-vi v send -X begin-selection
bind-key -T copy-mode-vi y send -X copy-selection-and-cancel

# =========================
# Claude Code / Terminal Title
# =========================

# 允许程序修改标题
set -g allow-rename on

# 自动使用 pane title 更新 window 名
set -g automatic-rename on
set -g automatic-rename-format '#{pane_title}'

# 同步 terminal title
set -g set-titles on
set -g set-titles-string '#T'

# Pane border 显示 title
set -g pane-border-status top

# 当前 pane title
set -g pane-border-format '#{?pane_active,#[fg=green],#[fg=grey]} #{pane_index} #{pane_title} '

# =========================
# 状态栏
# =========================

set -g status-position bottom
set -g status-justify left

set -g status-style "bg=#1f2335,fg=#c0caf5"

set -g status-left-length 50
set -g status-right-length 120

set -g status-left "#[fg=#7aa2f7,bold] #S "

set -g status-right "#[fg=#a9b1d6]#(whoami)@#H #[fg=#7dcfff]%Y-%m-%d %H:%M "

# =========================
# Window 样式
# =========================

setw -g window-status-format " #I:#W "
setw -g window-status-current-format " #[fg=#1a1b26,bg=#7aa2f7,bold] #I:#W "

# =========================
# Pane Border
# =========================

set -g pane-border-style "fg=#3b4261"
set -g pane-active-border-style "fg=#7aa2f7"

# =========================
# Focus Event
# =========================

set -g focus-events on
EOF
}

configure_zsh_defaults_if_selected() {
  case "$(basename "$CAC_FAKE_SHELL")" in
    zsh) ;;
    *) return 0 ;;
  esac

  mkdir -p "$PROFILE_HOME"
  if [[ ! -e "$PROFILE_HOME/.oh-my-zsh" && -d /usr/local/share/oh-my-zsh ]]; then
    ln -s /usr/local/share/oh-my-zsh "$PROFILE_HOME/.oh-my-zsh"
  fi

  if [[ ! -f "$PROFILE_ZSHRC" ]] || ! grep -q 'oh-my-zsh.sh' "$PROFILE_ZSHRC" 2>/dev/null; then
    cat > "$PROFILE_ZSHRC" <<'EOF'
# cac-docker-claude default zsh
export ZSH="$HOME/.oh-my-zsh"
export ZSH_CUSTOM="/usr/local/share/zsh-plugins"
ZSH_THEME="agnoster"
plugins=(git zsh-autosuggestions zsh-syntax-highlighting)

source "$ZSH/oh-my-zsh.sh"

[ -f ~/.cac-env ] && . ~/.cac-env
alias docker-real=/usr/local/bin/docker-real
EOF
  fi

  write_default_tmux_conf "$PROFILE_HOME/.tmux.conf"
  chown -h "$CURRENT_RUNTIME_UID:$CURRENT_RUNTIME_GID" "$PROFILE_HOME/.oh-my-zsh" 2>/dev/null || true
  chown "$CURRENT_RUNTIME_UID:$CURRENT_RUNTIME_GID" "$PROFILE_ZSHRC" "$PROFILE_HOME/.tmux.conf" 2>/dev/null || true
}

write_runtime_shims() {
  local shim_dir="$CAC_DIR/shim-bin"
  mkdir -p "$shim_dir"

  cat > "$shim_dir/uname" <<'EOF'
#!/usr/bin/env bash
real_uname="/usr/bin/uname"
[[ -x "$real_uname" ]] || real_uname="/bin/uname"

case "${1:--s}" in
  -s) printf '%s\n' "${CAC_OS_TYPE:-Linux}" ;;
  -r) printf '%s\n' "${CAC_OS_RELEASE:-}" ;;
  -sr|-rs) printf '%s %s\n' "${CAC_OS_TYPE:-Linux}" "${CAC_OS_RELEASE:-}" ;;
  -a) printf '%s %s %s %s %s %s\n' "${CAC_OS_TYPE:-Linux}" "${CAC_HOSTNAME:-localhost}" "${CAC_OS_RELEASE:-}" "${CAC_OS_VERSION:-}" "$(date +%Z 2>/dev/null || true)" "$( "$real_uname" -m 2>/dev/null || echo x86_64)" ;;
  *) exec "$real_uname" "$@" ;;
esac
EOF

  cat > "$shim_dir/cat" <<'EOF'
#!/usr/bin/env bash
real_cat="/bin/cat"

for arg in "$@"; do
  case "$arg" in
    /etc/os-release|/usr/lib/os-release)
      printf 'PRETTY_NAME="%s"\n' "${CAC_OS_PRETTY_NAME:-Debian GNU/Linux 12 (bookworm)}"
      printf 'NAME="%s"\n' "${CAC_OS_VERSION:-Debian GNU/Linux}"
      printf 'VERSION_ID="%s"\n' "${CAC_LINUX_DISTRO_VERSION:-12}"
      printf 'VERSION="%s"\n' "${CAC_OS_VERSION:-Debian GNU/Linux 12}"
      printf 'ID=%s\n' "${CAC_LINUX_DISTRO_ID:-debian}"
      exit 0
      ;;
    /proc/version)
      printf '%s\n' "${CAC_PROC_VERSION:-}"
      exit 0
      ;;
    /proc/1/cgroup)
      printf '%s\n' "${CAC_CGROUP_TEXT:-0::/}"
      exit 0
      ;;
    /proc/1/mountinfo)
      printf '%s\n' "${CAC_MOUNTINFO_TEXT:-24 23 0:1 / / rw,relatime - ext4 /dev/root rw}"
      exit 0
      ;;
  esac
done

exec "$real_cat" "$@"
EOF

  cat > "$shim_dir/hostname" <<'EOF'
#!/usr/bin/env bash
if [[ "$#" -eq 0 ]]; then
  printf '%s\n' "${CAC_HOSTNAME:-localhost}"
  exit 0
fi
exec /bin/hostname "$@"
EOF

  cat > "$shim_dir/whoami" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${CAC_USERNAME:-${USER:-unknown}}"
EOF

  cat > "$shim_dir/id" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -u) printf '%s\n' "${CAC_UID:-$(/usr/bin/id -u)}" ;;
  -g) printf '%s\n' "${CAC_GID:-$(/usr/bin/id -g)}" ;;
  -un) printf '%s\n' "${CAC_USERNAME:-${USER:-$(/usr/bin/id -un)}}" ;;
  -gn) printf '%s\n' "${CAC_USERNAME:-${USER:-$(/usr/bin/id -gn)}}" ;;
  "") exec /usr/bin/id ;;
  *) exec /usr/bin/id "$@" ;;
esac
EOF

  chmod 0755 "$shim_dir"/uname "$shim_dir"/cat "$shim_dir"/hostname "$shim_dir"/whoami "$shim_dir"/id
  chown -R "$CURRENT_RUNTIME_UID:$CURRENT_RUNTIME_GID" "$shim_dir" 2>/dev/null || true
}

prepend_fingerprint_options() {
  local hook="/usr/local/bin/fingerprint-hook.js"
  [[ -f "$hook" ]] || return 0

  case " ${NODE_OPTIONS:-} " in
    *" --require $hook "*) ;;
    *) export NODE_OPTIONS="--require $hook ${NODE_OPTIONS:-}" ;;
  esac

  case " ${BUN_OPTIONS:-} " in
    *" --preload $hook "*) ;;
    *) export BUN_OPTIONS="--preload $hook ${BUN_OPTIONS:-}" ;;
  esac
}

prepare_cloudcli_home_mapping() {
  local env_dir="${1:-}"
  [[ "$CAC_ENABLE_WEB" == "1" ]] || return 0
  [[ -n "$env_dir" ]] || return 0
  [[ -d "${env_dir}/.claude" ]] || return 0

  local home_claude="${PROFILE_HOME}/.claude"
  local target="${env_dir}/.claude"
  local backup="${PROFILE_HOME}/.claude.cac-home-backup"

  mkdir -p "${PROFILE_HOME}/.cloudcli"

  if [[ -L "$home_claude" ]]; then
    local current_target=""
    current_target="$(readlink "$home_claude" || true)"
    if [[ "$current_target" != "$target" ]]; then
      rm -f "$home_claude"
      ln -s "$target" "$home_claude"
    fi
  elif [[ -e "$home_claude" ]]; then
    if [[ ! -e "$backup" ]]; then
      mv "$home_claude" "$backup"
    else
      rm -rf "$home_claude"
    fi
    ln -s "$target" "$home_claude"
  else
    ln -s "$target" "$home_claude"
  fi

  chown -h "$CURRENT_RUNTIME_UID:$CURRENT_RUNTIME_GID" "$home_claude" 2>/dev/null || true
  chown -R "$CURRENT_RUNTIME_UID:$CURRENT_RUNTIME_GID" "${PROFILE_HOME}/.cloudcli" 2>/dev/null || true
}

prepare_cloudcli_env_file() {
  [[ "$CAC_ENABLE_WEB" == "1" ]] || return 0
  /usr/local/bin/cloudcli-env.sh
}

ensure_x11_socket_dir() {
  [[ "$CAC_ENABLE_WEB" == "1" ]] || return 0
  mkdir -p /tmp/.X11-unix
  chmod 1777 /tmp/.X11-unix 2>/dev/null || true
}

sync_active_proxy_file() {
  local env_dir="${1:-}"
  [[ -n "$env_dir" ]] || return 0
  mkdir -p "$env_dir"

  if [[ -n "${CAC_SINGBOX_CONFIG_B64:-}" ]]; then
    rm -f "$env_dir/proxy"
    return 0
  fi

  local proxy_value="none"
  if [[ -n "${PROXY_URI:-}" ]]; then
    local normalized=""
    normalized="$(normalize_proxy_for_cac "$PROXY_URI" || true)"
    [[ -n "$normalized" ]] && proxy_value="$normalized"
  fi

  printf '%s\n' "$proxy_value" > "$env_dir/proxy"
  chown "$CURRENT_RUNTIME_UID:$CURRENT_RUNTIME_GID" "$env_dir/proxy" 2>/dev/null || true
}

ensure_hostname_hosts_entry() {
  local host_name="${1:-}"
  [[ -n "$host_name" ]] || return 0
  grep -qE "^[[:space:]]*127\\.0\\.0\\.1[[:space:]].*([[:space:]]|^)${host_name}([[:space:]]|$)" /etc/hosts 2>/dev/null && return 0
  printf '127.0.0.1 %s\n' "$host_name" >> /etc/hosts
}

configure_ssh_password() {
  [[ "$CAC_ENABLE_SSH" == "1" ]] || return 0
  mkdir -p "${PROFILE_HOME}/.ssh"
  chmod 700 "${PROFILE_HOME}/.ssh"
  chown "$CURRENT_RUNTIME_UID:$CURRENT_RUNTIME_GID" "${PROFILE_HOME}/.ssh" 2>/dev/null || true
  printf '%s:%s\n' "$CAC_FAKE_USER" "$CAC_SSH_PASSWORD" | chpasswd
}

start_sshd() {
  [[ "$CAC_ENABLE_SSH" == "1" ]] || return 0
  command -v sshd >/dev/null 2>&1 || {
    echo "CAC_ENABLE_SSH=1 but sshd is not installed" >&2
    exit 1
  }

  mkdir -p /run/sshd
  chmod 0755 /run/sshd
  ssh-keygen -A >/dev/null 2>&1 || true
  configure_ssh_password
  pgrep -x sshd >/dev/null 2>&1 || /usr/sbin/sshd -p "$CAC_SSH_CONTAINER_PORT"
}

CURRENT_RUNTIME_UID="$CAC_FAKE_UID"
CURRENT_RUNTIME_GID="$CAC_FAKE_GID"

detect_runtime_identity() {
  CURRENT_RUNTIME_UID="${CAC_RUNTIME_UID:-$CAC_FAKE_UID}"
  CURRENT_RUNTIME_GID="${CAC_RUNTIME_GID:-$CAC_FAKE_GID}"
}

prepare_runtime_user() {
  detect_runtime_identity

  local current_uid current_gid current_group_name target_group_name owner_marker desired_owner current_owner
  current_uid="$(id -u "$CAC_FAKE_USER" 2>/dev/null || echo "$CAC_FAKE_UID")"
  current_gid="$(id -g "$CAC_FAKE_USER" 2>/dev/null || echo "$CAC_FAKE_GID")"
  current_group_name="$(id -gn "$CAC_FAKE_USER" 2>/dev/null || echo "$CAC_FAKE_USER")"

  if [[ "$CURRENT_RUNTIME_GID" != "$current_gid" ]]; then
    target_group_name="$(getent group "$CURRENT_RUNTIME_GID" 2>/dev/null | cut -d: -f1 || true)"
    if [[ -n "$target_group_name" ]]; then
      usermod -g "$CURRENT_RUNTIME_GID" "$CAC_FAKE_USER" 2>/dev/null || true
    else
      groupmod -o -g "$CURRENT_RUNTIME_GID" "$current_group_name" 2>/dev/null || true
      usermod -g "$CURRENT_RUNTIME_GID" "$CAC_FAKE_USER" 2>/dev/null || true
    fi
  fi

  if [[ "$CURRENT_RUNTIME_UID" != "$current_uid" ]]; then
    usermod -o -u "$CURRENT_RUNTIME_UID" "$CAC_FAKE_USER" 2>/dev/null || true
  fi

  usermod -s "$CAC_FAKE_SHELL" "$CAC_FAKE_USER" 2>/dev/null || true

  owner_marker="$PROFILE_HOME/.cac-runtime-owner"
  desired_owner="${CURRENT_RUNTIME_UID}:${CURRENT_RUNTIME_GID}"
  current_owner="$(cat "$owner_marker" 2>/dev/null || true)"
  if [[ "$current_owner" != "$desired_owner" ]]; then
    echo "Preparing runtime home ownership: ${PROFILE_HOME} -> ${desired_owner}"
    chown -R "$CURRENT_RUNTIME_UID:$CURRENT_RUNTIME_GID" "$PROFILE_HOME" 2>/dev/null || true
    printf '%s\n' "$desired_owner" > "$owner_marker" 2>/dev/null || true
    chown "$CURRENT_RUNTIME_UID:$CURRENT_RUNTIME_GID" "$owner_marker" 2>/dev/null || true
  fi
  [[ -f "$CAC_RUNTIME_ENV_FILE" ]] && chown "$CURRENT_RUNTIME_UID:$CURRENT_RUNTIME_GID" "$CAC_RUNTIME_ENV_FILE" 2>/dev/null || true
}

repair_runtime_home_permissions() {
  local uid_gid="${CURRENT_RUNTIME_UID}:${CURRENT_RUNTIME_GID}"
  local path

  mkdir -p \
    "$PROFILE_HOME" \
    "$PROFILE_HOME/.local" \
    "$PROFILE_HOME/.local/bin" \
    "$PROFILE_HOME/.cache" \
    "$PROFILE_HOME/.config" \
    "$PROFILE_HOME/.claude" \
    "$PROFILE_HOME/.cac"

  chown -R "$uid_gid" \
    "$PROFILE_HOME/.local" \
    "$PROFILE_HOME/.cache" \
    "$PROFILE_HOME/.config" \
    "$PROFILE_HOME/.claude" \
    "$PROFILE_HOME/.cac" 2>/dev/null || true

  for path in \
    "$PROFILE_HOME" \
    "$PROFILE_HOME/.bashrc" \
    "$PROFILE_HOME/.profile" \
    "$PROFILE_HOME/.bash_profile" \
    "$PROFILE_HOME/.zshrc" \
    "$PROFILE_HOME/.zprofile" \
    "$PROFILE_HOME/.tmux.conf" \
    "$PROFILE_HOME/.claude.json" \
    "$CAC_RUNTIME_ENV_FILE"
  do
    [[ -e "$path" || -L "$path" ]] || continue
    chown -h "$uid_gid" "$path" 2>/dev/null || true
  done

  chmod u+rwx,g+rwx "$PROFILE_HOME" 2>/dev/null || true
  chmod -R u+rwX,g+rwX \
    "$PROFILE_HOME/.local" \
    "$PROFILE_HOME/.cache" \
    "$PROFILE_HOME/.config" \
    "$PROFILE_HOME/.claude" \
    "$PROFILE_HOME/.cac" 2>/dev/null || true

  [[ -f "$PROFILE_HOME/.claude.json" ]] && chmod 0600 "$PROFILE_HOME/.claude.json" 2>/dev/null || true
  [[ -f "$PROFILE_HOME/.claude/.credentials.json" ]] && chmod 0600 "$PROFILE_HOME/.claude/.credentials.json" 2>/dev/null || true
  [[ -d "$PROFILE_HOME/.ssh" ]] && chmod 0700 "$PROFILE_HOME/.ssh" 2>/dev/null || true
  [[ -f "$PROFILE_HOME/.ssh/authorized_keys" ]] && chmod 0600 "$PROFILE_HOME/.ssh/authorized_keys" 2>/dev/null || true
}

hide_container_traces() {
  rm -f /.dockerenv /run/.containerenv 2>/dev/null || true
}

exec_as_runtime_user() {
  if [[ "$(id -u)" != "0" ]]; then
    exec "$@"
  fi

  if command -v gosu >/dev/null 2>&1; then
    exec gosu "${CURRENT_RUNTIME_UID}:${CURRENT_RUNTIME_GID}" "$@"
  fi

  if command -v setpriv >/dev/null 2>&1; then
    exec setpriv --reuid "$CURRENT_RUNTIME_UID" --regid "$CURRENT_RUNTIME_GID" --init-groups "$@"
  fi

  if command -v runuser >/dev/null 2>&1; then
    exec runuser -u "$CAC_FAKE_USER" -- "$@"
  fi

  echo "No supported privilege drop helper found (need setpriv or runuser)" >&2
  exit 1
}

run_as_runtime_user_bg() {
  if [[ "$(id -u)" != "0" ]]; then
    "$@" &
    return 0
  fi

  if command -v gosu >/dev/null 2>&1; then
    gosu "${CURRENT_RUNTIME_UID}:${CURRENT_RUNTIME_GID}" "$@" &
    return 0
  fi

  if command -v setpriv >/dev/null 2>&1; then
    setpriv --reuid "$CURRENT_RUNTIME_UID" --regid "$CURRENT_RUNTIME_GID" --init-groups "$@" &
    return 0
  fi

  if command -v runuser >/dev/null 2>&1; then
    runuser -u "$CAC_FAKE_USER" -- "$@" &
    return 0
  fi

  return 1
}

if [[ "$DISABLE_IPV6" == "1" ]]; then
  sysctl -w net.ipv6.conf.all.disable_ipv6=1 2>/dev/null || true
  sysctl -w net.ipv6.conf.default.disable_ipv6=1 2>/dev/null || true
fi

apply_net_tuning() {
  [[ "${CAC_NET_TUNING:-0}" == "1" ]] || return 0

  echo "Applying optional TCP network tuning..."
  sysctl -w net.ipv4.tcp_fastopen="${CAC_TCP_FASTOPEN:-3}" 2>/dev/null || \
    echo "warning: failed to set net.ipv4.tcp_fastopen" >&2
  sysctl -w net.ipv4.tcp_mtu_probing="${CAC_TCP_MTU_PROBING:-1}" 2>/dev/null || \
    echo "warning: failed to set net.ipv4.tcp_mtu_probing" >&2
  sysctl -w net.ipv4.tcp_keepalive_time="${CAC_TCP_KEEPALIVE_TIME:-600}" 2>/dev/null || \
    echo "warning: failed to set net.ipv4.tcp_keepalive_time" >&2
  sysctl -w net.ipv4.tcp_keepalive_intvl="${CAC_TCP_KEEPALIVE_INTVL:-30}" 2>/dev/null || \
    echo "warning: failed to set net.ipv4.tcp_keepalive_intvl" >&2
  sysctl -w net.ipv4.tcp_keepalive_probes="${CAC_TCP_KEEPALIVE_PROBES:-5}" 2>/dev/null || \
    echo "warning: failed to set net.ipv4.tcp_keepalive_probes" >&2

  local bbr_mode="${CAC_NET_TUNING_BBR:-auto}" available=""
  available="$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || true)"
  case "$bbr_mode" in
    0|false|False|FALSE|off|OFF)
      echo "BBR tuning skipped by CAC_NET_TUNING_BBR=${bbr_mode}"
      ;;
    1|true|True|TRUE|on|ON|auto|"")
      if grep -qw bbr <<<"$available"; then
        sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null || \
          echo "warning: failed to set net.ipv4.tcp_congestion_control=bbr" >&2
      else
        echo "BBR tuning skipped: bbr is not available (available: ${available:-unknown})"
      fi
      ;;
    *)
      echo "warning: unknown CAC_NET_TUNING_BBR=${bbr_mode}; expected auto, 0, or 1" >&2
      ;;
  esac
}

apply_net_tuning

_SINGBOX_PID=""
_DOCKER_ROUTE_SPEC=""
_PROXY_ROUTE_SPEC=""

docker_host_target() {
  local docker_host="${DOCKER_HOST:-}" target=""
  [[ -z "$docker_host" ]] && return 1

  case "$docker_host" in
    tcp://*)
      target="${docker_host#tcp://}"
      target="${target%%/*}"
      if [[ "$target" == \[*\]*:* ]]; then
        target="${target#\[}"
        target="${target%%]*}"
      else
        target="${target%%:*}"
      fi
      ;;
    *)
      return 1
      ;;
  esac

  printf '%s\n' "$target"
}

proxy_host_target() {
  local proxy="${PROXY_URI:-}" target=""
  [[ -z "$proxy" ]] && return 1

  if [[ "$proxy" != *"://"* ]]; then
    printf '%s\n' "${proxy%%:*}"
    return 0
  fi

  python3 - "$proxy" <<'PY'
from urllib.parse import urlparse
import sys

raw = sys.argv[1]
scheme = raw.split("://", 1)[0].lower()
if scheme in {"http", "https", "socks5", "vless", "trojan"}:
    parsed = urlparse(raw)
    print(parsed.hostname or "")
PY
}

capture_named_route() {
  local target="$1" resolved="" route_line="" host_alias=""
  [[ -z "$target" ]] && return 0

  if [[ "$target" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    resolved="$target"
  else
    resolved="$(getent ahostsv4 "$target" 2>/dev/null | awk 'NR==1{print $1}' || true)"
    host_alias="$target"
  fi
  [[ -z "$resolved" ]] && return 0

  route_line="$(ip -4 route get "$resolved" 2>/dev/null | head -n1 || true)"
  [[ -z "$route_line" ]] && return 0

  local dev via src
  dev="$(awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}' <<<"$route_line")"
  via="$(awk '{for (i = 1; i <= NF; i++) if ($i == "via") {print $(i + 1); exit}}' <<<"$route_line")"
  src="$(awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}' <<<"$route_line")"
  [[ -z "$dev" ]] && return 0

  printf '%s|%s|%s|%s|%s\n' "${resolved}/32" "$dev" "$via" "$src" "$host_alias"
}

pin_named_route() {
  local spec="$1"
  [[ -z "$spec" ]] && return 0

  local dst dev via src host
  IFS='|' read -r dst dev via src host <<<"$spec"
  [[ -z "$dst" || -z "$dev" ]] && return 0

  local cmd=(ip route replace "$dst" dev "$dev")
  [[ -n "$via" ]] && cmd+=(via "$via")
  [[ -n "$src" ]] && cmd+=(src "$src")
  "${cmd[@]}" 2>/dev/null || true
  if [[ -n "$host" ]]; then
    grep -qE "(^|[[:space:]])${host}([[:space:]]|$)" /etc/hosts 2>/dev/null || \
      printf '%s %s\n' "${dst%/32}" "$host" >> /etc/hosts
  fi
}

cherny_flatten_json() {
  local template="$1"
  python3 - "$template" <<'PY'
import json, sys

path = sys.argv[1]
data = json.load(open(path))
for key, value in data.items():
    if isinstance(value, list):
        value = ",".join(str(item) for item in value)
    print(f"{key}={value}")
PY
}

cherify_layer() {
  local template="$1" prefix="$2" dir="$3"
  [[ ! -f "$template" ]] && return
  while IFS='=' read -r key value; do
    [[ -z "$key" ]] && continue
    printf '%s\n' "$value" > "$dir/cherny.${prefix}.${key}"
    printf 'export CHERNY_%s_%s="%s"\n' "${prefix^^}" "${key^^}" "${value//\"/\\\"}" >> "$CAC_RUNTIME_ENV_FILE"
  done < <(cherny_flatten_json "$template")
}

apply_cherny_identity() {
  local template="$CHERNY_IDENTITY_JSON" dir="$1"
  [[ ! -f "$template" ]] && return
  local values=()
  local device_id="" email="" user_id="" session_alias=""
  mapfile -t values < <(
    python3 - "$template" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
print(data.get('device_id',''))
print(data.get('email',''))
print(data.get('user_id',''))
print(data.get('session_alias',''))
PY
  )
  device_id="${values[0]:-}"
  email="${values[1]:-}"
  user_id="${values[2]:-}"
  session_alias="${values[3]:-}"
  [[ -n "$device_id" ]] && {
    printf '%s\n' "$device_id" > "$dir/cherny.identity.device_id"
    printf 'export CAC_DEVICE_ID="%s"\n' "$device_id" >> "$CAC_RUNTIME_ENV_FILE"
    printf 'export CHERNY_ID_DEVICE_ID="%s"\n' "$device_id" >> "$CAC_RUNTIME_ENV_FILE"
  }
  [[ -n "$email" ]] && {
    printf '%s\n' "$email" > "$dir/cherny.identity.email"
    printf 'export CAC_EMAIL="%s"\n' "$email" >> "$CAC_RUNTIME_ENV_FILE"
    printf 'export CHERNY_ID_EMAIL="%s"\n' "$email" >> "$CAC_RUNTIME_ENV_FILE"
  }
  [[ -n "$user_id" ]] && {
    printf '%s\n' "$user_id" > "$dir/cherny.identity.user_id"
    printf 'export CAC_USER_ID="%s"\n' "$user_id" >> "$CAC_RUNTIME_ENV_FILE"
    printf 'export CHERNY_ID_USER_ID="%s"\n' "$user_id" >> "$CAC_RUNTIME_ENV_FILE"
  }
  [[ -n "$session_alias" ]] && {
    printf '%s\n' "$session_alias" > "$dir/cherny.identity.session_alias"
    printf 'export CHERNY_ID_SESSION_ALIAS="%s"\n' "$session_alias" >> "$CAC_RUNTIME_ENV_FILE"
  }
  return 0
}

apply_cherny_profile() {
  local dir="$1"
  apply_cherny_identity "$dir"
  cherify_layer "$CHERNY_ENV_JSON" "env" "$dir"
  cherify_layer "$CHERNY_PROMPT_JSON" "prompt" "$dir"
  cherify_layer "$CHERNY_TELEMETRY_JSON" "telemetry" "$dir"
}

wait_for_docker_host() {
  local docker_host="${DOCKER_HOST:-}"
  [[ -z "$docker_host" ]] && return 0

  for _ in $(seq 1 120); do
    DOCKER_HOST="$docker_host" /usr/local/bin/docker-real version >/dev/null 2>&1 && return 0
    sleep 0.25
  done

  echo "Docker API unavailable at ${docker_host}" >&2
  exit 1
}

_DOCKER_ROUTE_SPEC="$(capture_named_route "$(docker_host_target || true)")"
_PROXY_ROUTE_SPEC="$(capture_named_route "$(proxy_host_target || true)")"

ensure_profile_home

if [[ -z "$CAC_SSH_PASSWORD" || "$CAC_SSH_PASSWORD" == "cherny" ]]; then
  CAC_SSH_PASSWORD="$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(18))
PY
)"
  export CAC_SSH_PASSWORD
  echo "Generated random SSH password for this container. Persist CAC_SSH_PASSWORD in .env if SSH password login is required."
fi

hide_container_traces

export HOME="$PROFILE_HOME"
export CAC_DIR="$HOME/.cac"
export ENVS_DIR="$CAC_DIR/envs"
export USER="$CAC_FAKE_USER"
export LOGNAME="$CAC_FAKE_USER"
export SHELL="$CAC_FAKE_SHELL"
export TERM="$CAC_FAKE_TERM"

if [[ "$SINGBOX_ENABLE" == "1" ]]; then
  mkdir -p /etc/sing-box
  if [[ -n "${CAC_SINGBOX_CONFIG_B64:-}" ]]; then
    python3 - <<'PY' > /etc/sing-box/config.json
import base64
import os
import sys

raw = os.environ.get("CAC_SINGBOX_CONFIG_B64", "")
try:
    sys.stdout.write(base64.b64decode(raw).decode("utf-8"))
except Exception as exc:
    print(f"Failed to decode CAC_SINGBOX_CONFIG_B64: {exc}", file=sys.stderr)
    raise SystemExit(1)
PY
  else
    python3 -m ccimage > /etc/sing-box/config.json \
      || { echo "Failed to generate sing-box config" >&2; exit 1; }
  fi

  sing-box run -c /etc/sing-box/config.json &
  _SINGBOX_PID=$!

  for _ in $(seq 1 150); do
    ip -o link show tun0 2>/dev/null && break
    kill -0 "$_SINGBOX_PID" 2>/dev/null || { echo "sing-box exited before TUN came up" >&2; exit 1; }
    sleep 0.05
  done

  _net="${TUN_ADDRESS:-172.19.0.1/30}"
  _base="${_net%/*}"
  _prefix="${_base%.*}"
  _last="${_base##*.}"
  TUN_DNS="${_prefix}.$(( _last + 1 ))"
  printf 'nameserver %s\noptions ndots:0\n' "$TUN_DNS" > /etc/resolv.conf
  pin_named_route "$_DOCKER_ROUTE_SPEC"
  pin_named_route "$_PROXY_ROUTE_SPEC"

  # ── Auto-detect timezone and locale from exit IP ──────────────
  _GEO_TZ="" _GEO_LANG=""
  _GEO_TZ="" _GEO_LANG=""
  echo "Detecting exit geolocation..."
  if python3 -m ccimage.geo 2>/dev/null > "$CAC_RUNTIME_ENV_FILE"; then
    source "$CAC_RUNTIME_ENV_FILE"
    _GEO_TZ="${TZ:-}"
    _GEO_LANG="${LANG:-}"
    echo "Geo: ${TZ} / ${LANG}"
  fi

  # ── Auto-setup cac: install + create profile + activate ───────
  migrate_root_state

  # Create and activate profile if not complete
  _env_dir="$ENVS_DIR/$CAC_PROFILE"
  if [[ ! -f "$_env_dir/uuid" ]]; then
    echo "Creating cac profile: $CAC_PROFILE"
    mkdir -p "$_env_dir"

    # Generate identity
    uuidgen | tr '[:lower:]' '[:upper:]'           > "$_env_dir/uuid"
    uuidgen | tr '[:upper:]' '[:lower:]'           > "$_env_dir/stable_id"
    python3 -c "import os; print(os.urandom(32).hex())" > "$_env_dir/user_id"
    uuidgen | tr -d '-' | tr '[:upper:]' '[:lower:]'    > "$_env_dir/machine_id"
    echo "boris-$(uuidgen | cut -d- -f1 | tr '[:upper:]' '[:lower:]')" > "$_env_dir/hostname"
    printf '02:%02x:%02x:%02x:%02x:%02x' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) > "$_env_dir/mac_address"

    # Timezone and language from geo detection
    echo "${_GEO_TZ:-Asia/Tokyo}"           > "$_env_dir/tz"
    echo "${_GEO_LANG:-ja_JP.UTF-8}"        > "$_env_dir/lang"

    # Generate mTLS client certificate
    if [[ -f "$CAC_DIR/ca/ca_key.pem" ]]; then
      openssl genrsa -out "$_env_dir/client_key.pem" 2048 2>/dev/null
      openssl req -new -key "$_env_dir/client_key.pem" \
        -subj "/CN=boris-client-${CAC_PROFILE}" \
        -out /tmp/cac-csr.pem 2>/dev/null
      openssl x509 -req -in /tmp/cac-csr.pem \
        -CA "$CAC_DIR/ca/ca_cert.pem" -CAkey "$CAC_DIR/ca/ca_key.pem" \
        -CAcreateserial -days 365 \
        -out "$_env_dir/client_cert.pem" 2>/dev/null
      rm -f /tmp/cac-csr.pem
    fi

    echo "  Profile: $CAC_PROFILE"
    echo "  Hostname: $(cat "$_env_dir/hostname")"
    echo "  UUID: $(cat "$_env_dir/uuid")"
  fi

  printf '%s\n' "$CAC_FAKE_USER" > "$_env_dir/username"
  printf '%s\n' "$CAC_FAKE_UID" > "$_env_dir/uid"
  printf '%s\n' "$CAC_FAKE_GID" > "$_env_dir/gid"
  printf '%s\n' "$CAC_FAKE_HOME" > "$_env_dir/home_dir"
  printf '%s\n' "$CAC_FAKE_SHELL" > "$_env_dir/shell_path"
  printf '%s\n' "$CAC_FAKE_OS_TYPE" > "$_env_dir/os_type"
  printf '%s\n' "$CAC_FAKE_OS_RELEASE" > "$_env_dir/os_release"
  printf '%s\n' "$CAC_FAKE_OS_VERSION" > "$_env_dir/os_version"
  printf '%s\n' "$CAC_FAKE_OS_PRETTY_NAME" > "$_env_dir/os_pretty_name"
  printf '%s\n' "$CAC_FAKE_DISTRO_ID" > "$_env_dir/linux_distro_id"
  printf '%s\n' "$CAC_FAKE_DISTRO_VERSION" > "$_env_dir/linux_distro_version"
  printf '%s\n' "$CAC_FAKE_PROC_VERSION" > "$_env_dir/proc_version"
  printf '%s\n' "$CAC_FAKE_CGROUP_TEXT" > "$_env_dir/cgroup_text"
  printf '%s\n' "$CAC_FAKE_MOUNTINFO_TEXT" > "$_env_dir/mountinfo_text"
  sync_active_proxy_file "$_env_dir"

  # Activate profile
  echo "$CAC_PROFILE" > "$CAC_DIR/current"
  rm -f "$CAC_DIR/stopped"

  # Export identity env vars for current session (so cac-check sees them)
  export CAC_HOSTNAME="$(cat "$_env_dir/hostname" 2>/dev/null)"
  export CAC_MAC="$(cat "$_env_dir/mac_address" 2>/dev/null)"
  export CAC_MACHINE_ID="$(cat "$_env_dir/machine_id" 2>/dev/null)"
  export CAC_USERNAME="$CAC_FAKE_USER"
  export CAC_UID="$CAC_FAKE_UID"
  export CAC_GID="$CAC_FAKE_GID"
  export CAC_HOME="$CAC_FAKE_HOME"
  export CAC_SHELL="$CAC_FAKE_SHELL"
  export CAC_OS_TYPE="$CAC_FAKE_OS_TYPE"
  export CAC_OS_RELEASE="$CAC_FAKE_OS_RELEASE"
  export CAC_OS_VERSION="$CAC_FAKE_OS_VERSION"
  export CAC_OS_PRETTY_NAME="$CAC_FAKE_OS_PRETTY_NAME"
  export CAC_LINUX_DISTRO_ID="$CAC_FAKE_DISTRO_ID"
  export CAC_LINUX_DISTRO_VERSION="$CAC_FAKE_DISTRO_VERSION"
  export CAC_PROC_VERSION="$CAC_FAKE_PROC_VERSION"
  export HOME="$CAC_FAKE_HOME"
  export USER="$CAC_FAKE_USER"
  export LOGNAME="$CAC_FAKE_USER"
  export SHELL="$CAC_FAKE_SHELL"
  export TERM="$CAC_FAKE_TERM"
  export TZ="$(cat "$_env_dir/tz" 2>/dev/null || echo Asia/Tokyo)"
  export LANG="$(cat "$_env_dir/lang" 2>/dev/null || echo ja_JP.UTF-8)"
  export LC_ALL="$LANG"
  case "$LANG" in
    ja_JP.UTF-8) export LANGUAGE="ja_JP:ja" ;;
    *) export LANGUAGE="${LANG%%.*}" ;;
  esac
  hostname "$CAC_HOSTNAME" 2>/dev/null || true
  printf '%s\n' "$CAC_HOSTNAME" > /etc/hostname 2>/dev/null || true
  ensure_hostname_hosts_entry "$CAC_HOSTNAME"

  {
    append_runtime_export CAC_HOSTNAME "$CAC_HOSTNAME"
    append_runtime_export CAC_MAC "$CAC_MAC"
    append_runtime_export CAC_MACHINE_ID "$CAC_MACHINE_ID"
    append_runtime_export CAC_USERNAME "$CAC_USERNAME"
    append_runtime_export CAC_UID "$CAC_UID"
    append_runtime_export CAC_GID "$CAC_GID"
    append_runtime_export CAC_HOME "$CAC_HOME"
    append_runtime_export CAC_SHELL "$CAC_SHELL"
    append_runtime_export CAC_OS_TYPE "$CAC_OS_TYPE"
    append_runtime_export CAC_OS_RELEASE "$CAC_OS_RELEASE"
    append_runtime_export CAC_OS_VERSION "$CAC_OS_VERSION"
    append_runtime_export CAC_OS_PRETTY_NAME "$CAC_OS_PRETTY_NAME"
    append_runtime_export CAC_LINUX_DISTRO_ID "$CAC_LINUX_DISTRO_ID"
    append_runtime_export CAC_LINUX_DISTRO_VERSION "$CAC_LINUX_DISTRO_VERSION"
    append_runtime_export CAC_PROC_VERSION "$CAC_PROC_VERSION"
    append_runtime_export CAC_CGROUP_TEXT "$CAC_FAKE_CGROUP_TEXT"
    append_runtime_export CAC_MOUNTINFO_TEXT "$CAC_FAKE_MOUNTINFO_TEXT"
    append_runtime_export HOME "$HOME"
    append_runtime_export USER "$USER"
    append_runtime_export LOGNAME "$LOGNAME"
    append_runtime_export SHELL "$SHELL"
    append_runtime_export TERM "$TERM"
    append_runtime_export TZ "$TZ"
    append_runtime_export LANG "$LANG"
    append_runtime_export LC_ALL "$LC_ALL"
    append_runtime_export LANGUAGE "$LANGUAGE"
    append_runtime_export DOCKER_HOST "${DOCKER_HOST:-}"
    append_runtime_export PATH "$CAC_DIR/shim-bin:$PATH"
    append_runtime_unset TERM_PROGRAM
    append_runtime_unset TMUX
    append_runtime_unset STY
    append_runtime_unset KONSOLE_VERSION
    append_runtime_unset GNOME_TERMINAL_SERVICE
    append_runtime_unset XTERM_VERSION
    append_runtime_unset VTE_VERSION
    append_runtime_unset TERMINATOR_UUID
    append_runtime_unset KITTY_WINDOW_ID
    append_runtime_unset ALACRITTY_LOG
    append_runtime_unset TILIX_ID
    append_runtime_unset WT_SESSION
    append_runtime_unset SESSIONNAME
    append_runtime_unset MSYSTEM
    append_runtime_unset ConEmuANSI
    append_runtime_unset ConEmuPID
    append_runtime_unset ConEmuTask
    append_runtime_unset WSL_DISTRO_NAME
    append_runtime_unset TERMINAL_EMULATOR
    append_runtime_unset VSCODE_GIT_ASKPASS_MAIN
    append_runtime_unset CURSOR_TRACE_ID
    append_runtime_unset VisualStudioVersion
    append_runtime_unset __CFBundleIdentifier
  }
  migrate_root_state
  sync_shell_rc

  echo "Applying runtime profile..."
  apply_cherny_profile "$_env_dir"
  echo "Preparing runtime user..."
  prepare_runtime_user
  repair_runtime_home_permissions
  echo "Writing runtime shims..."
  write_runtime_shims
  export PATH="$CAC_DIR/shim-bin:$PATH"
  prepend_fingerprint_options
  configure_zsh_defaults_if_selected
  append_runtime_export CAC_EFFECTIVE_UID "$CURRENT_RUNTIME_UID"
  append_runtime_export CAC_EFFECTIVE_GID "$CURRENT_RUNTIME_GID"
  append_runtime_export CAC_RUNTIME_USER "$CAC_FAKE_USER"
  append_runtime_export CAC_ENABLE_WEB "$CAC_ENABLE_WEB"
  append_runtime_export CAC_WEB_PORT "$CAC_WEB_PORT"
  append_runtime_export DISPLAY "${DISPLAY:-:99}"
  append_runtime_export WORKSPACES_ROOT "/workspace"
  append_runtime_export NODE_OPTIONS "$NODE_OPTIONS"
  append_runtime_export BUN_OPTIONS "$BUN_OPTIONS"

  echo "Preparing CloudCLI runtime..."
  prepare_cloudcli_home_mapping "$_env_dir"
  prepare_cloudcli_env_file
  repair_runtime_home_permissions
  ensure_x11_socket_dir

  [[ "$HEALTHCHECK" == "1" ]] && echo "Startup checks available via: cac-check"

elif [[ "$SINGBOX_ENABLE" == "0" ]]; then
  if [[ -z "${PROXY_URI:-}" ]]; then
    echo "SINGBOX_ENABLE=0 but PROXY_URI not set" >&2
    exit 1
  fi
  if ! PROXY_URL="$(proxy_env_url_for_disabled_singbox "$PROXY_URI")"; then
    echo "SINGBOX_ENABLE=0 supports compact SOCKS5 or explicit http(s)/socks5(h) proxy URLs only. Use SINGBOX_ENABLE=1 for share links." >&2
    exit 1
  fi
  export ALL_PROXY="$PROXY_URL" HTTP_PROXY="$PROXY_URL" HTTPS_PROXY="$PROXY_URL"
  export all_proxy="$PROXY_URL" http_proxy="$PROXY_URL" https_proxy="$PROXY_URL"
  export NO_PROXY="localhost,127.0.0.1,::1" no_proxy="localhost,127.0.0.1,::1"
  echo "SINGBOX_ENABLE=0: using env SOCKS only (not leak-safe)." >&2
else
  echo "SINGBOX_ENABLE must be 0 or 1" >&2
  exit 1
fi

echo "Waiting for Docker API from runtime..."
wait_for_docker_host
echo "Starting SSH service..."
start_sshd

_cleanup() {
  [[ -n "$_SINGBOX_PID" ]] && kill -TERM "$_SINGBOX_PID" 2>/dev/null && wait "$_SINGBOX_PID" 2>/dev/null || true
}
trap _cleanup EXIT INT TERM

echo "Dropping privileges to ${CURRENT_RUNTIME_UID}:${CURRENT_RUNTIME_GID}..."
exec_as_runtime_user /init "$@"
