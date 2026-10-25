// Usage: a rich, multi-dimension analytics view over the local usage ledger.
// All pivoting/filtering/heatmapping is done client-side over the raw entries
// (personal volume is small), so every viewpoint is instant and offline. No
// chart library: SVG for the time series, CSS grid for the heatmap + cross-tab.
import { SettingsHeader } from "./sectionutil";
import { SideSpine } from "./sidespine";
import { useIsPhone } from "./useisphone";
import { Fragment, useEffect, useMemo, useState } from "react";
import { invoke } from "./bridge";
import { BarChart3, Cpu, Filter, Folder, Layers, LayoutDashboard, Monitor, Search, Workflow, X, type LucideIcon } from "lucide-react";

type Entry = {
  ts: number; day: string; session: string; domain: string | null;
  surface: string; cli: string; model: string;
  input_tokens: number; output_tokens: number; est_cost_usd: number; host: string;
};

// The dimensions the user can slice by. `label` is the human word; `get` pulls
// the value off an entry (with a friendly fallback for missing/legacy data).
type DimId = "model" | "domain" | "surface" | "host" | "cli";
import { modelLabel } from "./helpers2";
import { DETAIL_TITLE, META, SCORE, SECTION_TITLE } from "./typescale";
import { TintIcon } from "./tint";

const DIMS: { id: DimId; label: string; get: (e: Entry) => string }[] = [
  { id: "model", label: "Model", get: (e) => e.model || "(default)" },
  { id: "domain", label: "Domain", get: (e) => e.domain || "general" },
  { id: "surface", label: "Activity", get: (e) => e.surface || "other" },
  { id: "host", label: "Machine", get: (e) => e.host || "this device" },
  { id: "cli", label: "Runtime", get: (e) => e.cli || "unknown" },
];
// The side column's views: the overview, then one breakdown per dimension.
export type UsageView = "overview" | DimId;
export const USAGE_VIEWS: { id: UsageView; label: string; icon: LucideIcon }[] = [
  { id: "overview", label: "Overview", icon: LayoutDashboard },
  { id: "cli", label: "By runtime", icon: Cpu },
  { id: "model", label: "By model", icon: Layers },
  { id: "domain", label: "By domain", icon: Folder },
  { id: "surface", label: "By activity", icon: Workflow },
  { id: "host", label: "By machine", icon: Monitor },
];
const dimGet = (id: DimId) => DIMS.find((d) => d.id === id)!.get;

// Every dimension shows the name a person would recognise. Only "model" needs
// translating: the ledger records the id that actually ran.
function rowLabel(dim: DimId, key: string): string {
  if (dim !== "model") return key;
  return modelLabel(undefined, key) || key;
}

const RANGES: { id: string; label: string; days: number | null }[] = [
  { id: "7d", label: "7 days", days: 7 },
  { id: "30d", label: "30 days", days: 30 },
  { id: "90d", label: "90 days", days: 90 },
  { id: "all", label: "All time", days: null },
];

// Every AI tool this month, from the tools' own local records (engine `ai usage`).
type AiTool = { key: string; tokens: number; usd_api: number; usd_reported: number; sessions: number; paid_monthly?: number; value_multiple?: number; prompts?: number };
type AiUsage = { month: string; hosts: string[]; price_snapshot: string; total: { tokens: number; usd_api: number }; by_tool: AiTool[]; paid_monthly: number | null; value_multiple: number | null };
const TOOL_NAMES: Record<string, string> = { claude: "Claude Code", codex: "Codex", opencode: "opencode", hermes: "Hermes", antigravity: "Antigravity", cursor: "Cursor", aionui: "AionUi", wispr: "Wispr Flow", glyph: "glyph" };

/** The month's AI spend across every tool and machine, with honest labels. */
export function AllToolsPanel({ data }: { data: AiUsage }) {
  const rows = data.by_tool.filter((t) => t.tokens > 0 || t.sessions > 0 || (t.prompts ?? 0) > 0);
  const machines = data.hosts.length;
  return (
    <section className="@container" data-testid="ai-all-tools">
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <h3 className={SECTION_TITLE}>All AI tools, {new Date(`${data.month}-01T12:00:00`).toLocaleString(undefined, { month: "long", year: "numeric" })}</h3>
        <span className="text-[12px] text-text-muted">measured from each tool's own records on {machines} {machines === 1 ? "machine" : "machines"}</span>
      </div>
      <div className="mt-2 flex flex-wrap items-baseline gap-x-6 gap-y-1">
        <div><span className={`${SCORE} text-text-primary`} data-testid="ai-all-tools-usd">{fmtCost(data.total.usd_api)}</span> <span className="text-xs text-text-muted">at API prices</span></div>
        <div className="text-sm tabular-nums text-text-secondary">{fmtTok(data.total.tokens)} tokens</div>
        <div className="text-sm text-text-secondary">{data.paid_monthly !== null ? <>paid {fmtCost(data.paid_monthly)}{data.value_multiple !== null && <span className="text-text-muted"> ({data.value_multiple}x)</span>}</> : <span className="text-text-muted">paid: not set yet</span>}</div>
      </div>
      {rows.length > 0 && (
        <table className="mt-3 w-full text-[13px]">
          <tbody>
            {rows.map((t) => (
              <tr key={t.key} className="border-t border-border-subtle" data-testid="ai-tool-row">
                <td className="py-1.5 pr-2 text-text-primary">{TOOL_NAMES[t.key] ?? t.key}</td>
                <td className="hidden py-1.5 pr-2 text-right tabular-nums text-text-secondary @xs:table-cell">{t.tokens > 0 ? fmtTok(t.tokens) : t.prompts ? `${fmtNum(t.prompts)} prompts` : `${fmtNum(t.sessions)} sessions`}</td>
                <td className="py-1.5 text-right tabular-nums text-text-primary">{t.tokens > 0 ? fmtCost(t.usd_api) : <span className="text-text-muted">{t.prompts ? `${fmtNum(t.prompts)} prompts` : "no token counts"}</span>}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
      <p className="mt-2 text-[12px] text-text-muted">API prices as of {data.price_snapshot}: what this use would cost on the API. The turns below are Glyph Studio's own, and their tokens are estimated.</p>
    </section>
  );
}

const fmtCost = (n: number) => (n >= 1 ? `$${n.toFixed(2)}` : n > 0 ? `$${n.toFixed(3)}` : "$0");
const fmtTok = (n: number) => (n >= 1e6 ? `${(n / 1e6).toFixed(1)}M` : n >= 1e3 ? `${(n / 1e3).toFixed(1)}k` : `${n}`);
const fmtNum = (n: number) => n.toLocaleString();

// A heat color from a 0..1 intensity, biased to the app accent (office green).
function heat(t: number): string {
  if (t <= 0) return "transparent";
  const a = 0.08 + t * 0.82;
  return `color-mix(in srgb, var(--color-accent) ${Math.round(a * 100)}%, transparent)`;
}

export function UsageDashboard({ vaultPath, embedded = false, view: viewProp }: { vaultPath: string; embedded?: boolean; view?: UsageView }) {
  const [entries, setEntries] = useState<Entry[] | null>(null);
  const [ai, setAi] = useState<AiUsage | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [range, setRange] = useState("30d");
  const [query, setQuery] = useState("");
  const [filters, setFilters] = useState<Partial<Record<DimId, Set<string>>>>({});
  const [viewOwn, setView] = useState<UsageView>("overview");
  const view = viewProp ?? viewOwn;
  const [picked, setPicked] = useState(false);
  const phone = useIsPhone();
  const groupBy: DimId = view === "overview" ? "model" : view;
  const [metric, setMetric] = useState<"cost" | "tokens" | "turns">("cost");
  const [sortDesc, setSortDesc] = useState(true);
  const [crossX, setCrossX] = useState<DimId>("model");
  const [crossY, setCrossY] = useState<DimId>("domain");

  useEffect(() => {
    if (!vaultPath) return;
    let alive = true;
    invoke<Entry[]>("usage_entries", { vault: vaultPath })
      .then((rows) => { if (alive) setEntries(Array.isArray(rows) ? rows : []); })
      .catch((e) => { if (alive) { setError(String(e)); setEntries([]); } });
    invoke<AiUsage>("engine_ai_usage", { vault: vaultPath, month: null })
      .then((r) => { if (alive && r && Array.isArray(r.by_tool)) setAi(r); })
      .catch(() => { /* optional: older engines have no ai usage */ });
    return () => { alive = false; };
  }, [vaultPath]);

  // Time-window + active-filter application.
  const filtered = useMemo(() => {
    if (!entries) return [];
    const days = RANGES.find((r) => r.id === range)?.days ?? null;
    const cutoff = days ? Date.now() - days * 86400_000 : 0;
    const q = query.trim().toLowerCase();
    return entries.filter((e) => {
      if (e.ts < cutoff) return false;
      for (const d of DIMS) {
        const set = filters[d.id];
        if (set && set.size && !set.has(d.get(e))) return false;
      }
      // Free-text search: match the query against ANY dimension value
      // (model, domain, activity, machine, runtime). Empty query = no-op.
      if (q && !DIMS.some((d) => d.get(e).toLowerCase().includes(q))) return false;
      return true;
    });
  }, [entries, range, filters, query]);

  const metricOf = (e: Entry) => metric === "cost" ? e.est_cost_usd : metric === "tokens" ? e.input_tokens + e.output_tokens : 1;

  // Top-line totals.
  const totals = useMemo(() => {
    const t = { turns: 0, inTok: 0, outTok: 0, cost: 0, days: new Set<string>() };
    for (const e of filtered) { t.turns++; t.inTok += e.input_tokens; t.outTok += e.output_tokens; t.cost += e.est_cost_usd; t.days.add(e.day); }
    return t;
  }, [filtered]);

  // Group-by breakdown for the active metric.
  const breakdown = useMemo(() => {
    const g = dimGet(groupBy);
    const m = new Map<string, { key: string; turns: number; tok: number; cost: number }>();
    for (const e of filtered) {
      const k = g(e);
      const b = m.get(k) ?? { key: k, turns: 0, tok: 0, cost: 0 };
      b.turns++; b.tok += e.input_tokens + e.output_tokens; b.cost += e.est_cost_usd; m.set(k, b);
    }
    const val = (b: { turns: number; tok: number; cost: number }) => metric === "cost" ? b.cost : metric === "tokens" ? b.tok : b.turns;
    const rows = [...m.values()].sort((a, b) => (sortDesc ? val(b) - val(a) : val(a) - val(b)));
    const max = Math.max(1, ...rows.map(val));
    return { rows, max, val };
  }, [filtered, groupBy, metric, sortDesc]);

  // Per-day series for the over-time chart.
  const series = useMemo(() => {
    const days = RANGES.find((r) => r.id === range)?.days ?? 30;
    const span = days ?? Math.max(1, Math.ceil((Date.now() - Math.min(...(filtered.length ? filtered.map((e) => e.ts) : [Date.now()]))) / 86400_000));
    const buckets = new Map<string, number>();
    for (const e of filtered) buckets.set(e.day, (buckets.get(e.day) ?? 0) + metricOf(e));
    const out: { day: string; v: number }[] = [];
    for (let i = span - 1; i >= 0; i--) {
      const d = new Date(Date.now() - i * 86400_000);
      const key = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
      out.push({ day: key, v: buckets.get(key) ?? 0 });
    }
    return out;
  }, [filtered, range, metric]);

  // Weekday × hour heatmap.
  const heatGrid = useMemo(() => {
    const grid: number[][] = Array.from({ length: 7 }, () => Array(24).fill(0));
    for (const e of filtered) { const d = new Date(e.ts); grid[d.getDay()]![d.getHours()]! += metricOf(e); }
    const max = Math.max(1, ...grid.flat());
    return { grid, max };
  }, [filtered, metric]);

  // Cross-tab (activity map): crossY rows × crossX cols.
  const cross = useMemo(() => {
    const gx = dimGet(crossX), gy = dimGet(crossY);
    const rowsSet = new Set<string>(), colsSet = new Set<string>();
    const cell = new Map<string, number>();
    for (const e of filtered) {
      const rk = gy(e), ck = gx(e); rowsSet.add(rk); colsSet.add(ck);
      cell.set(`${rk}||${ck}`, (cell.get(`${rk}||${ck}`) ?? 0) + metricOf(e));
    }
    const rows = [...rowsSet].sort(), cols = [...colsSet].sort();
    const max = Math.max(1, ...[...cell.values()]);
    return { rows, cols, cell, max };
  }, [filtered, crossX, crossY, metric]);

  const toggleFilter = (dim: DimId, val: string) => setFilters((f) => {
    const next = { ...f }; const set = new Set(next[dim] ?? []);
    set.has(val) ? set.delete(val) : set.add(val);
    if (set.size) next[dim] = set; else delete next[dim];
    return next;
  });
  const activeFilterCount = Object.values(filters).reduce((n, s) => n + (s?.size ?? 0), 0);

  if (entries === null) return <div className={`${META} p-8`}>Loading usage…</div>;

  const empty = entries.length === 0;
  const metricLabel = metric === "cost" ? "Cost" : metric === "tokens" ? "Tokens" : "Turns";
  const fmtMetric = (v: number) => metric === "cost" ? fmtCost(v) : metric === "tokens" ? fmtTok(v) : fmtNum(v);

  // How many distinct values each dimension has, for the side column.
  const distinct = (id: DimId) => new Set(filtered.map(dimGet(id))).size;
  const viewList = (
    <nav className="space-y-0.5 p-2" aria-label="Usage views">
      {USAGE_VIEWS.map((v) => {
        const on = view === v.id && (!phone || picked);
        const Icon = v.icon;
        return (
          <button key={v.id} data-testid={`usage-view-${v.id}`} aria-current={on ? "true" : undefined} onClick={() => { setView(v.id); setPicked(true); }}
            className={`flex w-full items-center gap-2.5 rounded-lg px-2.5 py-2 text-left transition-colors ${on ? "bg-surface-warm" : "hover:bg-surface-warm/50"}`}>
            <TintIcon icon={Icon} />
            <span className={`min-w-0 flex-1 truncate text-[14px] ${on ? "font-semibold text-text-primary" : "text-text-secondary"}`}>{v.label}</span>
            {v.id !== "overview" && <span className="text-[12px] tabular-nums text-text-muted">{distinct(v.id)}</span>}
          </button>
        );
      })}
    </nav>
  );
  const viewLabel = USAGE_VIEWS.find((v) => v.id === view)?.label ?? "Overview";

  const controls = (
        <div className="flex min-w-0 max-w-full flex-wrap items-center justify-end gap-2">
          <div className="relative max-w-full">
            <Search className="pointer-events-none absolute left-2.5 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-text-muted" />
            <input
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              placeholder="Search model, domain, activity, machine…"
              className="w-56 max-w-full rounded-lg border border-border bg-surface py-1.5 pl-8 pr-7 text-xs text-text-primary placeholder:text-text-muted focus:border-accent-border focus:outline-none"
            />
            {query && (
              <button onClick={() => setQuery("")} className="absolute right-2 top-1/2 -translate-y-1/2 text-text-muted hover:text-accent" aria-label="clear search">
                <X className="h-3.5 w-3.5" />
              </button>
            )}
          </div>
          <div className="inline-flex max-w-full flex-wrap overflow-hidden rounded-lg border border-border">
            {(["cost", "tokens", "turns"] as const).map((m) => (
              <button key={m} onClick={() => setMetric(m)}
                className={`px-3 py-1 text-xs font-medium ${metric === m ? "bg-accent text-background" : "bg-surface text-text-secondary hover:bg-surface-strong"}`}>
                {m === "cost" ? "Cost" : m === "tokens" ? "Tokens" : "Turns"}
              </button>
            ))}
          </div>
          <div className="inline-flex max-w-full flex-wrap overflow-hidden rounded-lg border border-border">
            {RANGES.map((r) => (
              <button key={r.id} onClick={() => setRange(r.id)}
                className={`px-3 py-1 text-xs font-medium ${range === r.id ? "bg-accent-soft text-accent" : "bg-surface text-text-secondary hover:bg-surface-strong"}`}>
                {r.label}
              </button>
            ))}
          </div>
        </div>
  );
  const detailBody = (
    <div className={`flex flex-col gap-5 ${embedded ? "" : phone ? "px-4 py-4" : "w-full px-8 py-6"}`} data-testid="usage-detail">
      {embedded && <div className="flex min-w-0 justify-end">{controls}</div>}
      {!embedded && <h2 className={DETAIL_TITLE}>{viewLabel}</h2>}
      {view === "overview" && ai && ai.total.tokens > 0 && <AllToolsPanel data={ai} />}
      {empty ? (
        <p className={META}>
          No usage recorded yet. Run a chat, council, or benchmark and it will show up here.
        </p>
      ) : filtered.length === 0 ? (
        <p className={META}>
          Nothing matches the current search, filters, or time range.
          <button onClick={() => { setQuery(""); setFilters({}); setRange("all"); }} className="ml-1 underline underline-offset-2 hover:text-accent">Reset</button>
        </p>
      ) : (
        <>
          {/* Summary tiles */}
          {view === "overview" && <div className="grid grid-cols-2 gap-x-6 gap-y-3 border-t border-border-subtle pt-4 sm:grid-cols-4">
            {[
              { l: "Turns", v: fmtNum(totals.turns) },
              { l: "Tokens (in / out)", v: `${fmtTok(totals.inTok)} / ${fmtTok(totals.outTok)}` },
              { l: "Est. cost (Glyph Studio turns)", v: fmtCost(totals.cost) },
              { l: "Active days", v: `${totals.days.size}` },
            ].map((t) => (
              <div key={t.l} className="min-w-0">
                <div className="text-[15px] font-semibold tabular-nums text-text-primary">{t.v}</div>
                <div className="mt-0.5 text-[12px] text-text-muted">{t.l}</div>
              </div>
            ))}
          </div>}

          {/* Active filters */}
          {activeFilterCount > 0 && (
            <div className="flex flex-wrap items-center gap-x-3 gap-y-1 text-[12px]">
              <Filter className="h-3.5 w-3.5 text-accent" />
              <span className="text-[12px] font-medium text-accent">Filtered:</span>
              {DIMS.flatMap((d) => [...(filters[d.id] ?? [])].map((v) => (
                <button key={`${d.id}:${v}`} onClick={() => toggleFilter(d.id, v)}
                  className="inline-flex items-center gap-1 text-text-primary hover:text-accent">
                  <span className="text-text-muted">{d.label}:</span> {v} <X className="h-3 w-3" />
                </button>
              )))}
              <button onClick={() => setFilters({})} className="ml-1 text-[12px] text-text-muted underline underline-offset-2 hover:text-accent">Clear all</button>
            </div>
          )}

          {/* Over time */}
          {view === "overview" && <Panel title={`${metricLabel} over time`}>
            <TimeSeries data={series} fmt={fmtMetric} />
          </Panel>}

          {/* Breakdown (group-by) */}
          {view !== "overview" && <Panel title={`${metricLabel} by ${DIMS.find((d) => d.id === groupBy)?.label.toLowerCase()}`}
            right={
              <div className="flex items-center gap-1.5">
                <button onClick={() => setSortDesc((v) => !v)} className="text-[12px] text-text-muted hover:text-accent">
                  {sortDesc ? "High to low" : "Low to high"}
                </button>
              </div>
            }>
            <div className="flex flex-col gap-1.5">
              {breakdown.rows.map((r) => {
                const v = breakdown.val(r);
                return (
                  <button key={r.key} onClick={() => toggleFilter(groupBy, r.key)}
                    title={`Filter to ${r.key}`}
                    className="group grid grid-cols-[minmax(0,1fr)_auto] items-center gap-3 rounded-lg px-2 py-1.5 text-left hover:bg-surface-warm">
                    <div className="min-w-0">
                      <div className="flex items-center justify-between gap-2">
                        {/* A ledger row stores the model id it ran. Printed raw,
                            the list mixed "claude-opus-4-7" with "Gemini 3.1
                            Pro (High)" - the same thing named two ways in one
                            column. modelLabel turns an id into the name the
                            rest of the app uses; anything else passes through. */}
                        <span className="truncate text-[13px] text-text-primary">{rowLabel(groupBy, r.key)}</span>
                        <span className="shrink-0 text-xs tabular-nums text-text-secondary">{fmtMetric(v)}</span>
                      </div>
                      <div className="mt-1 h-1.5 overflow-hidden rounded-full bg-surface-strong">
                        <div className="h-full rounded-full bg-accent" style={{ width: `${(v / breakdown.max) * 100}%` }} />
                      </div>
                    </div>
                    <span className="text-[12px] tabular-nums text-text-muted">{r.turns}×</span>
                  </button>
                );
              })}
            </div>
          </Panel>}

          {/* Heatmap */}
          {view === "overview" && <Panel title="When you use it" subtitle="weekday × hour of day">
            <Heatmap grid={heatGrid.grid} max={heatGrid.max} fmt={fmtMetric} />
          </Panel>}

          {/* Activity map (cross-tab) */}
          {view === "overview" && <Panel title="Activity map"
            right={
              <div className="flex items-center gap-1.5 text-[12px] text-text-muted">
                <select value={crossY} onChange={(e) => setCrossY(e.target.value as DimId)} className="rounded-md border border-border bg-surface px-1.5 py-1 text-xs text-text-primary">
                  {DIMS.map((d) => <option key={d.id} value={d.id}>{d.label}</option>)}
                </select>
                <span>×</span>
                <select value={crossX} onChange={(e) => setCrossX(e.target.value as DimId)} className="rounded-md border border-border bg-surface px-1.5 py-1 text-xs text-text-primary">
                  {DIMS.map((d) => <option key={d.id} value={d.id}>{d.label}</option>)}
                </select>
              </div>
            }>
            <CrossTab {...cross} fmt={fmtMetric} />
          </Panel>}
          {error && <p className="text-[12px] text-text-muted">Some data couldn't load: {error}</p>}
        </>
      )}
    </div>
  );
  // Embedded in the Activity page: that page's column lists the views.
  if (embedded) return detailBody;
  return (
    <>
      <SettingsHeader title="Usage" icon={BarChart3} subtitle="What your models cost and how much you use them." right={controls} />
      <SideSpine storageKey="prevail.usage.spine" title="Views" label="usage views" testId="usage-list"
        phone={phone} phoneDetail={phone && picked} onBack={() => setPicked(false)} backLabel="All views"
        detail={detailBody}>
        {viewList}
      </SideSpine>
    </>
  );
}

function Panel({ title, subtitle, right, children }: { title: string; subtitle?: string; right?: React.ReactNode; children: React.ReactNode }) {
  return (
    <section className="border-t border-border-subtle pt-4">
      <div className="mb-3 flex items-center justify-between gap-3">
        <div>
          <h3 className={SECTION_TITLE}>{title}</h3>
          {subtitle && <p className="text-[12px] text-text-muted">{subtitle}</p>}
        </div>
        {right}
      </div>
      {children}
    </section>
  );
}

function TimeSeries({ data, fmt }: { data: { day: string; v: number }[]; fmt: (v: number) => string }) {
  const w = 720, h = 120, pad = 4;
  const max = Math.max(1, ...data.map((d) => d.v));
  const n = data.length;
  const x = (i: number) => pad + (i / Math.max(1, n - 1)) * (w - 2 * pad);
  const y = (v: number) => h - pad - (v / max) * (h - 2 * pad);
  const line = data.map((d, i) => `${i === 0 ? "M" : "L"}${x(i).toFixed(1)},${y(d.v).toFixed(1)}`).join(" ");
  const area = `${line} L${x(n - 1).toFixed(1)},${h - pad} L${x(0).toFixed(1)},${h - pad} Z`;
  const peak = data.reduce((a, b) => (b.v > a.v ? b : a), data[0] ?? { day: "", v: 0 });
  return (
    <div className="overflow-x-auto">
      <svg viewBox={`0 0 ${w} ${h + 16}`} className="w-full" style={{ minWidth: 420 }} role="img" aria-label="usage over time">
        <path d={area} fill="color-mix(in srgb, var(--color-accent) 12%, transparent)" />
        <path d={line} fill="none" stroke="var(--color-accent)" strokeWidth="1.5" />
        {peak.v > 0 && <circle cx={x(data.indexOf(peak))} cy={y(peak.v)} r="2.5" fill="var(--color-accent)" />}
        <text x={pad} y={h + 12} className="fill-current text-[9px] text-text-muted">{data[0]?.day.slice(5)}</text>
        <text x={w - pad} y={h + 12} textAnchor="end" className="fill-current text-[9px] text-text-muted">{data[n - 1]?.day.slice(5)}</text>
      </svg>
      <div className="mt-1 text-[12px] text-text-muted">Peak: <span className="text-text-secondary">{fmt(peak.v)}</span> on {peak.day}</div>
    </div>
  );
}

function Heatmap({ grid, max, fmt }: { grid: number[][]; max: number; fmt: (v: number) => string }) {
  const dows = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
  return (
    <div className="overflow-x-auto">
      <div style={{ minWidth: 560 }}>
        <div className="grid" style={{ gridTemplateColumns: `34px repeat(24, 1fr)`, gap: 2 }}>
          <div />
          {Array.from({ length: 24 }, (_, hh) => (
            <div key={hh} className="text-center text-[10px] text-text-muted">{hh % 3 === 0 ? hh : ""}</div>
          ))}
          {grid.map((rowArr, d) => (
            <Fragment key={d}>
              <div className="pr-1 text-right text-[12px] leading-4 text-text-muted">{dows[d]}</div>
              {rowArr.map((v, hh) => (
                <div key={`${d}-${hh}`} title={`${dows[d]} ${hh}:00: ${fmt(v)}`}
                  className="aspect-square rounded-[2px] border border-border-subtle/40"
                  style={{ backgroundColor: heat(v / max) }} />
              ))}
            </Fragment>
          ))}
        </div>
      </div>
    </div>
  );
}

function CrossTab({ rows, cols, cell, max, fmt }: { rows: string[]; cols: string[]; cell: Map<string, number>; max: number; fmt: (v: number) => string }) {
  if (!rows.length || !cols.length) return <p className="text-xs text-text-muted">Not enough data for a cross-tab.</p>;
  return (
    <div className="overflow-x-auto">
      <table className="border-collapse text-[12px]">
        <thead>
          <tr>
            <th className="sticky left-0 bg-surface p-1" />
            {cols.map((c) => <th key={c} className="max-w-[90px] truncate px-1.5 py-1 text-left text-[10px] font-normal text-text-muted" title={c}>{c}</th>)}
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => (
            <tr key={r}>
              <td className="sticky left-0 max-w-[110px] truncate bg-surface pr-2 text-[10px] text-text-secondary" title={r}>{r}</td>
              {cols.map((c) => {
                const v = cell.get(`${r}||${c}`) ?? 0;
                return (
                  <td key={c} className="p-0.5">
                    <div className="flex h-7 min-w-[44px] items-center justify-center rounded-[3px] text-[10px] tabular-nums text-text-primary"
                      style={{ backgroundColor: heat(v / max) }} title={`${r} × ${c}: ${fmt(v)}`}>
                      {v > 0 ? fmt(v) : ""}
                    </div>
                  </td>
                );
              })}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
