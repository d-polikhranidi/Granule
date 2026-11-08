#!/bin/sh
# The license texts and NOTICE files Help › Acknowledgments shows (Shared/Acknowledgments),
# copied again from the packages as resolved. Run it after updating them, then look at
# the diff (a new NOTICE, a new package to name in Acknowledgments.swift).
#   Tools/acknowledgments.sh <SourcePackages/checkouts of a build>
set -eu
checkouts=${1:?"usage: $0 <DerivedData/…/SourcePackages/checkouts>"}
here=$(cd "$(dirname "$0")/.." && pwd)
to="$here/Shared/Acknowledgments"

# SwiftNIO, SwiftNIO SSH and Swift Crypto share one Apache 2.0 text; Atomics and
# Collections add the Runtime Library Exception to it.
for package in swift-nio-ssh swift-crypto; do
    cmp -s "$checkouts/swift-nio/LICENSE.txt" "$checkouts/$package/LICENSE.txt" || echo "$package's LICENSE differs from swift-nio's" >&2
done
cmp -s "$checkouts/swift-atomics/LICENSE.txt" "$checkouts/swift-collections/LICENSE.txt" || echo "swift-atomics' LICENSE differs from swift-collections'" >&2
install -m 644 "$checkouts/swift-nio/LICENSE.txt" "$to/Apache-2.0.txt"
install -m 644 "$checkouts/swift-collections/LICENSE.txt" "$to/Apache-2.0-Runtime-Library-Exception.txt"
install -m 644 "$checkouts/swift-nio/NOTICE.txt" "$to/swift-nio-NOTICE.txt"
install -m 644 "$checkouts/swift-crypto/NOTICE.txt" "$to/swift-crypto-NOTICE.txt"
for package in swift-nio-ssh swift-atomics swift-collections; do
    [ ! -e "$checkouts/$package/NOTICE.txt" ] || echo "$package has a NOTICE now: add it" >&2
done
install -m 644 "$here/Packages/ClickHouseCore/Sources/CHZstd/zstd/LICENSE" "$to/zstd-LICENSE.txt"
install -m 644 "$here/Packages/ClickHouseCore/Sources/CHDecode/ryu/LICENSE-Boost" "$to/Ryu-LICENSE-Boost.txt"
git -C "$here" status --short -- Shared/Acknowledgments
