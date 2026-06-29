/**
 * Preview Window
 *
 * Frameless transparent always-on-top overlay that shows a screenshot preview
 * card near the cursor without stealing focus from the user's current app.
 */

import { BrowserWindow, screen, ipcMain, logger } from "@glaze/core/backend";
import { getPreloadPath, getWindowUrl } from "./window-paths.js";
import type { PreviewPayload } from "../services/screenshot-service.js";

// Single reused window instance
let previewWindow: BrowserWindow | null = null;

// Current payload waiting for preview:ready
let currentPayload: PreviewPayload | null = null;

const CARD_WIDTH = 288;
const TOOLBAR_HEIGHT = 56;
const CARD_PADDING = 24;

function computeImageHeight(width: number, height: number): number {
  const rawHeight = Math.round(280 * (height / width));
  return Math.max(130, Math.min(200, rawHeight));
}

function computeWindowSize(imageHeight: number): { w: number; h: number } {
  const winW = CARD_WIDTH;
  const winH = imageHeight + TOOLBAR_HEIGHT + CARD_PADDING;
  return { w: winW, h: winH };
}

function computePosition(
  cursorX: number,
  cursorY: number,
  winW: number,
  winH: number,
): { x: number; y: number } {
  const display = screen.getDisplayNearestPoint({ x: cursorX, y: cursorY });
  const { x: waX, y: waY, width: waW, height: waH } = display.workArea;

  // Default: place card ABOVE cursor, centered horizontally
  let x = cursorX - Math.round(winW / 2);
  let y = cursorY - winH - 12;

  // If it clips above the workArea top, place below instead
  if (y < waY) {
    y = cursorY + 12;
  }

  // Clamp horizontally inside workArea
  x = Math.max(waX, Math.min(x, waX + waW - winW));

  // Clamp vertically inside workArea
  y = Math.max(waY, Math.min(y, waY + waH - winH));

  logger.info("preview-window", `[preview:position]`, { cursorX, cursorY, x, y, winW, winH });
  return { x, y };
}

async function ensurePreviewWindow(): Promise<BrowserWindow> {
  if (previewWindow && !previewWindow.isDestroyed()) {
    return previewWindow;
  }

  logger.info("preview-window", "Creating preview window");

  previewWindow = new BrowserWindow({
    windowKey: "preview",
    width: CARD_WIDTH,
    height: 210, // initial placeholder; resized before show
    frame: false,
    transparent: true,
    backgroundColor: "#00000000",
    hasShadow: true,
    alwaysOnTop: true,
    skipTaskbar: true,
    focusable: true,
    visibleOnAllWorkspaces: true,
    hiddenInMissionControl: true,
    show: false,
    webPreferences: {
      preload: getPreloadPath(),
    },
  });

  previewWindow.setAlwaysOnTop(true, "floating");
  previewWindow.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });

  previewWindow.on("closed", () => {
    previewWindow = null;
    currentPayload = null;
  });

  const url = await getWindowUrl("preview-window.html");
  logger.info("preview-window", "Loading preview URL", { url });
  await previewWindow.loadURL(url);

  return previewWindow;
}

/**
 * Show (or update) the preview window with a new capture payload.
 * Called from the capture flow after screencapture completes.
 */
export async function showPreview(
  payload: PreviewPayload,
  cursorX: number,
  cursorY: number,
): Promise<void> {
  currentPayload = payload;

  const win = await ensurePreviewWindow();

  const imageHeight = computeImageHeight(payload.width, payload.height);
  const { w: winW, h: winH } = computeWindowSize(imageHeight);
  const { x, y } = computePosition(cursorX, cursorY, winW, winH);

  // Resize then reposition
  win.setSize(winW, winH);
  win.setPosition(x, y);

  // Send payload to renderer (broadcast pairs with renderer onNotification)
  ipcMain.broadcast("screenshot:new", payload);

  // Show without stealing focus
  win.showInactive();
}

/** Hide (close) the preview window */
export function hidePreview(): void {
  if (previewWindow && !previewWindow.isDestroyed()) {
    previewWindow.hide();
  }
  currentPayload = null;
}

/** Get the current payload — used for preview:ready response */
export function getCurrentPayload(): PreviewPayload | null {
  return currentPayload;
}

export function getPreviewWindow(): BrowserWindow | null {
  return previewWindow && !previewWindow.isDestroyed() ? previewWindow : null;
}
