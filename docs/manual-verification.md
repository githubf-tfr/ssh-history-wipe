# Manual verification runbook — ssh-history-wipe

Run these checks on a real AlmaLinux 8+ host after running `install.sh` as
root (see spec §4.2). These cover spec §6 items that need a live sshd/PAM
stack and cannot be exercised by the unit tests in `tests/`.

**Checks 1-6 below are automated in Docker** — run
`bash tests/docker/run-docker-verification.sh` (requires only a local Docker
daemon, no real host/VM). It builds an AlmaLinux 8 image, runs `install.sh`,
and drives real SSH sessions against it to verify install artifacts, cleanup
on logout (root and non-root), non-blocking behavior on script failure,
`install.sh` idempotence, and cleanup on an abrupt/frozen disconnect.
**Check 7 (audit/log non-regression) is not covered by Docker** — `auditd`
needs kernel audit netlink access and `journalctl` needs systemd, neither
meaningfully available in a container — it still requires the manual steps
below on a real host.

**Note (2026-07-11):** an earlier version of the script truncated history
at *both* PAM session open and close (PAM invokes a `session` line at both
phases) and ran with `euid=0` despite `seteuid` in the PAM line — this
created a root-owned `.bash_history` at login that then blocked the user
from writing history for the rest of the session, making check 2/3 pass for
the wrong reason (nothing was ever written, not because it got cleaned up
at logout). Found by manually inspecting `.bash_history` *while a session
was still open*, before logout, rather than only checking the automated
script's PASS/FAIL output. Fixed by gating on `$PAM_TYPE = close_session`
and adding a defensive `chown` — see `files/wipe-history-on-logout.sh`.

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
