# ── entry: Docker-only command dispatcher ──────────────────────────────

[[ $# -eq 0 ]] && { cmd_help; exit 0; }

case "$1" in
    docker)             cmd_docker "${@:2}" ;;
    -v|--version)       cmd_version         ;;
    help|--help|-h)     cmd_help            ;;
    *)                  _die "unknown command: cac $1\n  use: cac docker help" ;;
esac
