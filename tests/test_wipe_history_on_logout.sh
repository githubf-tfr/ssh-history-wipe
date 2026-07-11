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
    out="$(unset PAM_USER; export PAM_TYPE=close_session; source "$target"; main; echo "exit:$?")"
    [ "$out" = "exit:0" ]
}

# PAM invokes the "session" line at both open and close; main must only act
# on close_session (see comment in files/wipe-history-on-logout.sh). Shadow
# getent so the test proves cleanup was never attempted, without touching
# any real user's home directory.
test_main_skips_open_session() {
    local marker called
    marker="$(mktemp)"
    (
        getent() { echo "CALLED" >> "$marker"; }
        export PAM_TYPE=open_session
        export PAM_USER=root
        source "$target"
        main
    )
    called="$(cat "$marker")"
    rm -f "$marker"
    [ -z "$called" ]
}

test_main_proceeds_on_close_session() {
    local marker called
    marker="$(mktemp)"
    (
        getent() { echo "CALLED" >> "$marker"; }
        export PAM_TYPE=close_session
        export PAM_USER=root
        source "$target"
        main
    )
    called="$(cat "$marker")"
    rm -f "$marker"
    [ -n "$called" ]
}

run_test "truncates existing history" test_truncates_existing_history
run_test "missing home is a silent no-op" test_missing_home_is_noop
run_test "main without PAM_USER is a no-op" test_main_without_pam_user_is_noop
run_test "main skips PAM_TYPE=open_session (no cleanup attempted)" test_main_skips_open_session
run_test "main proceeds on PAM_TYPE=close_session" test_main_proceeds_on_close_session

exit $fail
