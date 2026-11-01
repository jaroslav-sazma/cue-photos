#!/bin/zsh
# Maintainer-only: builds the Release app signed with Developer ID, notarizes and staples it,
# then packs it with LICENSE and NOTICE into a disk image, signs, notarizes and staples that
# too, and writes a sha256 checksum next to it. Runs in the owner's Terminal, not sandboxed:
# it needs the login keychain and Apple's notary service.
# One-time setup:
#   xcrun notarytool store-credentials cue-photos-notary \
#     --apple-id <apple-id> --team-id <team-id> --password <app-specific-password>
# Overrides: CUE_TEAM_ID (signing team), CUE_NOTARY_PROFILE (keychain profile name).
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM_ID="${CUE_TEAM_ID:-ZMAK33FWYB}"
PROFILE="${CUE_NOTARY_PROFILE:-cue-photos-notary}"

fail() { echo "release: $*" >&2; exit 1; }

[ -z "$(git status --porcelain)" ] || fail "the working tree has uncommitted changes; commit first"
IDENTITY=$(security find-identity -v -p codesigning |
  awk -v t="($TEAM_ID)" '/"Developer ID Application: / && index($0, t) { print $2; exit }')
[ -n "$IDENTITY" ] || fail "no Developer ID Application certificate of team $TEAM_ID in the keychain"
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 ||
  fail "no working notary credentials under the keychain profile $PROFILE"

VERSION=$(grep -m1 'MARKETING_VERSION' Photos.xcodeproj/project.pbxproj | sed 's/[^0-9.]//g')
BUILD=$(grep -m1 'CURRENT_PROJECT_VERSION' Photos.xcodeproj/project.pbxproj | sed 's/[^0-9]//g')
[ -n "$VERSION" ] && [ -n "$BUILD" ] || fail "cannot read the version from the project"
OUT="build/release/$VERSION-$BUILD"
DMG="$OUT/Cue-Photos-$VERSION.dmg"
[ ! -e "$DMG.sha256" ] ||
  fail "$VERSION ($BUILD) was already released; raise CURRENT_PROJECT_VERSION for a new build"

xcodebuild -scheme Photos -configuration Debug -derivedDataPath build test

echo "Building Cue Photos $VERSION ($BUILD, team $TEAM_ID)"
rm -rf build/ReleaseBuild "$OUT"
mkdir -p "$OUT"
xcodebuild -scheme Photos -configuration Release -derivedDataPath build/ReleaseBuild build \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime"

APP="build/ReleaseBuild/Build/Products/Release/Cue Photos.app"
[ -d "$APP" ] || fail "the build produced no Cue Photos.app"
codesign --verify --strict --deep "$APP"
DETAILS=$(codesign -dvv "$APP" 2>&1)
grep -q "^Authority=Developer ID Application: .*($TEAM_ID)$" <<<"$DETAILS" ||
  fail "the app is not signed with the team's Developer ID"
grep -q "^TeamIdentifier=$TEAM_ID$" <<<"$DETAILS" || fail "the app's team is not $TEAM_ID"
grep -q "^CodeDirectory .*flags=.*runtime" <<<"$DETAILS" || fail "the app lacks the hardened runtime"
grep -q "^Timestamp=" <<<"$DETAILS" || fail "the app's signature has no secure timestamp"
# notarization rejects debuggable binaries
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q get-task-allow; then
  fail "get-task-allow present in release entitlements"
fi
[ "$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")" \
  = "$VERSION" ] || fail "the built app's version is not $VERSION"

notarize() {
  # "status" and "state" are read-only specials in zsh; hence "verdict"
  local result id verdict
  echo "notarizing $(basename "$1"): waiting for Apple's verdict, usually minutes, silent meanwhile"
  result=$(xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --output-format json) ||
    true
  id=$(plutil -extract id raw - <<<"$result" 2>/dev/null) || fail "notarytool answered: $result"
  verdict=$(plutil -extract status raw - <<<"$result")
  if [ "$verdict" != Accepted ]; then
    xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2 || true
    fail "notarization of $(basename "$1") ended $verdict (submission $id)"
  fi
  echo "notarized $(basename "$1"): submission $id"
}

ditto -c -k --keepParent "$APP" "$OUT/notarize-app.zip"
notarize "$OUT/notarize-app.zip"
xcrun stapler staple "$APP"
rm "$OUT/notarize-app.zip"

STAGE="$OUT/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Cue Photos.app"
ln -s /Applications "$STAGE/Applications"
cp LICENSE NOTICE "$STAGE/"
hdiutil create -volname "Cue Photos $VERSION" -srcfolder "$STAGE" -format UDZO -ov "$DMG"
rm -rf "$STAGE"
codesign --sign "$IDENTITY" --timestamp "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"

xcrun stapler validate "$APP"
xcrun stapler validate "$DMG"
spctl --assess --type execute --verbose=2 "$APP"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" >"$(basename "$DMG").sha256")

echo
echo "Cue Photos $VERSION ($BUILD) from $(git rev-parse --short HEAD)"
echo "$DMG"
cat "$DMG.sha256"
