#!/bin/zsh
# Archives Granule for the Mac (or the iPhone and iPad) on Gingham's binary and uploads it to
# App Store Connect (TestFlight), like Rowbolt's.
#
#   Tools/release.sh                  the next build number (one above the highest App Store Connect has)
#   BUILD=7 Tools/release.sh          a given build number
#   PLATFORM=ios Tools/release.sh     the iPhone and iPad app (its builds are numbered on their own)
#   ARCHIVE_ONLY=1 Tools/release.sh   archive and export only, nothing uploaded
#
# It builds what's committed: the HEAD's tree (`git archive`) in a folder of its own, its project
# generated there for Gingham's binary (`GINGHAM_SOURCE=release`), so the open project is left
# alone. The build number goes in on the command line (CURRENT_PROJECT_VERSION); the commit that
# went up is tagged testflight-<build> (testflight-ios-<build>). The upload is judged by its state
# in the API, not by altool's status. Needs Tools/asc-env.sh (local only) and the API's key.
set -e
cd "$(dirname "$0")/.."
source Tools/asc-env.sh
case "${PLATFORM:-mac}" in
  mac) SCHEME=Granule; DESTINATION="generic/platform=macOS"; ASC_PLATFORM=MAC_OS; ALTOOL_TYPE=macos; TAG=testflight; PACKAGE=pkg ;;
  ios) SCHEME="Granule iOS"; DESTINATION="generic/platform=iOS"; ASC_PLATFORM=IOS; ALTOOL_TYPE=ios; TAG=testflight-ios; PACKAGE=ipa ;;
  *) echo "✗ PLATFORM is mac or ios"; exit 1 ;;
esac
[[ -n "$ARCHIVE_ONLY" || -n "$ASC_APP" ]] || { echo "✗ no app with the bundle id $ASC_BUNDLE_ID in App Store Connect: create it there first"; exit 1 }
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || { echo "✗ uncommitted changes: commit first, so the build is what's in git"; exit 1 }

asc() { swift Tools/asc.swift "$@" 2>/dev/null | tail -n +2; }
json() { python3 -c "import sys,json
t = sys.stdin.read(); d = json.loads(t[t.index('{'):]) if '{' in t else {}
$1"; }
KEY=(-authenticationKeyPath "$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8"
     -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER")

if [[ -n "$ARCHIVE_ONLY" ]]; then
  BUILD=${BUILD:-1}
else
  HIGHEST=$(asc GET "/v1/apps/$ASC_APP/buildUploads?limit=200&fields[buildUploads]=cfBundleVersion,platform,state" \
    | ASC_PLATFORM=$ASC_PLATFORM json 'import os
# (An export registers its build, AWAITING_UPLOAD until it goes up: an ARCHIVE_ONLY run took none.)
print(max([int(u["attributes"]["cfBundleVersion"]) for u in d["data"] if u["attributes"]["platform"] == os.environ["ASC_PLATFORM"]
           and u["attributes"]["state"]["state"] != "AWAITING_UPLOAD"] or [0]) if isinstance(d.get("data"), list) else "?")')
  [[ "$HIGHEST" != "?" ]] || { echo "✗ App Store Connect didn't say which builds it has (an error): try again"; exit 1 }
  BUILD=${BUILD:-$((HIGHEST + 1))}
  (( BUILD > HIGHEST )) || { echo "✗ build $BUILD isn't above $HIGHEST, the highest App Store Connect has"; exit 1 }
fi

OUT=/tmp/granule-release-$ALTOOL_TYPE
WORK="$OUT/source"
rm -rf "$OUT"; mkdir -p "$WORK"
LOG="$OUT/log.txt"
# The committed tree, its project made for Gingham's binary.
git archive HEAD | tar -x -C "$WORK"
(cd "$WORK" && GINGHAM_SOURCE=release xcodegen > "$LOG" 2>&1) || { echo "✗ xcodegen failed: $LOG"; exit 1 }
GINGHAM=$(awk '/from:/ { print $2; exit }' Gingham-release.yml)
VERSION=$(awk '/MARKETING_VERSION:/ { gsub(/"/, "", $2); print $2; exit }' project.yml)
echo "▸ archive $SCHEME $VERSION ($BUILD) of $(git rev-parse --short HEAD) on Gingham $GINGHAM (from GitHub) with $(xcodebuild -version | head -1)"
xcodebuild clean archive -project "$WORK/ClickHouseViewer.xcodeproj" -scheme "$SCHEME" -configuration Release \
  -destination "$DESTINATION" -archivePath "$OUT/Granule.xcarchive" -derivedDataPath "$OUT/DerivedData" \
  -allowProvisioningUpdates "${KEY[@]}" CURRENT_PROJECT_VERSION="$BUILD" >> "$LOG" 2>&1 \
  || { echo "✗ archive failed:"; grep -E "error:" "$LOG" | head -5; exit 1 }

cat > "$OUT/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>export</string>
  <key>teamID</key><string>$ASC_TEAM</string>
  <key>uploadSymbols</key><true/>
  <!-- The build number the archive has: Xcode would give the next free one instead. -->
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST

echo "▸ export"
xcodebuild -exportArchive -archivePath "$OUT/Granule.xcarchive" -exportOptionsPlist "$OUT/export.plist" \
  -exportPath "$OUT" -allowProvisioningUpdates "${KEY[@]}" >> "$LOG" 2>&1 \
  || { echo "✗ export failed:"; grep -E "error:" "$LOG" | tail -5; exit 1 }
PKG=$(ls "$OUT"/*.$PACKAGE | head -1)
[[ -z "$ARCHIVE_ONLY" ]] || { echo "✓ $PKG (not uploaded)"; exit 0 }

echo "▸ upload $(basename "$PKG") (altool runs in the background; its log: $OUT/upload.txt)"
xcrun altool --upload-app -f "$PKG" -t $ALTOOL_TYPE --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER" > "$OUT/upload.txt" 2>&1 &
ALTOOL=$!

# The upload's own state, every 30 s, for up to 40 minutes.
for try in {1..80}; do
  sleep 30
  STATE=$(asc GET "/v1/apps/$ASC_APP/buildUploads?limit=10" | BUILD=$BUILD ASC_PLATFORM=$ASC_PLATFORM json 'import os
for u in d.get("data", []):
    a = u["attributes"]
    if a["cfBundleVersion"] == os.environ["BUILD"] and a["platform"] == os.environ["ASC_PLATFORM"]:
        print(a["state"]["state"], " ".join(e.get("description", e.get("code", "")) for e in a["state"]["errors"])); break')
  case "$STATE" in
    COMPLETE*) kill $ALTOOL 2>/dev/null || true
      git tag -f "$TAG-$BUILD" > /dev/null
      echo "✓ build $BUILD uploaded (tagged $TAG-$BUILD); App Store Connect processes it next"; exit 0 ;;
    FAILED*) kill $ALTOOL 2>/dev/null || true; echo "✗ upload failed: ${STATE#FAILED }"; exit 1 ;;
    "") kill -0 $ALTOOL 2>/dev/null || { echo "✗ altool stopped and no upload of build $BUILD is known:"; tail -8 "$OUT/upload.txt"; exit 1 } ;;
  esac
  (( try % 4 == 0 )) && echo "  ${STATE:-not started} after $((try / 2)) min…"
done
kill $ALTOOL 2>/dev/null || true
echo "✗ no answer after 40 min: look at $OUT/upload.txt"; exit 1
