#!/bin/bash
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
installer="$here/../install.sh"
canonical="$here/../files/wipe-history-on-logout.sh"
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

# The contract mode is 0755: the dropped-privilege re-exec needs the target
# account to be able to execute the script (a stricter mode makes the
# mechanism silently inoperative - first-class failure mode, see spec).
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
    [ "$mode" = "755" ]
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

# Crit. 8: a target already deployed with the old body and the old 0750 mode
# must converge to the new body AND mode 0755 after a single replay - the
# property that protects the existing fleet (no mixed "new script + old
# mode" state possible).
test_converges_from_old_mode_750() {
    local tmp dest pamfile mode
    tmp="$(mktemp -d)"
    dest="$tmp/wipe-history-on-logout.sh"
    pamfile="$tmp/sshd"
    : > "$pamfile"
    printf '#!/bin/bash\n# old body\n' > "$dest"
    chmod 750 "$dest"
    SCRIPT_DEST="$dest" PAM_SSHD_FILE="$pamfile" bash "$installer" >/dev/null
    mode="$(stat -c '%a' "$dest")"
    diff -q "$dest" "$canonical" >/dev/null || { rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
    [ "$mode" = "755" ]
}

run_test "installs script with mode 755" test_installs_script_with_correct_mode
run_test "adds the PAM line" test_adds_pam_line
run_test "re-running does not duplicate the PAM line" test_rerun_does_not_duplicate_pam_line
run_test "single replay converges body and mode from an old 0750 install" test_converges_from_old_mode_750

exit $fail
