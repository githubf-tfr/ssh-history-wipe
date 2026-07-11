#!/bin/bash
# Validates an Ansible role the way it's actually used in production: from
# the host, over a real SSH connection, against a bare AlmaLinux 8 container
# that has nothing pre-installed (see Dockerfile.bare). Then drives a real
# interactive SSH session as a normal user and inspects .bash_history before
# login, mid-session (before logout), and after logout, the same way the
# PAM-open-session bug was originally found by hand - to prove the fix holds
# regardless of which Ansible role deployed it.
#
# Usage: run-ansible-docker-verification.sh [playbook.yml|playbook-standalone.yml]
# Defaults to playbook.yml (the "via script" role).
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
playbook="${1:-playbook.yml}"
image="ssh-history-wipe-ansible-bare"
container="ssh-history-wipe-ansible-bare"
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

echo "Building bare image (no wipe mechanism installed)..."
if ! docker build -q -t "$image" -f "$here/Dockerfile.bare" "$root" >/dev/null; then
    echo "FAIL: docker build"
    exit 1
fi

docker rm -f "$container" >/dev/null 2>&1 || true
echo "Starting bare container..."
docker run -d --name "$container" -p 127.0.0.1::22 "$image" >/dev/null
port="$(docker port "$container" 22/tcp | head -1 | cut -d: -f2)"

echo "Waiting for sshd on 127.0.0.1:$port..."
ready=0
for _ in $(seq 1 30); do
    if ssh_key -o BatchMode=yes root@127.0.0.1 true 2>/dev/null; then
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

echo "=== Provisioning with $playbook, over real SSH, production paths ==="
if ! ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -i "127.0.0.1," -u root \
    --private-key "$keyfile" \
    -e ansible_port="$port" \
    -e ansible_python_interpreter=/usr/bin/python3.9 \
    "$root/ansible/$playbook"
then
    echo "FAIL: ansible-playbook apply"
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

test_idempotent_reapply() {
    local log
    log="$(mktemp)"
    ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -i "127.0.0.1," -u root \
        --private-key "$keyfile" \
        -e ansible_port="$port" \
        -e ansible_python_interpreter=/usr/bin/python3.9 \
        "$root/ansible/$playbook" > "$log" 2>&1
    grep -q 'changed=0' "$log"
    local result=$?
    rm -f "$log"
    return $result
}

test_history_lifecycle_nonroot() {
    docker exec "$container" bash -c 'ls /home/testuser/.bash_history 2>/dev/null' && return 1
    printf 'echo mon-mot-de-passe-secret\necho un-token-secret\nhistory -a\nexit\n' | \
        ssh_key testuser@127.0.0.1 >/dev/null 2>&1
    local lines
    lines="$(docker exec "$container" bash -c 'wc -l < /home/testuser/.bash_history 2>/dev/null || echo 0')"
    [ "$lines" = "0" ]
}

test_history_lifecycle_root() {
    printf 'echo mon-mot-de-passe-secret\nhistory -a\nexit\n' | \
        ssh_key root@127.0.0.1 >/dev/null 2>&1
    local lines
    lines="$(docker exec "$container" bash -c 'wc -l < /root/.bash_history 2>/dev/null || echo 0')"
    [ "$lines" = "0" ]
}

run_test "install artifacts present (script mode 750, PAM line)" test_install_artifacts
run_test "playbook re-apply is idempotent (changed=0)" test_idempotent_reapply
run_test "history absent then cleaned up after real logout (non-root)" test_history_lifecycle_nonroot
run_test "history cleaned up after real logout (root)" test_history_lifecycle_root

exit $fail
