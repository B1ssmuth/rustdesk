# dartssh2 4.1.0

Source archive: https://pub.dev/api/archives/dartssh2-4.1.0.tar.gz

SHA-256: `39359aceafcf5940b868249e3c9c6d86e4e0f989eec7417d033c943157c84c51`

The runtime source and MIT license are included. The sole manifest patch
lowers the `meta` floor to 1.12.0. The runtime imports use only `internal`,
`protected` and `visibleForTesting`, all available in 1.12.0. The app uses
Flutter 3.24.5 with `meta` 1.15.0. The existing FFI generator uses Flutter
3.22.3 with `meta` 1.12.0. Keep the license and recheck this patch and the
OpenSSH integration tests when updating the archive.
