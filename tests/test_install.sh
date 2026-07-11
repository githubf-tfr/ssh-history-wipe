#!/bin/bash
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
installer="$here/../install.sh"
fail=0

run_test() {
    local name="$1"
    shift
    if "$@"; then
        echo "PASS: $name"
    else
        echo "FAIL: $name"
        fail=1
    fi
}

test_installs_script_with_correct_mode() {
    local tmp dest pamfile
    tmp="$(mktemp -d)"
    dest="$tmp/wipe-history-on-logout.sh"
    pamfile="$tmp/sshd"
    : > "$pamfile"
    SCRIPT_DEST="$dest" PAM_SSHD_FILE="$pamfile" bash "$installer" >/dev/null
    [ -f "$dest" ] || { rm -rf "$tmp"; return 1; }
    local mode
    mode="$(stat -c '%a' "$dest")"
    rm -rf "$tmp"
    [ "$mode" = "750" ]
}

test_adds_pam_line() {
    local tmp dest pamfile
    tmp="$(mktemp -d)"
    dest="$tmp/wipe-history-on-logout.sh"
    pamfile="$tmp/sshd"
    : > "$pamfile"
    SCRIPT_DEST="$dest" PAM_SSHD_FILE="$pamfile" bash "$installer" >/dev/null
    local count
    count="$(grep -cF "session optional pam_exec.so seteuid $dest" "$pamfile")"
    rm -rf "$tmp"
    [ "$count" = "1" ]
}

test_rerun_does_not_duplicate_pam_line() {
    local tmp dest pamfile
    tmp="$(mktemp -d)"
    dest="$tmp/wipe-history-on-logout.sh"
    pamfile="$tmp/sshd"
    : > "$pamfile"
    SCRIPT_DEST="$dest" PAM_SSHD_FILE="$pamfile" bash "$installer" >/dev/null
    SCRIPT_DEST="$dest" PAM_SSHD_FILE="$pamfile" bash "$installer" >/dev/null
    local count
    count="$(grep -cF "session optional pam_exec.so seteuid $dest" "$pamfile")"
    rm -rf "$tmp"
    [ "$count" = "1" ]
}

run_test "installs script with mode 750" test_installs_script_with_correct_mode
run_test "adds the PAM line" test_adds_pam_line
run_test "re-running does not duplicate the PAM line" test_rerun_does_not_duplicate_pam_line

exit $fail
