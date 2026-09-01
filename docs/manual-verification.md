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
script's PASS/FAIL output. Fixed by gating on `$PAM_TYPE = close_session`,
initially completed by a defensive `chown` — since removed, see the
2026-09-01 note below.

**Note (2026-09-01):** the defensive `chown` mentioned above has been
removed: running with euid=0 (the PAM `seteuid` option does not reliably
drop privileges), it followed a symlinked `~/.bash_history` — truncating
then handing ownership of any root-owned file to the attacker (privilege
escalation). The script now drops privileges itself, before any file is
opened: it re-executes as `<script> --wipe <home>` under the target
account's identity (`setpriv --reuid --regid --init-groups`), bounded by
`timeout 5`. The installed mode is `0755` so the re-exec still works after
the drop (a stricter mode would make the mechanism silently inoperative).
The PAM line is unchanged. Checks 8-10 below prove the fix; they are not
covered by the Docker harness — this manual runbook is their normative
level.

## 1. Install

```bash
sudo bash install.sh
```

Expected: no output, exit code 0. Verify:

```bash
ls -l /usr/local/sbin/wipe-history-on-logout.sh   # root root, -rwxr-xr-x
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
ssh admin@host "sudo stat -c '%n %s %U %F' /home/testuser/.bash_history"
```

Expected: `/home/testuser/.bash_history 0 testuser regular file` — file exists (empty, size 0), belongs to the account (no ownership transfer), and is a regular file (not deleted, not symlinked).

## 3. Cleanup on normal logout (root account)

Repeat step 2 logging in as `root` instead of `testuser`:

```bash
ssh root@host
echo some-secret-command
history -a   # force write to disk before disconnecting
exit
```

Then from another session:

```bash
ssh admin@host "sudo stat -c '%n %s %U %F' /root/.bash_history"
```

Expected: `/root/.bash_history 0 root regular file` — file exists (empty, size 0), belongs to root (no ownership confusion), and is a regular file.

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
sudo chmod 755 /usr/local/sbin/wipe-history-on-logout.sh
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

## 8. Symlink attack is neutralized (privilege escalation fix)

As admin, create a root-owned witness file with known content:

```bash
ssh admin@host "echo witness-content | sudo tee /root/wipe-test-witness >/dev/null"
```

From the attacker's (non-root) account, point the history at it, then log
out:

```bash
ssh testuser@host
ln -sf /root/wipe-test-witness ~/.bash_history
exit
```

Then, as admin:

```bash
ssh admin@host "sudo stat -c '%s %U' /root/wipe-test-witness; sudo cat /root/wipe-test-witness; sudo ls -l /home/testuser/.bash_history"
```

Expected: the witness file still contains `witness-content` (16 bytes),
its owner is still `root` (no truncation, no ownership transfer), and
`/home/testuser/.bash_history` is still a symlink pointing at it. Clean up
afterwards (`sudo rm /root/wipe-test-witness`, restore the account's
`~/.bash_history` by removing the symlink).

## 9. FIFO in place of the history does not delay logout

From a non-root account, replace the history with a FIFO, then log out
while timing the disconnect:

```bash
ssh testuser@host
rm -f ~/.bash_history && mkfifo ~/.bash_history
exit   # measure: the disconnect must complete without noticeable delay
```

Expected: the logout completes normally — any extra delay stays under the
script's 5-second `timeout` bound. Then, as admin:

```bash
ssh admin@host "sudo stat -c '%F' /home/testuser/.bash_history"
```

Expected: `fifo` — the FIFO is left in place, nothing was written to it.
Clean up by removing the FIFO afterwards.

## 10. Ansible replay converges an old 0750 deployment

On a host still carrying the previous deployment (script mode `750`, old
body):

```bash
ssh admin@host "stat -c '%a' /usr/local/sbin/wipe-history-on-logout.sh"   # 750 before
ansible-playbook -i <inventory> ansible/playbook.yml --ask-become-pass    # or playbook-standalone.yml
ssh admin@host "stat -c '%a' /usr/local/sbin/wipe-history-on-logout.sh; sudo grep -c setpriv /usr/local/sbin/wipe-history-on-logout.sh; grep -c wipe-history-on-logout.sh /etc/pam.d/sshd"
```

Expected: mode `755`, `setpriv` present in the deployed body (new script),
and exactly `1` PAM line — converged by a single replay, no manual step.
The same property holds for `install.sh` replayed on such a host (covered
automatically by `tests/test_install.sh`).
