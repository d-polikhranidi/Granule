#!/bin/zsh
# Vendors zstd's decompression (Packages/ClickHouseCore/Sources/CHZstd): the release pinned
# below, its SHA-256 checked, only lib/common, lib/decompress and the public headers kept
# (no compression, no x86 assembly). Run it again to move to another release.
# Tools/vendor-zstd.sh [zstd-<version>.tar.gz]: a release's tarball fetched already.
set -euo pipefail
version=1.5.7
sha256=eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3
cd "$(dirname "$0")/.."
target=Packages/ClickHouseCore/Sources/CHZstd
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
if [[ $# -gt 0 ]]; then
    cp "$1" "$work/zstd.tar.gz"
elif ! gh release download "v$version" -R meta/zstd -p "zstd-$version.tar.gz" -O "$work/zstd.tar.gz" 2>/dev/null; then
    curl -sSL -o "$work/zstd.tar.gz" "https://github.com/meta/zstd/releases/download/v$version/zstd-$version.tar.gz"
fi
echo "$sha256  $work/zstd.tar.gz" | shasum -a 256 -c -
mkdir "$work/src"
tar -xzf "$work/zstd.tar.gz" -C "$work/src"
lib="$work/src/zstd-$version/lib"
rm -rf "$target/zstd"
mkdir -p "$target/zstd/common" "$target/zstd/decompress"
cp "$lib/zstd.h" "$lib/zstd_errors.h" "$target/zstd/"
cp "$lib"/common/*.[ch] "$target/zstd/common/"
cp "$lib"/decompress/*.[ch] "$target/zstd/decompress/"
cp "$work/src/zstd-$version/LICENSE" "$target/zstd/LICENSE"
echo "zstd $version vendored into $target/zstd"
