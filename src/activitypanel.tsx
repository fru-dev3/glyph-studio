// System Activity (Settings -> Automation): one feed of everything Prevail does
// on its own. "Running now" is live (the in-memory process registry); the
// history below is the persistent ledger the engine appends to
// (_meta/activity.jsonl) - loop runs, executed approvals, tasks filed by loops,
// briefings, app syncs. Full transparency into the autonomous system, at scale.
import { useCallback, useEffect, useMemo, useState } from "react";
import { VirtualRows } from "./virtualrows";
import { Activity, ArrowUpRight, ChevronRight, ListPlus, Loader2, Mail, RefreshCw, RotateCw, Zap, Repeat, Bell, Workflow, CornerDownRight } from "lucide-react";
import { invoke } from "./bridge";
import { invokeCached, peekInvoke } from "./query";
import { titleCase, relTime } from "./format";
import { useProcesses } from "./processes";
import { SettingsHeader } from "./sectionutil";
import { SideSpine } from "./sidespine";
import { useIsPhone } from "./useisphone";
import { USAGE_VIEWS, UsageDashboard, type UsageView } from "./usagedashboard";
import type { EngineApp } from "./types";
import { DETAIL_TITLE } from "./typescale";
import { TintIcon } from "./tint";

// These mirror the engine's activity-ledger producer types (cli activity.ts).
// Keep them in lockstep: any type the engine writes must be representable here,
// or the event falls through to the generic "other" label and can't be filtered.
type ActivityType = "loop_run" | "loop_exec" | "task_filed" | "briefing" | "sync" | "nudge" | "playbook" | "playbook_step" | "job" | "other";
interface ActivityEvent {
  ts: number;
  type: ActivityType;
  domain?: string;
  title: string;
  detail?: string;
  status?: "ok" | "error" | "pending";
  ref?: string;
  // The ledger (_meta/activity.jsonl) can carry richer per-event fields than the
  // typed core above: the loop/app/skill name behind the event, a summary,
  // outcome flags, error text, artifact lists/counts, and various ids. We don't
  // know them all ahead of time, so the drill-down reads whatever is present.
  [extra: string]: unknown;
}

// Core fields we render with friendly labels and in a deliberate order at the
// top of the drill-down. Anything else on the record is surfaced afterwards as
// "Additional detail" so no field is ever hidden from the user.
const KNOWN_FIELDS: { key: string; label: string }[] = [
  { key: "type", label: "Kind" },
  { key: "domain", label: "Domain" },
  { key: "title", label: "Title" },
  { key: "detail", label: "Detail" },
  { key: "status", label: "Outcome" },
  { key: "ref", label: "Reference" },
];

// Fields shown elsewhere in the row header / handled specially, so we skip them
// when listing the remaining "additional" record fields.
const SKIP_EXTRA = new Set(["ts", ...KNOWN_FIELDS.map((f) => f.key)]);

// Turn a snake_case / camelCase key into a readable label ("loop_name" ->
// "Loop name", "appId" -> "App id").
function fieldLabel(key: string): string {
  const spaced = key
    .replace(/[_-]+/g, " ")
    .replace(/([a-z0-9])([A-Z])/g, "$1 $2")
    .trim();
  return spaced ? spaced[0].toUpperCase() + spaced.slice(1) : key;
}

// Present any value as a tidy string for the detail block. Objects/arrays are
// JSON-stringified so artifact lists and counts stay legible.
function fieldValue(v: unknown): string {
  if (v === null || v === undefined) return "";
  if (typeof v === "string") return v;
  if (typeof v === "number" || typeof v === "boolean") return String(v);
  try {
    return JSON.stringify(v, null, 2);
  } catch {
    return String(v);
  }
}

// A small label / value row reused for every field in the drill-down.
function DetailRow({ label, value }: { label: string; value: string }) {
  const multiline = value.includes("\n");
  return (
    <div className="grid grid-cols-[7rem_1fr] gap-2 py-1">
      <div className="text-[12px] text-text-muted">{label}</div>
      {multiline ? (
        <pre className="whitespace-pre-wrap break-words text-[12px] leading-relaxed text-text-secondary">{value}</pre>
      ) : (
        <div className="break-words text-[12px] leading-relaxed text-text-secondary">{value}</div>
      )}
    </div>
  );
}

// The expanded panel for one activity: full timestamp plus every field the
// record carries, in a tidy key/value layout. Falls back to a friendly note
// when the record has nothing beyond what the row already showed.
function ActivityDetail({ event }: { event: ActivityEvent }) {
  const meta = TYPE_META[event.type] ?? TYPE_META.other;
  const when = new Date(event.ts);
  const whenStr = Number.isFinite(when.getTime()) ? when.toLocaleString() : String(event.ts);

  const knownRows = KNOWN_FIELDS
    .map((f) => ({ ...f, value: fieldValue(event[f.key]) }))
    .filter((f) => f.value !== "")
    .map((f) => ({
      label: f.label,
      value: f.key === "type" ? meta.label : f.key === "domain" ? titleCase(String(event.domain)) : f.value,
    }));

  const extraRows = Object.keys(event)
    .filter((k) => !SKIP_EXTRA.has(k))
    .map((k) => ({ label: fieldLabel(k), value: fieldValue(event[k]) }))
    .filter((r) => r.value !== "");

  // "When" always exists; if that is genuinely all we have, say so plainly.
  const hasMore = knownRows.length > 0 || extraRows.length > 0;

  return (
    <div className="mt-2 rounded-lg border border-border-subtle bg-surface px-3 py-2">
      <DetailRow label="When" value={whenStr} />
      {knownRows.map((r) => <DetailRow key={`k-${r.label}`} label={r.label} value={r.value} />)}
      {extraRows.length > 0 && (
        <>
          <div className="mt-2 mb-0.5 text-[12px] font-semibold text-text-muted">Additional detail</div>
          {extraRows.map((r) => <DetailRow key={`x-${r.label}`} label={r.label} value={r.value} />)}
        </>
      )}
      {!hasMore && (
        <div className="mt-1 text-[12px] italic leading-relaxed text-text-muted">No further detail recorded for this event.</div>
      )}
    </div>
  );
}

const TYPE_META: Record<ActivityType, { label: string; icon: typeof Activity; tint: string }> = {
  loop_run:   { label: "Loop run",   icon: Repeat,   tint: "text-accent" },
  loop_exec:  { label: "Action taken", icon: Zap,      tint: "text-warn" },
  task_filed: { label: "Task filed", icon: ListPlus, tint: "text-ok" },
  briefing:   { label: "Briefing",   icon: Mail,     tint: "text-accent" },
  sync:       { label: "App sync",   icon: RotateCw, tint: "text-text-secondary" },
  nudge:      { label: "Nudge",      icon: Bell,     tint: "text-text-secondary" },
  playbook:      { label: "Playbook",      icon: Workflow,        tint: "text-accent" },
  playbook_step: { label: "Playbook step", icon: CornerDownRight, tint: "text-text-secondary" },
  job:        { label: "Job",        icon: Workflow, tint: "text-accent" },
  other:      { label: "Event",      icon: Activity, tint: "text-text-muted" },
};

const FILTERS: { id: ActivityType | "all"; label: string }[] = [
  { id: "all", label: "All" },
  { id: "loop_run", label: "Loop runs" },
  { id: "loop_exec", label: "Actions taken" },
  { id: "task_filed", label: "Tasks" },
  { id: "briefing", label: "Briefings" },
  { id: "sync", label: "Syncs" },
  { id: "playbook", label: "Playbooks" },
  { id: "job", label: "Jobs" },
  { id: "nudge", label: "Nudges" },
  { id: "other", label: "Other" },
];

// The label on each row's "jump to source" link, by event kind. Every
// autonomous event traces back to a real surface (its loop, the task board, the
// domain it briefed, the app it synced), so every row is navigable.
const SOURCE_LABEL: Partial<Record<ActivityType, string>> = {
  loop_run: "Open loop",
  loop_exec: "Open loop",
  playbook: "Open loop",
  playbook_step: "Open loop",
  nudge: "Open loop",
  task_filed: "Open tasks",
  briefing: "Open journal",
  sync: "Open app",
};

// Route an activity event back to the surface that produced it, reusing the
// same window-event nav vocabulary the rest of the shell already listens to.
// `ref`/`domain` on the event carry the loop id, app id, or domain we need.
async function openActivitySource(e: ActivityEvent, vaultPath: string): Promise<void> {
  const dom = typeof e.domain === "string" ? e.domain : "";
  switch (e.type) {
    case "loop_run":
    case "loop_exec":
    case "playbook":
    case "playbook_step":
    case "nudge":
      // Playbooks replace loops: a run opens the Playbooks page.
      window.dispatchEvent(new CustomEvent("prevail:work-section", { detail: "playbooks" }));
      return;
    case "task_filed":
      window.dispatchEvent(new CustomEvent("prevail:open-settings", { detail: "task-list" }));
      return;
    case "briefing":
      if (dom) {
        window.dispatchEvent(new CustomEvent("prevail:open-domain", { detail: dom }));
        window.dispatchEvent(new CustomEvent("prevail:domain-tab", { detail: "journal" }));
      } else {
        window.dispatchEvent(new CustomEvent("prevail:settings-section", { detail: "activity" }));
      }
      return;
    case "sync": {
      const key = (typeof e.ref === "string" && e.ref) || (typeof e.appId === "string" ? e.appId : "") || dom;
      try {
        const apps = await invoke<EngineApp[]>("engine_apps_list", { vault: vaultPath });
        const a = Array.isArray(apps)
          ? apps.find((x) => x.id === key || x.title?.toLowerCase() === String(key).toLowerCase())
          : undefined;
        if (a) { window.dispatchEvent(new CustomEvent("prevail:open-app", { detail: a })); return; }
      } catch { /* fall through to the Apps list */ }
      window.dispatchEvent(new CustomEvent("prevail:open-settings", { detail: "apps" }));
      return;
    }
    default:
      return;
  }
}

// The Playbooks run-level event and its per-step children both surface under the
// "All" view; there's no dedicated Playbooks tab.
function matchesType(eventType: ActivityType, filter: ActivityType | "all"): boolean {
  if (filter === "all") return true;
  if (filter === "playbook") return eventType === "playbook" || eventType === "playbook_step";
  return eventType === filter;
}

// The Activity page: what Prevail did on its own (by kind), then what your
// models cost (the Usage views). `initial` picks the first row: "usage:<view>"
// or an activity kind.
export function SystemActivity({ vaultPath, initial }: { vaultPath: string; initial?: string }) {
  const [usageView, setUsageView] = useState<UsageView | null>(() =>
    initial?.startsWith("usage:") ? ((USAGE_VIEWS.find((v) => v.id === initial.slice(6))?.id ?? "overview") as UsageView) : null);
  // Seeded from the shared cache so a revisit paints the last feed at once.
  const [events, setEvents] = useState<ActivityEvent[]>(() => {
    const c = peekInvoke<ActivityEvent[]>("activity_read", { vault: vaultPath, limit: 400 });
    return Array.isArray(c) ? c : [];
  });
  const [loading, setLoading] = useState(() => peekInvoke("activity_read", { vault: vaultPath, limit: 400 }) === undefined);
  const [typeFilter, setTypeFilter] = useState<ActivityType | "all">("all");
  const [domainFilter, setDomainFilter] = useState<string>("all");
  // Which history row is drilled into (a stable id per row). Null = none open.
  const [expandedId, setExpandedId] = useState<string | null>(null);
  const live = useProcesses();

  const load = useCallback(async () => {
    try {
      const rows = await invokeCached<ActivityEvent[]>("activity_read", { vault: vaultPath, limit: 400 }, { force: true });
      setEvents(Array.isArray(rows) ? rows : []);
    } catch { setEvents([]); }
    finally { setLoading(false); }
  }, [vaultPath]);

  useEffect(() => {
    load();
    // Refresh when the system reports it did something, plus a slow poll so
    // background daemon activity shows up without a manual reload.
    const onChange = () => load();
    window.addEventListener("prevail:loops-advanced", onChange);
    window.addEventListener("prevail:tasks-changed", onChange);
    const iv = window.setInterval(load, 15000);
    return () => {
      window.removeEventListener("prevail:loops-advanced", onChange);
      window.removeEventListener("prevail:tasks-changed", onChange);
      window.clearInterval(iv);
    };
  }, [load]);

  const domains = useMemo(() => {
    const s = new Set<string>();
    for (const e of events) if (e.domain) s.add(e.domain);
    return [...s].sort();
  }, [events]);

  const phone = useIsPhone();
  const [picked, setPicked] = useState(false);
  // Counts per kind, over the domain filter, for the side column. Kinds with
  // nothing recorded stay out of the way; All always shows.
  const counts = useMemo(() => {
    const c: Record<string, number> = {};
    for (const f of FILTERS) c[f.id] = events.filter((e) => matchesType(e.type, f.id) && (domainFilter === "all" || e.domain === domainFilter)).length;
    return c;
  }, [events, domainFilter]);
  const kinds = FILTERS.filter((f) => f.id === "all" || f.id === typeFilter || counts[f.id] > 0);
  const shown = useMemo(() => events.filter((e) =>
    matchesType(e.type, typeFilter) &&
    (domainFilter === "all" || e.domain === domainFilter),
  ), [events, typeFilter, domainFilter]);

  const kindList = (
    <nav className="space-y-0.5 p-2" aria-label="Activity kinds">
      <div className="px-2.5 pb-1 pt-2 text-[15px] font-semibold text-text-primary">Activity</div>
      {kinds.map((f) => {
        const on = !usageView && typeFilter === f.id && (!phone || picked);
        const Icon = f.id === "all" ? Activity : (TYPE_META[f.id as ActivityType] ?? TYPE_META.other).icon;
        return (
          <button key={f.id} data-testid={`activity-kind-${f.id}`} aria-current={on ? "true" : undefined}
            onClick={() => { setUsageView(null); setTypeFilter(f.id); setPicked(true); setExpandedId(null); }}
            className={`flex w-full items-center gap-2.5 rounded-lg px-2.5 py-2 text-left transition-colors ${on ? "bg-surface-warm" : "hover:bg-surface-warm/50"}`}>
            <TintIcon icon={Icon} />
            <span className={`min-w-0 flex-1 truncate text-sm ${on ? "font-semibold text-text-primary" : "text-text-secondary"}`}>{f.label}</span>
            <span className="text-[13px] tabular-nums text-text-muted">{counts[f.id]}</span>
          </button>
        );
      })}
      <div className="px-2.5 pb-1 pt-4 text-[15px] font-semibold text-text-primary">Usage</div>
      {USAGE_VIEWS.map((v) => {
        const on = usageView === v.id && (!phone || picked);
        const Icon = v.icon;
        return (
          <button key={v.id} data-testid={`usage-view-${v.id}`} aria-current={on ? "true" : undefined}
            onClick={() => { setUsageView(v.id); setPicked(true); }}
            className={`flex w-full items-center gap-2.5 rounded-lg px-2.5 py-2 text-left transition-colors ${on ? "bg-surface-warm" : "hover:bg-surface-warm/50"}`}>
            <TintIcon icon={Icon} />
            <span className={`min-w-0 flex-1 truncate text-sm ${on ? "font-semibold text-text-primary" : "text-text-secondary"}`}>{v.label}</span>
          </button>
        );
      })}
    </nav>
  );
  const kindLabel = usageView ? (USAGE_VIEWS.find((v) => v.id === usageView)?.label ?? "Overview") : FILTERS.find((f) => f.id === typeFilter)?.label ?? "All";

  return (
    <>
      <SettingsHeader
        icon={Activity}
        title="Activity"
        subtitle="What Glyph Studio did on its own, and what your models cost."
      />
      <SideSpine storageKey="prevail.activity.spine" title="Show" label="activity" testId="activity-list"
        actions={
          <button onClick={load} disabled={loading} title="Refresh" aria-label="Refresh activity" data-testid="activity-refresh"
            className="rounded-md p-1.5 text-text-muted transition-colors hover:bg-surface-warm hover:text-accent disabled:opacity-50">
            <RefreshCw className={`h-4 w-4 ${loading ? "animate-spin" : ""}`} />
          </button>
        }
        phone={phone} phoneDetail={phone && picked} onBack={() => setPicked(false)} backLabel="Back"
        detail={<div className={`space-y-5 ${phone ? "px-4 py-4" : "w-full px-8 py-6"}`} data-testid="activity-detail">
      <h2 className={DETAIL_TITLE}>{kindLabel}{!usageView && shown.length > 0 && <span className="ml-2 font-sans text-[13px] font-normal tabular-nums text-text-muted">{shown.length}</span>}</h2>
      {usageView ? <UsageDashboard vaultPath={vaultPath} embedded view={usageView} /> : (<>
      {/* Running now - the live, in-flight processes (not yet in history). */}
      {/* Shown only while something runs; an empty "nothing running" box said nothing. */}
      {live.length > 0 && (
      <section>
        <h3 className="mb-1.5 text-[15px] font-semibold text-text-primary">Running now</h3>
          <ul className="divide-y divide-border-subtle">
            {live.map((p) => (
              <li key={p.id} className="flex items-center gap-2 py-2">
                <Loader2 className="h-3.5 w-3.5 shrink-0 animate-spin text-accent" />
                <span className="flex-1 truncate text-[14px] text-text-primary">{p.label}</span>
                <span className="shrink-0 text-[12px] text-text-muted">{p.kind}</span>
              </li>
            ))}
          </ul>
      </section>
      )}

      {/* The domain filter, when there is more than one place to filter by. */}
      {domains.length > 0 && (
      <div className="flex flex-wrap items-center gap-x-3 gap-y-2">
        {(
          <select value={domainFilter} onChange={(e) => setDomainFilter(e.target.value)}
            className="rounded-lg border border-border bg-background px-2.5 py-1.5 text-xs text-text-secondary transition-colors hover:border-accent-border focus:border-accent-border focus:outline-none">
            <option value="all">All domains</option>
            {domains.map((d) => <option key={d} value={d}>{titleCase(d)}</option>)}
          </select>
        )}
      </div>
      )}

      {/* History feed */}
      <section>
        {live.length > 0 && <h3 className="mb-1.5 text-[15px] font-semibold text-text-primary">History</h3>}
        {loading ? (
          <div className="text-[12px] text-text-muted">Loading activity…</div>
        ) : shown.length === 0 ? (
          <p className="text-[12px] text-text-muted">Nothing yet. Loop runs, approvals you allowed and briefings appear here as they happen.</p>
        ) : (
          <ul className="space-y-0 border-l border-border-subtle pl-4">
            <VirtualRows items={shown} estimate={56} getKey={(e, i) => `${e.ts}-${i}`} render={(e, i) => {
              const m = TYPE_META[e.type] ?? TYPE_META.other;
              const Icon = m.icon;
              const id = `${e.ts}-${i}`;
              const open = expandedId === id;
              return (
                <li key={id} className={`relative ${i === shown.length - 1 ? "pb-0" : "pb-3.5"}`}>
                  <span className={`absolute -left-[21px] top-0.5 flex h-3.5 w-3.5 items-center justify-center rounded-full bg-surface ring-2 ring-surface ${e.status === "error" ? "text-err" : m.tint}`}>
                    <Icon className="h-3 w-3" />
                  </span>
                  <div className="group -mx-2 flex items-start rounded-lg transition-colors hover:bg-surface-warm">
                    <button type="button" aria-expanded={open}
                      onClick={() => setExpandedId(open ? null : id)}
                      className="flex min-w-0 flex-1 items-start gap-2 px-2 py-1 text-left">
                      <ChevronRight className={`mt-0.5 h-3.5 w-3.5 shrink-0 text-text-muted transition-transform group-hover:text-text-secondary ${open ? "rotate-90" : ""}`} />
                      <div className="min-w-0 flex-1">
                        <div className="flex flex-wrap items-center gap-1 text-[12px] text-text-muted">
                          <span className={m.tint}>{m.label}</span>
                          {e.domain && <span>· {titleCase(e.domain)}</span>}
                          <span>· {relTime(e.ts)}</span>
                          {e.status === "error" && <span className="text-err">Failed</span>}
                          {e.status === "pending" && <span className="text-warn">Needs setup</span>}
                        </div>
                        {/* A filed task writes its whole rationale into the
                            title. Two lines collapsed keeps the row a row; the
                            expansion carries the rest. */}
                        <div title={e.title} className={`mt-0.5 text-[14px] leading-snug text-text-primary ${open ? "" : "line-clamp-2"}`}>{e.title}</div>
                        {/* One line collapsed. A loop run writes a paragraph of
                            its own reasoning, and four hundred of those stacked
                            is not a timeline, it is a transcript you cannot
                            scan. Expanding shows the whole thing. */}
                        {e.detail && (
                          <div className={`mt-0.5 text-[12px] leading-relaxed text-text-muted ${open ? "" : "line-clamp-1"}`}>{e.detail}</div>
                        )}
                      </div>
                    </button>
                  </div>
                  {open && (
                    <>
                      <ActivityDetail event={e} />
                      {SOURCE_LABEL[e.type] && (
                        <button type="button"
                          onClick={() => { void openActivitySource(e, vaultPath); }}
                          title={`${SOURCE_LABEL[e.type]}: go to the source of this event`}
                          className="mt-1.5 inline-flex items-center gap-1 text-[13px] font-medium text-text-secondary transition-colors hover:text-accent">
                          {SOURCE_LABEL[e.type]}<ArrowUpRight className="h-3 w-3" />
                        </button>
                      )}
                    </>
                  )}
                </li>
              );
            }} />
          </ul>
        )}
      </section>
      </>)}
      </div>}>
        {kindList}
      </SideSpine>
    </>
  );
}
