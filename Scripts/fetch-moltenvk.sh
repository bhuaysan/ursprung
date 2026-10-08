#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Downloads the prebuilt MoltenVK dylib that Ursprung links and embeds, and
# the Vulkan headers of the same release (see ThirdParty/moltenvk/README.md).
# Neither is committed: this script fetches the pinned release, checks its
# SHA-256 and thins the universal dylib to arm64. It does nothing when that
# version is already there.
#
# Usage: fetch-moltenvk.sh [output directory]

set -eu

VERSION="1.4.2"
ARCHIVE="MoltenVK-macos.tar"
SHA256="f95765a6229cb7b915990a2890ce12ebe36a730b021545d3d52ae69ce4c4024e"
URL="https://github.com/KhronosGroup/MoltenVK/releases/download/v$VERSION/$ARCHIVE"

OUTPUT="${1:-$(dirname "$0")/../ThirdParty/moltenvk}"
STAMP="$OUTPUT/lib/.version"

if [ -f "$OUTPUT/lib/libMoltenVK.dylib" ] && [ -f "$OUTPUT/include/vulkan/vulkan.h" ] \
    && [ "$(cat "$STAMP" 2>/dev/null)" = "$VERSION" ]; then
    exit 0
fi

echo "› Downloading MoltenVK $VERSION"
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
curl -fsSL --retry 3 -o "$STAGING/$ARCHIVE" "$URL"
echo "$SHA256  $STAGING/$ARCHIVE" | shasum -a 256 -c --quiet - || {
    echo "error: $ARCHIVE does not match the expected SHA-256" >&2
    exit 1
}
tar -xf "$STAGING/$ARCHIVE" -C "$STAGING" \
    MoltenVK/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib \
    MoltenVK/MoltenVK/include/vulkan MoltenVK/MoltenVK/include/vk_video MoltenVK/MoltenVK/include/MoltenVK
DYLIB="$STAGING/MoltenVK/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib"

# Ursprung runs on Apple Silicon only; the x86_64 half would double the size.
# The release already uses @rpath/libMoltenVK.dylib as install name.
lipo -thin arm64 "$DYLIB" -output "$STAGING/libMoltenVK.dylib"
codesign --force --sign - "$STAGING/libMoltenVK.dylib" 2>/dev/null

# Only the C headers: the C++ bindings (vulkan.hpp and friends) are 20 MB.
rm -rf "$OUTPUT/include"
mkdir -p "$OUTPUT/lib" "$OUTPUT/include/vulkan"
cp "$STAGING"/MoltenVK/MoltenVK/include/vulkan/*.h "$OUTPUT/include/vulkan/"
cp -R "$STAGING/MoltenVK/MoltenVK/include/vk_video" "$STAGING/MoltenVK/MoltenVK/include/MoltenVK" "$OUTPUT/include/"
mv -f "$STAGING/libMoltenVK.dylib" "$OUTPUT/lib/libMoltenVK.dylib"
echo "$VERSION" > "$STAMP"
