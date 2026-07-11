#!/bin/bash
# Automates checks 1-6 of docs/manual-verification.md against a real sshd/PAM
# stack running in an AlmaLinux 8 container. Check 7 (audit/log non-regression)
# is NOT covered here: auditd needs kernel audit netlink access and journalctl
# needs systemd, neither of which is meaningfully available in a container —
# that check still requires a real host (see docs/manual-verification.md).
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
image="ssh-history-wipe-test"
container="ssh-history-wipe-test"
fail=0
keydir="$(mktemp -d)"
keyfile="$keydir/id_test"
port=""

cleanup() {
    docker rm -f "$container" >/dev/null 2>&1
    rm -f "$here/id_test.pub"
    rm -rf "$keydir"
}
trap cleanup EXIT

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

ssh_key() {
    ssh -i "$keyfile" -o IdentitiesOnly=yes -o PreferredAuthentications=publickey \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 -p "$port" "$@"
}

echo "Generating ephemeral SSH keypair for this test run..."
ssh-keygen -t ed25519 -f "$keyfile" -N "" -q
cp "$keyfile.pub" "$here/id_test.pub"

echo "Building test image..."
if ! docker build -q -t "$image" -f "$here/Dockerfile" "$root" >/dev/null; then
    echo "FAIL: docker build"
    exit 1
fi

docker rm -f "$container" >/dev/null 2>&1 || true
echo "Starting container..."
docker run -d --name "$container" -p 127.0.0.1::22 "$image" >/dev/null

port="$(docker port "$container" 22/tcp | head -1 | cut -d: -f2)"

echo "Waiting for sshd on 127.0.0.1:$port..."
ready=0
for _ in $(seq 1 30); do
    if ssh_key -o BatchMode=yes testuser@127.0.0.1 true 2>/dev/null; then
        ready=1
        break
    fi
    sleep 1
done
if [ "$ready" -ne 1 ]; then
    echo "FAIL: sshd never became reachable"
    docker logs "$container"
    exit 1
fi

test_install_artifacts() {
    docker exec "$container" test -f /usr/local/sbin/wipe-history-on-logout.sh || return 1
    local mode
    mode="$(docker exec "$container" stat -c '%a' /usr/local/sbin/wipe-history-on-logout.sh)"
    [ "$mode" = "750" ] || return 1
    docker exec "$container" grep -qF \
        "session optional pam_exec.so seteuid /usr/local/sbin/wipe-history-on-logout.sh" \
        /etc/pam.d/sshd
}

test_cleanup_nonroot() {
    ssh_key testuser@127.0.0.1 'bash -ic "echo some-secret-command; history -a"' >/dev/null 2>&1
    local lines
    lines="$(docker exec "$container" bash -c 'wc -l < /home/testuser/.bash_history 2>/dev/null || echo 0')"
    [ "$lines" = "0" ]
}

test_cleanup_root() {
    ssh_key root@127.0.0.1 'bash -ic "echo some-secret-command; history -a"' >/dev/null 2>&1
    local lines
    lines="$(docker exec "$container" bash -c 'wc -l < /root/.bash_history 2>/dev/null || echo 0')"
    [ "$lines" = "0" ]
}

test_nonblocking_on_failure() {
    docker exec "$container" chmod 000 /usr/local/sbin/wipe-history-on-logout.sh
    local out status
    out="$(ssh_key testuser@127.0.0.1 'echo hi' 2>/dev/null)"
    status=$?
    docker exec "$container" chmod 750 /usr/local/sbin/wipe-history-on-logout.sh
    [ "$status" -eq 0 ] && [ "$out" = "hi" ]
}

test_idempotent_reinstall() {
    docker exec "$container" bash /opt/ssh-history-wipe/install.sh || return 1
    docker exec "$container" bash /opt/ssh-history-wipe/install.sh || return 1
    local count
    count="$(docker exec "$container" grep -cF \
        "session optional pam_exec.so seteuid /usr/local/sbin/wipe-history-on-logout.sh" \
        /etc/pam.d/sshd)"
    [ "$count" = "1" ]
}

test_abrupt_disconnect() {
    # SIGSTOP freezes the local ssh client without closing its socket, so no
    # FIN is sent - the server only notices via ClientAliveInterval, which is
    # exactly the "network cut mid-session" case from spec §3/§6. A plain
    # kill -9 would close the fd and send a FIN immediately, defeating the
    # point of this check.
    ssh_key -tt testuser@127.0.0.1 'bash -ic "echo some-secret-command; history -a; sleep 60"' \
        >/dev/null 2>&1 &
    local sshpid=$!
    sleep 2
    kill -STOP "$sshpid" 2>/dev/null
    sleep 8
    kill -KILL "$sshpid" 2>/dev/null
    wait "$sshpid" 2>/dev/null
    local lines
    lines="$(docker exec "$container" bash -c 'wc -l < /home/testuser/.bash_history 2>/dev/null || echo 0')"
    [ "$lines" = "0" ]
}

run_test "install artifacts present (script mode 750, PAM line)" test_install_artifacts
run_test "cleanup on normal logout (non-root)" test_cleanup_nonroot
run_test "cleanup on normal logout (root)" test_cleanup_root
run_test "non-blocking on script failure" test_nonblocking_on_failure
run_test "install.sh idempotent re-run (real PAM file in container)" test_idempotent_reinstall
run_test "cleanup on abrupt disconnect (frozen client, ClientAliveInterval)" test_abrupt_disconnect

exit $fail
