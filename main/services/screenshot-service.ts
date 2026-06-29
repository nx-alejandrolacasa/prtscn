/**
 * Screenshot Service
 *
 * Runs screencapture via child_process and manages pending capture state.
 */

import { execFile } from "child_process";
import fs from "fs/promises";
import { existsSync } from "fs";
import path from "path";
import { promisify } from "util";

import { app, clipboard, nativeImage, screen, logger } from "@glaze/core/backend";

import { settingsStore, type CaptureMode } from "./settings-store.js";

const execFileAsync = promisify(execFile);

export interface PreviewPayload {
  id: string;
  thumbnailDataUrl: string;
  width: number;
  height: number;
  timeoutSeconds: number;
}

interface PendingCapture {
  tmpPath: string;
}

const pendingCaptures = new Map<string, PendingCapture>();

function generateId(): string {
  return `${Date.now()}-${Math.random().toString(36).slice(2, 9)}`;
}

/**
 * Run screencapture and return a PreviewPayload, or null if the user cancelled.
 */
export async function captureScreenshot(mode: CaptureMode): Promise<PreviewPayload | null> {
  const id = generateId();
  const tmpPath = path.join(app.getPath("temp"), `prtscn-${id}.png`);

  let args: string[];
  if (mode === "region") {
    args = ["-i", tmpPath];
  } else if (mode === "window") {
    // No "-o": keep the window's drop shadow + transparent padding around it.
    args = ["-i", "-W", tmpPath];
  } else {
    // fullScreen
    args = [tmpPath];
  }

  logger.info("screenshot-service", `[screenshot:capture] starting`, { mode, id });

  try {
    await execFileAsync("/usr/sbin/screencapture", args, {
      maxBuffer: 10 * 1024 * 1024,
      timeout: 60_000,
    });
  } catch (err: unknown) {
    // screencapture exits non-zero when the user cancels a region/window pick
    logger.info("screenshot-service", "screencapture exited with error (likely user cancel)", {
      id,
      mode,
      error: err instanceof Error ? err.message : String(err),
    });
    return null;
  }

  // Check if the file was actually created (user may cancel without error on some macOS versions)
  if (!existsSync(tmpPath)) {
    logger.info("screenshot-service", "screencapture produced no output file (user cancel)", {
      id,
      mode,
    });
    return null;
  }

  // Build nativeImage, read dimensions and thumbnail
  const img = nativeImage.createFromPath(tmpPath);
  const { width, height } = img.getSize();
  const thumbnailDataUrl = (await img.resize({ width: 280 })).toDataURL();

  // Get cursor position for preview window positioning
  const cursor = screen.getCursorScreenPoint();

  // Store pending capture
  pendingCaptures.set(id, { tmpPath });

  const settings = settingsStore.get();
  const payload: PreviewPayload = {
    id,
    thumbnailDataUrl,
    width,
    height,
    timeoutSeconds: settings.previewTimeout,
  };

  logger.info("screenshot-service", `[screenshot:capture] capture ready`, {
    id,
    width,
    height,
    cursor,
  });

  return payload;
}

export function getPendingCapture(id: string): PendingCapture | undefined {
  return pendingCaptures.get(id);
}

export function hasPendingCaptures(): boolean {
  return pendingCaptures.size > 0;
}

/** Copy the image from tmpPath to clipboard */
export async function copyCapture(id: string): Promise<void> {
  const capture = pendingCaptures.get(id);
  if (!capture) {
    throw new Error(`[screenshot:copy] No pending capture with id=${id}`);
  }
  const img = nativeImage.createFromPath(capture.tmpPath);
  clipboard.writeImage(img);
  logger.info("screenshot-service", `[screenshot:copy] copied to clipboard`, { id });
}

/** Build the destination path for saving a capture */
function buildSavePath(saveFolder: string): string {
  const now = new Date();
  const dateStr = now.toLocaleDateString("en-CA"); // YYYY-MM-DD
  const timeStr = now.toTimeString().slice(0, 8).replace(/:/g, "."); // HH.MM.SS
  const filename = `PrtScn ${dateStr} at ${timeStr}.png`;
  return path.join(saveFolder, filename);
}

/** Copy tmp file to saveFolder, return the saved path */
export async function saveCapture(id: string): Promise<string> {
  const capture = pendingCaptures.get(id);
  if (!capture) {
    throw new Error(`[screenshot:save] No pending capture with id=${id}`);
  }
  const settings = settingsStore.get();
  const destPath = buildSavePath(settings.saveFolder);
  await fs.copyFile(capture.tmpPath, destPath);
  logger.info("screenshot-service", `[screenshot:save] saved`, { id, destPath });
  return destPath;
}

/** Save to saveFolder, then open that file in Preview.app */
export async function editCapture(id: string): Promise<string> {
  const savedPath = await saveCapture(id);
  await execFileAsync("/usr/bin/open", ["-a", "Preview", savedPath], {
    maxBuffer: 1 * 1024 * 1024,
    timeout: 15_000,
  });
  logger.info("screenshot-service", `[screenshot:edit] opened in Preview`, {
    id,
    savedPath,
  });
  return savedPath;
}

/** Delete the temp file and remove the pending entry */
export async function cleanupCapture(id: string): Promise<void> {
  const capture = pendingCaptures.get(id);
  pendingCaptures.delete(id);
  if (capture) {
    try {
      await fs.unlink(capture.tmpPath);
    } catch {
      // Ignore — file may have already been cleaned up
    }
  }
}
