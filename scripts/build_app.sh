#!/usr/bin/env bash
# Builds a universal (Apple Silicon + Intel) MacDownloader.app and a .dmg. Run on macOS.
set -euo pipefail

VERSION="${VERSION:-1.0.0}"
BUILD="${BUILD:-1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/dist"
APP="$OUT/MacDownloader.app"

cd "$ROOT"
rm -rf "$OUT"
mkdir -p "$OUT"

echo "==> Compiling"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/MacDownloader"

echo "==> Assembling app bundle"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacDownloader"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
cp -R ChromeExtension "$APP/Contents/Resources/ChromeExtension"

echo "==> Building icon"
ICONSET="$OUT/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

echo "==> Ad-hoc signing"
codesign --force --deep --sign - "$APP"

echo "==> Creating DMG"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "MacDownloader" -srcfolder "$STAGE" -ov -format UDZO "$OUT/MacDownloader-$VERSION.dmg"
rm -rf "$STAGE"

echo "==> Packaging browser extension"
(cd "$ROOT" && zip -qr "$OUT/MacDownloader-ChromeExtension-$VERSION.zip" ChromeExtension)

echo "Done:"
ls -lh "$OUT"
