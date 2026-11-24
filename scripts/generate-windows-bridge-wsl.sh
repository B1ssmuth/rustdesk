#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 6 ]]; then
    echo "Usage: $0 SOURCE_TAR OUTPUT_ROOT FLUTTER_ARCHIVE FLUTTER_SHA256 RUSTUP_INIT RUSTUP_SHA256" >&2
    exit 2
fi

source_tar=$1
output_root=$2
flutter_archive=$3
flutter_hash=$4
rustup_archive=$5
rustup_hash=$6
source /etc/os-release
if [[ $ID != ubuntu || $VERSION_ID != 22.04 || $(uname -m) != x86_64 ]]; then
    echo 'Bridge CI requires Ubuntu 22.04 x86_64.' >&2
    exit 1
fi
for command in clang cmake curl flock gcc git g++ llvm-config nasm ninja pkg-config tar wget xz; do
    if ! command -v "$command" >/dev/null; then
        echo "Missing Linux command: $command. Install the bridge prerequisites in the build guide." >&2
        exit 1
    fi
done
printf '%s  %s\n' "$flutter_hash" "$flutter_archive" "$rustup_hash" "$rustup_archive" | sha256sum --check --strict

cache="$HOME/.cache/yesdesk-bridge"
mkdir -p "$cache"
exec 9>"$cache/.lock"
flock -n 9 || { echo 'Another YES Desk bridge generation is running.' >&2; exit 1; }
stage=$(mktemp -d "$cache/stage.XXXXXXXX")
trap 'rm -rf -- "$stage"' EXIT
export CARGO_HOME="$cache/cargo"
export RUSTUP_HOME="$cache/rustup"
export PUB_CACHE="$cache/pub-cache"
export FLUTTER_STORAGE_BASE_URL=https://storage.googleapis.com
export PUB_HOSTED_URL=https://pub.dev
export CI=true

sdk="$cache/flutter-3.22.3"
if [[ ! -x "$sdk/bin/flutter" ]]; then
    tar xf "$flutter_archive" -C "$stage"
    mv -T "$stage/flutter" "$sdk"
fi
export PATH="$sdk/bin:$CARGO_HOME/bin:$PATH"
if [[ $(git -C "$sdk" rev-parse HEAD) != b0850beeb25f6d5b10426284f506557f66181b36 ]]; then
    echo "Unexpected Flutter revision in $sdk" >&2
    exit 1
fi
if [[ ! -x "$CARGO_HOME/bin/rustup" ]]; then
    install -m 0755 "$rustup_archive" "$stage/rustup-init"
    "$stage/rustup-init" -y --no-modify-path --default-toolchain none --profile minimal
fi
export RUSTUP_TOOLCHAIN=1.75.0-x86_64-unknown-linux-gnu
rustup toolchain install "$RUSTUP_TOOLCHAIN" --profile minimal --component rustfmt --no-self-update
cargo install cargo-expand --version '=1.0.95' --locked
cargo install flutter_rust_bridge_codegen --version '=1.80.1' --features uuid --locked

mkdir -p "$stage/source"
tar xf "$source_tar" -C "$stage/source"
cd "$stage/source"
if ! grep -q 'extended_text: 14.0.0' flutter/pubspec.yaml; then
    echo 'The bridge-specific extended_text edit no longer matches pubspec.yaml. Check bridge.yml.' >&2
    exit 1
fi
sed -i 's/extended_text: 14\.0\.0/extended_text: 13.0.0/' flutter/pubspec.yaml
(cd flutter && flutter pub get)
flutter_rust_bridge_codegen --rust-input ./src/flutter_ffi.rs \
    --dart-output ./flutter/lib/generated_bridge.dart --c-output ./flutter/macos/Runner/bridge_generated.h
cp flutter/macos/Runner/bridge_generated.h flutter/ios/Runner/bridge_generated.h

for file in src/bridge_generated.rs src/bridge_generated.io.rs flutter/lib/generated_bridge.dart \
    flutter/lib/generated_bridge.freezed.dart flutter/macos/Runner/bridge_generated.h \
    flutter/ios/Runner/bridge_generated.h; do
    test -s "$file" || { echo "Missing generated bridge file: $file" >&2; exit 1; }
    cp -- "$file" "$output_root/$file"
done
