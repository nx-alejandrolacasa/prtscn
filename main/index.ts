// Main process entry point - Node.js backend for PrtScn menu-bar app
//
// The glaze CLI runtime automatically handles all framework wiring (IPC server,
// native bridge, lifecycle, signal handlers) before this file runs.
// This entry point uses only public @glaze/core/backend APIs.

import {
  app,
  Menu,
  Tray,
  globalShortcut,
  screen,
  logger,
  initDevToolsButtonState,
} from "@glaze/core/backend";

import { registerHandlers } from "./handlers/index.js";
import { setTrayRebuildCallback, setShortcutRegisterCallback } from "./handlers/settings.js";
import { openSettingsWindow } from "./windows/settings-window.js";
import { showPreview } from "./windows/preview-window.js";
import { settingsStore, type CaptureMode, type Shortcuts } from "./services/settings-store.js";
import { captureScreenshot } from "./services/screenshot-service.js";

// ── Dev-only parity harness ───────────────────────────────────────────
type DevHarness = {
  applyParityScenarioStartup(): void;
  runParityAutotestIfRequested(): Promise<void>;
};
let devHarness: DevHarness | null = null;
if (process.env.GLAZE_DEV_HARNESS === "1") {
  // @ts-ignore dev-only harness; present only in the template, excluded from scaffolded apps
  devHarness = (await import("./dev/parity-autotest.js")) as DevHarness;
  devHarness.applyParityScenarioStartup();
}

// ── State ─────────────────────────────────────────────────────────────
let tray: Tray | null = null;

// ── IPC Handlers ──────────────────────────────────────────────────────
registerHandlers();

// ── Capture trigger ───────────────────────────────────────────────────
async function triggerCapture(mode: CaptureMode): Promise<void> {
  logger.info("main", `[screenshot:capture] triggered`, { mode });

  const payload = await captureScreenshot(mode);
  if (!payload) {
    // User cancelled — do nothing
    return;
  }

  // Read cursor AFTER capture so the preview anchors to where the selection
  // finished (region/window are interactive and move the cursor).
  const cursor = screen.getCursorScreenPoint();
  await showPreview(payload, cursor.x, cursor.y);
}

// ── Global Shortcuts ──────────────────────────────────────────────────
/**
 * Unregister any shortcuts for the given accelerators and re-register them.
 * Returns the list of modes whose registration failed.
 */
async function applyShortcuts(shortcuts: Shortcuts): Promise<CaptureMode[]> {
  const modes: CaptureMode[] = ["region", "window", "fullScreen"];
  const failures: CaptureMode[] = [];

  // Unregister all existing shortcuts first
  globalShortcut.unregisterAll();

  for (const mode of modes) {
    const accelerator = shortcuts[mode];
    const ok = await globalShortcut.register(accelerator, () => {
      triggerCapture(mode).catch((err) => {
        logger.error("main", `Error during capture (${mode})`, err);
      });
    });
    if (!ok) {
      logger.warn("main", `[settings:setShortcuts] failed to register shortcut`, {
        mode,
        accelerator,
      });
      failures.push(mode);
    } else {
      logger.info("main", "Registered global shortcut", { mode, accelerator });
    }
  }

  return failures;
}

// ── Tray ──────────────────────────────────────────────────────────────
function buildTrayMenu(): void {
  if (!tray) return;
  const settings = settingsStore.get();
  const { shortcuts } = settings;

  const menu = Menu.buildFromTemplate([
    {
      label: "Capture Region",
      icon: "viewfinder",
      accelerator: shortcuts.region,
      click: () => triggerCapture("region").catch((err) => logger.error("main", "Capture error", err)),
    },
    {
      label: "Capture Window",
      icon: "macwindow",
      accelerator: shortcuts.window,
      click: () => triggerCapture("window").catch((err) => logger.error("main", "Capture error", err)),
    },
    {
      label: "Capture Full Screen",
      icon: "display",
      accelerator: shortcuts.fullScreen,
      click: () => triggerCapture("fullScreen").catch((err) => logger.error("main", "Capture error", err)),
    },
    { type: "separator" },
    {
      label: "Settings…",
      icon: "gearshape",
      accelerator: "Command+,",
      click: () => openSettingsWindow().catch((err) => logger.error("main", "Settings open error", err)),
    },
    { type: "separator" },
    { label: "Quit PrtScn", role: "quit", icon: "power" },
  ]);

  tray.setContextMenu(menu);
}

function createTray(): void {
  tray = new Tray("camera.viewfinder");
  tray.setToolTip("PrtScn");
  buildTrayMenu();
  logger.info("main", "Tray created");
}

// ── Application menu ──────────────────────────────────────────────────
async function setupApplicationMenu(): Promise<void> {
  await initDevToolsButtonState();
  const menu = Menu.buildFromTemplate([
    {
      label: "PrtScn",
      submenu: [
        { role: "about" },
        { type: "separator" },
        {
          label: "Settings…",
          icon: "gearshape",
          accelerator: "Command+,",
          click: async () => await openSettingsWindow(),
        },
        { type: "separator" },
        { role: "services" },
        { type: "separator" },
        { role: "hide" },
        { role: "hideOthers" },
        { role: "unhide" },
        { type: "separator" },
        { role: "quit" },
      ],
    },
    { role: "editMenu" },
    { role: "viewMenu" },
    { role: "windowMenu" },
  ]);
  Menu.setApplicationMenu(menu);
  logger.info("main", "Application menu configured");
}

// ── Lifecycle events ──────────────────────────────────────────────────
app.on("window-all-closed", () => {
  // Menu-bar app — do not quit when all windows are closed
});

app.on("activate", () => {
  // Menu-bar app — keep dock hidden on re-activate
  app.dock.hide();
});

app.on("will-quit", () => {
  logger.info("main", "App will-quit: unregistering shortcuts and destroying tray");
  globalShortcut.unregisterAll();
  tray?.destroy();
  tray = null;
});

// ── App ready ─────────────────────────────────────────────────────────
const startTime = Date.now();
logger.info("main", "⏱️ [COLD_START] Waiting for app ready...", {
  timestamp: new Date().toISOString(),
});

// Wire callbacks before app ready so settings handlers can call them
setTrayRebuildCallback(() => buildTrayMenu());
setShortcutRegisterCallback((shortcuts) => applyShortcuts(shortcuts));

app.whenReady().then(async () => {
  logger.info("main", "⏱️ [COLD_START] App ready", {
    timestamp: new Date().toISOString(),
    wait_duration_ms: Date.now() - startTime,
  });

  await devHarness?.runParityAutotestIfRequested();

  // Load settings first (needed before tray labels and shortcut registration)
  const isFirstLaunch = !(await settingsStore.load());
  const settings = settingsStore.get();

  // Apply launch-at-login from persisted setting
  app.setLoginItemSettings({ openAtLogin: settings.launchAtLogin });

  await setupApplicationMenu();

  // Register global shortcuts
  await applyShortcuts(settings.shortcuts);

  // Create tray
  createTray();

  // On first launch open settings so the user can configure
  if (isFirstLaunch) {
    logger.info("main", "First launch detected — opening settings window");
    await openSettingsWindow();
  }

  logger.info("main", "PrtScn ready");
});
