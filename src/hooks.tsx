// Shared React hooks extracted from App.tsx: theme/palette appearance,
// framework+lens selection (Chat & Council), and the honest "thinking" status
// word with its dot/word indicators.
import { useEffect, useRef, useState } from "react";
import { invoke } from "./bridge";
import { FRAMEWORKS, LENSES, PALETTES } from "./constants";
import { LS, lsGet, lsSet } from "./storage";
import type { CliInfo, Mode, Palette } from "./types";

// Detected runtimes, shared across components without prop-drilling. detect_clis
// runs ONCE process-wide (shared in-flight promise + cache), and re-runs when a
// "prevail:rescan-clis" event fires (the Runtimes "Re-check" button). Lets the
// loop executor picker and Settings provider dropdown list only installed CLIs.
let _clisCache: CliInfo[] | null = null;
let _clisInflight: Promise<CliInfo[]> | null = null;
function loadClisOnce(): Promise<CliInfo[]> {
  if (_clisCache) return Promise.resolve(_clisCache);
  if (!_clisInflight) {
    _clisInflight = invoke<CliInfo[]>("detect_clis")
      .then((l) => { _clisCache = Array.isArray(l) ? l : []; return _clisCache; })
      .catch(() => { _clisInflight = null; return [] as CliInfo[]; });
  }
  return _clisInflight;
}
export function useDetectedClis(): CliInfo[] {
  const [clis, setClis] = useState<CliInfo[]>(_clisCache ?? []);
  useEffect(() => {
    let alive = true;
    loadClisOnce().then((l) => { if (alive) setClis(l); });
    const onRescan = () => {
      _clisCache = null;
      _clisInflight = null;
      loadClisOnce().then((l) => { if (alive) setClis(l); });
    };
    window.addEventListener("prevail:rescan-clis", onRescan);
    return () => { alive = false; window.removeEventListener("prevail:rescan-clis", onRescan); };
  }, []);
  return clis;
}

export function useAppearance() {
  const [mode, setMode] = useState<Mode>(() => {
    const saved = lsGet(LS.theme);
    if (saved === "light" || saved === "dark" || saved === "system") return saved;
    // D1: brand-new users open in dark mode, where the graphite-first Prevail
    // palette looks like the 2026 identity. Existing users keep their saved mode.
    return "dark";
  });
  const [palette, setPalette] = useState<Palette>(() => {
    const saved = lsGet(LS.palette) as Palette;
    // D1: brand-new users open in the signature "prevail" palette (office green + cyan
    // on graphite), so the app looks like the brand out of the box. Existing
    // users keep whatever they saved. Supersedes the earlier "mono" default.
    return PALETTES.some((p) => p.id === saved) ? saved : "prevail";
  });
  // Track system preference for "system" mode
  const [systemDark, setSystemDark] = useState<boolean>(() =>
    typeof window !== "undefined" && window.matchMedia
      ? window.matchMedia("(prefers-color-scheme: dark)").matches
      : false,
  );
  useEffect(() => {
    if (!window.matchMedia) return;
    const mq = window.matchMedia("(prefers-color-scheme: dark)");
    const handler = (e: MediaQueryListEvent) => setSystemDark(e.matches);
    mq.addEventListener("change", handler);
    return () => mq.removeEventListener("change", handler);
  }, []);
  // Profile switch: the entered profile's saved theme/palette were just written
  // to localStorage by hydrateProfilePrefs (or cleared, for a fresh profile).
  // Re-read them so the look follows the profile; the apply-effect below then
  // mirrors the active profile's choice to the machine-level store.
  useEffect(() => {
    const reload = () => {
      const savedMode = lsGet(LS.theme);
      setMode(savedMode === "light" || savedMode === "dark" || savedMode === "system" ? savedMode : "dark");
      const savedPal = lsGet(LS.palette) as Palette;
      setPalette(PALETTES.some((p) => p.id === savedPal) ? savedPal : "prevail");
    };
    window.addEventListener("prevail:appearance-reload", reload);
    return () => window.removeEventListener("prevail:appearance-reload", reload);
  }, []);
  // Cross-device hydrate: theme + palette are persisted on the desktop (see
  // ui_settings_get), so the WebUI - and a re-installed desktop - inherit the
  // same look instead of starting from an empty browser localStorage. Runs once
  // and overrides the local defaults if the backend has a saved value.
  const hydratedRef = useRef(false);
  useEffect(() => {
    (async () => {
      try {
        const raw = await invoke<string>("ui_settings_get");
        const s = JSON.parse(raw || "{}") as { theme?: string; palette?: string };
        if (s.theme === "light" || s.theme === "dark" || s.theme === "system") setMode(s.theme);
        if (s.palette && PALETTES.some((p) => p.id === s.palette)) setPalette(s.palette as Palette);
      } catch { /* offline / first run: keep localStorage values */ }
      hydratedRef.current = true;
    })();
  }, []);
  // Apply to <html>, cache locally, and write-through to the cross-device store.
  useEffect(() => {
    const effectiveDark = mode === "dark" || (mode === "system" && systemDark);
    document.documentElement.setAttribute("data-theme", effectiveDark ? "dark" : "light");
    document.documentElement.setAttribute("data-palette", palette);
    lsSet(LS.theme, mode);
    lsSet(LS.palette, palette);
    // Only persist after the initial hydrate so we never clobber saved settings
    // with the boot defaults before they've loaded.
    if (hydratedRef.current) {
      void invoke("ui_settings_set", { json: JSON.stringify({ theme: mode, palette }) }).catch(() => {});
    }
  }, [mode, palette, systemDark]);
  return { mode, setMode, palette, setPalette };
}

// Active framework + lens (shared between Chat and Council).
export function useFrameworkLens() {
  const [framework, setFramework] = useState<string>(() => lsGet(LS.framework, "none"));
  const [lens, setLens] = useState<string>(() => lsGet(LS.lens, "none"));
  useEffect(() => { lsSet(LS.framework, framework); }, [framework]);
  useEffect(() => { lsSet(LS.lens, lens); }, [lens]);

  function buildPrompt(raw: string): string {
    const fw = FRAMEWORKS.find((f) => f.id === framework);
    const ln = LENSES.find((l) => l.id === lens);
    const parts: string[] = [];
    if (fw?.instruction) parts.push(`[FRAMEWORK]\n${fw.instruction}`);
    if (ln?.instruction) parts.push(`[LENS]\n${ln.instruction}`);
    parts.push(raw);
    return parts.join("\n\n");
  }

  return { framework, setFramework, lens, setLens, buildPrompt };
}

// The status word shown while a CLI spins up and hasn't streamed its first token.
// I9: replaced a random whimsical verb (rotated every 2.4s, implied false meaning)
// with an HONEST progression keyed to elapsed wait time.
export function useThinkingWord() {
  const [secs, setSecs] = useState(0);
  useEffect(() => {
    const id = window.setInterval(() => setSecs((s) => s + 1), 1000);
    return () => window.clearInterval(id);
  }, []);
  if (secs < 4) return "Thinking";
  if (secs < 12) return "Still thinking";
  if (secs < 30) return "Working on it";
  return "Taking a while";
}

export function ThinkingWord() {
  return <>{useThinkingWord()}</>;
}

// A playful, ever-changing vocabulary for "the model is working" states (council
// and chat thinking). "Glyphing" always belongs; the rest mix real and
// invented words so it never feels mechanical.
export const PLAYFUL_WORDS = [
  "Glyphing", "Conjuring", "Convopulating", "Maximizing", "Jambalaya-ing",
  "Pondering", "Synthesizing", "Marinating", "Percolating", "Noodling",
  "Ruminating", "Cogitating", "Brewing", "Distilling", "Spelunking",
  "Confabulating", "Effervescing", "Concocting", "Crystallizing", "Untangling",
  "Foraging", "Scheming", "Mulling", "Tinkering", "Whisking", "Riffing",
  "Galavanting", "Wizarding", "Simmering", "Orbiting", "Kindling", "Frolicking",
];

export function randomPlayfulWord(): string {
  return PLAYFUL_WORDS[Math.floor(Math.random() * PLAYFUL_WORDS.length)];
}

// Rotates a random playful word every ~2.4s. Used by the agent thinking
// indicator so "working" reads with personality.
export function usePlayfulWord(): string {
  const [word, setWord] = useState(() => randomPlayfulWord());
  useEffect(() => {
    const id = window.setInterval(() => setWord(randomPlayfulWord()), 2400);
    return () => window.clearInterval(id);
  }, []);
  return word;
}

export function ThinkingDots() {
  const word = usePlayfulWord();
  return (
    <span className="inline-flex items-center gap-1 font-mono">
      <span className="thinking-dot inline-block h-1.5 w-1.5 rounded-full bg-accent" style={{ animationDelay: "0ms" }} />
      <span className="thinking-dot inline-block h-1.5 w-1.5 rounded-full bg-accent" style={{ animationDelay: "150ms" }} />
      <span className="thinking-dot inline-block h-1.5 w-1.5 rounded-full bg-accent" style={{ animationDelay: "300ms" }} />
      <span className="shimmer-text ml-1.5 text-xs">{word}…</span>
    </span>
  );
}
