#!/bin/zsh
# Makes the Xcode project: Tools/generate.sh [local|release]. Without an
# argument: Gingham's sources if this repository sits inside Gingham's
# (Gingham/Apps/ClickHouseViewer), its binary from GitHub otherwise.
set -euo pipefail
cd "$(dirname "$0")/.."
source=${1:-}
if [[ -z $source ]]; then
    if [[ -f ../../Package.swift ]] && grep -q 'name: "Gingham"' ../../Package.swift; then source=local; else source=release; fi
fi
[[ $source == local || $source == release ]] || { echo "usage: Tools/generate.sh [local|release]"; exit 1; }
GINGHAM_SOURCE=$source xcodegen --spec project.yml
echo "Gingham: $source"
