#!/usr/bin/env bash
set -euo pipefail
umask 077

usage() {
    echo "Usage: $0 /path/to/lab-images.tar trusted-sha256"
}
if [[ ${1:-} == --help ]]; then usage; exit 0; fi
if [[ $# != 2 || ! -f $1 || ! $2 =~ ^[[:xdigit:]]{64}$ ]]; then usage >&2; exit 2; fi
archive=$(realpath -- "$1")
cd -- "$(dirname -- "$0")"
if [[ $(id -u) == 0 ]]; then
    echo 'Run as an unprivileged user with access to the local Docker daemon.' >&2
    exit 1
fi
for tool in ip sha256sum docker openssl curl; do
    command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 1; }
done
if [[ -n ${DOCKER_HOST:-} || -n ${DOCKER_CONTEXT:-} || $(docker context show) != default ||
      $(docker context inspect default --format '{{.Endpoints.docker.Host}}') != unix:///var/run/docker.sock ]]; then
    echo 'Use the default local Docker daemon inside the isolated backend VM.' >&2
    exit 1
fi
if [[ -n $(ip -4 route show default) || -n $(ip -6 route show default) ]] ||
   ! ip -o -4 addr show scope global | awk '{print $4}' | grep -Fxq 192.168.237.10/24; then
    echo 'Backend must have 192.168.237.10/24 on the private switch and no default route.' >&2
    exit 1
fi

archive_sha=$(sha256sum < "$archive")
if [[ ${archive_sha%% *} != "${2,,}" ]]; then
    echo 'Offline image archive SHA-256 mismatch.' >&2
    exit 1
fi
docker load --input "$archive"
for component in management postgres rustdesk-server; do
    docker image inspect "yesdesk38-lab/$component:local" --format '{{.Id}}'
done
export LAB_UID LAB_GID
LAB_UID=$(id -u)
LAB_GID=$(id -g)

if [[ ! -e state ]]; then
    staging=$(mktemp -d "$PWD/.lab-state.XXXXXX")
    mkdir "$staging/approvals"
    openssl rand -hex 32 > "$staging/db-password"
    chmod 0444 "$staging/db-password"
    printf 'postgresql://yesdesk_lab:%s@db/yesdesk_lab\n' "$(< "$staging/db-password")" > "$staging/database-url"
    openssl rand -base64 32 | tr '+/' '-_' > "$staging/mfa-key"
    for ca in server device; do
        issuer='Server'
        [[ $ca == device ]] && issuer='Device'
        openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days 30 \
            -subj "/CN=YESDesk 38 Lab $issuer CA" \
            -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' \
            -addext 'keyUsage=critical,keyCertSign,cRLSign' \
            -keyout "$staging/$ca-ca.key" -out "$staging/$ca-ca.crt"
    done
    openssl x509 -in "$staging/server-ca.crt" -outform DER -out "$staging/server-ca.cer"
    printf '%s\n' 'basicConstraints=critical,CA:FALSE' 'keyUsage=critical,digitalSignature,keyEncipherment' \
        'extendedKeyUsage=serverAuth' 'subjectAltName=IP:192.168.237.10' > "$staging/server.ext"
    for service in api broker; do
        openssl req -new -newkey rsa:3072 -nodes -subj "/CN=YESDesk 38 Lab $service" \
            -keyout "$staging/$service.key" -out "$staging/$service.csr"
        openssl x509 -req -sha256 -days 14 -in "$staging/$service.csr" \
            -CA "$staging/server-ca.crt" -CAkey "$staging/server-ca.key" -CAcreateserial \
            -extfile "$staging/server.ext" -out "$staging/$service.crt"
    done
    mv -T -- "$staging" state
fi
if [[ -L state || $(stat -c '%u:%a' state) != "$LAB_UID:700" ]]; then
    echo 'Expected a dedicated lab state directory owned by this user with mode 0700.' >&2
    exit 1
fi

docker compose up -d --no-build --pull never
for (( attempt=0; attempt<30; attempt++ )); do
    if curl -fsS --noproxy '*' --connect-timeout 2 --max-time 4 --cacert state/server-ca.crt \
        https://192.168.237.10:8443/health/ready; then
        printf '\nLab CA SHA-256\n'
        sha256sum state/server-ca.cer
        docker compose ps
        exit 0
    fi
    sleep 2
done
docker compose ps -a
echo 'Readiness timed out. Inspect docker compose logs locally.' >&2
exit 1
