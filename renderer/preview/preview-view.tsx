import { useState, useEffect, useRef, useCallback } from "react";
import { PencilIcon, CopyIcon, SaveIcon } from "lucide-react";
import {
  Button,
  Tooltip,
  TooltipContent,
  TooltipTrigger,
  toast,
} from "@glaze/core/components";

interface PreviewPayload {
  id: string;
  thumbnailDataUrl: string;
  width: number;
  height: number;
  timeoutSeconds: number;
}

export function PreviewView() {
  const [payload, setPayload] = useState<PreviewPayload | null>(null);
  const [isPaused, setIsPaused] = useState(false);
  const [progress, setProgress] = useState(1); // 1 = full, 0 = elapsed
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const intervalRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const startTimeRef = useRef<number>(0);
  const durationRef = useRef<number>(0);
  const remainingRef = useRef<number>(0);
  // Ref tracks the current payload id so the dismiss callback is never stale
  const payloadIdRef = useRef<string | null>(null);

  const clearTimers = useCallback(() => {
    if (timerRef.current) {
      clearTimeout(timerRef.current);
      timerRef.current = null;
    }
    if (intervalRef.current) {
      clearInterval(intervalRef.current);
      intervalRef.current = null;
    }
  }, []);

  const startCountdown = useCallback(
    (seconds: number, remaining?: number) => {
      clearTimers();
      if (seconds <= 0) return;

      const totalMs = seconds * 1000;
      const remainingMs = remaining ?? totalMs;
      durationRef.current = totalMs;
      remainingRef.current = remainingMs;
      startTimeRef.current = Date.now();

      setProgress(remainingMs / totalMs);

      // Tick every 50ms for smooth bar animation
      intervalRef.current = setInterval(() => {
        const elapsed = Date.now() - startTimeRef.current;
        const left = remainingMs - elapsed;
        setProgress(Math.max(0, left / totalMs));
      }, 50);

      timerRef.current = setTimeout(() => {
        clearTimers();
        const currentId = payloadIdRef.current;
        console.log("[Preview:dismiss] Auto-dismiss timer elapsed", { id: currentId });
        window.glazeAPI.glaze.ipc
          .invoke("screenshot:dismiss", { id: currentId })
          .catch((err: unknown) => {
            console.error("[Preview:dismiss] Failed", err);
          });
      }, remainingMs);
    },
    [clearTimers],
  );

  const pauseTimer = useCallback(() => {
    if (!timerRef.current && !intervalRef.current) return;
    const elapsed = Date.now() - startTimeRef.current;
    remainingRef.current = Math.max(0, remainingRef.current - elapsed);
    clearTimers();
    console.log("[Preview:timer] Paused, remaining:", remainingRef.current, "ms");
  }, [clearTimers]);

  const resumeTimer = useCallback(() => {
    if (durationRef.current <= 0) return;
    console.log("[Preview:timer] Resumed, remaining:", remainingRef.current, "ms");
    startCountdown(durationRef.current / 1000, remainingRef.current);
  }, [startCountdown]);

  // On mount, fetch initial payload
  useEffect(() => {
    console.log("[Preview:mount] Requesting initial payload");
    window.glazeAPI.glaze.ipc
      .invoke<PreviewPayload | null>("preview:ready")
      .then((p) => {
        if (!p) {
          console.log("[Preview:mount] No pending payload");
          return;
        }
        console.log("[Preview:mount] Received payload", { id: p.id, timeoutSeconds: p.timeoutSeconds });
        payloadIdRef.current = p.id;
        setPayload(p);
        durationRef.current = p.timeoutSeconds * 1000;
        remainingRef.current = p.timeoutSeconds * 1000;
        if (p.timeoutSeconds > 0) {
          startCountdown(p.timeoutSeconds);
        } else {
          setProgress(1);
        }
      })
      .catch((err: unknown) => {
        console.error("[Preview:mount] Failed to get initial payload", err);
      });
  }, []);

  // Subscribe to new screenshot notifications
  useEffect(() => {
    const unsubscribe = window.glazeAPI.glaze.ipc.onNotification(
      "screenshot:new",
      (params: unknown) => {
        const newPayload = params as PreviewPayload;
        console.log("[Preview:screenshot:new] New capture received", {
          id: newPayload.id,
          timeoutSeconds: newPayload.timeoutSeconds,
        });
        clearTimers();
        payloadIdRef.current = newPayload.id;
        setPayload(newPayload);
        setIsPaused(false);
        durationRef.current = newPayload.timeoutSeconds * 1000;
        remainingRef.current = newPayload.timeoutSeconds * 1000;
        if (newPayload.timeoutSeconds > 0) {
          startCountdown(newPayload.timeoutSeconds);
        } else {
          setProgress(1);
        }
      },
    );
    return () => {
      unsubscribe();
    };
  }, [clearTimers, startCountdown]);

  // Cleanup on unmount
  useEffect(() => {
    return () => {
      clearTimers();
    };
  }, [clearTimers]);

  const handleMouseEnter = () => {
    if (durationRef.current <= 0) return;
    setIsPaused(true);
    pauseTimer();
  };

  const handleMouseLeave = () => {
    if (durationRef.current <= 0) return;
    setIsPaused(false);
    resumeTimer();
  };

  const handleSave = async () => {
    if (!payload) return;
    clearTimers();
    console.log("[Preview:action] Save", { id: payload.id });
    try {
      await window.glazeAPI.glaze.ipc.invoke("screenshot:save", { id: payload.id });
      toast.success("Screenshot saved");
    } catch (err) {
      console.error("[Preview:action] Save failed", err);
      toast.error("Failed to save screenshot");
    }
  };

  const handleCopy = async () => {
    if (!payload) return;
    clearTimers();
    console.log("[Preview:action] Copy", { id: payload.id });
    try {
      await window.glazeAPI.glaze.ipc.invoke("screenshot:copy", { id: payload.id });
      toast.success("Copied to clipboard");
    } catch (err) {
      console.error("[Preview:action] Copy failed", err);
      toast.error("Failed to copy screenshot");
    }
  };

  const handleEdit = async () => {
    if (!payload) return;
    clearTimers();
    console.log("[Preview:action] Edit", { id: payload.id });
    try {
      await window.glazeAPI.glaze.ipc.invoke("screenshot:edit", { id: payload.id });
    } catch (err) {
      console.error("[Preview:action] Edit failed", err);
      toast.error("Failed to open editor");
    }
  };

  const showCountdownBar = durationRef.current > 0;

  return (
    <div
      className="w-screen h-screen overflow-hidden"
      style={{ background: "transparent" }}
    >
      {/* Native popover-style card filling the entire viewport */}
      <div
        className="w-full h-full flex flex-col rounded-xl overflow-hidden border border-separator bg-surface-primary"
        style={{
          boxShadow:
            "0 10px 30px rgba(0,0,0,0.18), 0 1px 3px rgba(0,0,0,0.10)",
        }}
        onMouseEnter={handleMouseEnter}
        onMouseLeave={handleMouseLeave}
      >
        {/* Countdown bar — thin strip along the top edge */}
        {showCountdownBar && (
          <div
            className="relative h-[3px] shrink-0 overflow-hidden"
            style={{ background: "var(--color-border-separator)" }}
          >
            <div
              className="absolute inset-y-0 left-0 transition-none"
              style={{
                width: `${progress * 100}%`,
                background: "var(--color-text-accent)",
                opacity: isPaused ? 0.4 : 1,
                transition: isPaused ? "opacity 0.2s" : "none",
              }}
            />
          </div>
        )}

        {/* Thumbnail area — flex-1, neutral control backing */}
        <div className="flex-1 flex items-center justify-center overflow-hidden min-h-0 bg-control">
          {payload ? (
            <img
              src={payload.thumbnailDataUrl}
              alt="Screenshot preview"
              className="max-w-full max-h-full object-contain"
              draggable={false}
            />
          ) : (
            /* Skeleton placeholder — exact dimensions to prevent layout shift */
            <div
              className="w-full h-full bg-control animate-pulse"
              aria-label="Loading screenshot…"
            />
          )}
        </div>

        {/* Bottom toolbar — fixed ~52px height */}
        <div
          className="shrink-0 flex items-center justify-around px-4 border-t border-separator bg-surface-secondary"
          style={{ height: 52 }}
        >
          <Tooltip>
            <TooltipTrigger asChild>
              <Button
                variant="transparent"
                size="medium"
                iconOnly
                onClick={handleEdit}
                disabled={!payload}
                aria-label="Edit in Preview"
              >
                <PencilIcon className="size-4 text-secondary" />
              </Button>
            </TooltipTrigger>
            <TooltipContent side="top">Edit in Preview</TooltipContent>
          </Tooltip>

          <Tooltip>
            <TooltipTrigger asChild>
              <Button
                variant="transparent"
                size="medium"
                iconOnly
                onClick={handleCopy}
                disabled={!payload}
                aria-label="Copy to clipboard"
              >
                <CopyIcon className="size-4 text-secondary" />
              </Button>
            </TooltipTrigger>
            <TooltipContent side="top">Copy to Clipboard</TooltipContent>
          </Tooltip>

          <Tooltip>
            <TooltipTrigger asChild>
              <Button
                variant="accent"
                size="medium"
                iconOnly
                onClick={handleSave}
                disabled={!payload}
                aria-label="Save screenshot"
              >
                <SaveIcon className="size-4" />
              </Button>
            </TooltipTrigger>
            <TooltipContent side="top">Save Screenshot</TooltipContent>
          </Tooltip>
        </div>
      </div>
    </div>
  );
}
