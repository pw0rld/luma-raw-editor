#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${LUMA_BUILD_DIR:-$ROOT/.build-direct}"
mkdir -p "$BUILD"
ARCH="$(uname -m)"
FLAGS=(-target "$ARCH-apple-macosx13.0" -swift-version 5)
# Optional local workaround for an inconsistent Command Line Tools installation.
# It only changes the compiler's virtual view; no system files are edited.
if [[ -n "${LUMA_TOOLCHAIN_OVERLAY:-}" ]]; then
    FLAGS+=(-vfsoverlay "$LUMA_TOOLCHAIN_OVERLAY" -module-cache-path "$BUILD/ModuleCacheOverlay")
fi
xcrun swiftc "${FLAGS[@]}" -O -parse-as-library -emit-module -emit-library -module-name LumaCore \
    "$ROOT"/Sources/LumaCore/*.swift -o "$BUILD/libLumaCore.dylib" \
    -emit-module-path "$BUILD/LumaCore.swiftmodule" -Xlinker -install_name -Xlinker @rpath/libLumaCore.dylib
xcrun swiftc "${FLAGS[@]}" -O -parse-as-library -I "$BUILD" -L "$BUILD" -lLumaCore \
    "$ROOT"/Sources/LumaRAW/*.swift -o "$BUILD/LumaRAW" -Xlinker -rpath -Xlinker @executable_path/../Frameworks
APP="$ROOT/Luma RAW.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
# Build the macOS icon from the source artwork on every clean package.
ICONSET="$BUILD/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for spec in \
    "16 icon_16x16.png" "32 icon_16x16@2x.png" \
    "32 icon_32x32.png" "64 icon_32x32@2x.png" \
    "128 icon_128x128.png" "256 icon_128x128@2x.png" \
    "256 icon_256x256.png" "512 icon_256x256@2x.png" \
    "512 icon_512x512.png" "1024 icon_512x512@2x.png"; do
    size="${spec%% *}"; name="${spec#* }"
    sips -z "$size" "$size" "$ROOT/Art/AppIcon.png" --out "$ICONSET/$name" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
# Replace files by rename so a running older instance retains its mapped inodes.
cp "$BUILD/LumaRAW" "$APP/Contents/MacOS/LumaRAW.new"
mv -f "$APP/Contents/MacOS/LumaRAW.new" "$APP/Contents/MacOS/LumaRAW"
cp "$BUILD/libLumaCore.dylib" "$APP/Contents/Frameworks/libLumaCore.dylib.new"
mv -f "$APP/Contents/Frameworks/libLumaCore.dylib.new" "$APP/Contents/Frameworks/libLumaCore.dylib"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP/Contents/Frameworks/libLumaCore.dylib"
codesign --force --sign - "$APP"
printf 'Built: %s\n' "$APP"
if [[ "${1:-}" == "--check" ]]; then
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -D STANDALONE_CHECK -I "$BUILD" -L "$BUILD" -lLumaCore \
        "$ROOT"/Tests/LumaCoreTests/*.swift "$ROOT/scripts/CheckMain.swift" \
        -o "$BUILD/LumaCheck" -Xlinker -rpath -Xlinker @executable_path
    "$BUILD/LumaCheck"
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$BUILD" -L "$BUILD" -lLumaCore \
        "$ROOT/Sources/LumaRAW/EditorModel.swift" "$ROOT/scripts/FolderCheck.swift" \
        -o "$BUILD/FolderCheck" -Xlinker -rpath -Xlinker @executable_path
    "$BUILD/FolderCheck" "$ROOT/Samples"
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$BUILD" -L "$BUILD" -lLumaCore \
        "$ROOT/Sources/LumaRAW/EditorModel.swift" "$ROOT/scripts/MatchModelCheck.swift" \
        -o "$BUILD/MatchModelCheck" -Xlinker -rpath -Xlinker @executable_path
    "$BUILD/MatchModelCheck" "$ROOT/Samples"
fi
