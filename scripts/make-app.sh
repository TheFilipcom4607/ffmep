#!/usr/bin/env bash
# Packages build/ffmep.app (with the bundled static ffmpeg) and build/ffmep.zip for sharing.
# Usage: VERSION=1.0.0 [SIGN_IDENTITY="Apple Development: …"] scripts/make-app.sh
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

# Shortcuts only sees App Intents listed in Contents/Resources/Metadata.appintents. Xcode generates it from the
# constant values the compiler writes out. SwiftPM's build system writes those too but stops there, so finish the job.
echo "→ extracting App Intents metadata"
INTENTS_DIR="$ROOT/.build/appintents-$CONFIG"
rm -rf "$INTENTS_DIR"
mkdir -p "$INTENTS_DIR"
CONFIG_DIR="$(tr '[:lower:]' '[:upper:]' <<<"${CONFIG:0:1}")${CONFIG:1}"
FILE_MAP="$ROOT/.build/out/Intermediates.noindex/ffmep.build/$CONFIG_DIR/ffmep-p.build/Objects-normal/arm64/ffmep-OutputFileMap.json"
if [[ -f "$FILE_MAP" ]]; then
  plutil -convert json -o - "$FILE_MAP" | python3 -c 'import json, sys; print("\n".join(e["const-values"] for e in json.load(sys.stdin).values() if "const-values" in e))' >"$INTENTS_DIR/constvalues.txt"
fi
if [[ -s "$INTENTS_DIR/constvalues.txt" ]]; then
  find "$ROOT/Sources/ffmep" -name '*.swift' >"$INTENTS_DIR/sources.txt"
  xcrun appintentsmetadataprocessor \
    --toolchain-dir "$(dirname "$(dirname "$(dirname "$(xcrun --find swift)")")")/usr" \
    --module-name ffmep \
    --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
    --xcode-version "$(xcodebuild -version | awk '/Build version/ { print $3 }')" \
    --platform-family macOS \
    --deployment-target 14.0 \
    --target-triple arm64-apple-macos14.0 \
    --binary-file "$APP/Contents/MacOS/ffmep" \
    --source-file-list "$INTENTS_DIR/sources.txt" \
    --swift-const-vals-list "$INTENTS_DIR/constvalues.txt" \
    --output "$APP/Contents/Resources" \
    --force >"$INTENTS_DIR/processor.log" 2>&1 \
    || { cat "$INTENTS_DIR/processor.log"; exit 1; }
  [[ -f "$APP/Contents/Resources/Metadata.appintents/extract.actionsdata" ]] \
    || { cat "$INTENTS_DIR/processor.log"; echo "App Intents metadata is missing"; exit 1; }
else
  echo "⚠︎ This SwiftPM didn't write compiler constant values, so Shortcuts won't list ffmep's actions."
fi

cp vendor/licenses/COPYING.GPLv3 "$APP/Contents/Resources/LICENSE-GPL.txt"
cp vendor/licenses/* "$APP/Contents/Resources/licenses/"
[[ -f vendor/BUILDINFO.txt ]] && cp vendor/BUILDINFO.txt "$APP/Contents/Resources/BUILDINFO.txt"

# macOS only runs a Shortcuts action for an app signed with a team ID; linkd rejects ad-hoc builds.
# Uses SIGN_IDENTITY if set, otherwise the first Apple Development certificate, otherwise ad-hoc.
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ { print $2; exit }')"
fi
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "→ ad-hoc signing (hardened runtime)"
  echo "⚠︎ No developer certificate, so Shortcuts will list ffmep's action but can't run it."
else
  echo "→ signing as $SIGN_IDENTITY (hardened runtime)"
fi
codesign --force --options runtime --timestamp=none -s "$SIGN_IDENTITY" "$APP/Contents/MacOS/ffmpeg" "$APP/Contents/MacOS/ffprobe"
codesign --force --options runtime --timestamp=none -s "$SIGN_IDENTITY" "$APP"
codesign --verify --strict --verbose=1 "$APP"

echo "✓ $(du -sh "$APP" | cut -f1)  $APP"
if [[ -n "$ZIP" ]]; then
  echo "→ zipping"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "✓ $(du -sh "$ZIP" | cut -f1)  $ZIP"
fi
echo "Friends: unzip, then right-click ffmep.app → Open the first time."
