#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Downloads the prebuilt librashader dylib that Ursprung links and embeds
# (see ThirdParty/librashader/README.md). The binary is not committed: this
# script fetches the pinned release, checks its SHA-256 and gives it an
# @rpath install name. It does nothing when that version is already there.
#
# Usage: fetch-librashader.sh [output directory]

set -eu

VERSION="0.12.0"
ARCHIVE="librashader-aarch64-macos-v$VERSION-optimized.zip"
SHA256="49808004a4904f6a99e0231092dcfdfe52b7b61f68430a4c9f1e165749c4c90e"
URL="https://github.com/SnowflakePowered/librashader/releases/download/librashader-v$VERSION/$ARCHIVE"

OUTPUT="${1:-$(dirname "$0")/../ThirdParty/librashader/lib}"
STAMP="$OUTPUT/.version"

if [ -f "$OUTPUT/librashader.dylib" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$VERSION" ]; then
    exit 0
fi

echo "› Downloading librashader $VERSION"
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
curl -fsSL --retry 3 -o "$STAGING/$ARCHIVE" "$URL"
echo "$SHA256  $STAGING/$ARCHIVE" | shasum -a 256 -c --quiet - || {
    echo "error: $ARCHIVE does not match the expected SHA-256" >&2
    exit 1
}
unzip -q "$STAGING/$ARCHIVE" -d "$STAGING/unpacked"
DYLIB=$(find "$STAGING/unpacked" -name librashader.dylib | head -n1)
[ -n "$DYLIB" ] || { echo "error: $ARCHIVE contains no librashader.dylib" >&2; exit 1; }

# The release carries the path of its CI build as install name.
install_name_tool -id @rpath/librashader.dylib "$DYLIB" 2>/dev/null
codesign --force --sign - "$DYLIB" 2>/dev/null

mkdir -p "$OUTPUT"
mv -f "$DYLIB" "$OUTPUT/librashader.dylib"
echo "$VERSION" > "$STAMP"
