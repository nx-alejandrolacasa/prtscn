# CLAUDE.md

PrtScn — a native macOS **menu-bar screenshot utility** written in Swift/SwiftUI.
Capture a region/window/full screen, get a cursor-anchored floating preview with
Edit / Copy / Save, configurable global shortcuts, save folder, auto-dismiss, and
launch-at-login. (Originally prototyped in the Glaze app builder; that code has
been removed — this is now a pure native Swift app.)

## Build & run

- **No full Xcode** here — Command Line Tools only. Use **Swift Package Manager**.
- `./build.sh` — compile + assemble `build/PrtScn.app` (Info.plist + code sign).
- `./build.sh run` — also launch it. It's a menu-bar app (no Dock icon); look for
  the camera icon in the menu bar.
- `swift build -c release --disable-sandbox` to just compile. `--disable-sandbox`
  is required when building inside an agent/CI shell (SwiftPM's own sandbox can't
  nest); harmless otherwise.

## Signing (stop repeated Screen Recording prompts)

macOS ties Screen Recording permission to the signing identity. Ad-hoc signing
changes every build → re-prompts. Create a stable self-signed cert once named
**"PrtScn Dev"** (Keychain Access → Certificate Assistant → Create a Certificate,
Code Signing, Self-Signed Root); `build.sh` then uses it automatically. See
README → "Sign once, grant once".

## Layout

```
Package.swift            SwiftPM manifest (executable, macOS 26+)
build.sh                 build + bundle + sign
Resources/               Info.plist (LSUIElement), AppIcon.icns
Sources/PrtScn/          app code (see README for the file map)
tools/IconGenerator.swift  draws the app icon (CoreGraphics); see README to regenerate
```

## Conventions

- Pure native, **no third-party dependencies** — system frameworks only. Global
  hotkeys use Carbon `RegisterEventHotKey` (no Accessibility permission needed).
- Settings persist to `UserDefaults` via `SettingsStore` (`@MainActor @Observable`).
- The floating preview is a borderless `NSPanel` (`canBecomeKey`) hosting a SwiftUI
  card; it's activated on show so hover + keyboard shortcuts work immediately.
- Keep it dependency-free and on the CPU (this environment has no GPU/Metal).
