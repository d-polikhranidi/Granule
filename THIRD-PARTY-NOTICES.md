# Third-party notices

Granule's own code is under the MIT license in [LICENSE](LICENSE). It's built with the code of
others below; the app shows their licenses in Acknowledgments (Help on the Mac, Settings on the
iPad and iPhone).

- **Gingham**, the table, is a separate binary under its own license
  (https://github.com/digitalglobeby/Gingham), fetched by Swift Package Manager.
  `Shared/GinghamKey.swift` holds a free Gingham key that unlocks only the bundle id
  `by.digitalglobe.Clickhouse-Viewer`.
- **Ryu** by Ulf Adams, in `Packages/ClickHouseCore/Sources/CHDecode/ryu`, under the Boost
  Software License 1.0 (its `LICENSE-Boost` there).
- **Zstandard** (zstd 1.5.7, its decompression only) by Meta Platforms, Inc. and affiliates, in
  `Packages/ClickHouseCore/Sources/CHZstd/zstd`, under the BSD license in its `LICENSE` there,
  vendored by `Tools/vendor-zstd.sh`.
- **SwiftNIO, SwiftNIO SSH and Swift Crypto** by Apple Inc. and their projects' authors, for the
  SSH tunnels, under the Apache License 2.0, fetched by Swift Package Manager; with **Swift
  Atomics and Swift Collections**, which SwiftNIO uses, under the Apache License 2.0 with the
  Runtime Library Exception.

`Packages/ClickHouseCore/Sources/CHBcrypt` is this repository's own code (MIT): OpenBSD's
bcrypt_pbkdf written again after its description, for OpenSSH keys with a passphrase;
Blowfish's initial tables are the hex digits of pi.
