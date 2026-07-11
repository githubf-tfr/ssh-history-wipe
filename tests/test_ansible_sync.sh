#!/bin/bash
# The standalone role (roles/ssh_history_wipe_standalone) embeds the cleanup
# script's source directly in tasks/main.yml (content: |) so it has no
# external file dependency - but that means it can drift silently from
# files/wipe-history-on-logout.sh. This test extracts that inline block and
# diffs it against the canonical script to catch that.
#
# The other role (roles/ssh_history_wipe) reads files/wipe-history-on-logout.sh
# directly via `src:` at apply time, so there's nothing to drift there - no
# equivalent check needed for it.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
canonical="$here/../files/wipe-history-on-logout.sh"
tasks_file="$here/../ansible/roles/ssh_history_wipe_standalone/tasks/main.yml"
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

test_standalone_inline_script_matches_canonical() {
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

run_test "standalone role's inline script content matches files/wipe-history-on-logout.sh" \
    test_standalone_inline_script_matches_canonical

exit $fail
