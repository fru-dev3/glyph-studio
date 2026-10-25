// Loading ahead of the click. The code-split panels (App.tsx builds them with
// lazyPanel over these loaders) start downloading on a sidebar row's hover or focus, and once the
// app is idle after start. A few pages' first reads are warmed on hover too;
// each uses the same key the page itself reads, so the page finds the answer
// already in the shared cache (or joins the call still in flight).
import { createElement, lazy, useState, type ComponentType } from "react";
import { invokeCached } from "./query";

// Modules already fetched, by loader. React.lazy suspends on its first render
// even when the chunk is already here, and React holds a revealed fallback
// for up to 300 ms, so a prefetched panel still showed a blank beat. A panel
// whose module is in hand renders directly instead (lazyPanel below).
const mods = new Map<() => Promise<unknown>, unknown>();
function tracked<T>(load: () => Promise<T>): () => Promise<T> {
  const f = () => load().then((m) => { mods.set(f, m); return m; });
  return f;
}

export const loadChatPanel = tracked(() => import("./chatpanel"));
export const loadCouncilPanel = tracked(() => import("./councilpanel"));
export const loadSettingsPanel = tracked(() => import("./settingspanel"));
export const loadWorkPanel = tracked(() => import("./workpanel"));
export const loadBenchmarkPanel = tracked(() => import("./arenahandoff"));

/**
 * A code-split panel: lazy until its chunk is here, then rendered directly.
 * Each mounted instance keeps the one it started with, so it never remounts.
 */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function lazyPanel<M, C extends ComponentType<any>>(load: () => Promise<M>, pick: (m: M) => C): C {
  const Lazy = lazy(() => load().then((m) => ({ default: pick(m) })));
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  function Panel(props: any) {
    const [direct] = useState(() => { const m = mods.get(load) as M | undefined; return m ? pick(m) : null; });
    return createElement(direct ?? Lazy, props);
  }
  return Panel as unknown as C;
}

const started = new Set<string>();
function once(name: string, load: () => Promise<unknown>) {
  if (started.has(name)) return;
  started.add(name);
  load().catch(() => started.delete(name)); // a failed fetch may be retried
}

export function prefetchSettings() { once("settings", loadSettingsPanel); }
export function prefetchWork() { once("work", loadWorkPanel); }

// Pages whose first read runs through the cache on mount.
const WARM: Record<string, (vault: string) => void> = {
  toolkit: (vault) => { void invokeCached("scan_skills", { vault }).catch(() => {}); },
  projects: (vault) => { void invokeCached("projects_index", { vault }).catch(() => {}); },
  apps: (vault) => { void invokeCached("apps_mirror_list", { vault }).catch(() => {}); },
  intent: (vault) => { void invokeCached("engine_score_all", { vault }).catch(() => {}); },
  insights: (vault) => { void invokeCached("engine_score_all", { vault }).catch(() => {}); },
};

/** Hover or focus on a sidebar row: fetch its chunk, and warm its first read. */
export function prefetchSection(area: "work" | "settings", id: string, vault: string | null) {
  if (area === "work") prefetchWork(); else prefetchSettings();
  if (vault) WARM[id]?.(vault);
}

/** After start, once the window is idle: every panel chunk, one at a time. */
export function prefetchPanelsWhenIdle() {
  const idle = (cb: () => void) => {
    const w = window as unknown as { requestIdleCallback?: (cb: () => void, o?: { timeout: number }) => number };
    if (w.requestIdleCallback) w.requestIdleCallback(cb, { timeout: 3000 }); else window.setTimeout(cb, 1500);
  };
  idle(() => {
    once("work", loadWorkPanel);
    idle(() => {
      once("settings", loadSettingsPanel);
      idle(() => { once("chat", loadChatPanel); once("council", loadCouncilPanel); });
    });
  });
}
