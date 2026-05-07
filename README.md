# cac-docker-claude

Docker-only Claude Code runtime with sing-box TUN isolation, proxy-chain support, persistent Claude state, and local Docker image builds.

中文：这是从原 `cac` 项目拆分出来的 Docker 专用版本。它只保留 `cac docker ...` 工作流，用 Docker 容器运行 Claude Code，并通过 sing-box TUN 把容器网络流量纳入代理和规则控制。

## What It Provides

- Docker-only command surface: `cac docker ...`
- sing-box TUN isolation for the main runtime container
- Mihomo YAML chain conversion for chained proxy setups
- Direct rules for internal Docker/LAN traffic while keeping external traffic behind TUN
- Persistent Claude/container state under `~/.cac/docker`
- Full source install under `~/.cac/source`, so images can be built locally
- Stable update command with rollback behavior
- Optional zsh, Oh My Zsh, plugins, and tmux defaults inside the container
- Web UI, SSH, Docker socket proxy, child-container proxy bridge, and extra mount management

Non-Docker cac features such as `cac env`, `cac claude`, local relay mode, and local fingerprint-hook environments are not part of this project.

## Install

Install the latest stable release:

Migration note: this installer and updater preserve existing Claude login state, personalization data, Docker settings, mounts, and container home data under `~/.cac/docker`. Images and containers may be rebuilt during install or update, but user data is kept and you normally do not need to log in to Claude again.

中文提示：执行下面的一键安装或升级命令不会删除已有 Claude 登录信息、个性化配置、项目数据、挂载配置和 Docker 运行数据。迁移是安全的；安装或升级过程中可能会重建镜像/容器，但不会因此要求重复登录。

```bash
curl -fsSL https://github.com/ZMK112/cac-docker-claude/releases/latest/download/install-stable.sh | bash
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
```

## Common Commands

| Command | Description | 中文说明 |
| --- | --- | --- |
| `cac docker setup` | Interactive setup for proxy, network, data path, shell, SSH, Web UI, and mounts. | 交互式配置代理、网络、数据目录、Shell、SSH、Web UI 和挂载。 |
| `cac docker create` | Build or prepare Docker images and compose resources. | 构建或准备 Docker 镜像和 compose 资源。 |
| `CAC_DOCKER_REBUILD=1 cac docker create` | Force a local image rebuild. | 强制重新本地构建镜像。 |
| `cac docker start` | Start the Docker runtime stack. | 启动 Docker 运行环境。 |
| `cac docker stop` | Stop the runtime stack without deleting data. | 停止运行环境，不删除数据。 |
| `cac docker restart` | Restart the runtime stack. | 重启运行环境。 |
| `cac docker enter` | Open a shell inside the protected container. | 进入受保护的主容器 Shell。 |
| `cac docker check` | Run network, DNS, TUN, exit IP, identity, SSH, and trace checks. | 检查网络、DNS、TUN、出口 IP、身份伪装、SSH 和容器痕迹。 |
| `cac docker status` | Show current container, image, proxy, port, and data status. | 查看容器、镜像、代理、端口和数据状态。 |
| `cac docker logs` | Follow main container logs. | 跟随主容器日志。 |
| `cac docker mount` | Manage extra host-directory mounts. | 管理额外挂载目录。 |
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

After changing mounts, restart the stack:

```bash
cac docker restart
```

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

## Network Model

The runtime stack separates several responsibilities:

- Main container: Claude Code runtime, Web UI, SSH, sing-box TUN.
- Gateway/docker-proxy sidecar: exposes a controlled Docker API path into the main container.
- Proxy bridge sidecar: provides proxy settings for child containers created from inside the main container.
- Docker networks: isolate runtime traffic and keep internal control paths reachable.

External application traffic from the main container is expected to pass through sing-box TUN. Internal traffic required for Docker control, child containers, loopback, and configured private ranges can be direct.

## Local Builds

Stable installs keep complete source under `~/.cac/source`, so Docker mode defaults to local image builds:

```text
CAC_DOCKER_BUILD_LOCAL=1
```

That means normal installs do not depend on a remote runtime image pull. The pinned image name is still recorded for deterministic local tags and optional fallback:

```text
ghcr.io/zmk112/cac-docker-claude:v0.1.3
```

Force a rebuild:

```bash
CAC_DOCKER_REBUILD=1 cac docker create
```

Pass a build proxy for downloads during image build:

```bash
BUILD_PROXY=socks5h://127.0.0.1:7890 cac docker create
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

## zsh And tmux

When zsh is selected during setup, the container can initialize:

- Oh My Zsh
- `zsh-autosuggestions`
- `zsh-syntax-highlighting`
- default `~/.zshrc`
- default `~/.tmux.conf`

The default tmux config includes mouse support, `C-a` prefix, vim-style pane movement/resize, vi copy mode, Claude Code terminal title handling, pane title borders, and a compact status bar.

## Web UI And Access

If enabled during setup, the Web UI is exposed on the configured local port, normally:

```text
http://127.0.0.1:3001
```

SSH can also be enabled for direct container access. `cac docker setup` lets you enable SSH, choose the host port, and set the password. After the stack starts, `cac docker status` prints the SSH command.

Default local connection:

```bash
ssh -p 2222 cherny@127.0.0.1
```

Common SSH settings in `~/.cac/docker/.env`:

```text
CAC_ENABLE_SSH=1
CAC_HOST_SSH_BIND=127.0.0.1
CAC_HOST_SSH_PORT=2222
CAC_SSH_PASSWORD=your-password
```

Keep SSH bound to `127.0.0.1` unless you explicitly need LAN access. If you bind SSH to `0.0.0.0` or another LAN address, change `CAC_SSH_PASSWORD` first and restrict access at the host firewall.

中文：SSH 用于从宿主机直接进入主容器。默认建议只监听 `127.0.0.1`，连接命令通常是 `ssh -p 2222 cherny@127.0.0.1`。如果要开放给局域网，先修改默认密码，并确认宿主机防火墙规则。

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
PKG_VERSION=v0.1.3 bash scripts/package-source.sh
```

Upload these files to the GitHub release:

```text
dist/cac-docker-claude-source-v0.1.3.zip
dist/cac-docker-claude-source-v0.1.3.sha256
scripts/install-stable.sh
```

Use stable releases for versions intended for end users. Development releases should be prereleases or not marked as GitHub latest.
