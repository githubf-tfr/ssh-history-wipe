#!/bin/bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_SRC="$here/files/wipe-history-on-logout.sh"
SCRIPT_DEST="${SCRIPT_DEST:-/usr/local/sbin/wipe-history-on-logout.sh}"
PAM_SSHD_FILE="${PAM_SSHD_FILE:-/etc/pam.d/sshd}"
PAM_LINE="session optional pam_exec.so seteuid ${SCRIPT_DEST}"

cp "$SCRIPT_SRC" "$SCRIPT_DEST"
chmod 750 "$SCRIPT_DEST"
chown root:root "$SCRIPT_DEST" 2>/dev/null || true

if ! grep -qF "$PAM_LINE" "$PAM_SSHD_FILE" 2>/dev/null; then
    printf '%s\n' "$PAM_LINE" >> "$PAM_SSHD_FILE"
fi
