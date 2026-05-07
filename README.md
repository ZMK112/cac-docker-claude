# cac-docker-claude

Docker-only Claude Code runtime with sing-box TUN isolation, proxy-chain support, persistent Claude state, and local Docker image builds.

This project intentionally keeps the user-facing command shape for Docker mode:

```bash
cac docker setup
cac docker create
cac docker start
cac docker enter
cac docker check
```

Non-Docker cac features such as `cac env`, `cac claude`, local relay mode, and local fingerprint-hook environments are not part of this project.

## Install

Install the latest stable release:

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

## Basic Use

Configure proxy and network:

```bash
cac docker setup
```

Build local images and start:

```bash
cac docker create
cac docker start
```

Enter the protected container:

```bash
cac docker enter
```

Run diagnostics:

```bash
cac docker check
```

Update to the latest stable release with rollback:

```bash
cac docker update
```

## Local Builds

Stable installs keep complete source under `~/.cac/source`, so Docker mode defaults to local image builds:

```text
CAC_DOCKER_BUILD_LOCAL=1
```

That means normal installs do not depend on a remote runtime image pull. The pinned image name is still recorded for deterministic local tags and optional fallback:

```text
ghcr.io/zmk112/cac-docker-claude:v0.1.1
```

Force a rebuild:

```bash
CAC_DOCKER_REBUILD=1 cac docker create
```

## Mihomo YAML Chains

`cac docker setup` accepts a `.yaml` or `.yml` path. When the file exists, the setup flow converts the Mihomo chain rules into sing-box configs for the Docker TUN path. Non-internal traffic is forced through the chain; internal Docker/LAN ranges can be direct according to the generated rules.

## Release

Build a source release asset:

```bash
PKG_VERSION=v0.1.1 bash scripts/package-source.sh
```

Upload these files to the GitHub release:

```text
dist/cac-docker-claude-source-v0.1.1.zip
dist/cac-docker-claude-source-v0.1.1.sha256
scripts/install-stable.sh
```

Use stable releases for versions intended for end users. Development releases should be prereleases or not marked as GitHub latest.
