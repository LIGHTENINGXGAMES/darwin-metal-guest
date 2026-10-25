#!/bin/sh
# Builds the guest side for iOS (arm64e, the render server's architecture) on macOS with Xcode:
#   build/QemuMetal.bundle    the Metal plugin, ad hoc signed with 4 KiB pages
#   build/guest-metal-check   the discovery check tool, ad hoc signed
#   build/cdhashes.json       the CDHashes the guest's trust cache needs
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-"$ROOT/build"}
TARGET=${IOS_TARGET:-arm64e-apple-ios18.0}
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
CXXFLAGS="-std=c++17 -O1 -g -Wall -Wextra -Werror -Wno-unused-parameter -Wno-deprecated-declarations"
INCLUDES="-I$ROOT/frontend -I$ROOT/frontend/bridge -I$ROOT/wire -I$ROOT/include"
IOS="-target $TARGET -isysroot $SDK"

rm -rf "$OUT"
mkdir -p "$OUT/QemuMetal.bundle"
echo "SDK: $SDK ($(xcrun --sdk iphoneos --show-sdk-version)), target $TARGET"

cd "$ROOT"
xcrun clang++ $IOS $CXXFLAGS $INCLUDES -c remote/QemuMetalRemote.cpp -o "$OUT/QemuMetalRemote.o"
xcrun clang++ $IOS $CXXFLAGS -fobjc-arc $INCLUDES \
    frontend/NativeBridgeMetalFrontend.mm plugin/DarwinMetalPlugin.mm remote/QemuMetalLibraries.mm remote/QemuMetalGaps.mm \
    "$OUT/QemuMetalRemote.o" -bundle -Wl,-dead_strip \
    -framework Foundation -framework Metal -framework IOSurface -framework CoreFoundation \
    -o "$OUT/QemuMetal.bundle/QemuMetal"
xcrun strip -x "$OUT/QemuMetal.bundle/QemuMetal"
/usr/libexec/PlistBuddy -c 'Clear dict' \
    -c 'Add :CFBundleIdentifier string org.lstudio.QemuMetal' \
    -c 'Add :CFBundleExecutable string QemuMetal' \
    -c 'Add :CFBundlePackageType string BNDL' \
    -c 'Add :CFBundleVersion string 1' \
    -c 'Add :CFBundleShortVersionString string 1' \
    -c 'Add :NSPrincipalClass string QemuMetalDevice' \
    -c 'Add :MinimumOSVersion string 18.0' \
    "$OUT/QemuMetal.bundle/Info.plist" >/dev/null

xcrun clang++ $IOS $CXXFLAGS -fobjc-arc tools/guest-metal-check.mm -framework Foundation -framework Metal \
    -o "$OUT/guest-metal-check"

# The guest's kernel checks 4 KiB code pages; both are added to its trust cache by CDHash.
codesign --force --sign - --pagesize 4096 --identifier org.lstudio.QemuMetal "$OUT/QemuMetal.bundle"
codesign --force --sign - --pagesize 4096 --identifier org.lstudio.guest-metal-check \
    --entitlements "$ROOT/tools/guest-metal-check.entitlements.plist" "$OUT/guest-metal-check"
cdhash() {
    detail=$(codesign --display --verbose=4 "$1" 2>&1)
    echo "$detail" | grep -q '^Page size=4096$' || { echo "$1: not signed with 4 KiB pages" >&2; exit 1; }
    echo "$detail" | sed -n 's/^CDHash=\([0-9a-f]*\)$/\1/p'
}
BUNDLE_HASH=$(cdhash "$OUT/QemuMetal.bundle")
TOOL_HASH=$(cdhash "$OUT/guest-metal-check")
printf '{\n  "QemuMetal.bundle/QemuMetal": "%s",\n  "guest-metal-check": "%s"\n}\n' "$BUNDLE_HASH" "$TOOL_HASH" > "$OUT/cdhashes.json"
lipo -info "$OUT/QemuMetal.bundle/QemuMetal" "$OUT/guest-metal-check"
cat "$OUT/cdhashes.json"
