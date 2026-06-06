# cac-docker-claude

[![Latest release](https://img.shields.io/github/v/release/ZMK112/claude-docker?sort=semver)](https://github.com/ZMK112/claude-docker/releases/latest)
[![License](https://img.shields.io/github/license/ZMK112/claude-docker)](LICENSE)
[![Docker Compose](https://img.shields.io/badge/Docker%20Compose-required-2496ED)](https://docs.docker.com/compose/)
[![sing-box](https://img.shields.io/badge/network-sing--box%20TUN-00A3FF)](https://sing-box.sagernet.org/)

Docker-only Claude Code runtime for isolated, proxy-controlled Claude Code workspaces.

`cac-docker-claude` provides a reproducible Docker workspace for Claude Code with sing-box TUN routing, chained proxy support, persistent Claude state, local image builds, SSH/Web access, and safe stable upgrades.

中文：`cac-docker-claude` 是从原 `cac` 项目拆分出来的 Docker 专用版本。它只保留 `cac docker ...` 工作流，用 Docker 容器运行 Claude Code，并通过 sing-box TUN 把容器网络流量纳入代理和规则控制，同时保留 Claude 登录状态、个性化数据和工作区数据。

## Why This Project

Running Claude Code inside a container is useful only if the runtime stays predictable: network traffic must follow the intended proxy path, Claude state must survive rebuilds, and updates must not disrupt a working environment. This project focuses on that Docker runtime layer and keeps the command surface intentionally small.

## Highlights

| Area | What it does |
| --- | --- |
| Runtime | Docker-only command surface: `cac docker ...` |
| Network | sing-box TUN isolation for the main container, with direct internal Docker/LAN routes where needed |
| Proxy chains | Mihomo YAML chain configs can be converted into sing-box runtime config |
| Persistence | Claude credentials, personalization, home data, mounts, and Docker settings live under `~/.cac/docker` |
| Builds | Stable installs include full source under `~/.cac/source`, so images can be rebuilt locally |
| Access | SSH on localhost by default, Web UI, Docker socket proxy, child-container proxy bridge, zsh, tmux, bubblewrap, and extra mounts |
| Updates | `cac docker update` installs the latest stable release with rollback behavior |

## Components

| Component | Purpose |
| --- | --- |
| Main container | Claude Code runtime, Web UI, SSH, shell environment, and sing-box TUN |
| Gateway/docker-proxy | Controlled Docker API path for Docker commands inside the runtime |
| Proxy bridge | Proxy endpoint for child containers created from inside the runtime |
| Docker resources | Compose files, generated mounts, proxy config, and persistent data under `~/.cac/docker` |

Non-Docker cac features such as `cac env`, `cac claude`, local relay mode, and local fingerprint-hook environments are not part of this project.

## Project Scope

This project is intentionally narrow: it manages the Docker-based Claude Code runtime only. It does not replace Docker itself, does not expose the old local `cac` workflows, and does not delete existing Claude data during normal install, update, rebuild, start, stop, or restart operations.

## Contents

- [Install](#install)
- [Quick Start](#quick-start)
- [Common Commands](#common-commands)
- [Mounts](#mounts)
- [Proxy Modes](#proxy-modes)
- [Network Model](#network-model)
- [Local Builds](#local-builds)
- [Data Layout](#data-layout)
- [zsh and tmux](#zsh-and-tmux)
- [Web UI and Access](#web-ui-and-access)
- [Troubleshooting](#troubleshooting)
- [Release](#release)

## Requirements

- Docker with Docker Compose v2.
- `bash`, `curl`, `git`, and standard Unix shell tools on the host.
- A host environment that can run privileged containers with `/dev/net/tun`.
- A working proxy endpoint or a Mihomo YAML file if external traffic must go through a chained proxy.

## Install

Install the latest stable release:

Migration note: this installer and updater preserve existing Claude login state, personalization data, Docker settings, mounts, and container home data under `~/.cac/docker`. Install and update leave existing containers running by default; rebuild images explicitly when you are ready. User data is kept and you normally do not need to log in to Claude again.

中文提示：执行下面的一键安装或升级命令不会删除已有 Claude 登录信息、个性化配置、项目数据、挂载配置和 Docker 运行数据。迁移是安全的；安装和升级默认不会停止正在运行的旧容器，需要时再手动重建镜像/容器，不会因此要求重复登录。

```bash
curl -fsSL https://github.com/ZMK112/claude-docker/releases/latest/download/install-stable.sh | bash
```

The installer downloads a `cac-docker-claude-source-*.zip` release asset, verifies the `.sha256` file when present, installs the full source tree to `~/.cac/source`, and links:

```text
~/.cac/docker -> ~/.cac/source/docker
~/bin/cac    -> ~/.cac-dist/cac
```

Temporary installer files are removed automatically. Existing Docker state is preserved:

```text
~/.cac/docker/.env
~/.cac/docker/data/
~/.cac/docker/mounts.json
~/.cac/docker/docker-compose.mounts.yml
```

中文：安装包只作为安装介质使用，后续运行数据保存在 `~/.cac/docker`。升级时会尽量保留 Claude 个性化数据、登录状态、挂载配置和 Docker 配置；容器和镜像可以重建，用户数据不应被覆盖。

## Quick Start

```bash
cac docker setup
cac docker create
cac docker start
cac docker enter
```

Check network and identity state:

```bash
cac docker check
```

Update to the latest stable release:

```bash
cac docker update
CAC_DOCKER_REBUILD=1 cac docker create
cac docker start
```

## Common Commands

| Command | Description | 中文说明 |
| --- | --- | --- |
| `cac docker setup` | Interactive setup for proxy, network, data path, shell, SSH, Web UI, and mounts. | 交互式配置代理、网络、数据目录、Shell、SSH、Web UI 和挂载。 |
| `cac docker create` | Build or prepare Docker images and compose resources. | 构建或准备 Docker 镜像和 compose 资源。 |
| `CAC_DOCKER_REBUILD=1 cac docker create` | Force a local image rebuild. | 强制重新本地构建镜像。 |
| `cac docker rebuild` | Force a rebuild, recreate the container when needed, then ask before removing old project images. | 强制重建，需要时重建容器；完成后会询问是否清理本项目旧镜像。 |
| `cac docker start` | Start the Docker runtime stack; if already running, report status and exit successfully. | 启动 Docker 运行环境；如果已经运行则提示状态并正常退出。 |
| `cac docker stop` | Stop the runtime stack without deleting data. | 停止运行环境，不删除数据。 |
| `cac docker restart` | Restart the runtime stack and remount the current directory as `/workspace`. | 重启运行环境，并把当前目录重新挂载为 `/workspace`。 |
| `cac docker enter` | Open a shell inside the protected container. | 进入受保护的主容器 Shell。 |
| `cac docker check` | Run network, DNS, TUN, exit IP, identity, SSH, and trace checks. | 检查网络、DNS、TUN、出口 IP、身份伪装、SSH 和容器痕迹。 |
| `cac docker status` | Show current container, image, proxy, port, and data status. | 查看容器、镜像、代理、端口和数据状态。 |
| `cac docker logs` | Follow main container logs. | 跟随主容器日志。 |
| `cac docker mount` | Manage extra host-directory mounts. | 管理额外挂载目录。 |
| `cac docker direct` | Manage domain keywords that use direct DNS and direct route. | 管理 DNS 和访问都直连的域名关键词。 |
| `cac docker port` | Forward a local host port to the container. | 把本机端口转发到容器。 |
| `cac docker update` | Install latest stable release with rollback on failure. | 更新到最新 stable 版本，失败时自动回滚。 |
| `cac docker destroy` | Remove containers/networks/images managed by this project. | 删除本项目管理的容器、网络和镜像。 |

## Mounts

Add a host directory mount:

```bash
cac docker mount add /path/on/host /workspace/name
```

List mounts:

```bash
cac docker mount ls
```

Remove a mount:

```bash
cac docker mount rm /workspace/name
```

Restart the stack and remount the current directory as `/workspace`:

```bash
cac docker restart
```

Mount targets under `/workspace` are reserved and rejected. The main `/workspace` bind is controlled by the directory used for `cac docker restart` or the first `cac docker start` when no container is running. Running `cac docker start` against an already running stack is a no-op and will not change the active workspace. If a running container is recreated by `cac docker mount`, the existing workspace path is preserved.

## Proxy Modes

`cac docker setup` accepts a normal proxy URI or a YAML file path.

Normal proxy examples:

```text
socks5h://127.0.0.1:7890
http://127.0.0.1:7890
host:port:user:password
ss://...
vmess://...
vless://...
trojan://...
```

YAML chain mode:

```text
/path/to/config.yaml
/path/to/config.yml
```

When the setup input is an existing `.yaml` or `.yml` file, the setup flow treats it as a Mihomo config and converts the needed proxy chain/rules into sing-box configs. The main runtime container still uses sing-box TUN; the YAML is not run directly as a Mihomo process.

中文：如果输入的是存在的 YAML/YML 文件，则启用 Mihomo YAML 链式代理迁移逻辑。外网流量经过 TUN 和链式代理；内部 Docker 网络、容器网络、必要局域网地址可以按规则直连，避免把内部控制流量错误送进代理。

### Direct Domains for EAA/Internal Access

Some enterprise access products, including Akamai EAA, authenticate on the host and expect selected internal domains to avoid the container proxy chain. Configure those domains explicitly:

```env
CAC_DIRECT_DOMAIN_KEYWORDS=akamai-access.com,timeresearch,rockbund
CAC_DIRECT_DNS_SERVER=127.0.0.11
```

This adds both sing-box DNS rules and route rules for matching domains. DNS for matching domains uses the direct DNS path, and the final connection uses `direct`; other traffic continues to use the configured proxy or YAML chain. The default direct DNS server is Docker's embedded resolver `127.0.0.11`, so EAA and internal domains can follow the host/Docker DNS path instead of being sent to a public DoH resolver.

中文：对于 EAA 或企业内网域名，可以设置 `CAC_DIRECT_DOMAIN_KEYWORDS`。匹配关键词的域名会使用直连 DNS，并且连接本身也直连，不进入 Docker 内部代理链。直连 DNS 默认使用 Docker 内置解析器 `127.0.0.11`，避免公司内网域名被送到公网 DoH。该配置默认包含 `akamai-access.com,timeresearch,rockbund`，用于常见 EAA 内网访问；如不需要可用 `cac docker direct rm` 删除。

Manage the keyword list with:

```bash
cac docker direct add akamai-access.com timeresearch rockbund
cac docker direct ls
cac docker direct rm timeresearch
```

中文：推荐使用 `cac docker direct add|ls|rm` 管理直连关键词。`add` 和 `rm` 会更新 `.env`；如果当前是 Mihomo YAML 链式模式，还会基于保存的 YAML 源文件重新生成 sing-box 配置，保证 DNS 直连和访问直连同时生效。

After editing `~/.cac/docker/.env` manually, or after saving direct keyword changes without an immediate restart, restart:

```bash
cac docker restart
```

## Network Model

The runtime stack separates several responsibilities:

- Main container: Claude Code runtime, Web UI, SSH, sing-box TUN.
- Gateway/docker-proxy sidecar: exposes a controlled Docker API path into the main container.
- Proxy bridge sidecar: provides proxy settings for child containers created from inside the main container.
- Docker networks: isolate runtime traffic and keep internal control paths reachable.

External application traffic from the main container is expected to pass through sing-box TUN. Internal traffic required for Docker control, child containers, loopback, and configured private ranges can be direct.

Optional TCP tuning is available but disabled by default to preserve historical behavior:

```env
CAC_NET_TUNING=1
CAC_NET_TUNING_BBR=auto
```

When enabled, the container tries to apply TCP fast open, MTU probing, and shorter keepalive values inside the privileged network namespace. BBR is only enabled when the Docker VM or Linux host kernel exposes `bbr` in `tcp_available_congestion_control`; on many Docker Desktop or OrbStack hosts it is not available, so the runtime logs that BBR was skipped. `cac docker check` reports the active tuning state.

中文：网络调优默认关闭。开启 `CAC_NET_TUNING=1` 后会尝试设置 TCP fast open、MTU probing 和 keepalive 参数。BBR 只有在宿主机或 Docker VM 内核支持时才会启用；如果不可用会跳过，不影响容器启动。

## Local Builds

Stable installs keep complete source under `~/.cac/source`, so Docker mode defaults to local image builds:

```text
CAC_DOCKER_BUILD_LOCAL=1
```

That means normal installs do not depend on a remote runtime image pull. The pinned image name is still recorded for deterministic local tags and optional fallback:

```text
ghcr.io/zmk112/claude-docker:v0.1.30
```

Force a rebuild:

```bash
CAC_DOCKER_REBUILD=1 cac docker create
```

Rebuild and optionally clean old project images:

```bash
cac docker rebuild
```

`cac docker rebuild` only offers to remove images identified as this project or historical cac Docker image tags, and it protects images currently used by containers.

Pass a build proxy for downloads during image build:

```bash
BUILD_PROXY=socks5h://127.0.0.1:7890 cac docker create
```

Build progress is printed in plain mode by default so Dockerfile steps, package downloads, and npm output remain visible in real time. To restore Docker Compose's default progress UI, set:

```bash
COMPOSE_PROGRESS=auto BUILDKIT_PROGRESS=auto cac docker create
```

## Data Layout

Important paths:

```text
~/.cac/source/       Full installed source tree
~/.cac/docker/       Docker runtime directory
~/.cac/docker/data/  Persistent container home/state
~/.cac-dist/         Installed cac launcher files
~/bin/cac            User command entry
```

Release zip files and temporary install directories are not needed after installation. The installer removes its temporary files automatically.

## zsh and tmux

When zsh is selected during setup, the container can initialize:

- Oh My Zsh
- `zsh-autosuggestions`
- `zsh-syntax-highlighting`
- default `~/.zshrc`
- default `~/.tmux.conf`

The default tmux config includes mouse support, `C-a` prefix, vim-style pane movement/resize, vi copy mode, Claude Code terminal title handling, pane title borders, and a compact status bar.

## Web UI and Access

If enabled during setup, the Web UI is exposed on the configured local port, normally:

```text
http://127.0.0.1:3001
```

SSH is enabled by default for direct localhost container access. `cac docker setup` lets you keep SSH on, choose the host port, and set the password. After the stack starts, `cac docker status` prints the SSH command.

Default local connection:

```bash
ssh -p 2222 cherny@127.0.0.1
```

Common SSH settings in `~/.cac/docker/.env`:

```text
CAC_ENABLE_SSH=1
CAC_HOST_SSH_BIND=127.0.0.1
CAC_HOST_SSH_PORT=2222
CAC_SSH_PASSWORD=REPLACE_WITH_STRONG_PASSWORD
```

Keep SSH and the no-login Web UI bound to `127.0.0.1` unless you explicitly need LAN access. If you bind either service to `0.0.0.0` or another LAN address, change `CAC_SSH_PASSWORD` first and restrict access with host firewall rules, IP allowlisting, or an authenticated reverse proxy. Do not commit real proxy share links, SSH passwords, bridge passwords, generated `.env` files, or subscription exports.

New setup runs generate a random SSH password and a random child proxy bridge password when none exists. Existing `.env` values are preserved during install/update, so users with older deployments should review `CAC_HOST_SSH_BIND`, `CAC_HOST_WEB_BIND`, `CAC_SSH_PASSWORD`, and `CAC_CHILD_PROXY_BRIDGE_PASSWORD` manually.

中文：SSH 默认开启，用于从宿主机直接进入主容器，并默认只监听 `127.0.0.1`。连接命令通常是 `ssh -p 2222 cherny@127.0.0.1`。如果要开放给局域网，先修改默认密码，并确认宿主机防火墙规则。

## Troubleshooting

Show status:

```bash
cac docker status
```

Follow logs:

```bash
cac docker logs
```

Run diagnostics:

```bash
cac docker check
```

Rebuild after Dockerfile or dependency changes:

```bash
CAC_DOCKER_REBUILD=1 cac docker create
cac docker restart
```

If setup saves a bad proxy, rerun:

```bash
cac docker setup
```

## Release

Build a source release asset:

```bash
PKG_VERSION=v0.1.30 bash scripts/package-source.sh
```

Upload these files to the GitHub release:

```text
dist/cac-docker-claude-source-v0.1.30.zip
dist/cac-docker-claude-source-v0.1.30.sha256
scripts/install-stable.sh
```

Use stable releases for versions intended for end users. Development releases should be prereleases or not marked as GitHub latest.
