#!/bin/bash
#
# Builds PrtScn and assembles a runnable macOS .app bundle.
#
# Why a script instead of `swift run`? A menu-bar app needs a real .app bundle
# with an Info.plist (for LSUIElement / accessory mode) and a code signature
# (so macOS Screen Recording permission can be granted and remembered). SwiftPM
# only produces a bare executable, so we wrap it here.
#
# Usage:
#   ./build.sh        build + bundle
#   ./build.sh run    build + bundle + launch

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="PrtScn"
CONFIG="release"
BIN=".build/${CONFIG}/${APP_NAME}"
APP="build/${APP_NAME}.app"

# --disable-sandbox: SwiftPM normally wraps build steps in its own sandbox,
# which fails inside other sandboxes (e.g. CI / agent shells). Harmless here
# since the package has no third-party dependencies.
swift build -c "$CONFIG" --disable-sandbox

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/${APP_NAME}"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Code signing.
#
# macOS ties Screen Recording (and other) permissions to the app's signing
# identity. An ad-hoc signature ("-") changes every build, so macOS re-prompts
# for permission each time. Signing with a STABLE self-signed certificate keeps
# the identity constant, so you grant Screen Recording once and it sticks.
#
# Create the certificate once (see README "Sign once, grant once"), then this
# script picks it up automatically. Override the name with PRTSCN_SIGN_IDENTITY.
SIGN_IDENTITY="${PRTSCN_SIGN_IDENTITY:-PrtScn Dev}"

if security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY"; then
  codesign --force --sign "$SIGN_IDENTITY" "$APP"
  echo "Signed with '$SIGN_IDENTITY' (stable identity)."
else
  codesign --force --sign - "$APP"
  echo "warning: '$SIGN_IDENTITY' code-signing identity not found — used ad-hoc."
  echo "         macOS will re-prompt for Screen Recording on each rebuild."
  echo "         See README → 'Sign once, grant once' to fix this permanently."
fi

echo "Built ${APP}"

if [[ "${1:-}" == "run" ]]; then
  # Relaunch cleanly if an old instance is running.
  pkill -x "$APP_NAME" 2>/dev/null || true
  open "$APP"
fi
