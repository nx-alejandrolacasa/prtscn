/**
 * Screenshot Handlers
 *
 * IPC boundary for screenshot preview and delivery operations.
 * Business logic lives in main/services/screenshot-service.ts.
 */

import { ipcMain, logger } from "@glaze/core/backend";

import {
  copyCapture,
  editCapture,
  saveCapture,
  cleanupCapture,
  getPendingCapture,
} from "../services/screenshot-service.js";
import { getCurrentPayload, hidePreview } from "../windows/preview-window.js";

export function registerScreenshotHandlers(): void {
  // preview:ready → PreviewPayload | null
  // Renderer calls this on mount to receive the current pending payload
  ipcMain.handle("preview:ready", async (_event) => {
    const payload = getCurrentPayload();
    logger.info("screenshot-handler", "preview:ready called", {
      hasPayload: payload !== null,
      id: payload?.id,
    });
    return payload;
  });

  // screenshot:save { id: string } → { savedPath: string }
  ipcMain.handle("screenshot:save", async (_event, params: unknown) => {
    if (
      typeof params !== "object" ||
      params === null ||
      typeof (params as Record<string, unknown>).id !== "string"
    ) {
      throw new Error("screenshot:save requires { id: string }");
    }
    const { id } = params as { id: string };
    logger.info("screenshot-handler", `[screenshot:save] saving`, { id });
    const savedPath = await saveCapture(id);
    await cleanupCapture(id);
    hidePreview();
    return { savedPath };
  });

  // screenshot:copy { id: string } → { ok: true }
  ipcMain.handle("screenshot:copy", async (_event, params: unknown) => {
    if (
      typeof params !== "object" ||
      params === null ||
      typeof (params as Record<string, unknown>).id !== "string"
    ) {
      throw new Error("screenshot:copy requires { id: string }");
    }
    const { id } = params as { id: string };
    await copyCapture(id);
    await cleanupCapture(id);
    hidePreview();
    return { ok: true as const };
  });

  // screenshot:edit { id: string } → { ok: true }
  ipcMain.handle("screenshot:edit", async (_event, params: unknown) => {
    if (
      typeof params !== "object" ||
      params === null ||
      typeof (params as Record<string, unknown>).id !== "string"
    ) {
      throw new Error("screenshot:edit requires { id: string }");
    }
    const { id } = params as { id: string };
    logger.info("screenshot-handler", `[screenshot:save] editing (save then open)`, { id });
    await editCapture(id);
    await cleanupCapture(id);
    hidePreview();
    return { ok: true as const };
  });

  // screenshot:dismiss { id: string } → { ok: true }
  // Auto-saves to saveFolder then closes the preview
  ipcMain.handle("screenshot:dismiss", async (_event, params: unknown) => {
    if (
      typeof params !== "object" ||
      params === null ||
      typeof (params as Record<string, unknown>).id !== "string"
    ) {
      throw new Error("screenshot:dismiss requires { id: string }");
    }
    const { id } = params as { id: string };
    // Tolerate a stale dismiss: if the capture was already handled (save/copy/edit)
    // the pending entry is gone — just hide the preview, don't double-save.
    if (!getPendingCapture(id)) {
      logger.info("screenshot-handler", `[screenshot:dismiss] no pending capture, ignoring`, { id });
      hidePreview();
      return { ok: true as const };
    }
    logger.info("screenshot-handler", `[screenshot:dismiss] auto-saving`, { id });
    await saveCapture(id);
    await cleanupCapture(id);
    hidePreview();
    return { ok: true as const };
  });
}
