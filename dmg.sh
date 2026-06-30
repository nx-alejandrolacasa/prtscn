#!/bin/bash
#
# Packages the already-built build/PrtScn.app into a distributable .dmg.
#
# Run ./build.sh first to produce build/PrtScn.app, then ./dmg.sh. The DMG is a
# compressed (UDZO) image containing the app plus an /Applications symlink, so
# users can drag-to-install in the mounted volume.
#
# Usage:
#   ./dmg.sh            -> build/PrtScn.dmg
#   ./dmg.sh 1.2.0      -> build/PrtScn-1.2.0.dmg

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="PrtScn"
APP="build/${APP_NAME}.app"
VERSION="${1:-}"

if [[ ! -d "$APP" ]]; then
  echo "error: $APP not found — run ./build.sh first." >&2
  exit 1
fi

if [[ -n "$VERSION" ]]; then
  DMG="build/${APP_NAME}-${VERSION}.dmg"
else
  DMG="build/${APP_NAME}.dmg"
fi

# Stage the contents of the DMG: the app plus a symlink to /Applications so the
# mounted volume offers the familiar drag-to-install layout.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$DMG"

echo "Built ${DMG}"
