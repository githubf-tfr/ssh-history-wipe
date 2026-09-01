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

# --- Security fix (2026-09-01): the guard and the dropped-privilege path ---

# Crit. 1: a symlinked ~/.bash_history must never be followed - the witness
# file it points to stays intact and the link stays in place.
test_symlink_history_leaves_witness_intact() {
    local tmp home witness
    tmp="$(mktemp -d)"
    home="$tmp/home"
    witness="$tmp/witness"
    mkdir "$home"
    printf 'contenu-temoin\n' > "$witness"
    ln -s "$witness" "$home/.bash_history"
    ( source "$target"; truncate_history "$home" )
    [ "$(cat "$witness")" = "contenu-temoin" ] || { rm -rf "$tmp"; return 1; }
    [ -L "$home/.bash_history" ] || { rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
    return 0
}

# Crit. 3: a FIFO in place of ~/.bash_history is left untouched and the call
# returns (no hang on open). timeout only bounds a would-be hang: exit 124
# means the call blocked, which is the failure this test guards against.
test_fifo_history_left_in_place() {
    local tmp status
    tmp="$(mktemp -d)"
    mkfifo "$tmp/.bash_history"
    timeout 5 bash -c "source '$target'; truncate_history '$tmp'"
    status=$?
    [ "$status" -ne 124 ] || { rm -rf "$tmp"; return 1; }
    [ -p "$tmp/.bash_history" ] || { rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
    return 0
}

# Crit. 4: an account without history has nothing to clean - the file must
# not be created (a root-owned one would lock history writing at login).
test_absent_history_not_created() {
    local tmp
    tmp="$(mktemp -d)"
    ( source "$target"; truncate_history "$tmp" )
    [ ! -e "$tmp/.bash_history" ] || { rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
    return 0
}

# Crit. 2 - central criterion: the dropped-privilege path runs end to end,
# exactly the way PAM invokes it (direct execution of the file, not sourced).
# A fake getent ahead of PATH resolves PAM_USER to a sandbox home owned by
# the current user, whose uid equals the current euid, so main takes the
# "euid = target uid" branch: main -> dispatch -> timeout -> re-exec with
# --wipe -> truncate_history. The script copy carries the contract mode 0755;
# the test fails if the dispatch, the re-exec or the executability breaks
# (e.g. a mode that stops the re-exec would leave the file non-empty).
test_pam_exec_path_wipes_history_end_to_end() {
    local tmp script home fakebin
    tmp="$(mktemp -d)"
    script="$tmp/wipe-history-on-logout.sh"
    cp "$target" "$script"
    chmod 755 "$script"
    home="$tmp/home"
    mkdir "$home"
    printf 'echo secret\n' > "$home/.bash_history"
    fakebin="$tmp/bin"
    mkdir "$fakebin"
    cat > "$fakebin/getent" <<FAKE
#!/bin/bash
printf '%s\n' "testuser:x:$(id -u):$(id -g)::$home:/bin/bash"
FAKE
    chmod 755 "$fakebin/getent"
    env PATH="$fakebin:$PATH" PAM_TYPE=close_session PAM_USER="$(id -un)" "$script"
    [ -f "$home/.bash_history" ] || { rm -rf "$tmp"; return 1; }
    [ -s "$home/.bash_history" ] && { rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
    return 0
}

# Crit. 6: PAM_USER unknown to account resolution - nothing written anywhere.
# HOME points at a sandbox with a non-empty history to catch any wrongful
# fallback on the caller's environment.
test_main_unknown_user_writes_nothing() {
    local tmp script home fakebin
    tmp="$(mktemp -d)"
    script="$tmp/wipe-history-on-logout.sh"
    cp "$target" "$script"
    chmod 755 "$script"
    home="$tmp/home"
    mkdir "$home"
    printf 'echo secret\n' > "$home/.bash_history"
    fakebin="$tmp/bin"
    mkdir "$fakebin"
    printf '#!/bin/bash\nexit 2\n' > "$fakebin/getent"
    chmod 755 "$fakebin/getent"
    env PATH="$fakebin:$PATH" HOME="$home" PAM_TYPE=close_session PAM_USER=ghost "$script"
    [ "$(cat "$home/.bash_history")" = "echo secret" ] || { rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
    return 0
}

# Spec edge case: a passwd entry with an empty uid field must be a silent
# no-op (7 colon-separated fields: name:passwd:uid:gid:gecos:home:shell,
# uid and gid left empty here).
test_main_empty_uid_writes_nothing() {
    local tmp script home fakebin
    tmp="$(mktemp -d)"
    script="$tmp/wipe-history-on-logout.sh"
    cp "$target" "$script"
    chmod 755 "$script"
    home="$tmp/home"
    mkdir "$home"
    printf 'echo secret\n' > "$home/.bash_history"
    fakebin="$tmp/bin"
    mkdir "$fakebin"
    cat > "$fakebin/getent" <<FAKE
#!/bin/bash
printf '%s\n' "ghost:x::::$home:/bin/bash"
FAKE
    chmod 755 "$fakebin/getent"
    env PATH="$fakebin:$PATH" PAM_TYPE=close_session PAM_USER=ghost "$script"
    [ "$(cat "$home/.bash_history")" = "echo secret" ] || { rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
    return 0
}

run_test "truncates existing history" test_truncates_existing_history
run_test "missing home is a silent no-op" test_missing_home_is_noop
run_test "main without PAM_USER is a no-op" test_main_without_pam_user_is_noop
run_test "main skips PAM_TYPE=open_session (no cleanup attempted)" test_main_skips_open_session
run_test "main proceeds on PAM_TYPE=close_session" test_main_proceeds_on_close_session
run_test "symlinked history leaves target intact" test_symlink_history_leaves_witness_intact
run_test "FIFO history left in place, no hang" test_fifo_history_left_in_place
run_test "absent history is not created" test_absent_history_not_created
run_test "PAM exec path wipes history end to end" test_pam_exec_path_wipes_history_end_to_end
run_test "unknown PAM_USER writes nothing" test_main_unknown_user_writes_nothing
run_test "empty uid in passwd entry writes nothing" test_main_empty_uid_writes_nothing

exit $fail
