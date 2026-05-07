# ── cmd: help ──────────────────────────────────────────────────

cmd_help() {
    echo
    echo "  $(_bold "cac-docker-claude") $(_dim "$CAC_VERSION") — Docker-only Claude Code runtime"
    echo

    echo "  $(_bold "Docker")"
    echo "    $(_green "cac docker setup")      Configure proxy and Docker network"
    echo "    $(_green "cac docker create")     Build local runtime images"
    echo "    $(_green "cac docker start")      Start the protected container"
    echo "    $(_green "cac docker enter")      Open a shell in the container"
    echo "    $(_green "cac docker check")      Validate network and identity"
    echo "    $(_green "cac docker update")     Update to latest stable release"
    echo "    $(_green "cac docker help")       Show all Docker commands"
    echo

    echo "  $(_dim "Examples:")"
    echo "    $(_dim "cac docker setup")"
    echo "    $(_dim "cac docker create")"
    echo "    $(_dim "cac docker start")"
    echo
}
