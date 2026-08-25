# CLAUDE.md

PrtScn — a native macOS **menu-bar screenshot utility** written in Swift/SwiftUI.
Capture a region/window/full screen, get a cursor-anchored floating preview with
Edit / Copy / Save, configurable global shortcuts, save folder, auto-dismiss, and
launch-at-login. (Originally prototyped in the Glaze app builder; that code has
been removed — this is now a pure native Swift app.)

## Build & run

- **No full Xcode** here — Command Line Tools only. Use **Swift Package Manager**.
- `./build.sh` — compile + assemble the **dev** app, `build/PrtScn Dev.app`
  (bundle id `…prtscn.dev`, warning-badged photo menu-bar icon, ⌘⌥⇧ default
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
  BlankCanvas.swift            white scratch image opened straight in the editor
  DockIconMode.swift           Dock icon / ⌘Tab presence: while editing / always / never
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
  SettingsWindow.swift         AppKit NSSplitViewController settings window (full-height sidebar)
  SettingsView.swift           sidebar panes: General/Capture/Preview/Editor/Hotkeys/About
  Appearance.swift             Auto/Light/Dark
  Shortcut.swift                key code + modifiers + glyph display
  HotkeyManager.swift          Carbon global hotkey registration
  ShortcutRecorder.swift       click-to-record key field
tools/IconGenerator.swift     draws both app icons; see "App icon"
assets/                       README header image
Resources/AppIcon.icns        generated flat app icon (fallback)
Resources/AppIcon.icon/       generated Icon Composer document (macOS 26)
```

## App icon

The icon is drawn programmatically, in **two representations of one design**,
both emitted by `tools/IconGenerator.swift` from the same palette and the same
`windows` geometry specs — so they can't drift apart:

- `Resources/AppIcon.icon` — an **Apple Icon Composer** document: the two
  windows as unmasked full-bleed 1024×1024 SVG layers over a document-level
  gradient fill. This is what macOS 26 ships; it applies its own Liquid Glass
  material, shadows and specular highlights per appearance (light / dark /
  clear / tinted), so the SVGs carry shape and colour only.
- `Resources/AppIcon.icns` — the **flat** raster icon, drawn with CoreGraphics
  and baking in the effects macOS 26 would otherwise draw. It's the fallback
  for hosts without `actool` (which ships with Xcode, not the Command Line
  Tools) and for anything that reads `CFBundleIconFile`.

Tweak colors/layout in `tools/IconGenerator.swift`, then:

```sh
swiftc tools/IconGenerator.swift -o /tmp/icongen && /tmp/icongen
iconutil -c icns AppIcon.iconset -o Resources/AppIcon.icns
./build.sh
```

The generator writes `Resources/AppIcon.icon` in place, in Icon Composer's own
on-disk format (alphabetical keys, two-space indent, `" : "` separators, no
trailing newline — which `JSONEncoder` with `.sortedKeys`/`.prettyPrinted`
reproduces exactly). So opening the package in Icon Composer, saving, and
re-running the generator leaves no diff either way, and regenerating doesn't
clobber the package — files are rewritten individually and any extra asset is
reported, not deleted.

`AppIcon-preview.png` (1024px) is written for quick inspection; the README
header image is `assets/PrtScr-AppIcon-1024.png` (update it too if the design
changes). The intermediates (`AppIcon.iconset/`, the preview) are gitignored —
`Resources/AppIcon.icns`, `Resources/AppIcon.icon/` and the assets PNG are
committed.

### Verifying a change to the layered icon

`ictool` (inside Icon Composer.app) is the authority on **validity** — it
refuses to open a document it dislikes, so a rejected value surfaces as
`The data couldn't be read…`. Its `--export-image` needs a GPU and crashes
here (exit 133); *that crash means the document loaded fine*. Check every
appearance:

```sh
ICTOOL="$(dirname "$(xcode-select -p)")/Applications/Icon Composer.app/Contents/Executables/ictool"
for r in Default Dark TintedLight TintedDark; do
  "$ICTOOL" Resources/AppIcon.icon --export-image --output-file /dev/null \
    --platform macOS --rendition "$r" --width 1024 --height 1024 --scale 1
done
```

To actually *see* it, `actool` renders without a GPU (256px max; `--app-icon`
must match the package basename):

```sh
actool Resources/AppIcon.icon --compile /tmp/out --platform macosx \
  --minimum-deployment-target 26.0 --app-icon AppIcon \
  --output-partial-info-plist /tmp/out/partial.plist
iconutil -c iconset /tmp/out/AppIcon.icns -o /tmp/out/AppIcon.iconset
```

Non-obvious rules the generator already encodes — worth knowing before hand-editing:

- `groups` runs **front to back**: `groups[0]` is drawn last, on top. The front
  window comes first.
- The background is the document's top-level `fill`, never a layer (as a layer
  it would take its group's glass treatment, and the dark/clear/tinted variants
  are derived from the fill). `linear-gradient` takes two stops and runs
  top-to-bottom with no direction control, so the flat icon's *diagonal*
  lilac → apricot ramp becomes a *vertical* one here. That's the one
  intentional difference between the two icons.
- `translucency` must be explicitly `{ enabled: false, value: 0.5 }` on every
  group — Icon Composer defaults it on at 0.5, which turns these near-white
  cards into ghosts against the pastel background. `glass: true` stays.
- Omit `color-space-for-untagged-svg-colors`. Omitting it is what makes the
  SVGs' untagged hex literals mean sRGB (the space the palette is authored in);
  Icon Composer 1.6 rejects the documented value `"srgb"` outright and only
  accepts `"display-p3"`, which changes nothing in `actool`'s output.
- The skill's `validate_icon.py` needs `uv`, which isn't installed here —
  `ictool` is the check.

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
