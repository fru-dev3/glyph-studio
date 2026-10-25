// Mirror > Projects > Restart. What a newer model needs to redo a project
// properly, from `prevail projects restart`: the goal, the requirements (said
// by you or inferred), the rules you already had to give, decisions, dead ends
// and open questions. Untick anything that should not carry over, then copy
// the handoff prompt. "Check a rebuild" compares a folder against it.
import { useEffect, useMemo, useState } from "react";
import { Check, ClipboardCopy, FolderSearch, HelpCircle, Loader2, RotateCcw, X } from "lucide-react";
import { invoke, isBrowser } from "./bridge";
import { modelName } from "./projectsview";

export interface RestartDoc {
  slug: string; title: string; goal: string;
  requirements: { text: string; source: "you" | "inferred" }[];
  rules: string[]; decisions: string[]; dead_ends: string[]; open_questions: string[];
  brief_model?: string;
}
export interface DiffDoc { met: string[]; missed: string[]; unclear: string[] }

function CopyBtn({ label, get, primary, big }: { label: string; get: () => Promise<string>; primary?: boolean; big?: boolean }) {
  const [state, setState] = useState<"idle" | "busy" | "done" | "err">("idle");
  return (
    <button
      onClick={async () => {
        setState("busy");
        try { await navigator.clipboard.writeText(await get()); setState("done"); setTimeout(() => setState("idle"), 1800); }
        catch { setState("err"); setTimeout(() => setState("idle"), 2500); }
      }}
      className={primary
        ? `inline-flex items-center justify-center gap-2 rounded-lg bg-accent font-medium text-on-accent transition-colors hover:bg-accent-hover ${big ? "h-11 w-full px-5 text-[14px]" : "h-8 px-3 text-[13px]"}`
        : "inline-flex items-center gap-1.5 text-[13px] text-text-muted transition-colors hover:text-text-primary"}
    >
      {state === "busy" ? <Loader2 className="h-4 w-4 animate-spin" /> : state === "done" ? <Check className="h-4 w-4" /> : <ClipboardCopy className="h-4 w-4" />}
      {state === "done" ? "Copied" : state === "err" ? "Could not copy" : label}
    </button>
  );
}

type Row = { text: string; tag?: "you" | "inferred" };

function Section({ title, rows, excluded, toggle, readOnly }: { title: string; rows: Row[]; excluded: Set<string>; toggle: (t: string) => void; readOnly: boolean }) {
  if (!rows.length) return null;
  return (
    <section className="mt-5">
      {title && <h4 className="mb-1 text-[14px] font-semibold text-text-primary">{title}</h4>}
      <ul className="divide-y divide-border-subtle">
        {rows.map((r) => {
          const off = excluded.has(r.text);
          return (
            <li key={r.text}>
              <label className={`flex items-start gap-3 py-2 ${readOnly ? "" : "cursor-pointer"}`}>
                {!readOnly && (
                  <input type="checkbox" checked={!off} onChange={() => toggle(r.text)} aria-label={`Include: ${r.text}`}
                    className="mt-1 h-4 w-4 shrink-0 accent-[var(--color-accent)]" />
                )}
                <span className={`min-w-0 flex-1 text-[14px] leading-snug ${off ? "text-text-muted line-through" : "text-text-primary"}`}>{r.text}</span>
                {r.tag && <span className={`shrink-0 pt-px text-[12px] ${r.tag === "you" ? "text-accent" : "text-text-muted"}`}>{r.tag === "you" ? "you" : "inferred"}</span>}
              </label>
            </li>
          );
        })}
      </ul>
    </section>
  );
}

function RebuildCheck({ vaultPath, slug }: { vaultPath: string; slug: string }) {
  const [folder, setFolder] = useState("");
  const [busy, setBusy] = useState(false);
  const [diff, setDiff] = useState<DiffDoc | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const pick = async () => {
    try {
      const { open } = await import("@tauri-apps/plugin-dialog");
      const p = await open({ directory: true, multiple: false });
      if (typeof p === "string") setFolder(p);
    } catch { /* no native picker: type the path */ }
  };
  const run = async () => {
    setBusy(true); setErr(null);
    try { setDiff(await invoke<DiffDoc>("projects_diff", { vault: vaultPath, slug, against: folder.trim() })); }
    catch (e) { setErr(String(e)); setDiff(null); }
    finally { setBusy(false); }
  };
  const cols: { key: keyof DiffDoc; label: string; icon: typeof Check; tone: string }[] = [
    { key: "met", label: "Met", icon: Check, tone: "text-accent" },
    { key: "missed", label: "Missed", icon: X, tone: "text-err" },
    { key: "unclear", label: "Unclear", icon: HelpCircle, tone: "text-text-muted" },
  ];
  return (
    <section className="mt-6 border-t border-border-subtle pt-4" data-testid="rebuild-check">
      <h3 className="text-[15px] font-semibold text-text-primary flex items-center gap-2"><FolderSearch className="h-4 w-4 text-text-muted" />Check a rebuild</h3>
      <p className="mt-1 text-[12px] text-text-muted">Point at the folder a model built from this brief. Glyph Studio reads it and says which requirements it met. The folder is only read.</p>
      <div className="mt-3 flex flex-wrap gap-2">
        <input value={folder} onChange={(e) => setFolder(e.target.value)} placeholder="/path/to/rebuild" aria-label="Rebuild folder"
          className="h-9 min-w-0 flex-1 basis-60 rounded-lg border border-border bg-background px-3 text-[14px] text-text-primary focus:border-accent-border focus:outline-none" />
        {!isBrowser() && <button onClick={() => void pick()} className="inline-flex h-9 items-center px-1 text-[13px] text-text-muted hover:text-text-primary">Choose folder</button>}
        <button onClick={() => void run()} disabled={busy || !folder.trim()} className="inline-flex h-9 items-center gap-2 rounded-lg bg-accent px-3 text-[13px] font-medium text-on-accent hover:bg-accent-hover disabled:opacity-60">
          {busy && <Loader2 className="h-4 w-4 animate-spin" />}{busy ? "Checking" : "Check"}
        </button>
      </div>
      {err && <div className="mt-2 text-[13px] text-err">{err}</div>}
      {diff && (
        <div className="mt-4 grid gap-3">
          {cols.map(({ key, label, icon: Icon, tone }) => (
            <div key={key} data-testid={`diff-${key}`}>
              <div className={`mb-1 flex items-center gap-1.5 text-[14px] font-semibold ${tone}`}><Icon className="h-4 w-4" />{label} <span className="tabular-nums">{(diff[key] ?? []).length}</span></div>
              <ul className="space-y-1.5 text-[14px] leading-snug text-text-secondary">
                {(diff[key] ?? []).map((t, i) => <li key={i}>{t}</li>)}
              </ul>
            </div>
          ))}
        </div>
      )}
    </section>
  );
}

// One project's restart document, shared by the detail's tabs: the Overview
// carries the copy buttons, Requirements the tick list, Technical details the
// rest. What is unticked anywhere is left out of every copy.
export function useRestart(vaultPath: string, slug: string) {
  const [doc, setDoc] = useState<RestartDoc | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [excluded, setExcluded] = useState<Set<string>>(new Set());
  useEffect(() => {
    let alive = true;
    setDoc(null); setErr(null); setExcluded(new Set());
    invoke<RestartDoc>("projects_restart", { vault: vaultPath, slug })
      .then((d) => { if (alive) setDoc(d); })
      .catch((e) => { if (alive) setErr(String(e)); });
    return () => { alive = false; };
  }, [vaultPath, slug]);
  const toggle = (t: string) => setExcluded((s) => { const n = new Set(s); if (n.has(t)) n.delete(t); else n.add(t); return n; });
  const exclude = useMemo(() => [...excluded], [excluded]);
  const text = (format: "handoff" | "intent" | "raw") => () =>
    invoke<string>("projects_restart_text", { vault: vaultPath, slug, format, exclude: exclude.length ? exclude : null });
  return { vaultPath, slug, doc, err, excluded, toggle, text };
}
export type Restart = ReturnType<typeof useRestart>;

const loading = <div className="mt-4 flex items-center gap-2 text-[12px] text-text-muted"><Loader2 className="h-3.5 w-3.5 animate-spin" />Reading the project</div>;

export function RestartCard({ r, phone }: { r: Restart; phone: boolean }) {
  const { doc, err } = r;
  return (
    <section className="mt-6" data-testid="restart">
      <h3 className="text-[15px] font-semibold text-text-primary flex items-center gap-2"><RotateCcw className="h-4 w-4 text-accent" />Restart</h3>
      <p className="mt-1 text-[14px] leading-snug text-text-secondary">
        Everything a newer model needs to do this properly, without the back-and-forth.{!phone && " Untick what should not carry over under Requirements and Technical details."}
        {doc?.brief_model ? ` Distilled by ${modelName(doc.brief_model)}.` : ""}
      </p>
      <div className="mt-3 flex flex-wrap items-center gap-x-5 gap-y-2">
        <CopyBtn primary big={phone} label="Copy restart brief" get={r.text("handoff")} />
        {!phone && <CopyBtn label="Copy intent" get={r.text("intent")} />}
        {!phone && <CopyBtn label="Copy raw prompts" get={r.text("raw")} />}
      </div>
      {err && <div className="mt-3 text-[13px] text-err">{err}</div>}
      {!doc && !err && loading}
      {doc?.goal && <Section title="Goal" rows={[{ text: doc.goal }]} excluded={r.excluded} toggle={r.toggle} readOnly={phone} />}
    </section>
  );
}

type Who = "all" | "you" | "inferred";
export function RequirementsPane({ r, phone }: { r: Restart; phone: boolean }) {
  const [who, setWho] = useState<Who>("all");
  if (!r.doc) return r.err ? <div className="mt-4 text-[13px] text-err">{r.err}</div> : loading;
  const all = r.doc.requirements ?? [];
  const n = (w: Who) => (w === "all" ? all.length : all.filter((x) => x.source === w).length);
  const rows = all.filter((x) => who === "all" || x.source === who).map((x) => ({ text: x.text, tag: x.source }));
  const opts: { id: Who; label: string }[] = [{ id: "all", label: "All" }, { id: "you", label: "From you" }, { id: "inferred", label: "Inferred" }];
  return (
    <div data-testid="project-requirements" className="pt-5">
      <div role="radiogroup" aria-label="Who said it" className="inline-flex rounded-lg bg-surface-warm p-0.5">
        {opts.map((o) => (
          <button key={o.id} role="radio" aria-checked={who === o.id} onClick={() => setWho(o.id)} data-testid={`req-filter-${o.id}`}
            className={`inline-flex h-8 items-center gap-1.5 rounded-md px-3 text-[13px] ${who === o.id ? "bg-background font-semibold text-text-primary shadow-sm" : "text-text-muted hover:text-text-secondary"}`}>
            {o.label}<span className="text-[12px] font-normal tabular-nums text-text-muted">{n(o.id)}</span>
          </button>
        ))}
      </div>
      {rows.length === 0
        ? <p className="mt-5 text-[12px] text-text-muted">{all.length ? "None of this kind." : "No requirements found yet."}</p>
        : <Section title="" rows={rows} excluded={r.excluded} toggle={r.toggle} readOnly={phone} />}
    </div>
  );
}

// Rules, decisions, dead ends, open questions and the rebuild check: folded
// away until asked for.
export function TechnicalDetails({ r, phone }: { r: Restart; phone: boolean }) {
  const d = r.doc;
  if (!d) return null;
  const sections: { title: string; rows: Row[] }[] = [
    { title: "Rules you already had to give", rows: (d.rules ?? []).map((text) => ({ text })) },
    { title: "Decisions", rows: (d.decisions ?? []).map((text) => ({ text })) },
    { title: "Dead ends", rows: (d.dead_ends ?? []).map((text) => ({ text })) },
    { title: "Open questions", rows: (d.open_questions ?? []).map((text) => ({ text })) },
  ];
  return (
    <details data-testid="project-technical" className="group mt-6">
      <summary className="cursor-pointer select-none text-[13px] text-text-muted hover:text-text-primary">Technical details</summary>
      {sections.map((s) => <Section key={s.title} title={s.title} rows={s.rows} excluded={r.excluded} toggle={r.toggle} readOnly={phone} />)}
      {!phone && <RebuildCheck vaultPath={r.vaultPath} slug={r.slug} />}
    </details>
  );
}
