#!/bin/bash
#
# Builds PrtScn and assembles a runnable macOS .app bundle.
#
# Why a script instead of `swift run`? A menu-bar app needs a real .app bundle
# with an Info.plist (for LSUIElement / accessory mode) and a code signature
# (so macOS Screen Recording permission can be granted and remembered). SwiftPM
# only produces a bare executable, so we wrap it here.
#
# Two variants, so a stable install and a work-in-progress build can run side
# by side without fighting over permissions, settings, or hotkeys:
#   dev     → "PrtScn Dev.app", bundle id com.alejandrolacasa.prtscn.dev
#   release → "PrtScn.app",     bundle id com.alejandrolacasa.prtscn
# macOS keys Screen Recording (TCC), UserDefaults, and login items to the
# bundle id, so each variant gets its own one-time permission grant and its
# own settings. The app itself shows a distinct menu-bar icon for the dev
# build and defaults its hotkeys to ⌘⌥⇧ (vs ⌘⌥) so both can coexist.
#
# Usage:
#   ./build.sh            build the DEV app (build/PrtScn Dev.app)
#   ./build.sh run        build the dev app + (re)launch it
#   ./build.sh release    build the RELEASE app bundle (build/PrtScn.app) only
#                         — what CI uses before packaging the DMG
#   ./build.sh install    build the RELEASE app + install into /Applications
#                         (replacing and relaunching the installed copy)

set -euo pipefail
cd "$(dirname "$0")"

if [[ "${1:-}" == "install" || "${1:-}" == "release" ]]; then
  APP_NAME="PrtScn"
  BUNDLE_ID="com.alejandrolacasa.prtscn"
else
  APP_NAME="PrtScn Dev"
  BUNDLE_ID="com.alejandrolacasa.prtscn.dev"
fi

CONFIG="release"
BIN=".build/${CONFIG}/PrtScn"
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

# App icon.
#
# macOS 26 draws the layered Icon Composer document (Resources/AppIcon.icon):
# `actool` compiles it into an Assets.car carrying every appearance — light,
# dark, clear and tinted — alongside a flat AppIcon.icns for older systems and
# for Finder's smaller sizes. Info.plist's CFBundleIconName points at it.
#
# actool ships with Xcode, and this project otherwise only needs the Command
# Line Tools, so when it's missing we bundle the pre-rendered flat icon instead
# — which is why Resources/AppIcon.icns stays committed. CFBundleIconName is
# dropped in that case so nothing points at an Assets.car that isn't there.
#
# Both icons come from tools/IconGenerator.swift; see CLAUDE.md → "App icon".
LAYERED_ICON=0
if command -v actool >/dev/null 2>&1 && [[ -d "Resources/AppIcon.icon" ]]; then
  ICON_TMP="$(mktemp -d)"
  # Treat a failure here as "no layered icon", not as a fatal error. actool
  # drives Xcode's XPC helpers (ibtoold, CoreSimulatorService) and dies when
  # they're unavailable — inside a sandboxed shell, for instance. Under `set -e`
  # that aborted the script mid-assembly, leaving an app whose Info.plist was
  # still the unstamped template: CFBundleExecutable said "PrtScn" while the
  # binary was "PrtScn Dev", which macOS rejects on launch as "damaged or
  # incomplete". Assets.car has to exist for the compile to count as a success —
  # actool has been seen exiting 0 without writing anything.
  if actool "Resources/AppIcon.icon" \
      --compile "$APP/Contents/Resources" \
      --platform macosx \
      --minimum-deployment-target 26.0 \
      --app-icon AppIcon \
      --output-partial-info-plist "$ICON_TMP/icon.plist" >/dev/null \
     && [[ -f "$APP/Contents/Resources/Assets.car" ]]; then
    LAYERED_ICON=1
  fi
  rm -rf "$ICON_TMP"
fi

# actool derives its own AppIcon.icns from the layered document, but only up to
# 256px. Ours is the same design rendered to 1024, so it wins either way: macOS
# 26 reads Assets.car when it's there, and anything falling back to the icns
# (Finder at large sizes, the DMG) gets the full-resolution art.
cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

if (( LAYERED_ICON )); then
  echo "Compiled Resources/AppIcon.icon (layered macOS 26 icon)."
else
  # Nothing must point at an Assets.car that isn't there.
  /usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" \
    "$APP/Contents/Info.plist" >/dev/null 2>&1 || true
  echo "note: no layered icon (actool missing or failed) — bundled the flat AppIcon.icns."
fi

# The marketing version. Bump it here when cutting a release; the build
# number comes from git (commit count — monotonic and reproducible), so the
# About tab and Finder always show which build this actually is. CI overrides
# the version from the pushed tag via PRTSCN_VERSION.
VERSION="${PRTSCN_VERSION:-0.16.0}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 0)"

# Stamp the variant's identity and the version into the bundle.
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleIdentifier ${BUNDLE_ID}" \
  -c "Set :CFBundleName ${APP_NAME}" \
  -c "Set :CFBundleDisplayName ${APP_NAME}" \
  -c "Set :CFBundleExecutable ${APP_NAME}" \
  -c "Set :CFBundleShortVersionString ${VERSION}" \
  -c "Set :CFBundleVersion ${BUILD_NUMBER}" \
  "$APP/Contents/Info.plist"

# Never report success for a bundle macOS won't open. If the stamping above was
# skipped or silently no-oped, CFBundleExecutable still names the other variant
# and launching only ever produces Finder's useless "damaged or incomplete" —
# with nothing in this script's output to suggest why. Check it here instead.
STAMPED_EXEC="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$APP/Contents/Info.plist")"
if [[ "$STAMPED_EXEC" != "$APP_NAME" || ! -x "$APP/Contents/MacOS/$STAMPED_EXEC" ]]; then
  echo "error: ${APP} is inconsistent — CFBundleExecutable is '${STAMPED_EXEC}'," >&2
  echo "       but the bundled binary is 'MacOS/${APP_NAME}'. Re-run the build." >&2
  exit 1
fi

# Code signing.
#
# macOS ties Screen Recording (and other) permissions to the app's signing
# identity. An ad-hoc signature ("-") changes every build, so macOS re-prompts
# for permission each time. Signing with a STABLE self-signed certificate keeps
# the identity constant, so you grant Screen Recording once and it sticks.
# (Both variants share the certificate; their bundle ids keep them distinct.)
#
# Create the certificate once (see README "Sign once, grant once"), then this
# script picks it up automatically. Override the name with PRTSCN_SIGN_IDENTITY.
# Each variant has its own identity so dev and prod don't collide: the release
# cert also lives in CI (repo secrets), the dev one never leaves this machine.
if [[ "${1:-}" == "install" || "${1:-}" == "release" ]]; then
  SIGN_IDENTITY="${PRTSCN_SIGN_IDENTITY:-PrtScn Release}"
else
  SIGN_IDENTITY="${PRTSCN_SIGN_IDENTITY:-PrtScn Dev}"
fi

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
  # Relaunch cleanly if an old dev instance is running (the installed
  # "PrtScn" is a different process name and is left alone).
  pkill -x "$APP_NAME" 2>/dev/null || true
  open "$APP"
fi

if [[ "${1:-}" == "install" ]]; then
  killall "$APP_NAME" 2>/dev/null || true
  rm -rf "/Applications/${APP_NAME}.app"
  # ditto preserves the code signature and metadata better than cp.
  ditto "$APP" "/Applications/${APP_NAME}.app"
  open "/Applications/${APP_NAME}.app"
  echo "Installed /Applications/${APP_NAME}.app"
fi
