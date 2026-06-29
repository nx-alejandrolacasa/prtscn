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

// Transparent margin around the card so its CSS drop shadow has room to render
// (must match the `padding` in preview-view.tsx).
const SHADOW_MARGIN = 22;
const CARD_WIDTH = 248;
const TOOLBAR_HEIGHT = 48;

function computeImageHeight(width: number, height: number): number {
  const rawHeight = Math.round(CARD_WIDTH * (height / width));
  return Math.max(104, Math.min(168, rawHeight));
}

function computeWindowSize(imageHeight: number): { w: number; h: number } {
  const cardH = imageHeight + TOOLBAR_HEIGHT;
  return {
    w: CARD_WIDTH + SHADOW_MARGIN * 2,
    h: cardH + SHADOW_MARGIN * 2,
  };
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
    width: CARD_WIDTH + SHADOW_MARGIN * 2,
    height: 210, // initial placeholder; resized before show
    frame: false,
    transparent: true,
    backgroundColor: "#00000000",
    hasShadow: false, // the card draws its own CSS shadow inside the margin
    alwaysOnTop: true,
    skipTaskbar: true,
    focusable: true,
    // Become key on show so CSS :hover and keyboard shortcuts work immediately
    // (macOS only delivers mouse-moved/hover events to the key window), and
    // register the very first click instead of just activating the window.
    acceptFirstMouse: true,
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

  // Show AND focus: the preview must be the key window so hover highlights and
  // keyboard shortcuts (Enter/⌘C/⌘S) work without an extra click. Focus returns
  // to the previous app once the preview is dismissed.
  win.show();
  win.focus();
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
