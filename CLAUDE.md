# Project Notes

This repository is the Docker-only split of the original cac project.

- Keep `cac docker ...` command compatibility.
- Do not reintroduce local `cac env`, `cac claude`, local relay, or local fingerprint-hook modes.
- Stable release assets use `cac-docker-claude-source-<version>.zip`.
- The one-command installer keeps full source under `~/.cac/source` so Docker images can build locally.
