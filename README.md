# PrtScn — native (Swift/SwiftUI)

A from-scratch native macOS rewrite of the Glaze PrtScn app: a menu-bar
screenshot utility. No third-party dependencies — system frameworks only.

## Requirements

- macOS 14+
- Swift toolchain (Xcode **or** Command Line Tools — `xcode-select --install`)

## Build & run

```sh
./build.sh        # compile + assemble build/PrtScn.app
./build.sh run    # also (re)launch it
```

Or open the bundle manually:

```sh
open build/PrtScn.app
```

The app has **no Dock icon** — look for the camera (`􀌞`) icon in the menu bar.

On the first capture, macOS will ask for **Screen Recording** permission
(System Settings → Privacy & Security → Screen Recording). This is required for
`screencapture` to produce non-blank output.

## Sign once, grant once (stop the repeated permission prompts)

By default the build is **ad-hoc** signed, whose identity changes on every
build — so macOS treats each rebuild as a new app and re-asks for Screen
Recording permission. Create a **stable self-signed certificate once** and the
grant sticks across all future builds.

**One-time setup (≈1 min):**

1. Open **Keychain Access** (⌘-Space → "Keychain Access").
2. Menu bar → **Keychain Access → Certificate Assistant → Create a Certificate…**
3. Fill in:
   - **Name:** `PrtScn Dev`  ← must match exactly
   - **Identity Type:** Self-Signed Root
   - **Certificate Type:** Code Signing
4. Click **Create** → Continue through the warning → **Done**.

Verify it's there:

```sh
security find-identity -v -p codesigning   # should list "PrtScn Dev"
```

Now `./build.sh` signs with it automatically. The next build will prompt for
Screen Recording **one last time** (new identity) — grant it, and you won't be
asked again. If old `PrtScn` entries linger in **System Settings → Privacy &
Security → Screen Recording**, remove them and keep the new one.

> Want a different cert name? `PRTSCN_SIGN_IDENTITY="My Cert" ./build.sh`.

## Project layout

```
Package.swift                 SwiftPM manifest (executable target, macOS 14)
Resources/Info.plist          bundle metadata; LSUIElement = menu-bar app
build.sh                      build + bundle + ad-hoc sign
Sources/PrtScn/
  PrtScnApp.swift             @main App: MenuBarExtra + Settings scenes
  AppDelegate.swift           accessory policy, appearance + hotkey setup
  MenuContent.swift           the menu-bar dropdown
  CaptureMode.swift           region/window/full → screencapture flags
  ScreenshotService.swift     runs /usr/sbin/screencapture; save/copy/edit
  PreviewController.swift     floating NSPanel that hosts the card
  PreviewModel.swift          card state + countdown + actions
  PreviewCard.swift           the SwiftUI preview card
  PreviewAction.swift         Edit/Copy/Save + icons + shortcuts
  SettingsStore.swift         @Observable settings, persisted to UserDefaults
  SettingsView.swift          General / Capture / Hotkeys tabs
  Appearance.swift            Auto/Light/Dark
  Shortcut.swift              key code + modifiers + glyph display
  HotkeyManager.swift         Carbon global hotkey registration
  ShortcutRecorder.swift      click-to-record key field
tools/IconGenerator.swift     draws the app icon (CoreGraphics)
Resources/AppIcon.icns        generated app icon
```

## Regenerating the app icon

The icon is drawn programmatically (no image editor needed) — tweak colors or
layout in `tools/IconGenerator.swift`, then:

```sh
swiftc tools/IconGenerator.swift -o /tmp/icongen && /tmp/icongen
iconutil -c icns AppIcon.iconset -o Resources/AppIcon.icns
./build.sh
```

`AppIcon-preview.png` (1024px) is written for quick inspection.

## Status / roadmap

- [x] **Slice 1** — menu-bar skeleton; captures to Desktop.
- [x] **Slice 2** — cursor-anchored floating preview panel (Edit/Copy/Save), hover-to-pause auto-dismiss, ⏎/⌘C/⌘S shortcuts, untouched-auto-save.
- [x] **Slice 3** — Settings: General (launch-at-login, appearance) + Capture (auto-dismiss duration, save folder), persisted to UserDefaults.
- [x] **Slice 4** — global shortcuts (Carbon hotkeys + click-to-record UI). Defaults ⌘⌥1/2/3; per-row clear + Restore Defaults.
- [x] **Slice 5** — app icon (programmatic, retro keyboard close-up). Remaining: any UX polish.
