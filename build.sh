#!/bin/bash
# Build ClaudeUsageWidget.app and install it to ~/Applications
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="ClaudeUsageWidget"
DIST="$HOME/Applications"
BUILD="build"

# Auto-start agent (written by the app's --enable-login-item / menu toggle).
LABEL="com.shino3.claude-usage-widget"
AGENT_PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

mkdir -p "$BUILD"
export CLANG_MODULE_CACHE_PATH="$PWD/$BUILD/module-cache"
swiftc -O Sources/main.swift -o "$BUILD/$APP_NAME"

APP="$BUILD/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
mv "$BUILD/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
codesign --force --sign - "$APP"

# Boot the agent out before killing the process: with KeepAlive, launchd would
# otherwise respawn the old binary while the bundle is being replaced.
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
pkill -x "$APP_NAME" 2>/dev/null || true
mkdir -p "$DIST"
rm -rf "$DIST/$APP_NAME.app"
cp -R "$APP" "$DIST/"

echo "Installed: $DIST/$APP_NAME.app"

if [ -f "$AGENT_PLIST" ]; then
  launchctl bootstrap "$DOMAIN" "$AGENT_PLIST"
  echo "Started via launchd ($LABEL)"
else
  echo "Not started. Enable auto-start (and start now) with:"
  echo "  $DIST/$APP_NAME.app/Contents/MacOS/$APP_NAME --enable-login-item"
fi
