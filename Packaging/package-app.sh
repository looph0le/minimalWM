#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build"
ARM_BUILD_DIR="$BUILD_DIR-arm64"
INTEL_BUILD_DIR="$BUILD_DIR-x86_64"
DIST_DIR="$ROOT_DIR/dist"
APP="$DIST_DIR/minimalWM.app"
ICONSET="$BUILD_DIR/minimalwm.iconset"
ICON_SVG="$ROOT_DIR/assets/minimalwm-icon.svg"

rm -rf "$APP" "$ICONSET" "$ARM_BUILD_DIR" "$INTEL_BUILD_DIR"
mkdir -p "$DIST_DIR" "$ICONSET" "$APP/Contents/MacOS" "$APP/Contents/Resources"

SWIFT_COMPAT_FLAGS=(-Xswiftc -swift-version -Xswiftc 5)
swift build -c release --arch arm64 --scratch-path "$ARM_BUILD_DIR" "${SWIFT_COMPAT_FLAGS[@]}"
swift build -c release --arch x86_64 --scratch-path "$INTEL_BUILD_DIR" "${SWIFT_COMPAT_FLAGS[@]}"
ARM_BIN="$ARM_BUILD_DIR/arm64-apple-macosx/release/minimalWM"
INTEL_BIN="$INTEL_BUILD_DIR/x86_64-apple-macosx/release/minimalWM"
lipo -create "$ARM_BIN" "$INTEL_BIN" -output "$APP/Contents/MacOS/minimalWM"
chmod +x "$APP/Contents/MacOS/minimalWM"

render_icon() {
    local size="$1"
    local output="$2"
    local rendered
    rendered="$(mktemp -d)/icon.png"
    qlmanage -t -s "$size" -o "$(dirname "$rendered")" "$ICON_SVG" >/dev/null 2>&1
    mv "$(dirname "$rendered")/minimalwm-icon.svg.png" "$rendered"
    sips -z "$size" "$size" "$rendered" --out "$output" >/dev/null
    rm -rf "$(dirname "$rendered")"
}

for spec in \
    "16 icon_16x16.png" "32 icon_16x16@2x.png" \
    "32 icon_32x32.png" "64 icon_32x32@2x.png" \
    "128 icon_128x128.png" "256 icon_128x128@2x.png" \
    "256 icon_256x256.png" "512 icon_256x256@2x.png" \
    "512 icon_512x512.png" "1024 icon_512x512@2x.png"; do
    set -- $spec
    render_icon "$1" "$ICONSET/$2"
done

iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/minimalwm.icns"
cp "$ROOT_DIR/Packaging/Info.plist" "$APP/Contents/Info.plist"

ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST_DIR/minimalWM-universal.zip"
shasum -a 256 "$DIST_DIR/minimalWM-universal.zip" > "$DIST_DIR/minimalWM-universal.zip.sha256"
echo "Packaged $APP"
