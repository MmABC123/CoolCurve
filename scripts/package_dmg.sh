#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
VERSION="${1:-1.0.0}"
APP_NAME="Fanline"
APP_BUNDLE="$ROOT_DIR/$APP_NAME.app"
DIST_DIR="$ROOT_DIR/dist"
STAGE_DIR="$ROOT_DIR/.build/dmg-stage"
DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION-arm64.dmg"

echo "[1/3] Building $APP_NAME.app..."
zsh "$ROOT_DIR/scripts/build_app.sh"

echo "[2/3] Staging DMG contents..."
rm -rf "$STAGE_DIR" "$DMG_PATH"
mkdir -p "$STAGE_DIR" "$DIST_DIR"
cp -R "$APP_BUNDLE" "$STAGE_DIR/$APP_NAME.app"
ln -s /Applications "$STAGE_DIR/Applications"

echo "[3/3] Creating compressed DMG..."
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGE_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

rm -rf "$STAGE_DIR"
SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
echo "✅ Packaged: $DMG_PATH"
echo "SHA-256: $SHA256"
