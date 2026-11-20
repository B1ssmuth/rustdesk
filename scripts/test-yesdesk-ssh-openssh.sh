#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d)"
fixture_user=""
owned_user=""
privilege=()
servers=()
pidfiles=()

cleanup() {
  for pidfile in "${pidfiles[@]}"; do
    if [[ -s "$pidfile" ]]; then
      "${privilege[@]}" kill "$(cat "$pidfile")" 2>/dev/null || true
    fi
  done
  for server in "${servers[@]}"; do
    kill "$server" 2>/dev/null || true
    wait "$server" 2>/dev/null || true
  done
  if [[ -n "$owned_user" ]]; then
    "${privilege[@]}" userdel -r "$owned_user" >/dev/null 2>&1 || true
  fi
  rm -rf -- "$fixture"
}
trap cleanup EXIT

if [[ "${1:-}" == "--handshake-only" ]]; then
  fixture_user="$(id -un)"
  pam=no
  password_auth=no
  export YESDESK_TEST_PASSWORD="" YESDESK_TEST_HANDSHAKE_ONLY=1
else
  if [[ "$(id -u)" -ne 0 ]]; then
    privilege=(sudo -n)
  fi
  fixture_user="yesdesk_ssh_$$"
  "${privilege[@]}" install -d -m 0755 /run/sshd
  "${privilege[@]}" useradd -m -s /bin/bash "$fixture_user"
  owned_user="$fixture_user"
  YESDESK_TEST_PASSWORD="$(openssl rand -hex 24)"
  printf '%s:%s\n' "$fixture_user" "$YESDESK_TEST_PASSWORD" |
    "${privilege[@]}" chpasswd
  export YESDESK_TEST_PASSWORD
  pam=yes
  password_auth=yes
fi

export YESDESK_TEST_KEY_PASSPHRASE
YESDESK_TEST_KEY_PASSPHRASE="$(openssl rand -hex 16)"
export YESDESK_TEST_KEY="$fixture/client"
ssh-keygen -q -t ed25519 -N "$YESDESK_TEST_KEY_PASSPHRASE" -f "$YESDESK_TEST_KEY"
ssh-keygen -q -t ed25519 -N '' -f "$fixture/host"
ssh-keygen -q -t ed25519 -N '' -f "$fixture/replacement"
chmod 0755 "$fixture"
cp "$fixture/client.pub" "$fixture/authorized_keys"
chmod 0644 "$fixture/authorized_keys"

read -r YESDESK_TEST_PORT YESDESK_TEST_OTHER_PORT < <(python3 - <<'PYPORT'
import socket
with socket.socket() as first, socket.socket() as second:
    first.bind(('127.0.0.1', 0))
    second.bind(('127.0.0.1', 0))
    print(first.getsockname()[1], second.getsockname()[1])
PYPORT
)
export YESDESK_TEST_PORT YESDESK_TEST_OTHER_PORT
export YESDESK_TEST_USER="$fixture_user"
export YESDESK_TEST_HOST_FINGERPRINT
YESDESK_TEST_HOST_FINGERPRINT="$(ssh-keygen -lf "$fixture/host.pub" | cut -d ' ' -f 2)"
sshd="$(command -v sshd || echo /usr/sbin/sshd)"

start_server() {
  local host_key="$1" port="$2" pid="$fixture/$2.pid"
  local config="$fixture/$2.conf"
  cat > "$config" <<SSHD
ListenAddress 127.0.0.1
Port $port
HostKey $host_key
PidFile $pid
AuthorizedKeysFile $fixture/authorized_keys
StrictModes no
AllowUsers $fixture_user
PasswordAuthentication $password_auth
KbdInteractiveAuthentication $password_auth
UsePAM $pam
PermitRootLogin no
PermitUserEnvironment no
AllowAgentForwarding no
AllowTcpForwarding no
X11Forwarding no
PrintMotd no
SSHD
  pidfiles+=("$pid")
  "${privilege[@]}" "$sshd" -D -e -f "$config" > "$fixture/$port.log" 2>&1 &
  servers+=("$!")
  for _ in {1..40}; do
    if [[ -s "$pid" ]]; then return; fi
    if ! kill -0 "${servers[-1]}" 2>/dev/null; then break; fi
    sleep .1
  done
  cat "$fixture/$port.log" >&2
  return 1
}

start_server "$fixture/host" "$YESDESK_TEST_PORT"
start_server "$fixture/replacement" "$YESDESK_TEST_OTHER_PORT"

cd "$root/flutter"
flutter test --no-pub --reporter expanded test/yesdesk_ssh/openssh_test.dart
