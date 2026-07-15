# CLAUDE.md

PrtScn — a native macOS **menu-bar screenshot utility** written in Swift/SwiftUI.
Capture a region/window/full screen, get a cursor-anchored floating preview with
Edit / Copy / Save, configurable global shortcuts, save folder, auto-dismiss, and
launch-at-login. (Originally prototyped in the Glaze app builder; that code has
been removed — this is now a pure native Swift app.)

## Build & run

- **No full Xcode** here — Command Line Tools only. Use **Swift Package Manager**.
- `./build.sh` — compile + assemble the **dev** app, `build/PrtScn Dev.app`
  (bundle id `…prtscn.dev`, camera-with-ellipsis menu-bar icon, ⌘⌥⇧ default
  hotkeys) so it coexists with an installed stable copy — separate Screen
  Recording grant, settings, and login item.
- `./build.sh run` — also (re)launch it (kills only the dev instance).
- `./build.sh install` — build the **release** app (`PrtScn.app`, bundle id
  `…prtscn`) and install/relaunch it in `/Applications`.
- It's a menu-bar app (no Dock icon); look for the camera icon in the menu bar.
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
  MenuBarState.swift           menu-bar icon "shot taken" flash state
  UpdateChecker.swift          GitHub Releases update check + DMG self-install
  CaptureMode.swift            region/window/full/fixed → screencapture flags
  FixedSizePrompt.swift        width × height dialog for fixed-size capture
  FixedSizeOverlay.swift       cursor-following fixed-size capture rectangle
  ScrollCaptureOverlay.swift   drag-select region overlay for scrolling capture
  ScrollCaptureController.swift scrolling capture: AX pre-flight, scroll loop, HUD
  ScrollStitcher.swift         aligns + composites scroll frames into one tall image
  WindowBackground.swift       margins/solid/wallpaper/trim window-shot backgrounds
  ScreenshotService.swift      runs /usr/sbin/screencapture; composite, save/copy/OCR
  PreviewController.swift      floating NSPanel that hosts the card
  PreviewModel.swift           card state + countdown + actions
  PreviewCard.swift            style dispatcher + shared pieces + classic card
  PreviewCardStyles.swift      the Archipelago (floating islands) style
  PreviewStyle.swift           which preview style is active (Settings → Capture)
  PreviewAction.swift          Edit/Copy/Save/OCR/Discard + icons + shortcuts
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
tools/IconGenerator.swift     draws the app icon (CoreGraphics); see "App icon"
assets/                       README header image
Resources/AppIcon.icns        generated app icon
```

## App icon

The icon is drawn programmatically — tweak colors/layout in
`tools/IconGenerator.swift`, then:

```sh
swiftc tools/IconGenerator.swift -o /tmp/icongen && /tmp/icongen
iconutil -c icns AppIcon.iconset -o Resources/AppIcon.icns
./build.sh
```

`AppIcon-preview.png` (1024px) is written for quick inspection; the README
header image is `assets/PrtScr-AppIcon-1024.png` (update it too if the design
changes). The intermediates (`AppIcon.iconset/`, the preview) are gitignored —
only `Resources/AppIcon.icns` and the assets PNG are committed.

## Conventions

- Pure native, **no third-party dependencies** — system frameworks only. Global
  hotkeys use Carbon `RegisterEventHotKey` (no Accessibility permission needed).
  The one Accessibility-gated feature is **scrolling capture** (it posts
  synthetic scroll-wheel events); `ScrollCaptureController` pre-flights the
  grant and sends the user to System Settings when missing.
- Settings persist to `UserDefaults` via `SettingsStore` (`@MainActor @Observable`).
- The floating preview is a borderless `NSPanel` (`canBecomeKey`) hosting a SwiftUI
  card; it's activated on show so hover + keyboard shortcuts work immediately.
- Keep it dependency-free and on the CPU (this environment has no GPU/Metal).
