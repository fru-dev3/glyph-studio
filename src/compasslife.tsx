// Goals G5, desktop side: the Compass over a lifetime.
//   YearlyReviews     every yearly review (the hub writes one a year), each
//                     opened to edit in place or talked through in chat
//   exportCompass     the confirmed Compass as a constitution file
// The engine owns every rule; this file shows and asks.
import { useState } from "react";
import { Check, Loader2, Plus } from "lucide-react";
import { invoke } from "./bridge";
import { useInvokeQuery } from "./query";
import { DETAIL_TITLE, META } from "./typescale";
import { Group, LineRow, Meta } from "./compasslines";
import { chatAbout } from "./chatabout";

interface YearRow { year: number; file: string; updated: number; text: string }

function YearEditor({ vaultPath, r, onSaved }: { vaultPath: string; r: YearRow; onSaved: () => void }) {
  const [text, setText] = useState(r.text);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const save = async () => {
    setBusy(true); setMsg(null);
    try {
      const x = await invoke<{ ok?: boolean; error?: string }>("engine_compass_yearly_save", { vault: vaultPath, year: r.year, text });
      if (x && x.ok === false) throw new Error(x.error);
      setMsg("Saved. The text before is kept."); onSaved();
    } catch (e) { setMsg(`Not saved: ${String(e).replace(/^Error:\s*/, "")}`); } finally { setBusy(false); }
  };
  return (
    <div data-testid="yearly-editor">
      <textarea value={text} onChange={(e) => setText(e.target.value)} aria-label={`The ${r.year} review`} rows={18}
        className="w-full resize-y rounded-md border border-border bg-background p-3 text-[14px] leading-relaxed text-text-primary focus:border-accent-border focus:outline-none" />
      <div className="mt-1.5 flex items-center gap-3">
        <button type="button" onClick={() => void save()} disabled={busy || text === r.text} data-testid="yearly-save"
          className="inline-flex h-8 items-center gap-1.5 rounded-md px-2 text-[13px] font-medium text-accent hover:bg-accent-soft disabled:opacity-40">
          {busy ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <Check className="h-3.5 w-3.5" />} Save
        </button>
        {msg && <span className={META} data-testid="yearly-msg">{msg}</span>}
      </div>
    </div>
  );
}

/**
 * The yearly review: once a year the hub writes a page across the same parts
 * of life, so years compare. Past reviews are listed; each opens to edit, and
 * Chat talks it through.
 */
export function YearlyReviews({ vaultPath }: { vaultPath: string }) {
  const q = useInvokeQuery<YearRow[]>("engine_compass_yearly_list", { vault: vaultPath }, { staleMs: 60_000 });
  const rows = Array.isArray(q.data) ? q.data : [];
  const [busy, setBusy] = useState(false);
  const writeNow = async () => {
    setBusy(true);
    try { await invoke("engine_compass_yearly", { vault: vaultPath, draft: false, write: true }); await q.refresh(); } finally { setBusy(false); }
  };
  const thisYear = new Date().getFullYear();
  return (
    <section data-testid="compass-detail-yearly">
      <h2 className={DETAIL_TITLE}>Yearly review</h2>
      <p className={`${META} mt-1 mb-4`}>Once a year Glyph Studio writes a review of your health, relationships, work, money, growth and joy, beside your values and purpose; answer in it, edit it, or talk it through.</p>
      <Group title="Reviews" count={rows.length}>
        <ul data-testid="yearly-list">
          {rows.map((r) => (
            <LineRow key={r.year} id={`year-${r.year}`} title={`${r.year}`} display={<>Review of {r.year}</>} testId="yearly-row"
              meta={<Meta bits={[r.updated ? `Updated ${new Date(r.updated).toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" })}` : null, r.year === thisYear ? "This year" : null]} />}
              onChat={() => chatAbout(`Let's go through my ${r.year} yearly review together: my health, relationships, work, money, growth and joy, and whether my values and purpose still hold. Ask me one question at a time.`)}>
              <YearEditor vaultPath={vaultPath} r={r} onSaved={() => void q.refresh()} />
            </LineRow>
          ))}
        </ul>
        {!rows.some((r) => r.year === thisYear) && (
          <button type="button" onClick={() => void writeNow()} disabled={busy} data-testid="yearly-write" className="mt-1.5 inline-flex items-center gap-1 py-1 text-[13px] text-text-muted hover:text-accent disabled:opacity-50">
            {busy ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <Plus className="h-3.5 w-3.5" />} Write this year's now
          </button>
        )}
      </Group>
    </section>
  );
}

/** Save the confirmed Compass as a constitution file; returns a line to show. */
export async function exportCompass(vaultPath: string): Promise<string> {
  const r = await invoke<{ file?: string; text?: string }>("engine_compass_export", { vault: vaultPath });
  try { if (r?.text) await navigator.clipboard.writeText(r.text); } catch { /* clipboard off */ }
  return r?.file ? `Saved as ${r.file.split("/").pop()} in your vault's exports, and copied. Paste it into any AI.` : "Not saved.";
}
