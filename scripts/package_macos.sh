#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${NIMCULUS_VERSION:-0.1.0}"
ARCH="${NIMCULUS_ARCH:-arm64}"
IDENTITY="${NIMCULUS_CODESIGN_IDENTITY:-}"
OUT_DIR="${NIMCULUS_OUT_DIR:-$ROOT_DIR/build/macos}"
APP="$OUT_DIR/Nimculus.app"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "macOS packaging must run on Darwin" >&2
  exit 2
fi
if [[ "$ARCH" != "arm64" && "$ARCH" != "x86_64" ]]; then
  echo "NIMCULUS_ARCH must be arm64 or x86_64" >&2
  exit 2
fi

rm -rf "$OUT_DIR"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

nim c --mm:arc -d:release --cpu:"$ARCH" \
  --nimcache:"$OUT_DIR/nimcache" \
  --path:"$ROOT_DIR/src" -o:"$APP/Contents/MacOS/Nimculus" \
  "$ROOT_DIR/src/nimculus/main.nim"
rm -rf "$OUT_DIR/nimcache"
cp "$ROOT_DIR/packaging/macos/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT_DIR/packaging/macos/entitlements.plist" "$APP/Contents/Resources/Nimculus.entitlements"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"

if [[ -z "$IDENTITY" ]]; then
  if [[ "${NIMCULUS_ALLOW_ADHOC:-0}" != "1" ]]; then
    echo "Set NIMCULUS_CODESIGN_IDENTITY, or NIMCULUS_ALLOW_ADHOC=1 for local-only output" >&2
    exit 3
  fi
  codesign --force --sign - "$APP"
else
  codesign --force --options runtime --timestamp \
    --entitlements "$APP/Contents/Resources/Nimculus.entitlements" \
    --sign "$IDENTITY" "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP"

ditto -c -k --keepParent "$APP" "$OUT_DIR/Nimculus-$VERSION-$ARCH.zip"
hdiutil create -quiet -volname Nimculus -srcfolder "$APP" \
  -ov -format UDZO "$OUT_DIR/Nimculus-$VERSION-$ARCH.dmg"

if [[ "${NIMCULUS_NOTARIZE:-0}" == "1" ]]; then
  if [[ -z "$IDENTITY" || -z "${APPLE_ID:-}" || -z "${APPLE_TEAM_ID:-}" ||
        -z "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]]; then
    echo "notarization requires signing identity and Apple notarization credentials" >&2
    exit 4
  fi
  xcrun notarytool submit "$OUT_DIR/Nimculus-$VERSION-$ARCH.zip" \
    --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" --wait
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  # Rebuild containers so the stapled app is what users receive.
  ditto -c -k --keepParent "$APP" "$OUT_DIR/Nimculus-$VERSION-$ARCH.zip"
  hdiutil create -quiet -volname Nimculus -srcfolder "$APP" \
    -ov -format UDZO "$OUT_DIR/Nimculus-$VERSION-$ARCH.dmg"
  xcrun notarytool submit "$OUT_DIR/Nimculus-$VERSION-$ARCH.dmg" \
    --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" --wait
  xcrun stapler staple "$OUT_DIR/Nimculus-$VERSION-$ARCH.dmg"
  xcrun stapler validate "$OUT_DIR/Nimculus-$VERSION-$ARCH.dmg"
fi

echo "Created $APP"
echo "Created $OUT_DIR/Nimculus-$VERSION-$ARCH.zip"
echo "Created $OUT_DIR/Nimculus-$VERSION-$ARCH.dmg"
