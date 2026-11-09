#!/bin/zsh
# Archives Granule for the Mac (or the iPhone and iPad) on Gingham's binary and uploads it to
# App Store Connect (TestFlight), like Rowbolt's; or makes the Mac's notarized dmg for download.
#
#   Tools/release.sh                  the next build number (one above the highest App Store Connect has)
#   BUILD=7 Tools/release.sh          a given build number
#   PLATFORM=ios Tools/release.sh     the iPhone and iPad app (its builds are numbered on their own)
#   ARCHIVE_ONLY=1 Tools/release.sh   archive and export only, nothing uploaded
#   PLATFORM=dmg REF=testflight-1 Tools/release.sh
#                                     the Mac app signed with Developer ID, notarized and stapled, in a
#                                     dmg (also notarized and stapled): for a GitHub release, nothing
#                                     uploaded but to the notary service. Its build number is the Mac
#                                     App Store build of the same commit (its testflight-<n> tag).
#
# It builds what's committed: the tree of REF (HEAD by default; `git archive`) in a folder of its own,
# its project generated there for Gingham's binary (`GINGHAM_SOURCE=release`), so the open project is
# left alone. The build number goes in on the command line (CURRENT_PROJECT_VERSION); the commit that
# went up is tagged testflight-<build> (testflight-ios-<build>). The upload is judged by its state in
# the API, not by altool's status. Needs Tools/asc-env.sh (local only) and the API's key; the dmg also
# needs the Developer ID Application certificate in the keychain (an API key can't cloud-sign one).
set -e
cd "$(dirname "$0")/.."
source Tools/asc-env.sh
case "${PLATFORM:-mac}" in
  mac) SCHEME=Granule; DESTINATION="generic/platform=macOS"; ASC_PLATFORM=MAC_OS; ALTOOL_TYPE=macos; TAG=testflight; PACKAGE=pkg ;;
  ios) SCHEME="Granule iOS"; DESTINATION="generic/platform=iOS"; ASC_PLATFORM=IOS; ALTOOL_TYPE=ios; TAG=testflight-ios; PACKAGE=ipa ;;
  dmg) SCHEME=Granule; DESTINATION="generic/platform=macOS"; ALTOOL_TYPE=dmg ;;
  *) echo "✗ PLATFORM is mac, ios or dmg"; exit 1 ;;
esac
REF=${REF:-HEAD}
COMMIT=$(git rev-parse --short "$REF^{commit}")
if [[ "$REF" == HEAD ]]; then
  [[ -z "$(git status --porcelain --untracked-files=no)" ]] || { echo "✗ uncommitted changes: commit first, so the build is what's in git"; exit 1 }
fi

asc() { swift Tools/asc.swift "$@" 2>/dev/null | tail -n +2; }
json() { python3 -c "import sys,json
t = sys.stdin.read(); d = json.loads(t[t.index('{'):]) if '{' in t else {}
$1"; }
AUTH_KEY="$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8"
KEY=(-authenticationKeyPath "$AUTH_KEY" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER")

if [[ "$ALTOOL_TYPE" == dmg ]]; then
  DEVELOPER_ID=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*('"$ASC_TEAM"')\)".*/\1/p' | head -1)
  [[ -n "$DEVELOPER_ID" ]] || { echo "✗ no Developer ID Application certificate of team $ASC_TEAM in the keychain"; exit 1 }
  # The same number as the Mac App Store's build of this commit.
  BUILD=${BUILD:-$(git tag --points-at "$REF" | sed -n 's/^testflight-\([0-9][0-9]*\)$/\1/p' | head -1)}
  [[ -n "$BUILD" ]] || { echo "✗ $REF has no testflight-<n> tag (no Mac App Store build of it): give BUILD=n"; exit 1 }
elif [[ -n "$ARCHIVE_ONLY" ]]; then
  BUILD=${BUILD:-1}
else
  [[ -n "$ASC_APP" ]] || { echo "✗ no app with the bundle id $ASC_BUNDLE_ID in App Store Connect: create it there first"; exit 1 }
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
git archive "$REF" | tar -x -C "$WORK"
(cd "$WORK" && GINGHAM_SOURCE=release xcodegen > "$LOG" 2>&1) || { echo "✗ xcodegen failed: $LOG"; exit 1 }
GINGHAM=$(awk '/from:/ { print $2; exit }' "$WORK/Gingham-release.yml")
VERSION=$(awk '/MARKETING_VERSION:/ { gsub(/"/, "", $2); print $2; exit }' "$WORK/project.yml")
echo "▸ archive $SCHEME $VERSION ($BUILD) of $COMMIT on Gingham $GINGHAM (from GitHub) with $(xcodebuild -version | head -1)"
xcodebuild clean archive -project "$WORK/ClickHouseViewer.xcodeproj" -scheme "$SCHEME" -configuration Release \
  -destination "$DESTINATION" -archivePath "$OUT/Granule.xcarchive" -derivedDataPath "$OUT/DerivedData" \
  -allowProvisioningUpdates "${KEY[@]}" CURRENT_PROJECT_VERSION="$BUILD" >> "$LOG" 2>&1 \
  || { echo "✗ archive failed:"; grep -E "error:" "$LOG" | head -5; exit 1 }

if [[ "$ALTOOL_TYPE" == dmg ]]; then
  # Signed here with the keychain's Developer ID: the app needs no profile (no such entitlements).
  cat > "$OUT/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>destination</key><string>export</string>
  <key>teamID</key><string>$ASC_TEAM</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict>
</plist>
PLIST
  echo "▸ export with $DEVELOPER_ID"
  xcodebuild -exportArchive -archivePath "$OUT/Granule.xcarchive" -exportOptionsPlist "$OUT/export.plist" \
    -exportPath "$OUT/export" >> "$LOG" 2>&1 || { echo "✗ export failed:"; grep -E "error:" "$LOG" | tail -5; exit 1 }
  APP="$OUT/export/Granule.app"
  codesign --verify --deep --strict "$APP" || { echo "✗ the exported app's signature doesn't verify"; exit 1 }

  # Notarized by the API's key; the verdict is the service's JSON, its log said on a failure.
  notarize() {
    local result
    result=$(xcrun notarytool submit "$1" --key "$AUTH_KEY" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER" \
      --wait --timeout 40m --output-format json 2>> "$LOG")
    echo "$result" >> "$LOG"
    local state=$(echo "$result" | json 'print(d.get("status", "?"))')
    if [[ "$state" != Accepted ]]; then
      local id=$(echo "$result" | json 'print(d.get("id", ""))')
      echo "✗ notarization of $(basename "$1"): $state"
      [[ -n "$id" ]] && xcrun notarytool log "$id" --key "$AUTH_KEY" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER" | head -40
      exit 1
    fi
  }

  # The app first, stapled, so it opens offline once copied out of the dmg.
  echo "▸ notarize the app"
  ditto -c -k --keepParent "$APP" "$OUT/Granule.zip"
  notarize "$OUT/Granule.zip"
  xcrun stapler staple "$APP" >> "$LOG" 2>&1

  echo "▸ dmg"
  DMG="$OUT/Granule-$VERSION.dmg"
  mkdir -p "$OUT/dmg"
  ditto "$APP" "$OUT/dmg/Granule.app"
  ln -s /Applications "$OUT/dmg/Applications"
  hdiutil create -volname "Granule $VERSION" -srcfolder "$OUT/dmg" -fs HFS+ -format UDZO -ov "$DMG" >> "$LOG" 2>&1
  codesign --sign "$DEVELOPER_ID" --timestamp "$DMG"
  notarize "$DMG"
  xcrun stapler staple "$DMG" >> "$LOG" 2>&1

  # What Gatekeeper says about both, as a downloaded copy would be judged.
  spctl --assess --type open --context context:primary-signature -vv "$DMG" 2>&1 | sed 's/^/  /'
  spctl --assess --type execute -vv "$APP" 2>&1 | sed 's/^/  /'
  xcrun stapler validate "$DMG" > /dev/null && xcrun stapler validate "$APP" > /dev/null
  echo "✓ $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' ')), $VERSION ($BUILD) of $COMMIT: signed, notarized, stapled; not published"
  exit 0
fi

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
      git tag -f "$TAG-$BUILD" "$REF" > /dev/null
      echo "✓ build $BUILD uploaded (tagged $TAG-$BUILD); App Store Connect processes it next"; exit 0 ;;
    FAILED*) kill $ALTOOL 2>/dev/null || true; echo "✗ upload failed: ${STATE#FAILED }"; exit 1 ;;
    "") kill -0 $ALTOOL 2>/dev/null || { echo "✗ altool stopped and no upload of build $BUILD is known:"; tail -8 "$OUT/upload.txt"; exit 1 } ;;
  esac
  (( try % 4 == 0 )) && echo "  ${STATE:-not started} after $((try / 2)) min…"
done
kill $ALTOOL 2>/dev/null || true
echo "✗ no answer after 40 min: look at $OUT/upload.txt"; exit 1
