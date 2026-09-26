#!/usr/bin/env bash
# Builds, notarizes and staples the DMG people download, so ffmep opens on a double-click.
# Usage: scripts/release.sh 1.0.0
#
# One-time setup, on your Mac only:
#   • a "Developer ID Application" certificate in the keychain
#     (Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application)
#   • xcrun notarytool store-credentials ffmep-notary
#     (your Apple ID and an app-specific password, which stay in your keychain)
#
# Environment: NOTARY_PROFILE (default ffmep-notary), SIGN_IDENTITY, TAP_DIR, SKIP_PREFLIGHT=1
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Usage: scripts/release.sh VERSION   (e.g. 1.0.0)" >&2
  exit 1
fi

NOTARY_PROFILE="${NOTARY_PROFILE:-ffmep-notary}"
APP="$ROOT/build/ffmep.app"
STAGE="$ROOT/build/dmg"
DMG="$ROOT/build/ffmep-$VERSION.dmg"

# Apple Development signs well enough for Shortcuts, but notarization only takes Developer ID.
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ { print $2; exit }')"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
  cat >&2 <<'EOF'
No "Developer ID Application" certificate in the keychain.
Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application.
EOF
  exit 1
fi

# Checked before the build, because finding out after ten minutes of compiling is no fun.
if [[ -z "${SKIP_PREFLIGHT:-}" ]]; then
  echo "→ checking the notarytool credentials"
  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "notarytool can't use the keychain profile \"$NOTARY_PROFILE\"." >&2
    echo "Run: xcrun notarytool store-credentials $NOTARY_PROFILE" >&2
    exit 1
  fi
fi

echo "→ building ffmep $VERSION"
VERSION="$VERSION" SIGN_IDENTITY="$SIGN_IDENTITY" scripts/make-app.sh

# Captured, not piped to grep -q, which would die of SIGPIPE and trip pipefail on a good signature.
SIGNATURE="$(codesign -dv --verbose=4 "$APP" 2>&1 || true)"
case "$SIGNATURE" in
  *"Authority=Developer ID Application"*) ;;
  *) echo "$APP didn't come out Developer ID signed; notarization would reject it." >&2; exit 1 ;;
esac

echo "→ staging the disk image"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/ffmep.app"
ln -s /Applications "$STAGE/Applications"

echo "→ building $(basename "$DMG")"
hdiutil create -quiet -format UDZO -fs HFS+ -volname "ffmep" -srcfolder "$STAGE" "$DMG"
codesign --force --timestamp -s "$SIGN_IDENTITY" "$DMG"

echo "→ notarizing, which takes a few minutes"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "→ stapling"
xcrun stapler staple "$DMG"

echo "→ verifying"
xcrun stapler validate "$DMG"
# For a disk image this is the check Apple documents; -t install is for installer packages.
spctl -a -vvv -t open --context context:primary-signature "$DMG"

# What actually matters is the app inside, since that's what runs after the drag to /Applications.
MOUNT="$(mktemp -d)"
cleanup() { hdiutil detach -quiet "$MOUNT" 2>/dev/null || true; rm -rf "$MOUNT"; }
trap cleanup EXIT
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MOUNT" "$DMG"
xcrun stapler validate "$MOUNT/ffmep.app"
spctl -a -vvv -t exec "$MOUNT/ffmep.app"
cleanup
trap - EXIT

SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo
echo "✓ $(du -sh "$DMG" | cut -f1)  $DMG"
echo "  sha256  $SHA"
echo

# The Homebrew cask, if the tap is checked out next to this repo.
TAP_DIR="${TAP_DIR:-$ROOT/../homebrew-tap}"
CASK="$TAP_DIR/Casks/ffmep.rb"
if [[ -f "$CASK" ]]; then
  echo "→ updating $CASK"
  sed -i '' -e "s/^  version \".*\"\$/  version \"$VERSION\"/" \
            -e "s/^  sha256 \".*\"\$/  sha256 \"$SHA\"/" "$CASK"
  git -C "$TAP_DIR" --no-pager diff --stat
  echo "  Commit and push the tap once the release is up, or brew won't find the file."
else
  echo "ℹ No cask at $CASK. Set TAP_DIR if your tap lives somewhere else."
fi
echo

if ! command -v gh >/dev/null; then
  echo "gh isn't installed, so upload the DMG to the release yourself."
  exit 0
fi
PUBLISH="n"
if [[ -t 0 ]]; then
  printf 'Tag v%s and publish the release with this DMG? [y/N] ' "$VERSION"
  read -r PUBLISH
fi
if [[ "$PUBLISH" == [yY] ]]; then
  gh release create "v$VERSION" "$DMG" --title "ffmep $VERSION" --generate-notes
else
  echo "Nothing published. When you're ready:"
  echo "  gh release create v$VERSION \"$DMG\" --title \"ffmep $VERSION\" --generate-notes"
fi
