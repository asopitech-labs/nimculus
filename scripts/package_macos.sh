#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${NIMCULUS_VERSION:-0.1.0}"
ARCH="${NIMCULUS_ARCH:-arm64}"
IDENTITY="${NIMCULUS_CODESIGN_IDENTITY:-}"
OUT_DIR="${NIMCULUS_OUT_DIR:-$ROOT_DIR/build/macos}"
APP="$OUT_DIR/Nimculus.app"
NIMCACHE_DIR="${TMPDIR:-/tmp}/nimculus-package-nimcache-$$"
ZIP="$OUT_DIR/Nimculus-$VERSION-$ARCH.zip"
DMG="$OUT_DIR/Nimculus-$VERSION-$ARCH.dmg"

cleanup() {
  rm -rf "$NIMCACHE_DIR"
}
trap cleanup EXIT

verify_artifact() {
  local artifact="$1"
  if [[ ! -s "$artifact" ]]; then
    echo "distribution artifact is missing or empty: $artifact" >&2
    exit 5
  fi
}

verify_dmg() {
  local artifact="$1"
  verify_artifact "$artifact"
  hdiutil verify "$artifact" >/dev/null
}

submit_notarization() {
  local artifact="$1"
  local -a credentials
  if [[ -n "${APPLE_NOTARY_PROFILE:-}" ]]; then
    credentials=(--keychain-profile "$APPLE_NOTARY_PROFILE")
  elif [[ -n "${APPLE_NOTARY_KEY:-}" ||
          -n "${APPLE_NOTARY_KEY_ID:-}" ||
          -n "${APPLE_NOTARY_ISSUER_ID:-}" ]]; then
    if [[ -z "${APPLE_NOTARY_KEY:-}" ||
          -z "${APPLE_NOTARY_KEY_ID:-}" ||
          -z "${APPLE_NOTARY_ISSUER_ID:-}" ||
          ! -r "$APPLE_NOTARY_KEY" ]]; then
      echo "API-key notarization requires a readable key, key ID, and issuer ID" >&2
      exit 4
    fi
    credentials=(--key "$APPLE_NOTARY_KEY"
      --key-id "$APPLE_NOTARY_KEY_ID" --issuer "$APPLE_NOTARY_ISSUER_ID")
  elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" &&
          -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]]; then
    credentials=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID"
      --password "$APPLE_APP_SPECIFIC_PASSWORD")
  else
    echo "notarization requires a keychain profile, API key credentials, or Apple ID credentials" >&2
    exit 4
  fi
  xcrun notarytool submit "$artifact" "${credentials[@]}" --wait
}

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

ICONSET="$OUT_DIR/Nimculus.iconset"
mkdir -p "$NIMCACHE_DIR/clang-module-cache"
if ! CLANG_MODULE_CACHE_PATH="$NIMCACHE_DIR/clang-module-cache" \
  swift "$ROOT_DIR/scripts/generate_macos_icon.swift" "$ICONSET" \
  "$APP/Contents/Resources/Nimculus.icns"; then
  # ImageIO is the primary writer. Older/macOS runner images may not expose
  # the ICNS destination, while iconutil can still consume the documented
  # iconset renditions.
  rm -f "$APP/Contents/Resources/Nimculus.icns"
  iconutil --convert icns --output "$APP/Contents/Resources/Nimculus.icns" "$ICONSET"
fi
verify_artifact "$APP/Contents/Resources/Nimculus.icns"
rm -rf "$ICONSET"

nim c --mm:arc -d:release --cpu:"$ARCH" \
  --nimcache:"$NIMCACHE_DIR" \
  --path:"$ROOT_DIR/src" -o:"$APP/Contents/MacOS/Nimculus" \
  "$ROOT_DIR/src/nimculus/main.nim"
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
if [[ -n "$IDENTITY" ]]; then
  # spctl is the Gatekeeper assessment that a signed distribution must pass.
  # Ad-hoc CI smoke artifacts are intentionally excluded because Gatekeeper
  # rejects them without a Developer ID certificate.
  spctl --assess --type execute --verbose "$APP"
fi

ditto -c -k --keepParent "$APP" "$ZIP"
hdiutil create -quiet -volname Nimculus -srcfolder "$APP" \
  -ov -format UDZO "$DMG"
verify_artifact "$ZIP"
verify_dmg "$DMG"

if [[ "${NIMCULUS_NOTARIZE:-0}" == "1" ]]; then
  if [[ -z "$IDENTITY" ]]; then
    echo "notarization requires a Developer ID signing identity" >&2
    exit 4
  fi
  submit_notarization "$ZIP"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose "$APP"
  # Rebuild containers so the stapled app is what users receive.
  ditto -c -k --keepParent "$APP" "$ZIP"
  hdiutil create -quiet -volname Nimculus -srcfolder "$APP" \
    -ov -format UDZO "$DMG"
  verify_artifact "$ZIP"
  verify_dmg "$DMG"
  submit_notarization "$DMG"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl --assess --type open --context context:primary-signature \
    "$DMG"
fi

echo "Created $APP"
echo "Created $ZIP"
echo "Created $DMG"
