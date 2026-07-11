# ssh-history-wipe Implementation Plan


**Goal:** Build the two artifacts (PAM-exec cleanup script + idempotent installer) that truncate `~/.bash_history` on SSH logout for every account on AlmaLinux 8+, plus the manual verification runbook for the checks that require a real SSH session.

**Architecture:** A single self-contained shell script (`wipe-history-on-logout.sh`) is invoked by `pam_exec` at `session close` of `sshd`'s PAM stack; it truncates the disconnecting account's `~/.bash_history`. A second script (`install.sh`) deploys that script and registers the PAM line idempotently, and is the same artifact used both for ad-hoc SSH rollout on existing VMs and for baking into a VM template.

**Tech Stack:** POSIX-ish bash, PAM (`pam_exec.so`), no external test framework (plain bash assertions to avoid adding dependencies).

## Global Constraints

- Target OS: AlmaLinux 8+ only (spec §1).
- Target shell: bash only (spec §2).
- Applies uniformly to every account, including root, with no per-account config (spec §2).
- Must never block or delay SSH logout on error (spec §2, §5).
- Must never touch audit/log mechanisms (auditd, syslog, journalctl) (spec §1, §6).
- PAM line is exactly: `session optional pam_exec.so seteuid /usr/local/sbin/wipe-history-on-logout.sh` (spec §3).
- Script destination: `/usr/local/sbin/wipe-history-on-logout.sh`, owner `root:root`, mode `750` (spec §3).
- Truncate `~/.bash_history` in place — never delete/recreate the file (spec §3).
- `install.sh` must be idempotent — safe to re-run, no duplicate PAM lines (spec §4.2).
- Ansible role is out of scope for this plan (spec §4.2, §7).

---

## File Structure

```
projects/ssh-history-wipe/
├── spec.md                              (already written)
├── plan.md                              (this file)
├── files/
│   └── wipe-history-on-logout.sh        # PAM-exec cleanup script
├── install.sh                           # idempotent installer (uses files/wipe-history-on-logout.sh)
├── tests/
│   ├── test_wipe_history_on_logout.sh   # unit tests for the cleanup script
│   └── test_install.sh                  # idempotency/behavior tests for install.sh
└── docs/
    └── manual-verification.md           # runbook for the real-SSH checks from spec §6
```

- `files/wipe-history-on-logout.sh` exposes a `truncate_history <home_dir>` function (sourceable, so tests can call it directly without needing a real PAM session or a real system user) and a `main` entrypoint that reads `$PAM_USER`, resolves the home directory via `getent`, and calls `truncate_history`. `main` only runs when the file is executed directly, not when sourced — this is the test seam.
- `install.sh` reads its destination paths from environment variables with production defaults (`SCRIPT_DEST`, `PAM_SSHD_FILE`), so tests can redirect them to a temp sandbox instead of touching real `/etc/pam.d/sshd` and `/usr/local/sbin`.

---

### Task 1: Cleanup script (`wipe-history-on-logout.sh`)

**Files:**
- Create: `projects/ssh-history-wipe/files/wipe-history-on-logout.sh`
- Test: `projects/ssh-history-wipe/tests/test_wipe_history_on_logout.sh`

**Interfaces:**
- Produces: `truncate_history` — bash function, signature `truncate_history <home_dir>`. Truncates `<home_dir>/.bash_history` to empty if `<home_dir>` is a directory; no-op (return 0) if it isn't. Never errors out.
- Produces: `main` — bash function, no arguments. Reads `$PAM_USER` from the environment; if unset/empty, returns 0 immediately. Otherwise resolves the home directory via `getent passwd "$PAM_USER"` and calls `truncate_history` on it.
- Consumes: nothing (first task, no dependencies).

- [ ] **Step 1: Write the failing test**

Create `projects/ssh-history-wipe/tests/test_wipe_history_on_logout.sh`:

```bash
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
```

Make it executable:

```bash
chmod +x projects/ssh-history-wipe/tests/test_wipe_history_on_logout.sh
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash projects/ssh-history-wipe/tests/test_wipe_history_on_logout.sh`
Expected: FAIL — `files/wipe-history-on-logout.sh: No such file or directory` (the target script doesn't exist yet).

- [ ] **Step 3: Write minimal implementation**

Create `projects/ssh-history-wipe/files/wipe-history-on-logout.sh`:

```bash
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
```

Make it executable:

```bash
chmod +x projects/ssh-history-wipe/files/wipe-history-on-logout.sh
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash projects/ssh-history-wipe/tests/test_wipe_history_on_logout.sh`
Expected:
```
PASS: truncates existing history
PASS: missing home is a silent no-op
PASS: main without PAM_USER is a no-op
```
Exit code 0.

- [ ] **Step 5: Commit**

```bash
git add projects/ssh-history-wipe/files/wipe-history-on-logout.sh projects/ssh-history-wipe/tests/test_wipe_history_on_logout.sh
git commit -m "Add PAM-exec history cleanup script with unit tests"
```

---

### Task 2: Idempotent installer (`install.sh`)

**Files:**
- Create: `projects/ssh-history-wipe/install.sh`
- Test: `projects/ssh-history-wipe/tests/test_install.sh`

**Interfaces:**
- Consumes: `projects/ssh-history-wipe/files/wipe-history-on-logout.sh` (Task 1) — copied verbatim to `$SCRIPT_DEST`.
- Produces: `install.sh` accepts two optional environment overrides — `SCRIPT_DEST` (default `/usr/local/sbin/wipe-history-on-logout.sh`) and `PAM_SSHD_FILE` (default `/etc/pam.d/sshd`). This is also how it gets invoked from a VM-template build step (spec §4.1): run with production defaults, no overrides needed.

- [ ] **Step 1: Write the failing test**

Create `projects/ssh-history-wipe/tests/test_install.sh`:

```bash
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
```

Make it executable:

```bash
chmod +x projects/ssh-history-wipe/tests/test_install.sh
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash projects/ssh-history-wipe/tests/test_install.sh`
Expected: FAIL — `install.sh: No such file or directory` (installer doesn't exist yet).

- [ ] **Step 3: Write minimal implementation**

Create `projects/ssh-history-wipe/install.sh`:

```bash
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
```

Make it executable:

```bash
chmod +x projects/ssh-history-wipe/install.sh
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash projects/ssh-history-wipe/tests/test_install.sh`
Expected:
```
PASS: installs script with mode 750
PASS: adds the PAM line
PASS: re-running does not duplicate the PAM line
```
Exit code 0.

- [ ] **Step 5: Commit**

```bash
git add projects/ssh-history-wipe/install.sh projects/ssh-history-wipe/tests/test_install.sh
git commit -m "Add idempotent installer for the history cleanup mechanism"
```

---

### Task 3: Manual verification runbook

**Files:**
- Create: `projects/ssh-history-wipe/docs/manual-verification.md`

**Interfaces:**
- Consumes: `install.sh` (Task 2), run with production defaults (no env overrides) as documented in spec §4.1/§4.2.
- Produces: nothing consumed by later tasks — this is the terminal deliverable covering the spec §6 checks that need a real AlmaLinux host with sshd and PAM, which cannot run in this dev environment.

- [ ] **Step 1: Write the runbook**

Create `projects/ssh-history-wipe/docs/manual-verification.md`:

```markdown
# Manual verification runbook — ssh-history-wipe

Run these checks on a real AlmaLinux 8+ host after running `install.sh` as
root (see spec §4.2). These cover spec §6 items that need a live sshd/PAM
stack and cannot be exercised by the unit tests in `tests/`.

## 1. Install

```bash
sudo bash install.sh
```

Expected: no output, exit code 0. Verify:

```bash
ls -l /usr/local/sbin/wipe-history-on-logout.sh   # root root, -rwxr-x---
tail -1 /etc/pam.d/sshd                            # session optional pam_exec.so seteuid /usr/local/sbin/wipe-history-on-logout.sh
```

## 2. Cleanup on normal logout (non-root account)

```bash
ssh testuser@host
echo some-secret-command
history -a   # force write to disk before disconnecting
exit
```

Then from another session:

```bash
ssh admin@host "sudo cat /home/testuser/.bash_history | wc -l"
```

Expected: `0`.

## 3. Cleanup on normal logout (root account)

Repeat step 2 logging in as `root` instead of `testuser`, checking
`/root/.bash_history` afterward. Expected: `0` lines.

## 4. Non-blocking on script failure

Temporarily break the script to force a failure, then confirm SSH logout is
unaffected:

```bash
sudo chmod 000 /usr/local/sbin/wipe-history-on-logout.sh
ssh testuser@host "echo hi; exit"
```

Expected: the SSH session exits normally (no hang, no error surfaced to the
user). Restore permissions afterward:

```bash
sudo chmod 750 /usr/local/sbin/wipe-history-on-logout.sh
```

## 5. Idempotence of install.sh

```bash
sudo bash install.sh
sudo bash install.sh
grep -c "wipe-history-on-logout.sh" /etc/pam.d/sshd
```

Expected: `1` (single line, no duplicate).

## 6. Abrupt disconnect

```bash
ssh testuser@host
echo some-secret-command
history -a
```

Then kill the client-side connection abruptly (close the terminal, or
`kill -9` the local `ssh` process) instead of typing `exit`. Wait past the
server's `ClientAliveInterval * ClientAliveCountMax` (check
`sshd -T | grep -i clientalive` for the active values), then check:

```bash
ssh admin@host "sudo cat /home/testuser/.bash_history | wc -l"
```

Expected: `0`, once the wait has elapsed (see spec §3, "Comportement sur
coupure brutale" — this delay is expected behavior, not a defect).

## 7. No impact on audit/log mechanisms

Before and after the checks above, compare:

```bash
sudo ausearch --input-logs -ts recent | wc -l   # if auditd is active
sudo journalctl -u sshd --since "-10min" | wc -l
```

Expected: both keep growing/recording normally across the test session —
neither is emptied or altered by the cleanup mechanism.
```

- [ ] **Step 2: Review against spec §6**

Check off each spec §6 test line against the runbook: nettoyage effectif
(§1 non-root, §3 root), non-blocage (§4), idempotence de install.sh (§5),
coupure brutale (§6), non-régression audit (§7). All five spec §6 items are
covered — no gaps.

- [ ] **Step 3: Commit**

```bash
git add projects/ssh-history-wipe/docs/manual-verification.md
git commit -m "Add manual verification runbook for real-SSH checks"
```

---

## Self-Review Notes

- **Spec coverage:** §3 mechanism → Task 1. §4.2 install.sh → Task 2. §4.1 VM-template usage → documented as a Task 2 usage note (run `install.sh` with defaults during template build) and cross-referenced in Task 3 step 1. §5 error handling (silent no-op, `optional`, idempotent re-run) → covered by Task 1 tests (no-op cases) and Task 2 tests (idempotency) plus manual check #4. §6 tests → Task 1/2 unit tests cover what's automatable (truncation logic, idempotency); Task 3 runbook covers the remaining real-SSH/root/abrupt-disconnect/audit checks. §7 out-of-scope items (other shells, other distros, Ansible, open-session safety net) are correctly absent from all tasks.
- **Placeholder scan:** no TBD/TODO; every step has literal file content and exact commands.
- **Type consistency:** `truncate_history <home_dir>` and `main` (Task 1) are referenced by name only in prose in Task 2/3, not re-implemented with a different signature anywhere.
