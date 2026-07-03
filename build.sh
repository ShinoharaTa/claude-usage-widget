#!/bin/bash
# Build ClaudeUsageWidget.app and install it to ~/Applications
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="ClaudeUsageWidget"
DIST="$HOME/Applications"
BUILD="build"

mkdir -p "$BUILD"
swiftc -O Sources/main.swift -o "$BUILD/$APP_NAME"

APP="$BUILD/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
mv "$BUILD/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
codesign --force --sign - "$APP"

pkill -x "$APP_NAME" 2>/dev/null || true
mkdir -p "$DIST"
rm -rf "$DIST/$APP_NAME.app"
cp -R "$APP" "$DIST/"

echo "Installed: $DIST/$APP_NAME.app"
