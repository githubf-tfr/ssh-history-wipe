#!/bin/bash
# The Ansible role keeps its own copy of the cleanup script (not a symlink,
# so the role stays self-contained/portable) - this guards against the two
# copies drifting apart silently.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
canonical="$here/../files/wipe-history-on-logout.sh"
role_copy="$here/../ansible/roles/ssh_history_wipe/files/wipe-history-on-logout.sh"
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

test_ansible_copy_matches_canonical_script() {
    diff -q "$canonical" "$role_copy" >/dev/null 2>&1
}

run_test "ansible role's script copy matches files/wipe-history-on-logout.sh" \
    test_ansible_copy_matches_canonical_script

exit $fail
