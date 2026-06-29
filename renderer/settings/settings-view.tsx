import React, { useState, useEffect, useCallback, useRef } from "react";
import { X } from "lucide-react";
import {
  Label,
  RadioGroup,
  RadioGroupItem,
  ScrollArea,
  Toolbar,
  ToolbarContent,
  Field,
  FieldContent,
  FieldGroup,
  FieldLabel,
  FieldSet,
  Button,
  Switch,
  Select,
  SelectTrigger,
  SelectValue,
  SelectContent,
  SelectItem,
  Text,
  TabsRoot,
  Tabs,
  TabsTrigger,
  TabsSeparator,
  TabsContent,
  toast,
} from "@glaze/core/components";
import { cn } from "@glaze/core/utils";
import type { NativeThemeInfo } from "@glaze/core/ipc";

// ─── Types ────────────────────────────────────────────────────────────────────

type CaptureMode = "region" | "window" | "fullScreen";

interface AppShortcuts {
  region: string;
  window: string;
  fullScreen: string;
}

interface AppSettings {
  shortcuts: AppShortcuts;
  saveFolder: string;
  launchAtLogin: boolean;
  previewTimeout: number;
}

// ─── Constants ────────────────────────────────────────────────────────────────

const DEFAULT_SHORTCUTS: AppShortcuts = {
  region: "Command+Alt+1",
  window: "Command+Alt+2",
  fullScreen: "Command+Alt+3",
};

// ─── Keyboard helpers ─────────────────────────────────────────────────────────

const MODIFIER_GLYPH: Record<string, string> = {
  Command: "⌘",
  Cmd: "⌘",
  CommandOrControl: "⌘",
  CmdOrCtrl: "⌘",
  Control: "⌃",
  Ctrl: "⌃",
  Alt: "⌥",
  Option: "⌥",
  Shift: "⇧",
};

const SPECIAL_KEY_NAMES: Record<string, string> = {
  " ": "Space",
  ArrowLeft: "←",
  ArrowRight: "→",
  ArrowUp: "↑",
  ArrowDown: "↓",
  Backspace: "⌫",
  Delete: "⌦",
  Escape: "Esc",
  Tab: "⇥",
  Enter: "↩",
  Home: "↖",
  End: "↘",
  PageUp: "⇞",
  PageDown: "⇟",
  F1: "F1",
  F2: "F2",
  F3: "F3",
  F4: "F4",
  F5: "F5",
  F6: "F6",
  F7: "F7",
  F8: "F8",
  F9: "F9",
  F10: "F10",
  F11: "F11",
  F12: "F12",
};

function buildAccelerator(event: KeyboardEvent): string | null {
  const modifiers: string[] = [];
  if (event.metaKey) modifiers.push("Command");
  if (event.ctrlKey) modifiers.push("Control");
  if (event.altKey) modifiers.push("Alt");
  if (event.shiftKey) modifiers.push("Shift");

  const key = event.key;
  const isModifier = [
    "Meta",
    "Control",
    "Alt",
    "Shift",
    "OS",
    "Super",
    "Hyper",
  ].includes(key);
  if (isModifier || modifiers.length === 0) return null;

  const normalKey =
    SPECIAL_KEY_NAMES[key] ??
    (key.length === 1 ? key.toUpperCase() : key);

  return [...modifiers, normalKey].join("+");
}

function acceleratorToGlyph(accelerator: string): string {
  if (!accelerator) return "";
  return accelerator
    .split("+")
    .map((part) => MODIFIER_GLYPH[part] ?? part)
    .join("");
}

// ─── Timeout options ──────────────────────────────────────────────────────────

const TIMEOUT_OPTIONS: { label: string; value: string }[] = [
  { label: "3 seconds", value: "3" },
  { label: "5 seconds", value: "5" },
  { label: "8 seconds", value: "8" },
  { label: "15 seconds", value: "15" },
  { label: "Never", value: "0" },
];

// ─── Shortcut Recorder ───────────────────────────────────────────────────────

interface ShortcutRecorderProps {
  value: string;
  onChange: (value: string) => void;
  disabled?: boolean;
}

function ShortcutRecorder({ value, onChange, disabled }: ShortcutRecorderProps) {
  const [recording, setRecording] = useState(false);
  const containerRef = useRef<HTMLDivElement>(null);

  const handleKeyDown = useCallback(
    (e: React.KeyboardEvent<HTMLDivElement>) => {
      if (!recording) return;
      e.preventDefault();
      e.stopPropagation();
      const accelerator = buildAccelerator(e.nativeEvent);
      if (accelerator) {
        onChange(accelerator);
        setRecording(false);
      }
    },
    [recording, onChange],
  );

  const handleBlur = useCallback((e: React.FocusEvent<HTMLDivElement>) => {
    if (!containerRef.current?.contains(e.relatedTarget as Node)) {
      setRecording(false);
    }
  }, []);

  const handleContainerClick = useCallback(() => {
    if (disabled) return;
    setRecording((r) => !r);
  }, [disabled]);

  const handleClear = useCallback(
    (e: React.MouseEvent) => {
      e.stopPropagation();
      onChange("");
      setRecording(false);
    },
    [onChange],
  );

  const displayText = recording
    ? "Press shortcut…"
    : value
      ? acceleratorToGlyph(value)
      : "None";

  return (
    <div
      ref={containerRef}
      tabIndex={disabled ? -1 : 0}
      role="button"
      onClick={handleContainerClick}
      onKeyDown={handleKeyDown}
      onBlur={handleBlur}
      aria-label={
        recording
          ? "Recording shortcut — press a key combo"
          : `Current shortcut: ${value || "None"}`
      }
      className={cn(
        "inline-flex items-center min-w-[96px] h-7 px-2 rounded-control",
        "border border-field bg-control text-primary text-small tabular-nums",
        "transition-colors select-none outline-none",
        recording
          ? "border-accent bg-control-active ring-2 ring-accent/30 text-accent"
          : "hover:bg-control-active focus-visible:ring-2 focus-visible:ring-accent/30",
        disabled ? "opacity-50 cursor-not-allowed" : "cursor-pointer",
      )}
    >
      <span className="flex-1 text-center">{displayText}</span>
      {value && !recording && !disabled && (
        <button
          type="button"
          tabIndex={-1}
          onClick={handleClear}
          aria-label="Clear shortcut"
          className="ml-1 shrink-0 inline-flex items-center justify-center size-3.5 rounded-full bg-control hover:bg-control-active text-secondary"
        >
          <X size={8} strokeWidth={2.5} />
        </button>
      )}
    </div>
  );
}

// ─── App Icon ──────────────────────────────────────────────────────────────────

function PrtScnIcon() {
  const COLS = [-11, 6, 23, 40, 57];
  const ROWS = [-11, 5, 21, 37, 53];
  const KW = 14;
  const KH = 13;
  const D = 2.2;

  const HX = 21;
  const HY = 18;
  const HW = 18;
  const HH = 18;
  const HD = 3.4;

  return (
    <svg
      aria-hidden="true"
      width="52"
      height="49"
      viewBox="0 0 60 56"
      style={{ flexShrink: 0, display: "block" }}
    >
      <defs>
        <linearGradient id="kc-frame" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#ecdfbf" />
          <stop offset="1" stopColor="#d4bf8e" />
        </linearGradient>
        <linearGradient id="kc-cap" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#ffffff" />
          <stop offset="1" stopColor="#e6e6ec" />
        </linearGradient>
        <filter id="kc-grain" x="0" y="0" width="100%" height="100%">
          <feTurbulence
            type="fractalNoise"
            baseFrequency="0.9"
            numOctaves="2"
            stitchTiles="stitch"
            result="n"
          />
          <feColorMatrix
            in="n"
            type="matrix"
            values="0 0 0 0 0.42  0 0 0 0 0.32  0 0 0 0 0.17  0 0 0 0.07 0"
          />
        </filter>
        <clipPath id="kc-clip">
          <rect x="0" y="0" width="60" height="56" rx="13" />
        </clipPath>
      </defs>

      <g clipPath="url(#kc-clip)">
        <rect x="0" y="0" width="60" height="56" fill="url(#kc-frame)" />
        <rect x="0" y="0" width="60" height="56" filter="url(#kc-grain)" />
        <rect
          x="0.6"
          y="0.6"
          width="58.8"
          height="54.8"
          rx="12.4"
          fill="none"
          stroke="rgba(90,64,24,0.22)"
          strokeWidth="1"
        />

        {ROWS.map((y) =>
          COLS.map((x) => {
            if (x === 23 && y === 21) return null;
            return (
              <g key={`${x}-${y}`}>
                <rect x={x} y={y + D} width={KW} height={KH} rx="3" fill="#c5c6cb" />
                <rect
                  x={x}
                  y={y}
                  width={KW}
                  height={KH}
                  rx="3"
                  fill="url(#kc-cap)"
                  stroke="rgba(255,255,255,0.55)"
                  strokeWidth="0.5"
                />
              </g>
            );
          }),
        )}

        <rect x={HX} y={HY + HD} width={HW} height={HH} rx="3.5" fill="var(--accent)" />
        <rect x={HX} y={HY + HD} width={HW} height={HH} rx="3.5" fill="rgba(0,0,0,0.30)" />
        <rect
          x={HX}
          y={HY}
          width={HW}
          height={HH}
          rx="3.5"
          fill="var(--accent)"
          stroke="rgba(255,255,255,0.35)"
          strokeWidth="0.6"
        />
        <rect
          x={HX + 0.8}
          y={HY + 0.8}
          width={HW - 1.6}
          height={(HH - 1.6) / 2}
          rx="2.6"
          fill="rgba(255,255,255,0.20)"
        />
        <text
          x={HX + HW / 2}
          y={HY + HH / 2 + 1.9}
          textAnchor="middle"
          fontSize="5"
          fontWeight="700"
          letterSpacing="-0.02em"
          fill="#ffffff"
          style={{ userSelect: "none" }}
        >
          PrtScn
        </text>
      </g>
    </svg>
  );
}

// ─── Main Settings View ───────────────────────────────────────────────────────

export function SettingsView() {
  const [themeInfo, setThemeInfo] = useState<NativeThemeInfo | null>(null);
  const [settings, setSettings] = useState<AppSettings | null>(null);
  const [shortcutFailures, setShortcutFailures] = useState<CaptureMode[]>([]);

  const [shortcuts, setShortcuts] = useState<AppShortcuts>({
    region: "",
    window: "",
    fullScreen: "",
  });

  // Close settings window on Escape, unless an interactive element is focused
  useEffect(() => {
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key !== "Escape") return;
      if (event.defaultPrevented) return;

      const el = document.activeElement;
      if (
        el instanceof HTMLInputElement ||
        el instanceof HTMLTextAreaElement ||
        el instanceof HTMLSelectElement ||
        (el instanceof HTMLElement && el.isContentEditable)
      ) {
        return;
      }

      if (document.querySelector("[data-radix-popper-content-wrapper]")) {
        return;
      }

      event.preventDefault();
      window.glazeAPI.glaze.ipc.invoke("window:closeSettings");
    };

    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, []);

  useEffect(() => {
    const load = async () => {
      try {
        const [appSettings, themeData] = await Promise.all([
          window.glazeAPI.glaze.ipc.invoke<AppSettings>("settings:get"),
          window.glazeAPI.nativeTheme.getInfo(),
        ]);
        setSettings(appSettings);
        setShortcuts(appSettings.shortcuts);
        setThemeInfo(themeData);
      } catch (error) {
        toast.error(`Failed to load settings: ${error}`);
      }
    };
    load();
  }, []);

  const refreshThemeInfo = async () => {
    try {
      const info = await window.glazeAPI.nativeTheme.getInfo();
      setThemeInfo(info);
    } catch (error) {
      toast.error(`Failed to get theme info: ${error}`);
    }
  };

  const handleThemeChange = async (value: string) => {
    const source = value as "system" | "light" | "dark";
    try {
      await window.glazeAPI.nativeTheme.setThemeSource(source);
      await refreshThemeInfo();
    } catch (error) {
      toast.error(`Failed to set theme: ${error}`);
    }
  };

  // ── Shortcuts (autosave on change) ───────────────────────────────────────

  const handleShortcutChange = useCallback(
    async (mode: CaptureMode, value: string) => {
      const newShortcuts = { ...shortcuts, [mode]: value };
      setShortcuts(newShortcuts);
      setShortcutFailures((prev) => prev.filter((m) => m !== mode));
      try {
        const result = await window.glazeAPI.glaze.ipc.invoke<{
          settings: AppSettings;
          failures: CaptureMode[];
        }>("settings:setShortcuts", { shortcuts: newShortcuts });
        setSettings(result.settings);
        setShortcuts(result.settings.shortcuts);
        if (result.failures.length > 0) {
          setShortcutFailures(result.failures);
          toast.error("Shortcut already in use");
        }
      } catch (error) {
        toast.error(`Failed to save shortcut: ${error}`);
        setShortcuts((prev) => ({ ...prev }));
      }
    },
    [shortcuts],
  );

  const handleRestoreDefaults = async () => {
    setShortcuts(DEFAULT_SHORTCUTS);
    setShortcutFailures([]);
    try {
      const result = await window.glazeAPI.glaze.ipc.invoke<{
        settings: AppSettings;
        failures: CaptureMode[];
      }>("settings:setShortcuts", { shortcuts: DEFAULT_SHORTCUTS });
      setSettings(result.settings);
      setShortcuts(result.settings.shortcuts);
      if (result.failures.length === 0) {
        toast.success("Shortcuts restored to defaults");
      } else {
        setShortcutFailures(result.failures);
        toast.error("Some default shortcuts could not be registered");
      }
    } catch (error) {
      toast.error(`Failed to restore defaults: ${error}`);
      if (settings) setShortcuts(settings.shortcuts);
    }
  };

  // ── Save folder ──────────────────────────────────────────────────────────

  const handlePickFolder = async () => {
    try {
      const result = await window.glazeAPI.glaze.ipc.invoke<{
        settings: AppSettings;
        canceled: boolean;
      }>("settings:pickSaveFolder");
      if (!result.canceled) {
        setSettings(result.settings);
        toast.success("Save location updated");
      }
    } catch (error) {
      toast.error(`Failed to pick folder: ${error}`);
    }
  };

  // ── Preview timeout ──────────────────────────────────────────────────────

  const handleTimeoutChange = async (value: string) => {
    const seconds = parseInt(value, 10);
    try {
      const updated =
        await window.glazeAPI.glaze.ipc.invoke<AppSettings>(
          "settings:setPreviewTimeout",
          { seconds },
        );
      setSettings(updated);
    } catch (error) {
      toast.error(`Failed to update preview duration: ${error}`);
    }
  };

  // ── Launch at login ──────────────────────────────────────────────────────

  const handleLaunchAtLoginChange = async (enabled: boolean) => {
    try {
      const updated =
        await window.glazeAPI.glaze.ipc.invoke<AppSettings>(
          "settings:setLaunchAtLogin",
          { enabled },
        );
      setSettings(updated);
    } catch (error) {
      toast.error(`Failed to update launch at login: ${error}`);
    }
  };

  // ─────────────────────────────────────────────────────────────────────────

  const isLoaded = settings !== null;

  return (
    <TabsRoot defaultValue="general">
      <ScrollArea
        toolbar={
          <Toolbar>
            <ToolbarContent>
              <div className="w-full flex justify-center">
                <Tabs variant="filled" size="medium">
                  <TabsTrigger value="general">General</TabsTrigger>
                  <TabsSeparator />
                  <TabsTrigger value="capture">Capture</TabsTrigger>
                  <TabsSeparator />
                  <TabsTrigger value="hotkeys">Hotkeys</TabsTrigger>
                </Tabs>
              </div>
            </ToolbarContent>
          </Toolbar>
        }
      >
        <div className="px-4 flex flex-col pt-2 pb-8">
          {/* ── Header: keycap logo + app name ─────────────────────────────── */}
          <div className="flex items-center gap-3 pt-2 pb-5">
            <PrtScnIcon />
            <div className="flex flex-col min-w-0">
              <Text variant="large-strong" color="primary">
                PrtScn
              </Text>
              <Text variant="small" color="secondary">
                Screenshot Utility
              </Text>
            </div>
          </div>

          {/* ── General tab ───────────────────────────────────────────────── */}
          <TabsContent value="general" className="flex flex-col gap-6">
            <FieldSet title="General">
              <FieldGroup>
                <Field
                  label="Launch at login"
                  description="Start PrtScn automatically when you log in"
                  orientation="horizontal"
                >
                  <Switch
                    checked={settings?.launchAtLogin ?? false}
                    onCheckedChange={handleLaunchAtLoginChange}
                    disabled={!isLoaded}
                  />
                </Field>
              </FieldGroup>
            </FieldSet>

            <FieldSet title="Appearance">
              <FieldGroup>
                <Field orientation="horizontal">
                  <FieldContent>
                    <FieldLabel htmlFor="theme">Theme</FieldLabel>
                  </FieldContent>
                  <RadioGroup
                    value={themeInfo?.themeSource ?? "system"}
                    onValueChange={handleThemeChange}
                    orientation="horizontal"
                  >
                    <Label>
                      <RadioGroupItem value="system" />
                      Auto
                    </Label>
                    <Label>
                      <RadioGroupItem value="light" />
                      Light
                    </Label>
                    <Label>
                      <RadioGroupItem value="dark" />
                      Dark
                    </Label>
                  </RadioGroup>
                </Field>
              </FieldGroup>
            </FieldSet>
          </TabsContent>

          {/* ── Capture tab ───────────────────────────────────────────────── */}
          <TabsContent value="capture" className="flex flex-col gap-6">
            <FieldSet title="Preview">
              <FieldGroup>
                <Field
                  label="Preview duration"
                  description="How long the preview overlay stays visible"
                  orientation="horizontal"
                >
                  <Select
                    value={String(settings?.previewTimeout ?? "5")}
                    onValueChange={handleTimeoutChange}
                    disabled={!isLoaded}
                  >
                    <SelectTrigger size="small">
                      <SelectValue placeholder="Select…" />
                    </SelectTrigger>
                    <SelectContent>
                      {TIMEOUT_OPTIONS.map((opt) => (
                        <SelectItem key={opt.value} value={opt.value}>
                          {opt.label}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </Field>
              </FieldGroup>
            </FieldSet>

            <FieldSet title="Save Location">
              <FieldGroup>
                <Field
                  label="Folder"
                  description={
                    settings?.saveFolder ? (
                      <Text variant="small" color="secondary" className="truncate max-w-[220px]">
                        {settings.saveFolder}
                      </Text>
                    ) : (
                      "Where screenshots are saved"
                    )
                  }
                  orientation="horizontal"
                >
                  <Button
                    variant="filled"
                    size="small"
                    onClick={handlePickFolder}
                    disabled={!isLoaded}
                  >
                    Choose…
                  </Button>
                </Field>
              </FieldGroup>
            </FieldSet>
          </TabsContent>

          {/* ── Hotkeys tab ───────────────────────────────────────────────── */}
          <TabsContent value="hotkeys" className="flex flex-col gap-6">
            <FieldSet title="Keyboard Shortcuts">
              <FieldGroup>
                <Field
                  label="Region"
                  description="Capture a selected screen region"
                  orientation="horizontal"
                  error={shortcutFailures.includes("region") ? "Shortcut already in use" : undefined}
                >
                  <ShortcutRecorder
                    value={shortcuts.region}
                    onChange={(v) => handleShortcutChange("region", v)}
                    disabled={!isLoaded}
                  />
                </Field>

                <Field
                  label="Window"
                  description="Capture a specific window"
                  orientation="horizontal"
                  error={shortcutFailures.includes("window") ? "Shortcut already in use" : undefined}
                >
                  <ShortcutRecorder
                    value={shortcuts.window}
                    onChange={(v) => handleShortcutChange("window", v)}
                    disabled={!isLoaded}
                  />
                </Field>

                <Field
                  label="Full Screen"
                  description="Capture the entire screen"
                  orientation="horizontal"
                  error={shortcutFailures.includes("fullScreen") ? "Shortcut already in use" : undefined}
                >
                  <ShortcutRecorder
                    value={shortcuts.fullScreen}
                    onChange={(v) => handleShortcutChange("fullScreen", v)}
                    disabled={!isLoaded}
                  />
                </Field>

                <Field orientation="horizontal">
                  <Button
                    variant="filled"
                    size="small"
                    onClick={handleRestoreDefaults}
                    disabled={!isLoaded}
                  >
                    Restore Defaults
                  </Button>
                </Field>
              </FieldGroup>
            </FieldSet>
          </TabsContent>
        </div>
      </ScrollArea>
    </TabsRoot>
  );
}
