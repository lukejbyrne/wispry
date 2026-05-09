#!/usr/bin/env bash
set -euo pipefail

APP_NAME="TypeLocal"
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT_DIR/.build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
DOWNLOADS_DIR="$ROOT_DIR/site/downloads"
ENTITLEMENTS="$ROOT_DIR/Entitlements.plist"
VERSION="0.1.0"
SIGN_MODE="${SIGN_MODE:-auto}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
DMG_STAGE="$BUILD_DIR/dmg-stage"

find_identity() {
  local pattern="$1"
  security find-identity -v -p codesigning 2>/dev/null \
    | sed -n "s/.*\"\($pattern[^\"]*\)\".*/\1/p" \
    | head -n 1
}

resolve_signing() {
  local developer_id
  local development_id
  local local_id
  developer_id="$(find_identity "Developer ID Application:")"
  development_id="$(find_identity "Apple Development:")"
  local_id="$(find_identity "TypeLocal Local Code Signing")"
  if [[ -z "$local_id" ]]; then
    local_id="$(find_identity "Wispry Local Code Signing")"
  fi

  case "$SIGN_MODE" in
    auto)
      if [[ -n "$SIGN_IDENTITY" ]]; then
        RESOLVED_SIGN_MODE="custom"
      elif [[ -n "$developer_id" ]]; then
        SIGN_IDENTITY="$developer_id"
        RESOLVED_SIGN_MODE="developer-id"
      elif [[ -n "$development_id" ]]; then
        SIGN_IDENTITY="$development_id"
        RESOLVED_SIGN_MODE="development"
      elif [[ -n "$local_id" ]]; then
        SIGN_IDENTITY="$local_id"
        RESOLVED_SIGN_MODE="local"
      else
        RESOLVED_SIGN_MODE="adhoc"
      fi
      ;;
    developer-id)
      if [[ -z "$SIGN_IDENTITY" ]]; then
        SIGN_IDENTITY="$developer_id"
      fi
      if [[ -z "$SIGN_IDENTITY" ]]; then
        echo "error: SIGN_MODE=developer-id requested, but no Developer ID Application certificate is installed." >&2
        echo "Install one in Keychain Access/Xcode, or pass SIGN_IDENTITY=\"Developer ID Application: ...\"." >&2
        exit 1
      fi
      RESOLVED_SIGN_MODE="developer-id"
      ;;
    development)
      if [[ -z "$SIGN_IDENTITY" ]]; then
        SIGN_IDENTITY="$development_id"
      fi
      if [[ -z "$SIGN_IDENTITY" ]]; then
        echo "error: SIGN_MODE=development requested, but no Apple Development certificate is installed." >&2
        exit 1
      fi
      RESOLVED_SIGN_MODE="development"
      ;;
    local)
      if [[ -z "$SIGN_IDENTITY" ]]; then
        SIGN_IDENTITY="$local_id"
      fi
      if [[ -z "$SIGN_IDENTITY" ]]; then
        echo "error: SIGN_MODE=local requested, but no TypeLocal/Wispry local signing identity is installed." >&2
        exit 1
      fi
      RESOLVED_SIGN_MODE="local"
      ;;
    adhoc)
      RESOLVED_SIGN_MODE="adhoc"
      ;;
    *)
      echo "error: SIGN_MODE must be auto, developer-id, development, local, or adhoc." >&2
      exit 1
      ;;
  esac
}

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

swiftc \
  -O \
  -target arm64-apple-macosx13.0 \
  -framework Cocoa \
  -framework AVFoundation \
  -framework Speech \
  -framework Carbon \
  -framework ApplicationServices \
  "$ROOT_DIR"/Sources/Wispry/*.swift \
  -o "$MACOS_DIR/$APP_NAME"

cp "$ROOT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"

swift "$ROOT_DIR/Tools/GenerateAppIcon.swift" "$RESOURCES_DIR/AppIcon.icns"

resolve_signing

case "$RESOLVED_SIGN_MODE" in
  developer-id|development|custom)
    codesign \
      --force \
      --sign "$SIGN_IDENTITY" \
      --options runtime \
      --timestamp \
      --entitlements "$ENTITLEMENTS" \
      "$APP_DIR" >/dev/null
    ;;
  local)
    codesign \
      --force \
      --sign "$SIGN_IDENTITY" \
      --options runtime \
      --entitlements "$ENTITLEMENTS" \
      "$APP_DIR" >/dev/null
    ;;
  adhoc)
    codesign \
      --force \
      --sign - \
      --entitlements "$ENTITLEMENTS" \
      "$APP_DIR" >/dev/null
    ;;
esac

codesign --verify --strict --verbose=2 "$APP_DIR" >/dev/null

mkdir -p "$DOWNLOADS_DIR"
ZIP_PATH="$DOWNLOADS_DIR/$APP_NAME-$VERSION.zip"
DMG_PATH="$DOWNLOADS_DIR/$APP_NAME-$VERSION.dmg"
ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"

rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
ditto "$APP_DIR" "$DMG_STAGE/$APP_NAME.app"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_STAGE" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

if [[ "$RESOLVED_SIGN_MODE" != "adhoc" ]]; then
  codesign --force --sign "$SIGN_IDENTITY" "$DMG_PATH" >/dev/null
fi

if [[ -n "$NOTARY_PROFILE" ]]; then
  if [[ "$RESOLVED_SIGN_MODE" != "developer-id" && "$RESOLVED_SIGN_MODE" != "custom" ]]; then
    echo "error: NOTARY_PROFILE requires Developer ID signing." >&2
    exit 1
  fi

  xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_DIR"
  xcrun stapler validate "$APP_DIR"
  ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"
  rm -rf "$DMG_STAGE"
  mkdir -p "$DMG_STAGE"
  ditto "$APP_DIR" "$DMG_STAGE/$APP_NAME.app"
  ln -s /Applications "$DMG_STAGE/Applications"
  hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGE" \
    -ov \
    -format UDZO \
    "$DMG_PATH" >/dev/null
  codesign --force --sign "$SIGN_IDENTITY" "$DMG_PATH" >/dev/null
fi

echo "$APP_DIR"
echo "$DMG_PATH"
echo "Signing mode: $RESOLVED_SIGN_MODE"
if [[ "$RESOLVED_SIGN_MODE" == "adhoc" ]]; then
  echo "warning: no Developer ID, Apple Development, or TypeLocal local signing identity was found; built with ad-hoc signing." >&2
fi
