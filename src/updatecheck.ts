// "Is there a newer Prevail?" answered without the signed updater feed, which
// is not published while the signing key is mismatched. GitHub Releases is
// the source of truth for what shipped, so ask it once per launch and once an
// hour after, and let the shell show a badge. Never in Bunker Mode: that is a
// network call, and Bunker promises there are none.
import { useEffect, useState } from "react";
import { APP_VERSION } from "./constants";
import { isBunkerOn } from "./storage";

export const RELEASES_URL = "https://github.com/fru-dev3/glyph-studio/releases/latest";
const API = "https://api.github.com/repos/fru-dev3/glyph-studio/releases/latest";

/// True when `a` is a strictly newer x.y.z than `b`. Tolerates a leading "v".
export function isNewer(a: string, b: string): boolean {
  const n = (v: string) => v.replace(/^v/, "").split(".").map((x) => parseInt(x, 10) || 0);
  const [x, y] = [n(a), n(b)];
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    const d = (x[i] ?? 0) - (y[i] ?? 0);
    if (d !== 0) return d > 0;
  }
  return false;
}

export function useUpdateAvailable(): string | null {
  const [latest, setLatest] = useState<string | null>(null);
  useEffect(() => {
    let alive = true;
    const check = async () => {
      if (isBunkerOn()) return;
      try {
        const r = await fetch(API, { headers: { accept: "application/vnd.github+json" } });
        if (!r.ok) return;
        const j = (await r.json()) as { tag_name?: string; draft?: boolean; prerelease?: boolean };
        const tag = (j.tag_name ?? "").replace(/^v/, "");
        if (alive && tag && !j.draft && !j.prerelease && isNewer(tag, APP_VERSION)) setLatest(tag);
      } catch { /* offline: no badge, no noise */ }
    };
    void check();
    const id = window.setInterval(() => void check(), 60 * 60 * 1000);
    return () => { alive = false; window.clearInterval(id); };
  }, []);
  return latest;
}
