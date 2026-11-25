#!/usr/bin/env bash
set -euo pipefail
umask 077
cd -- "$(dirname -- "$0")"

if [[ $# != 1 || ! $1 =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    echo "Usage: $0 endpoint-machine-guid" >&2
    exit 2
fi
guid=${1,,}
if [[ -L state || $(stat -c '%u:%a' state) != "$(id -u):700" || ! -f state/device-ca.key ]]; then
    echo 'Initialize the private lab state first.' >&2
    exit 1
fi
out="state/client-$guid"
mkdir -- "$out"
printf '%s\n' 'basicConstraints=critical,CA:FALSE' 'keyUsage=critical,digitalSignature' \
    'extendedKeyUsage=clientAuth' > "$out/client.ext"
openssl req -new -newkey rsa:3072 -nodes -subj "/CN=YESDesk-Lab-$guid" \
    -keyout "$out/client.key" -out "$out/client.csr"
openssl x509 -req -sha256 -days 7 -in "$out/client.csr" -CA state/device-ca.crt \
    -CAkey state/device-ca.key -CAcreateserial -extfile "$out/client.ext" -out "$out/client.crt"
openssl rand -hex 24 > "$out/import-password"
openssl pkcs12 -export -inkey "$out/client.key" -in "$out/client.crt" -certfile state/device-ca.crt \
    -passout "file:$out/import-password" -out "$out/endpoint.pfx"
openssl x509 -in "$out/client.crt" -outform DER | sha256sum
printf 'PFX: %s/endpoint.pfx\nPassword file: %s/import-password\n' "$out" "$out"
