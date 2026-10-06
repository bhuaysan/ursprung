#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Builds a signed, notarized Ursprung disk image for people without Xcode.
# Usage: Scripts/dist.sh   (or: make dist)
#
# Needs, once:
#   - a "Developer ID Application" certificate in the login keychain
#     (Apple Developer Program, Xcode › Settings › Accounts › Manage Certificates)
#   - a notarytool keychain profile:
#       xcrun notarytool store-credentials ursprung-notary \
#           --apple-id <apple id> --team-id <team id> --password <app-specific password>
#   - .env with the ScreenScraper developer credentials (see README): end
#     users cannot add them, so a release without them cannot fetch metadata.
#
# Environment:
#   SIGN_IDENTITY   code signing identity (default: the first Developer ID Application)
#   TEAM_ID         team ID (default: taken from the identity)
#   NOTARY_PROFILE  notarytool keychain profile (default: ursprung-notary)
#   SKIP_NOTARIZE=1 build and package only, e.g. to test this script; the
#                   result is not for distribution
set -eu
cd "$(dirname "$0")/.."

DERIVED_DATA="${DERIVED_DATA:-build/DerivedData}"
DIST="build/dist"
NOTARY_PROFILE="${NOTARY_PROFILE:-ursprung-notary}"

fail() { echo "error: $*" >&2; exit 1; }

command -v xcodegen >/dev/null || fail "xcodegen missing: brew install xcodegen"

if [ -z "${SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)
    [ -n "$SIGN_IDENTITY" ] || fail "no \"Developer ID Application\" certificate in the keychain. Set SIGN_IDENTITY, or see the comment at the top of $0."
fi
if [ -z "${TEAM_ID:-}" ]; then
    # The certificate's organisational unit is the team (the name in
    # parentheses is the team only for Developer ID certificates).
    TEAM_ID=$(security find-certificate -c "$SIGN_IDENTITY" -p | openssl x509 -noout -subject -nameopt multiline \
        | sed -n 's/^ *organizationalUnitName *= *\([A-Z0-9]\{10\}\)$/\1/p' | head -1)
fi
[ -n "$TEAM_ID" ] || fail "could not determine the team ID; set TEAM_ID."

has_credential() {
    [ -n "$(printenv "$1" || true)" ] || { [ -f .env ] && grep -q "^$1=..*" .env; }
}
if ! has_credential SCREENSCRAPER_DEV_ID || ! has_credential SCREENSCRAPER_DEV_PASSWORD; then
    fail "ScreenScraper developer credentials are required for a release: put SCREENSCRAPER_DEV_ID and SCREENSCRAPER_DEV_PASSWORD in .env or the environment (see README)."
fi

echo "› Building Release, signed by $SIGN_IDENTITY"
./Scripts/generate-secrets.sh .env Ursprung/Support/Secrets.generated.swift
./Scripts/fetch-librashader.sh
xcodegen generate --quiet
xcodebuild -project Ursprung.xcodeproj -scheme Ursprung -configuration Release \
    -derivedDataPath "$DERIVED_DATA" -destination 'platform=macOS,arch=arm64' \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_IDENTITY" DEVELOPMENT_TEAM="$TEAM_ID" \
    OTHER_CODE_SIGN_FLAGS="--timestamp" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    build -quiet

APP="$DERIVED_DATA/Build/Products/Release/Ursprung.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
echo "› Verifying the signature of Ursprung $VERSION"
codesign --verify --deep --strict --verbose=1 "$APP"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "com.apple.security.get-task-allow" \
    && fail "the app carries get-task-allow (a debug entitlement); notarization would reject it."

rm -rf "$DIST"
mkdir -p "$DIST/image"
cp -R "$APP" "$DIST/image/"
ln -s /Applications "$DIST/image/Applications"
DMG="$DIST/Ursprung-$VERSION.dmg"
echo "› Creating $DMG"
hdiutil create -quiet -volname "Ursprung $VERSION" -srcfolder "$DIST/image" -fs APFS -format UDZO "$DMG"
codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"
rm -rf "$DIST/image"

if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
    echo "› Skipping notarization (SKIP_NOTARIZE=1). $DMG is not for distribution."
    exit 0
fi

echo "› Notarizing (this takes a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "› Done: $DMG — attach it and the .sha256 file to a GitHub release tagged v$VERSION."
