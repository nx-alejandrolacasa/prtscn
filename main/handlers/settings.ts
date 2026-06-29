/**
 * Settings Handlers
 *
 * Thin IPC boundary for settings read/write operations.
 * Business logic lives in main/services/settings-store.ts.
 */

import { app, dialog, ipcMain, logger } from "@glaze/core/backend";

import { settingsStore, type CaptureMode, type Shortcuts } from "../services/settings-store.js";

type RebuildTrayFn = () => void;
type RegisterShortcutsFn = (shortcuts: Shortcuts) => Promise<CaptureMode[]>;

let rebuildTray: RebuildTrayFn | null = null;
let registerShortcuts: RegisterShortcutsFn | null = null;

export function setTrayRebuildCallback(fn: RebuildTrayFn): void {
  rebuildTray = fn;
}

export function setShortcutRegisterCallback(fn: RegisterShortcutsFn): void {
  registerShortcuts = fn;
}

export function registerSettingsHandlers(): void {
  // settings:get → AppSettings
  ipcMain.handle("settings:get", async (_event) => {
    return settingsStore.get();
  });

  // settings:setLaunchAtLogin { enabled: boolean } → AppSettings
  ipcMain.handle("settings:setLaunchAtLogin", async (_event, params: unknown) => {
    if (
      typeof params !== "object" ||
      params === null ||
      typeof (params as Record<string, unknown>).enabled !== "boolean"
    ) {
      throw new Error("settings:setLaunchAtLogin requires { enabled: boolean }");
    }
    const { enabled } = params as { enabled: boolean };
    app.setLoginItemSettings({ openAtLogin: enabled });
    const updated = await settingsStore.update({ launchAtLogin: enabled });
    ipcMain.broadcast("settings:launchAtLogin-changed", { value: enabled });
    logger.info("settings", "launchAtLogin updated", { enabled });
    return updated;
  });

  // settings:setPreviewTimeout { seconds: number } → AppSettings
  ipcMain.handle("settings:setPreviewTimeout", async (_event, params: unknown) => {
    if (
      typeof params !== "object" ||
      params === null ||
      typeof (params as Record<string, unknown>).seconds !== "number"
    ) {
      throw new Error("settings:setPreviewTimeout requires { seconds: number }");
    }
    const { seconds } = params as { seconds: number };
    const updated = await settingsStore.update({ previewTimeout: seconds });
    ipcMain.broadcast("settings:previewTimeout-changed", { value: seconds });
    logger.info("settings", "previewTimeout updated", { seconds });
    return updated;
  });

  // settings:setShortcuts { shortcuts: Shortcuts } → { settings: AppSettings, failures: CaptureMode[] }
  ipcMain.handle("settings:setShortcuts", async (_event, params: unknown) => {
    if (
      typeof params !== "object" ||
      params === null ||
      typeof (params as Record<string, unknown>).shortcuts !== "object"
    ) {
      throw new Error("settings:setShortcuts requires { shortcuts: Shortcuts }");
    }
    const { shortcuts } = params as { shortcuts: Shortcuts };

    if (!registerShortcuts) {
      throw new Error("settings:setShortcuts: shortcut register callback not wired");
    }

    logger.info("settings", `[settings:setShortcuts] updating shortcuts`, { shortcuts });

    // Delegate re-registration to main/index.ts (which owns globalShortcut lifecycle)
    const failures = await registerShortcuts(shortcuts);

    // Only persist shortcuts that succeeded
    const current = settingsStore.get();
    const persisted: Shortcuts = { ...current.shortcuts };
    const modes: CaptureMode[] = ["region", "window", "fullScreen"];
    for (const mode of modes) {
      if (!failures.includes(mode)) {
        persisted[mode] = shortcuts[mode];
      }
    }

    const updated = await settingsStore.update({ shortcuts: persisted });

    // Rebuild tray so accelerator labels reflect the new shortcuts
    rebuildTray?.();

    ipcMain.broadcast("settings:shortcuts-changed", { value: updated.shortcuts });
    return { settings: updated, failures };
  });

  // settings:pickSaveFolder → { settings: AppSettings, canceled: boolean }
  ipcMain.handle("settings:pickSaveFolder", async (_event) => {
    const result = await dialog.showOpenDialog({
      title: "Choose Save Folder",
      properties: ["openDirectory", "createDirectory"],
    });

    if (result.canceled || result.filePaths.length === 0) {
      return { settings: settingsStore.get(), canceled: true };
    }

    const saveFolder = result.filePaths[0];
    const updated = await settingsStore.update({ saveFolder });
    ipcMain.broadcast("settings:saveFolder-changed", { value: saveFolder });
    logger.info("settings", "saveFolder updated", { saveFolder });
    return { settings: updated, canceled: false };
  });
}
