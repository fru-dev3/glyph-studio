// Insights > Metrics: what you already do, counted without asking you to
// enter anything. The engine (`prevail metrics`) reads every Mac's AI and git
// events and the vault's own files; this view shows them:
//   This week  the glance: a few numbers against your own normal, each with
//              its tier (Measured, Derived), coverage and the files behind it
//   families   small multiples with 12-week sparklines and the normal band
//   Rhythm     one dot per prompt or commit, time of day by date
//   Sources    what each number is read from, and its caveats
import { useEffect, useMemo, useState } from "react";
import { Activity, BookOpen, CalendarDays, CalendarRange, Check, PartyPopper, Cpu, Database, Lightbulb, Map as MapIcon, Pencil, Sparkles, TrendingUp, Wallet, X } from "lucide-react";
import { invoke } from "./bridge";
import { invalidateQueries, useInvokeQuery } from "./query";
import type { MetricProposal } from "./plansmodel";
import { SideSpine } from "./sidespine";
import { SourcesConsent } from "./sourcesview";
import { PatternsView } from "./patternsview";
import { MonthRecapView, YourYearView } from "./storiesview";

/** Open Insights > Metrics on one view ("year", "month"...). */
export const METRICS_FOCUS_KEY = "prevail.metrics.focus";
export const METRICS_FOCUS_EVENT = "prevail:metrics-focus";
function takeMetricsFocus(): "year" | "month" | null {
  try { const f = localStorage.getItem(METRICS_FOCUS_KEY); localStorage.removeItem(METRICS_FOCUS_KEY); return f === "year" || f === "month" ? f : null; } catch { return null; }
}
import { BODY, DETAIL_TITLE, META, ROW_TITLE, SCORE, SECTION_TITLE } from "./typescale";
import { REVEAL, RowMenu } from "./ui";
import { label } from "./plansmodel";
import { TintIcon } from "./tint";

export interface Normal { median: number; lo: number; hi: number; weeks: number; learning: boolean; learningWeeksLeft: number }
export interface GlanceRow {
  id: string; title: string; unit: string; tier: string; family: string; value: number; normal: Normal;
  spark: number[]; documentary: boolean; coverage: string; citations: { file: string; note?: string }[]; record?: string;
}
export interface Glance { week: string; through: string; rows: GlanceRow[]; surprise: string | null; computed: number }
export interface MetricItem extends Omit<GlanceRow, "value" | "record"> { thisWeek: number; status: string; from: string; per: string }
interface Dot { day: string; hour: number; kind: "prompt" | "commit" }
interface Source { id: string; kind: string; files: string[]; first?: string; last?: string; events: number; note?: string; hosts?: string[] }

const FAMILY_ICON: Record<string, typeof Cpu> = {
  "AI and building": Cpu, "Glyph Studio itself": Sparkles, "Prevail itself": Sparkles, Exploration: MapIcon, "Learning and attention": BookOpen, Money: Wallet,
};
const TIER: Record<string, string> = { measured: "Measured", derived: "Derived", inferred: "Inferred", asked: "Asked" };

export function fmtValue(v: number, unit: string): string {
  if (unit === "usd") return `$${v >= 100 ? Math.round(v).toLocaleString("en-US") : v.toFixed(2)}`;
  if (unit === "tokens") return v >= 1e9 ? `${(v / 1e9).toFixed(1)}B` : v >= 1e6 ? `${(v / 1e6).toFixed(1)}M` : `${Math.round(v / 1e3)}k`;
  if (unit === "minutes") return `${Math.round(v)} min`;
  return String(Math.round(v * 10) / 10);
}
export function normalText(n: Normal, unit: string): string {
  if (n.learning) return `learning your normal, ${n.learningWeeksLeft} more week${n.learningWeeksLeft === 1 ? "" : "s"}`;
  return `normal ${fmtValue(n.lo, unit)} to ${fmtValue(n.hi, unit)}`;
}
const weekLabel = (d: string) => new Date(`${d}T12:00:00`).toLocaleDateString(undefined, { month: "short", day: "numeric" });

/** Twelve weeks as a line, with your normal band behind it (when learned). */
export function Sparkline({ values, normal, width = 168, height = 40 }: { values: number[]; normal?: Normal; width?: number; height?: number }) {
  const max = Math.max(1, ...values, normal && !normal.learning ? normal.hi : 0);
  const x = (i: number) => (values.length <= 1 ? width / 2 : (i / (values.length - 1)) * (width - 4) + 2);
  const y = (v: number) => height - 3 - (v / max) * (height - 6);
  const pts = values.map((v, i) => `${x(i).toFixed(1)},${y(v).toFixed(1)}`).join(" ");
  return (
    <svg width={width} height={height} viewBox={`0 0 ${width} ${height}`} role="img" aria-label={`last ${values.length} weeks`} data-testid="sparkline" className="block max-w-full">
      {normal && !normal.learning && <rect x={0} width={width} y={y(normal.hi)} height={Math.max(1, y(normal.lo) - y(normal.hi))} className="fill-accent/10" data-testid="normal-band" />}
      <polyline points={pts} fill="none" strokeWidth={1.75} className="stroke-accent" strokeLinejoin="round" strokeLinecap="round" />
      {values.length > 0 && <circle cx={x(values.length - 1)} cy={y(values[values.length - 1])} r={2.5} className="fill-accent" />}
    </svg>
  );
}

/** "From Your Compass", in words; the file itself stays on hover. */
export function fromLabel(from: string): string {
  const d = /data\/domains\/([^/]+)\//.exec(from)?.[1];
  if (d) return `${label(d)} notes`;
  if (/compass/.test(from)) return "Your Compass";
  if (/ideal-state|constitution/.test(from)) return "Your ideal state";
  if (/user\.md/.test(from)) return "Your profile";
  if (/chat|thread/.test(from)) return "What you said in chat";
  return label((from.split("/").pop() ?? from).replace(/\.[a-z]+$/i, ""));
}

function Citations({ items }: { items: { file: string; note?: string }[] }) {
  const [open, setOpen] = useState(false);
  if (!items.length) return null;
  return (
    <div className="mt-1">
      <button onClick={() => setOpen((v) => !v)} className={`${META} hover:text-accent`} aria-expanded={open} data-testid="metric-sources-toggle">
        {open ? "Hide sources" : `${items.length} source file${items.length === 1 ? "" : "s"}`}
      </button>
      {open && (
        <ul className="mt-1 space-y-0.5" data-testid="metric-sources">
          {items.map((c) => <li key={c.file} className="break-all text-[12px] text-text-muted">{c.file}{c.note ? `, ${c.note}` : ""}</li>)}
        </ul>
      )}
    </div>
  );
}

function GlanceRowView({ r }: { r: GlanceRow }) {
  return (
    <li data-testid="glance-row" data-id={r.id} className="grid gap-x-6 gap-y-1 border-b border-border-subtle py-4 last:border-b-0 sm:grid-cols-[minmax(0,1fr)_auto]">
      <div className="min-w-0">
        <div className="flex flex-wrap items-baseline gap-x-3 gap-y-1">
          <span className={ROW_TITLE}>{r.title}</span>
          {!r.documentary && <span className={`${SCORE} text-text-primary`} data-testid="glance-value">{fmtValue(r.value, r.unit)}</span>}
        </div>
        <p className={`${BODY} mt-0.5 text-text-secondary`}>{r.documentary ? r.record : normalText(r.normal, r.unit)}</p>
        <p className={`${META} mt-0.5`}><span data-testid="glance-tier">{TIER[r.tier] ?? r.tier}</span>{r.documentary ? " · A record, no target" : ""} · <span data-testid="glance-coverage">{r.coverage}</span></p>
        <Citations items={r.citations} />
      </div>
      {!r.documentary && <div className="self-center"><Sparkline values={r.spark} normal={r.normal} /></div>}
    </li>
  );
}

function MetricCard({ m }: { m: MetricItem }) {
  return (
    <li data-testid="metric-card" data-id={m.id} className="grid gap-x-6 gap-y-1 border-b border-border-subtle py-4 last:border-b-0 sm:grid-cols-[minmax(0,1fr)_auto]">
      <div className="min-w-0">
        <div className="flex flex-wrap items-baseline gap-x-3 gap-y-1">
          <span className={ROW_TITLE}>{m.title}</span>
          {!m.documentary && <span className={`${SCORE} text-text-primary`}>{fmtValue(m.thisWeek, m.unit)}<span className={`${META} ml-1.5 font-sans font-normal`}>this {m.per === "month" ? "month" : "week"}</span></span>}
        </div>
        <p className={`${BODY} mt-0.5 text-text-secondary`}>{m.documentary ? "A record, no target. Counted for your year, not shown as a number." : normalText(m.normal, m.unit)}</p>
        <p className={`${META} mt-0.5`} title={m.from}>{TIER[m.tier] ?? m.tier} · {m.coverage}</p>
      </div>
      {!m.documentary && <div className="self-center"><Sparkline values={m.spark} normal={m.normal} /></div>}
    </li>
  );
}

/** One dot per event, time of day (down) by date (across). */
export function RhythmPlot({ dots, days = 30, end }: { dots: Dot[]; days?: number; end: string }) {
  const W = 720;
  const H = 260;
  const left = 34;
  const endMs = new Date(`${end}T12:00:00`).getTime();
  const col = (day: string) => days - 1 - Math.round((endMs - new Date(`${day}T12:00:00`).getTime()) / 86_400_000);
  const x = (day: string) => left + ((col(day) + 0.5) / days) * (W - left - 4);
  const y = (h: number) => 6 + (h / 24) * (H - 24);
  return (
    <svg viewBox={`0 0 ${W} ${H}`} className="block h-auto w-full max-w-4xl" role="img" aria-label="When you worked: prompts and commits by time of day" data-testid="rhythm-plot">
      {[0, 6, 12, 18, 24].map((h) => (
        <g key={h}>
          <line x1={left} x2={W - 2} y1={y(h)} y2={y(h)} className="stroke-border" strokeWidth={0.5} />
          <text x={left - 6} y={y(h) + 4} textAnchor="end" className="fill-text-muted text-[10px]">{h === 24 ? "" : `${h}:00`}</text>
        </g>
      ))}
      {Array.from({ length: Math.floor(days / 7) + 1 }, (_, k) => days - 1 - 7 * k).filter((c) => c >= 0).map((c) => {
        const d = new Date(endMs - (days - 1 - c) * 86_400_000);
        const cx = left + ((c + 0.5) / days) * (W - left - 4);
        return <text key={c} x={cx} y={H - 1} textAnchor="middle" className="fill-text-muted text-[10px]">{d.toLocaleDateString(undefined, { month: "short", day: "numeric" })}</text>;
      })}
      {dots.filter((d) => col(d.day) >= 0 && col(d.day) < days).map((d, i) => (
        <circle key={i} cx={x(d.day)} cy={y(d.hour)} r={2.2} className={d.kind === "commit" ? "fill-text-primary/70" : "fill-accent/70"} />
      ))}
    </svg>
  );
}

type Sel = "week" | "rhythm" | "sources" | "proposals" | "changes" | "patterns" | `family:${string}` | "year" | "month";
interface Insight { key: string; week: string; metric: string; title: string; text: string; direction: "up" | "down"; files: string[] }

const iconBtn = "flex h-7 w-7 shrink-0 items-center justify-center rounded-md text-text-muted transition-colors hover:bg-surface-warm hover:text-accent disabled:opacity-40";

/** A proposed metric: what it is, why, 12 weeks of history when Prevail can count it. Track / Not useful / Edit. */
export function ProposalCard({ p, vaultPath, onAnswered }: { p: MetricProposal; vaultPath: string; onAnswered: () => void }) {
  const [busy, setBusy] = useState(false);
  const [edit, setEdit] = useState(false);
  const [title, setTitle] = useState(p.title);
  const [err, setErr] = useState<string | null>(null);
  const answer = async (a: "track" | "dismiss" | "edit") => {
    setBusy(true); setErr(null);
    try { await invoke("engine_metric_answer", { vault: vaultPath, key: p.key, answer: a, title: a === "edit" ? title : null, serves: null, never: null }); onAnswered(); }
    catch (e) { setErr(String(e)); } finally { setBusy(false); }
  };
  return (
    <li data-testid="metric-proposal" data-kind={p.kind} className="group border-b border-border-subtle py-3 last:border-b-0">
      <div className="flex items-start gap-3">
        <div className="min-w-0 flex-1">
          <span title={p.title} className={`${ROW_TITLE} line-clamp-2 break-words`}>{p.title}</span>
          <p title={p.why} className={`${BODY} mt-0.5 line-clamp-2 break-words text-text-secondary`}>{p.why}</p>
          <p className={`${META} mt-0.5`}>
            {p.computable ? (TIER[p.tier] ?? p.tier) : "Needs a source"}{p.servesTitle ? ` · Serves ${p.servesTitle}` : ""} · <span title={p.from}>From {fromLabel(p.from)}</span>
          </p>
        </div>
        <span className={`flex shrink-0 items-center gap-0.5 ${REVEAL}`}>
          <button onClick={() => void answer("track")} disabled={busy} title="Track" aria-label={`Track ${p.title}`} data-testid="proposal-track" className={iconBtn}><Check className="h-4 w-4" /></button>
          <RowMenu items={[
            { icon: Pencil, label: "Rename, then track", onClick: () => setEdit((v) => !v) },
            { icon: X, label: "Not useful", onClick: () => void answer("dismiss") },
          ]} />
        </span>
      </div>
      {p.computable && p.spark.length > 0 && <div className="mt-2"><Sparkline values={p.spark} /></div>}
      {edit && (
        <div className="mt-2 flex max-w-md gap-2">
          <input value={title} onChange={(e) => setTitle(e.target.value)} aria-label="Metric name" className="h-9 min-w-0 flex-1 rounded-md border border-border bg-background px-2.5 text-[14px]" />
          <button onClick={() => void answer("edit")} disabled={busy || !title.trim()} className="inline-flex h-9 items-center text-[13px] font-medium text-accent hover:underline disabled:opacity-50">Track as this</button>
        </div>
      )}
      {err && <p className="mt-1 text-[13px] text-err">{err}</p>}
    </li>
  );
}

export function MetricsView({ vaultPath, phone }: { vaultPath: string; phone: boolean }) {
  const [sel, setSel] = useState<Sel>(() => takeMetricsFocus() ?? "week");
  const [picked, setPicked] = useState(false);
  // Another page (For You, the weekly card) can open Your year or a month here.
  useEffect(() => {
    const on = () => { const f = takeMetricsFocus(); if (f) { setSel(f); setPicked(true); } };
    window.addEventListener(METRICS_FOCUS_EVENT, on);
    return () => window.removeEventListener(METRICS_FOCUS_EVENT, on);
  }, []);
  const glanceQ = useInvokeQuery<Glance>("engine_metrics", { vault: vaultPath, view: "glance", week: null }, { staleMs: 10 * 60_000 });
  const listQ = useInvokeQuery<MetricItem[]>("engine_metrics", { vault: vaultPath, view: "list", week: null }, { staleMs: 10 * 60_000 });
  const rhythmQ = useInvokeQuery<Dot[]>("engine_metrics", sel === "rhythm" ? { vault: vaultPath, view: "rhythm", week: null } : null, { staleMs: 10 * 60_000 });
  const sourcesQ = useInvokeQuery<Source[]>("engine_metrics", sel === "sources" ? { vault: vaultPath, view: "sources", week: null } : null, { staleMs: 10 * 60_000 });
  const propQ = useInvokeQuery<MetricProposal[]>("engine_metric_proposals", { vault: vaultPath, view: "proposals" }, { staleMs: 10 * 60_000 });
  const insightQ = useInvokeQuery<Insight[]>("engine_metric_proposals", sel === "changes" ? { vault: vaultPath, view: "insights" } : null, { staleMs: 10 * 60_000 });
  const props = Array.isArray(propQ.data) ? propQ.data : [];
  const g = glanceQ.data ?? null;
  const list = useMemo(() => (Array.isArray(listQ.data) ? listQ.data : []), [listQ.data]);
  const families = useMemo(() => [...new Set(list.map((m) => m.family))], [list]);
  const choose = (s: Sel) => { setSel(s); setPicked(true); };
  const isOn = (s: Sel) => sel === s && (!phone || picked);
  const row = (s: Sel, label: string, Icon: typeof Cpu, sub?: string, count?: number) => (
    <button key={s} data-testid={`metrics-row-${s}`} aria-current={isOn(s) ? "true" : undefined} onClick={() => choose(s)}
      className={`flex w-full items-center gap-2.5 rounded-lg px-2.5 py-2 text-left transition-colors ${isOn(s) ? "bg-surface-warm" : "hover:bg-surface-warm/50"}`}>
      <TintIcon icon={Icon} />
      <span className="min-w-0 flex-1">
        <span className={`block truncate text-[14px] ${isOn(s) ? "font-semibold text-text-primary" : "text-text-secondary"}`}>{label}</span>
        {sub && <span className="block truncate text-[12px] text-text-muted">{sub}</span>}
      </span>
      {count !== undefined && <span className="shrink-0 text-[12px] tabular-nums text-text-muted">{count}</span>}
    </button>
  );
  const column = (
    <nav className="space-y-0.5 p-2" aria-label="Metrics">
      {row("week", "This week", CalendarRange, g ? `Week of ${weekLabel(g.week)}` : undefined)}
      {row("month", "This month", CalendarDays, "The month in short")}
      {row("year", "Your year", PartyPopper, "The year as a story")}
      <div className="px-2.5 pb-1 pt-3 text-[13px] font-semibold text-text-secondary">Families</div>
      {families.map((f) => row(`family:${f}`, f, FAMILY_ICON[f] ?? Activity, undefined, list.filter((m) => m.family === f).length))}
      {row("proposals", "Proposals", Lightbulb, "Metrics to track, from what you said", props.length)}
      <div className="px-2.5 pb-1 pt-3 text-[13px] font-semibold text-text-secondary">Patterns</div>
      {row("changes", "Changes", TrendingUp, "Three weeks outside your normal")}
      {row("patterns", "Patterns", Sparkles, "What moves what, themes, seasons")}
      {row("rhythm", "Rhythm", Activity, "When you work")}
      {row("sources", "Sources", Database, "What each number reads")}
    </nav>
  );

  const loading = (q: { data?: unknown; error?: unknown }) => !q.data && !q.error;
  const err = (q: { error?: unknown }) => q.error ? <p className="text-[13px] text-err">Could not read metrics: {String(q.error)}</p> : null;
  let detail: React.ReactNode = null;
  if (sel === "week") {
    detail = (
      <section data-testid="metrics-week">
        <h2 className={DETAIL_TITLE}>This week{g ? `, ${weekLabel(g.week)} to ${weekLabel(g.through)}` : ""}</h2>
        <p className={`${META} mt-1`}>Against your own normal. Every number says how it was counted and where it came from.</p>
        {err(glanceQ)}
        {loading(glanceQ) && <p className={`${META} mt-4`}>Counting...</p>}
        {g && <ul className="mt-3 max-w-4xl">{g.rows.map((r) => <GlanceRowView key={r.id} r={r} />)}</ul>}
        {g?.surprise && <p className={`${BODY} mt-4 max-w-4xl text-text-primary`} data-testid="glance-surprise"><span className="font-semibold">One surprise: </span>{g.surprise}</p>}
      </section>
    );
  } else if (sel.startsWith("family:")) {
    const f = sel.slice(7);
    const ms = list.filter((m) => m.family === f);
    detail = (
      <section data-testid="metrics-family">
        <h2 className={DETAIL_TITLE}>{f}</h2>
        {err(listQ)}
        <ul className="mt-3 max-w-4xl">{ms.map((m) => <MetricCard key={m.id} m={m} />)}</ul>
      </section>
    );
  } else if (sel === "proposals") {
    detail = (
      <section data-testid="metrics-proposals">
        <h2 className={DETAIL_TITLE}>Proposals</h2>
        <p className={`${META} mt-1`}>Metrics Glyph Studio could track for you, from your ideal states, your Compass goals and what you say in chat. One tap each; two "not useful" on a kind and it stops proposing that kind.</p>
        {err(propQ)}
        {!props.length && !loading(propQ) && <p className={`${META} mt-4`}>No proposals right now.</p>}
        <ul className="mt-3 max-w-4xl">{props.map((p) => <ProposalCard key={p.key} p={p} vaultPath={vaultPath} onAnswered={() => { invalidateQueries("engine_metric_proposals"); invalidateQueries("engine_review"); void propQ.refresh(); }} />)}</ul>
      </section>
    );
  } else if (sel === "changes") {
    const ins = Array.isArray(insightQ.data) ? insightQ.data : [];
    detail = (
      <section data-testid="metrics-changes">
        <h2 className={DETAIL_TITLE}>Changes</h2>
        <p className={`${META} mt-1`}>A metric that sat outside your normal for three weeks running. A change, not a cause; each lists the files behind it.</p>
        {err(insightQ)}
        {!ins.length && !loading(insightQ) && <p className={`${META} mt-4`}>Nothing has moved outside your normal for three weeks.</p>}
        <ul className="mt-3 max-w-4xl">{ins.map((i) => (
          <li key={i.key} data-testid="metric-change" className="border-b border-border-subtle py-3 last:border-b-0">
            <p className={`${BODY} text-text-primary`}>{i.text}</p>
            <Citations items={i.files.map((file) => ({ file }))} />
          </li>
        ))}</ul>
      </section>
    );
  } else if (sel === "patterns") {
    detail = <PatternsView vaultPath={vaultPath} />;
  } else if (sel === "year") {
    detail = <YourYearView vaultPath={vaultPath} />;
  } else if (sel === "month") {
    detail = <MonthRecapView vaultPath={vaultPath} />;
  } else if (sel === "rhythm") {
    const dots = Array.isArray(rhythmQ.data) ? rhythmQ.data : [];
    const end = g?.through ?? new Date().toISOString().slice(0, 10);
    detail = (
      <section data-testid="metrics-rhythm">
        <h2 className={DETAIL_TITLE}>Rhythm</h2>
        <p className={`${META} mt-1`}>The last 30 days, one dot per prompt you wrote (green) and per commit (grey): time of day down, date across.</p>
        {err(rhythmQ)}
        {loading(rhythmQ) ? <p className={`${META} mt-4`}>Plotting...</p> : <div className="mt-4"><RhythmPlot dots={dots} end={end} /></div>}
        <p className={`${META} mt-2`}>{dots.filter((d) => d.kind === "prompt").length} prompts, {dots.filter((d) => d.kind === "commit").length} commits</p>
      </section>
    );
  } else {
    const ss = Array.isArray(sourcesQ.data) ? sourcesQ.data : [];
    detail = (
      <section data-testid="metrics-sources">
        <h2 className={DETAIL_TITLE}>Sources</h2>
        <p className={`${META} mt-1`}>What Glyph Studio may read on this Mac. Connections and sensitive sources stay off until you turn them on; counts only, never content.</p>
        <SourcesConsent vaultPath={vaultPath} />
        <h3 className={`${SECTION_TITLE} mt-8`}>What each number read</h3>
        {err(sourcesQ)}
        <ul className="mt-3 max-w-4xl">{ss.map((s) => (
          <li key={s.id} data-testid="source-row" className="border-b border-border-subtle py-3 last:border-b-0">
            <div className="flex flex-wrap items-baseline gap-x-3">
              <h4 className={ROW_TITLE}>{s.id === "ai" ? "AI tools" : s.id.charAt(0).toUpperCase() + s.id.slice(1)}</h4>
              <span className={META}>{s.events.toLocaleString("en-US")} records{s.first ? `, ${s.first} to ${s.last}` : ""}</span>
            </div>
            <p className={`${BODY} text-text-secondary`}>{s.kind === "machine" ? `On ${s.hosts?.length ? s.hosts.join(", ") : "no Mac yet"}` : "Your vault, read in place"}{s.note ? `. ${s.note}` : ""}</p>
          </li>
        ))}</ul>
      </section>
    );
  }

  return (
    <SideSpine storageKey="prevail.metrics.spine" title="Metrics" label="metrics" testId="metrics-list"
      phone={phone} phoneDetail={phone && picked} onBack={() => setPicked(false)} backLabel="Metrics"
      detail={<div className={phone ? "px-4 py-4" : "w-full px-8 py-6"}>{detail}</div>}>
      {column}
    </SideSpine>
  );
}
