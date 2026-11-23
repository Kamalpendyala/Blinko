#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIGURATION="${CONFIGURATION:-release}"
SIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
APP_DIR="build/Blinko.app"

swift build -c "$CONFIGURATION" --product Blinko
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/Blinko" "$APP_DIR/Contents/MacOS/Blinko"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"

codesign \
    --force \
    --sign "$SIGN_IDENTITY" \
    --entitlements Resources/Blinko.entitlements \
    --timestamp=none \
    "$APP_DIR"

codesign --verify --strict "$APP_DIR"

echo "Built $APP_DIR"
echo "Launch with: open \"$APP_DIR\" --args --debug"
