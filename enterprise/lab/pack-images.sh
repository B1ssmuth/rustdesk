#!/usr/bin/env bash
set -euo pipefail
umask 077

if [[ $# != 4 ]]; then
    echo "Usage: $0 output.tar postgres-sha256 rustdesk-sha256 python-sha256" >&2
    exit 2
fi
for digest in "$2" "$3" "$4"; do
    if [[ ! $digest =~ ^[a-f0-9]{64}$ ]]; then
        echo 'Supply the verified SHA-256 digests from the official registries.' >&2
        exit 2
    fi
done
output=$(realpath -m -- "$1")
if [[ -e $output || -L $output ]]; then
    echo 'Output archive already exists.' >&2
    exit 1
fi
source_dir="$(dirname -- "$0")/../management"
postgres="docker.io/library/postgres:17.9@sha256:$2"
rustdesk="ghcr.io/rustdesk/rustdesk-server:1.1.16@sha256:$3"
python="docker.io/library/python:3.12.12-slim@sha256:$4"
docker pull --platform linux/amd64 "$postgres"
docker pull --platform linux/amd64 "$rustdesk"
docker pull --platform linux/amd64 "$python"
docker tag "$postgres" yesdesk38-lab/postgres:local
docker tag "$rustdesk" yesdesk38-lab/rustdesk-server:local
sed "1s|^FROM .*|FROM $python|" "$source_dir/Dockerfile" |
    docker build --platform linux/amd64 -t yesdesk38-lab/management:local -f - "$source_dir"
docker save -o "$output" yesdesk38-lab/postgres:local yesdesk38-lab/rustdesk-server:local yesdesk38-lab/management:local
sha256sum -- "$output"
