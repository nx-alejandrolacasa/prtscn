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
Package.swift                 SwiftPM manifest (executable target, macOS 26)
Resources/Info.plist          bundle metadata; LSUIElement = menu-bar app
build.sh                      build + bundle + sign
Sources/PrtScn/
  PrtScnApp.swift              @main App: MenuBarExtra + Settings scenes
  AppDelegate.swift            accessory policy, appearance + hotkey setup
  MenuContent.swift            the menu-bar dropdown
  CaptureMode.swift            region/window/full → screencapture flags
  WindowBackground.swift       margins/solid/wallpaper/trim window-shot backgrounds
  ScreenshotService.swift      runs /usr/sbin/screencapture; composite, save/copy/OCR
  PreviewController.swift      floating NSPanel that hosts the card
  PreviewModel.swift           card state + countdown + actions
  PreviewCard.swift            the SwiftUI preview card
  PreviewAction.swift          Edit/Copy/Save/Copy Text + icons + shortcuts
  DefaultAction.swift          what happens on auto-dismiss / Esc
  DraggableImage.swift         drag-to-export from the preview thumbnail
  Annotation.swift             annotation model + per-tool geometry
  EditorModel.swift            editor state, undo/redo, export flattening
  EditorCanvas.swift           the SwiftUI Canvas: drawing + gestures
  EditorView.swift             editor window body + floating tool palette
  EditorController.swift       editor NSWindow + title-bar toolbar
  SettingsStore.swift          @Observable settings, persisted to UserDefaults
  SettingsView.swift           General / Capture / Hotkeys tabs
  Appearance.swift             Auto/Light/Dark
  Shortcut.swift                key code + modifiers + glyph display
  HotkeyManager.swift          Carbon global hotkey registration
  ShortcutRecorder.swift       click-to-record key field
tools/IconGenerator.swift     draws the app icon (CoreGraphics); see README to regenerate
Resources/AppIcon.icns        generated app icon
```

## Conventions

- Pure native, **no third-party dependencies** — system frameworks only. Global
  hotkeys use Carbon `RegisterEventHotKey` (no Accessibility permission needed).
- Settings persist to `UserDefaults` via `SettingsStore` (`@MainActor @Observable`).
- The floating preview is a borderless `NSPanel` (`canBecomeKey`) hosting a SwiftUI
  card; it's activated on show so hover + keyboard shortcuts work immediately.
- Keep it dependency-free and on the CPU (this environment has no GPU/Metal).
