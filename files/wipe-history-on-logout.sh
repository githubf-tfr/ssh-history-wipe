#!/bin/bash
set -u

truncate_history() {
    local home="$1"
    [ -d "$home" ] || return 0
    : > "$home/.bash_history" 2>/dev/null
    return 0
}

main() {
    [ -n "${PAM_USER:-}" ] || return 0
    local home
    home="$(getent passwd "$PAM_USER" | cut -d: -f6)"
    truncate_history "$home"
    return 0
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main
    exit 0
fi
