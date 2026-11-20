# YES Desk IT Workspace

<img src="flutter/assets/icon.svg" alt="YES Desk" width="72" height="72">

YES Desk is a corporate remote support workspace built on the RustDesk engine. It brings quick connect, device inventory, address books and incoming support into one desktop application. Windows x64 is the primary distribution target.

For Windows installation, migration from older builds and rollback, see the [YES Desk Windows installation guide](docs/YESDESK-WINDOWS-INSTALLATION.md).

## Downloads and support

Use the official YES Desk repository for builds and source. For a branch under review, download the Windows x64 EXE and MSI from the **Full Flutter CI** run. Reports about the client belong in the project issue tracker. Keep device IDs, keys, account details and internal deployment information out of public issues.

[Build runs](https://github.com/B1ssmuth/rustdesk/actions) · [YES Desk releases](https://github.com/B1ssmuth/rustdesk/releases) · [Support](https://github.com/B1ssmuth/rustdesk/issues)

## Server architecture

The current deployment uses RustDesk OSS Server 1.1.15 for rendezvous and relay, lejianwen/rustdesk-api 2.7 for the client API, and Nginx on Ubuntu 24.04 LTS. Docker Compose manages the services. The administrative web panel is closed. See the [server architecture and capability matrix](docs/YESDESK-SERVER-ARCHITECTURE.md).

## Development

- Flutter desktop UI lives under `flutter/lib/desktop`. Shared palette and components are in `flutter/lib/yesdesk`.
- Rust transport and capture live in `src` and `libs`. `libs/hbb_common` is vendored.
- Use Flutter 3.24.5 for the Windows application. The bridge workflow generates its FFI files with flutter_rust_bridge codegen 1.80.1. The Windows workflow installs LLVM, Rust and vcpkg and builds the portable EXE and WiX MSI. [Windows CI definition](.github/workflows/flutter-build.yml)
- After generating the bridge, run `flutter pub get --enforce-lockfile`, `flutter analyze --no-pub` and `flutter test --no-pub` from `flutter/`.
- Use **Full Flutter CI** for review artifacts. Its release flag is false and its contents permission is read-only. [Artifact workflow](.github/workflows/flutter-ci.yml)

[Roadmap](docs/YESDESK-2.0-ROADMAP.md) · [Sprint 1 audit](docs/yesdesk-sprint1-audit.md) · [Desktop identity and installer audit](docs/YESDESK-IDENTITY.md) · [SSH design](docs/YESDESK-SSH-ARCHITECTURE.md)

## License and upstream

YES Desk is distributed under the GNU Affero General Public License v3.0. RustDesk is copyright Purslane Ltd. and contributors. The corresponding source, license text and upstream notices are available in this repository. The desktop client exposes the license registry under **Settings → About → Open source licenses**.

[AGPL-3.0](LICENCE) · [Upstream RustDesk source](https://github.com/rustdesk/rustdesk)
