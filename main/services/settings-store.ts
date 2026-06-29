/**
 * Settings Store - persists AppSettings to <userData>/settings.json
 */

import fs from "fs/promises";
import path from "path";

import { app, logger } from "@glaze/core/backend";

export type CaptureMode = "region" | "window" | "fullScreen";

export interface Shortcuts {
  region: string;
  window: string;
  fullScreen: string;
}

export interface AppSettings {
  shortcuts: Shortcuts;
  saveFolder: string;
  launchAtLogin: boolean;
  previewTimeout: number; // seconds; 0 = never auto-dismiss
}

const DEFAULT_SETTINGS: AppSettings = {
  shortcuts: {
    region: "Command+Alt+1",
    window: "Command+Alt+2",
    fullScreen: "Command+Alt+3",
  },
  saveFolder: app.getPath("desktop"),
  launchAtLogin: false,
  previewTimeout: 5,
};

class SettingsStore {
  private cache: AppSettings | null = null;
  private filePath: string | null = null;

  private async getFilePath(): Promise<string> {
    if (!this.filePath) {
      const userDataPath = app.getPath("userData");
      await fs.mkdir(userDataPath, { recursive: true });
      this.filePath = path.join(userDataPath, "settings.json");
    }
    return this.filePath;
  }

  /**
   * Load settings from disk, applying defaults for any missing fields.
   * Returns true if a settings file existed, false if this is first launch.
   */
  async load(): Promise<boolean> {
    const filePath = await this.getFilePath();
    try {
      const raw = await fs.readFile(filePath, "utf-8");
      const parsed = JSON.parse(raw) as Partial<AppSettings>;
      this.cache = {
        ...DEFAULT_SETTINGS,
        ...parsed,
        shortcuts: {
          ...DEFAULT_SETTINGS.shortcuts,
          ...(parsed.shortcuts ?? {}),
        },
      };
      logger.info("settings-store", "Settings loaded from disk", { path: filePath });
      return true;
    } catch {
      // File does not exist or is malformed — use defaults
      this.cache = { ...DEFAULT_SETTINGS };
      logger.info("settings-store", "No settings file found, using defaults");
      return false;
    }
  }

  get(): AppSettings {
    if (!this.cache) {
      throw new Error("SettingsStore.load() must be called before get()");
    }
    return { ...this.cache };
  }

  async save(settings: AppSettings): Promise<void> {
    const filePath = await this.getFilePath();
    this.cache = { ...settings };
    await fs.writeFile(filePath, JSON.stringify(settings, null, 2), "utf-8");
    logger.info("settings-store", "Settings saved to disk");
  }

  async update(patch: Partial<AppSettings>): Promise<AppSettings> {
    const current = this.get();
    const updated: AppSettings = { ...current, ...patch };
    await this.save(updated);
    return updated;
  }
}

export const settingsStore = new SettingsStore();
