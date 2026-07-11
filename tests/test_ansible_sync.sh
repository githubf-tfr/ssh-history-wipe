#!/bin/bash
# The Ansible role embeds the cleanup script's source directly in
# tasks/main.yml (content: |) rather than copying an external file, so
# there's no separate asset to keep in sync automatically - this test
# extracts that inline block and diffs it against the canonical script to
# catch the two copies drifting apart silently.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
canonical="$here/../files/wipe-history-on-logout.sh"
tasks_file="$here/../ansible/roles/ssh_history_wipe/tasks/main.yml"
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

test_ansible_inline_script_matches_canonical() {
    local extracted
    extracted="$(mktemp)"
    python3 - "$tasks_file" > "$extracted" <<'PYEOF'
import sys
import yaml

with open(sys.argv[1]) as f:
    tasks = yaml.safe_load(f)

for task in tasks:
    copy_args = task.get("ansible.builtin.copy")
    if copy_args and "content" in copy_args:
        sys.stdout.write(copy_args["content"])
        break
PYEOF
    diff "$extracted" "$canonical" >/dev/null 2>&1
    local result=$?
    rm -f "$extracted"
    return $result
}

run_test "ansible role's inline script content matches files/wipe-history-on-logout.sh" \
    test_ansible_inline_script_matches_canonical

exit $fail
