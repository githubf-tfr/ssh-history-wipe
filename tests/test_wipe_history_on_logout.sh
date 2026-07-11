#!/bin/bash
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target="$here/../files/wipe-history-on-logout.sh"
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

test_truncates_existing_history() {
    local tmp
    tmp="$(mktemp -d)"
    echo "ls -la" > "$tmp/.bash_history"
    echo "cat /etc/shadow" >> "$tmp/.bash_history"
    ( source "$target"; truncate_history "$tmp" )
    [ -f "$tmp/.bash_history" ] || { rm -rf "$tmp"; return 1; }
    [ -s "$tmp/.bash_history" ] && { rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
    return 0
}

test_missing_home_is_noop() {
    ( source "$target"; truncate_history "/nonexistent/path/does-not-exist" )
    [ $? -eq 0 ]
}

test_main_without_pam_user_is_noop() {
    local out
    out="$(unset PAM_USER; source "$target"; main; echo "exit:$?")"
    [ "$out" = "exit:0" ]
}

run_test "truncates existing history" test_truncates_existing_history
run_test "missing home is a silent no-op" test_missing_home_is_noop
run_test "main without PAM_USER is a no-op" test_main_without_pam_user_is_noop

exit $fail
