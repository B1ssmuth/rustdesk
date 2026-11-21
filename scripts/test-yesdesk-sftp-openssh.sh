#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d)"
image="yesdesk-sftp-fixture:$(basename "$fixture" | tr '[:upper:]' '[:lower:]')"
containers=()
cleanup() {
  if (( ${#containers[@]} )); then
    docker rm -f "${containers[@]}" >/dev/null 2>&1 || true
  fi
  docker image rm "$image" >/dev/null 2>&1 || true
  rm -rf -- "$fixture"
}
trap cleanup EXIT
ssh-keygen -q -t ed25519 -N '' -f "$fixture/client"
export YESDESK_SFTP_KEY="$fixture/client"
build_args=()
if [[ -n "${YESDESK_SFTP_CA_BUNDLE:-}" ]]; then
  build_args+=(--secret "id=fixture_ca,src=$YESDESK_SFTP_CA_BUNDLE")
fi
docker build "${build_args[@]}" -t "$image" "$root/scripts/fixtures/yesdesk-sftp"
for mode in enabled disabled; do
  container="$(docker run -d -p 127.0.0.1::22 \
    --mount "type=bind,src=$fixture/client.pub,dst=/client.pub,readonly" "$image" "$mode")"
  containers+=("$container")
  address="$(docker port "$container" 22/tcp)"
  port="${address##*:}"
  for _ in {1..60}; do
    if docker exec "$container" test -s /run/sshd.pid 2>/dev/null; then break; fi
    sleep .25
  done
  if ! docker exec "$container" test -s /run/sshd.pid; then
    docker logs "$container"
    exit 1
  fi
  fingerprint="$(docker exec "$container" ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub | cut -d ' ' -f 2)"
  if [[ "$mode" == enabled ]]; then
    export YESDESK_SFTP_PORT="$port" YESDESK_SFTP_FINGERPRINT="$fingerprint"
  else
    export YESDESK_SFTP_DISABLED_PORT="$port" YESDESK_SFTP_DISABLED_FINGERPRINT="$fingerprint"
  fi
done

cd "$root/flutter"
flutter test --no-pub --reporter expanded test/yesdesk_sftp "$@"
