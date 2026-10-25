// Bring an existing Obsidian vault into Prevail: pick the folder, choose the
// destination domain, import. Notes become AI-readable source in that domain.
// Shared by the Map header and the Apps panel so both entry points open the
// exact same, verified import flow (engine command: obsidian import).
import { useCallback, useMemo, useState } from "react";
import { FolderOpen, RefreshCw } from "lucide-react";
import { siObsidian } from "simple-icons";
import { open as openDialog } from "@tauri-apps/plugin-dialog";
import { invoke } from "./bridge";

// The real Obsidian brand mark (simple-icons, #7C3AED). Shared by every entry
// point and the modal header so the feature reads as Obsidian at a glance.
export function ObsidianLogo({ className = "h-4 w-4" }: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" className={className} fill="#7C3AED" aria-hidden="true">
      <path d={(siObsidian as { path: string }).path} />
    </svg>
  );
}

// The remembered Obsidian vault location. Set in Vault settings (or the first
// import) and reused everywhere so the user picks the folder once. UI-side
// convenience for one-way import; the real read happens at import time.
export const OBSIDIAN_PATH_KEY = "prevail.obsidian.path";
export function getObsidianPath(): string {
  try { return localStorage.getItem(OBSIDIAN_PATH_KEY) || ""; } catch { return ""; }
}
export function setObsidianPath(p: string) {
  try { p ? localStorage.setItem(OBSIDIAN_PATH_KEY, p) : localStorage.removeItem(OBSIDIAN_PATH_KEY); } catch { /* ignore */ }
}

export function ObsidianImportModal({ vaultPath, domains, onClose, onDone }: {
  vaultPath: string;
  domains: { slug: string; label: string }[];
  onClose: () => void;
  onDone: () => void;
}) {
  const [from, setFrom] = useState<string>(() => getObsidianPath());
  const [domain, setDomain] = useState<string>("notes");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [result, setResult] = useState<{ imported: number } | null>(null);

  const pick = useCallback(async () => {
    try {
      const picked = await openDialog({ directory: true, multiple: false, title: "Choose your Obsidian vault folder" });
      if (typeof picked === "string") { setFrom(picked); setObsidianPath(picked); }
    } catch (e) { setErr(e instanceof Error ? e.message : String(e)); }
  }, []);

  const run = useCallback(async () => {
    if (!from) return;
    setBusy(true); setErr(null);
    try {
      const r = await invoke<{ ok: boolean; imported?: number; error?: string }>("engine_obsidian_import", {
        vault: vaultPath, from, domain: domain.trim() || "notes",
      });
      if (r && r.ok) setResult({ imported: r.imported ?? 0 });
      else setErr(r?.error || "import failed");
    } catch (e) { setErr(e instanceof Error ? e.message : String(e)); } finally { setBusy(false); }
  }, [from, domain, vaultPath]);

  // Offer existing domains + a default "notes"; the import creates the domain if new.
  const domainOptions = useMemo(() => {
    const set = new Map<string, string>();
    set.set("notes", "notes");
    for (const d of domains) set.set(d.slug, d.label || d.slug);
    return [...set.entries()];
  }, [domains]);

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4" onClick={onClose}>
      <div className="w-full max-w-md rounded-lg border border-border bg-surface p-5 shadow-xl" onClick={(e) => e.stopPropagation()}>
        <div className="mb-3 flex items-center gap-2">
          <ObsidianLogo className="h-5 w-5" />
          <h2 className="text-base font-semibold text-text-primary">Import an Obsidian vault</h2>
        </div>

        {result ? (
          <div className="space-y-3">
            <p className="text-sm text-text-secondary">
              Imported <span className="font-semibold text-text-primary">{result.imported}</span> note{result.imported === 1 ? "" : "s"} into the <span className="font-mono">{domain}</span> domain. They are now AI-readable source, and Obsidian shows as a connected app. Re-run any time to sync changes.
            </p>
            <div className="flex justify-end">
              <button onClick={onDone} className="rounded-md bg-accent px-3 py-1.5 text-sm text-background hover:opacity-90">Done</button>
            </div>
          </div>
        ) : (
          <div className="space-y-3">
            <p className="text-[13px] leading-relaxed text-text-muted">
              Point Glyph Studio at your existing Obsidian vault folder. Its notes are copied in as markdown (wikilinks and embeds converted, tags and frontmatter kept) so your AI can read and ground on them.
            </p>
            <div>
              <label className="mb-1 block text-[11px] text-text-muted">Obsidian vault folder</label>
              <button onClick={() => void pick()} className="flex w-full items-center gap-2 rounded-md border border-border bg-background px-3 py-2 text-left text-sm text-text-secondary hover:border-accent-border">
                <FolderOpen className="h-4 w-4 shrink-0 text-text-muted" />
                <span className="truncate">{from || "Choose folder..."}</span>
              </button>
            </div>
            <div>
              <label className="mb-1 block text-[11px] text-text-muted">Import into domain</label>
              <select value={domain} onChange={(e) => setDomain(e.target.value)} className="w-full rounded-md border border-border bg-background px-3 py-2 text-sm text-text-primary">
                {domainOptions.map(([slug, label]) => <option key={slug} value={slug}>{label}</option>)}
              </select>
            </div>
            {err && <div className="rounded-md border border-err/40 bg-err/10 px-3 py-1.5 text-[12px] text-err">{err}</div>}
            <div className="flex justify-end gap-2">
              <button onClick={onClose} className="rounded-md border border-border px-3 py-1.5 text-sm text-text-secondary hover:text-accent">Cancel</button>
              <button disabled={!from || busy} onClick={() => void run()} className="flex items-center gap-1.5 rounded-md bg-accent px-3 py-1.5 text-sm text-background hover:opacity-90 disabled:opacity-50">
                {busy ? <><RefreshCw className="h-3.5 w-3.5 animate-spin" /> Importing...</> : "Import"}
              </button>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
