#!/usr/bin/env bash
# Packages build/ffmep.app (with the bundled static ffmpeg) and build/ffmep.zip for sharing.
# Usage: VERSION=1.0.0 scripts/make-app.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d.%H%M)}"
CONFIG="${CONFIG:-release}"   # CONFIG=debug builds build/debug/ffmep.app (with screenshot hooks), no zip
if [[ "$CONFIG" == "debug" ]]; then
  APP="$ROOT/build/debug/ffmep.app"
  ZIP=""
else
  APP="$ROOT/build/ffmep.app"
  ZIP="$ROOT/build/ffmep.zip"
fi
RES="$ROOT/Sources/ffmep/Resources"

if [[ ! -x vendor/ffmpeg || ! -x vendor/ffprobe ]]; then
  echo "vendor/ffmpeg is missing. Run scripts/build-ffmpeg.sh first."
  exit 1
fi

echo "→ swift build ($CONFIG, arm64)"
swift build -c "$CONFIG" --arch arm64
BIN_DIR="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)"

[[ -f "$RES/AppIcon.icns" ]] || scripts/make-icon.sh

echo "→ assembling $APP"
rm -rf "$APP"
[[ -n "$ZIP" ]] && rm -f "$ZIP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/licenses"
cp "$BIN_DIR/ffmep" "$APP/Contents/MacOS/ffmep"
# SwiftPM stamps the deployment target (14.0) as the SDK version, which makes macOS 26 run the app
# in legacy appearance mode (no Liquid Glass). Record the real SDK version instead.
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
vtool -set-build-version macos 14.0 "$SDK_VERSION" -replace -output "$APP/Contents/MacOS/ffmep.tmp" "$APP/Contents/MacOS/ffmep" 2>/dev/null
mv "$APP/Contents/MacOS/ffmep.tmp" "$APP/Contents/MacOS/ffmep"
install -m 755 vendor/ffmpeg vendor/ffprobe "$APP/Contents/MacOS/"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" "$RES/Info.plist" >"$APP/Contents/Info.plist"
plutil -lint -s "$APP/Contents/Info.plist"
printf 'APPL????' >"$APP/Contents/PkgInfo"
cp "$RES/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp vendor/licenses/COPYING.GPLv3 "$APP/Contents/Resources/LICENSE-GPL.txt"
cp vendor/licenses/* "$APP/Contents/Resources/licenses/"
[[ -f vendor/BUILDINFO.txt ]] && cp vendor/BUILDINFO.txt "$APP/Contents/Resources/BUILDINFO.txt"

echo "→ ad-hoc signing (hardened runtime)"
codesign --force --options runtime --timestamp=none -s - "$APP/Contents/MacOS/ffmpeg" "$APP/Contents/MacOS/ffprobe"
codesign --force --options runtime --timestamp=none -s - "$APP"
codesign --verify --strict --verbose=1 "$APP"

echo "✓ $(du -sh "$APP" | cut -f1)  $APP"
if [[ -n "$ZIP" ]]; then
  echo "→ zipping"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "✓ $(du -sh "$ZIP" | cut -f1)  $ZIP"
fi
echo "Friends: unzip, then right-click ffmep.app → Open the first time."
