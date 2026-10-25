// Intent > Projects. Everything the user has been building, from their
// whole prompt history across every AI tool, each with a restart brief a future
// model can rebuild it from. The engine does the work (`prevail projects`);
// this view reads the index, shows a project's arc, and hands out the replay
// prompt. The raw prompts stay untouched in the capture streams; each pack
// keeps a readable copy (prompts.md) and an exact one (prompts.jsonl).
import { useEffect, useMemo, useState } from "react";
import {
  ArrowRight, Check, Lightbulb, Loader2, RefreshCw, Sparkles, Target, type LucideIcon,
} from "lucide-react";
import { invoke } from "./bridge";
import { hasInvoke, invokeCached, invokeKey, peekInvoke, setQueryData } from "./query";
import { titleCase } from "./format";
import { domainColor } from "./helpers";
import { domainIcon } from "./icons";
import { useIsPhone } from "./useisphone";
import { SideSpine } from "./sidespine";
import { BODY, DETAIL_TITLE, DetailTitle, META, SECTION_TITLE } from "./typescale";
import { RowMenu, StatusDot, type DotTone } from "./ui";
import { RequirementsPane, RestartCard, TechnicalDetails, useRestart } from "./mirrorrestart";
import type { HistoryDoc } from "./mirror";
import { createMission, missionFor, openMission, useMissions } from "./missions";
import { openProject } from "./recmodel";

export interface ProjectIntent { title: string; goal: string; status: string }
export interface ProjectEntry {
  slug: string; title: string; domain: string; kind: string; summary: string;
  status: "active" | "dormant" | "done";
  prompt_count: number; first_ts: number; last_ts: number;
  monthly: Record<string, number>; weekly?: Record<string, number>; tools: Record<string, number>;
  pack_dir: string; brief_model: string; brief_ts: number;
  intents: ProjectIntent[]; takeaways: string[]; ideas: string[]; open_questions: string[];
}
export interface Recommendation { kind: "task" | "skill" | "app" | "habit" | "automation" | "project"; title: string; why: string; domain?: string; project?: string; project_slug?: string }
export interface ProjectsIndex {
  generated_ts: number; model: string;
  stats?: { records: number; kept: number; internal: number; program?: number; projects: number; unassigned: number };
  months?: Record<string, number>;
  projects: ProjectEntry[]; recommendations: Recommendation[]; recommendations_model?: string;
}

const STATUS_DOT: Record<ProjectEntry["status"], DotTone> = { active: "ok", dormant: "muted", done: "accent" };
// The model words intent status freely ("in progress", "shipped", "open").
export function statusKind(s: string): ProjectEntry["status"] {
  const l = s.toLowerCase();
  if (/done|resolved|complete|shipped|finished|closed/.test(l)) return "done";
  if (/active|progress|ongoing|open|doing|started/.test(l)) return "active";
  return "dormant";
}
export const nPrompts = (n: number) => `${n.toLocaleString()} prompt${n === 1 ? "" : "s"}`;

// Every Monday from the first week to the last (keys match the engine's).
export function weekSpan(first: number, last: number): string[] {
  const monday = (ts: number) => { const d = new Date(ts); d.setHours(0, 0, 0, 0); d.setDate(d.getDate() - ((d.getDay() + 6) % 7)); return d; };
  const out: string[] = [];
  const d = monday(first);
  const end = monday(last);
  while (d <= end && out.length < 60) {
    out.push(`${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`);
    d.setDate(d.getDate() + 7);
  }
  return out;
}

// Prompts over time: weekly bars for a history under four months (a single
// monthly bar says nothing), monthly beyond that.
function ActivityChart({ p }: { p: ProjectEntry }) {
  const weekly = p.weekly && p.last_ts - p.first_ts < 120 * 864e5;
  const keys = weekly ? weekSpan(p.first_ts, p.last_ts) : monthSpan(p.first_ts, p.last_ts);
  const counts = weekly ? p.weekly! : p.monthly;
  const max = Math.max(1, ...keys.map((k) => counts[k] ?? 0));
  const label = (k: string) => weekly
    ? new Date(`${k}T12:00:00`).toLocaleDateString(undefined, { month: "short", day: "numeric" })
    : new Date(`${k}-15T12:00:00`).toLocaleDateString(undefined, { month: "short" });
  const every = Math.max(1, Math.ceil(keys.length / 8)); // label at most ~8 ticks
  const color = domainColor(p.domain);
  return (
    <div className="mt-5">
      <div className={`${META} mb-3`}>Prompts per {weekly ? "week" : "month"}</div>
      <div className="flex h-20 items-end gap-1">
        {keys.map((k, i) => {
          const n = counts[k] ?? 0;
          return (
            <div key={k} className="flex h-full min-w-0 flex-1 flex-col items-center justify-end gap-1" title={`${label(k)}: ${nPrompts(n)}`}>
              {n > 0 && <span className="text-[10px] tabular-nums text-text-muted">{n}</span>}
              <div className="w-full max-w-6 rounded-sm" style={{ height: n ? `${Math.max(4, (n / max) * 52)}px` : "2px", backgroundColor: n ? color : "var(--color-border)" }} />
              <span className="h-3 whitespace-nowrap text-[10px] text-text-muted">{i % every === 0 ? label(k) : ""}</span>
            </div>
          );
        })}
      </div>
    </div>
  );
}

// A project's title as a title, whatever case the model wrote it in: each
// word capitalized, small joining words kept low, acronyms and brands kept.
const SMALL = new Set(["a", "an", "the", "and", "or", "of", "to", "in", "on", "for", "with", "at", "by", "vs"]);
export function displayTitle(t: string): string {
  return t.trim().split(/(\s+)/).map((w, i) => {
    if (/^\s+$/.test(w) || !w) return w;
    if (i > 0 && SMALL.has(w.toLowerCase())) return w.toLowerCase();
    return /[A-Z]/.test(w.slice(1)) || /\./.test(w) ? w : w.charAt(0).toUpperCase() + w.slice(1);
  }).join("");
}

const fmtDay = (ts: number) => new Date(ts).toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" });
const fmtSpan = (a: number, b: number) => {
  const A = new Date(a); const B = new Date(b);
  const sameYear = A.getFullYear() === B.getFullYear();
  const left = A.toLocaleDateString(undefined, sameYear ? { month: "short", day: "numeric" } : { month: "short", day: "numeric", year: "numeric" });
  return `${left} to ${fmtDay(b)}`;
};
// "claude-fable-5-1" -> "Fable 5.1", "gpt-6-astra" -> "GPT-6 Astra"
export function modelName(id: string): string {
  const cap = (w: string) => w.charAt(0).toUpperCase() + w.slice(1);
  const g = id.match(/^gpt-(\d+(?:\.\d+)?)(?:-(.+))?$/i);
  if (g) return `GPT-${g[1]}${g[2] ? ` ${g[2].split("-").map(cap).join(" ")}` : ""}`;
  const m = id.replace(/^claude-/, "").match(/^([a-z]+)-(\d+)(?:-(\d+))?$/i);
  if (m) return `${cap(m[1])} ${m[2]}${m[3] ? `.${m[3]}` : ""}`;
  return id;
}

// Every month from the first to the last in `months`, so gaps show as gaps.
export function monthSpan(first: number, last: number): string[] {
  const out: string[] = [];
  const d = new Date(new Date(first).getFullYear(), new Date(first).getMonth(), 1);
  const end = new Date(new Date(last).getFullYear(), new Date(last).getMonth(), 1);
  while (d <= end && out.length < 120) {
    out.push(`${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}`);
    d.setMonth(d.getMonth() + 1);
  }
  return out;
}

function Sparkline({ monthly, months, color }: { monthly: Record<string, number>; months: string[]; color: string }) {
  const max = Math.max(1, ...months.map((m) => monthly[m] ?? 0));
  return (
    <div className="flex h-5 items-end gap-[2px]" aria-hidden>
      {months.map((m) => {
        const n = monthly[m] ?? 0;
        return <span key={m} className="w-1.5 rounded-sm" style={{ height: n ? `${Math.max(12, (n / max) * 100)}%` : "2px", backgroundColor: n ? color : "var(--color-border)" }} />;
      })}
    </div>
  );
}

// The project's badge in its detail header: a small tile with its domain's icon.
function ProjectBadge({ domain }: { domain: string }) {
  const c = domainColor(domain);
  const Icon = domainIcon(domain) ?? Target;
  return (
    <span aria-hidden className="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg border border-border bg-surface-warm" style={{ color: c }}>
      <Icon size={16} />
    </span>
  );
}

type ProjectTab = "overview" | "requirements" | "prompts" | "timeline";
const PROJECT_TABS: { id: ProjectTab; label: string }[] = [
  { id: "overview", label: "Overview" }, { id: "requirements", label: "Requirements" }, { id: "prompts", label: "Your prompts" }, { id: "timeline", label: "Timeline" },
];

// The project's own prompts, exactly as typed (the capture streams, through
// `intent history --project`), oldest first within each sitting.
function useProjectPrompts(vaultPath: string, slug: string, on: boolean) {
  const [doc, setDoc] = useState<HistoryDoc | null>(null);
  const [err, setErr] = useState<string | null>(null);
  useEffect(() => {
    if (!on || doc) return;
    let alive = true;
    invoke<HistoryDoc>("mirror_history", { vault: vaultPath, q: null, tool: null, project: slug, before: null, limit: 2000, week: null, day: null, tz: new Date().getTimezoneOffset() })
      .then((d) => { if (alive) setDoc(d && Array.isArray(d.weeks) ? d : { total: 0, tools: [], weeks: [] }); })
      .catch((e) => { if (alive) setErr(String(e)); });
    return () => { alive = false; };
  }, [vaultPath, slug, on, doc]);
  const sittings = useMemo(() => (doc?.weeks ?? []).flatMap((w) => w.sittings).sort((a, b) => b.start_ts - a.start_ts), [doc]);
  return { doc, err, sittings };
}

const fmtWhen = (ts: number) => new Date(ts).toLocaleString(undefined, { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });

// "Start a mission": makes a mission from this prompt project (your yes), or
// opens the one already made from it.
function TrackButton({ vaultPath, p, phone }: { vaultPath: string; p: ProjectEntry; phone: boolean }) {
  const { missions } = useMissions(vaultPath);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const tracked = missionFor(missions, p.slug);
  const track = async () => {
    setBusy(true); setErr(null);
    try { const made = await createMission(vaultPath, { name: displayTitle(p.title), fromPromptProject: p.slug }); if (made?.slug) openMission(made.slug); }
    catch (e) { setErr(String(e)); } finally { setBusy(false); }
  };
  const label = tracked ? "Open its project" : "Start a project";
  const Icon = busy ? Loader2 : Target;
  return (
    <button onClick={() => (tracked ? openMission(tracked.slug) : void track())} disabled={busy} data-testid="project-track" title={err ?? label} aria-label={label}
      className={`inline-flex h-8 shrink-0 items-center gap-1.5 text-[13px] font-medium hover:underline disabled:opacity-60 ${err ? "text-err" : "text-accent"}`}>
      <Icon className={`h-3.5 w-3.5 ${busy ? "animate-spin" : ""}`} />{!phone && label}
    </button>
  );
}

// A tracked project's Brief tab: the restart brief of the Intent project it
// came from, the same cards the Intent detail shows.
export function IntentBrief({ vaultPath, slug }: { vaultPath: string; slug: string }) {
  const phone = useIsPhone();
  const r = useRestart(vaultPath, slug);
  return (
    <div data-testid="project-brief" className="pb-6">
      <RestartCard r={r} phone={phone} />
      <h3 className={`${SECTION_TITLE} mt-7`}>Requirements</h3>
      <RequirementsPane r={r} phone={phone} />
      <TechnicalDetails r={r} phone={phone} />
      <button onClick={() => openProject(slug)} className="mt-6 inline-flex items-center gap-1.5 text-[13px] font-medium text-accent hover:underline">
        Open in Intent<ArrowRight className="h-3.5 w-3.5" />
      </button>
    </div>
  );
}

function ProjectDetail({ vaultPath, p, phone, building, onRewrite }: { vaultPath: string; p: ProjectEntry; phone: boolean; building: string | null; onRewrite: () => void }) {
  const [tab, setTab] = useState<ProjectTab>("overview");
  const [seen, setSeen] = useState<Set<ProjectTab>>(new Set(["overview"]));
  const go = (t: ProjectTab) => { setTab(t); setSeen((s) => new Set(s).add(t)); };
  const r = useRestart(vaultPath, p.slug);
  const hist = useProjectPrompts(vaultPath, p.slug, seen.has("prompts") || seen.has("timeline"));
  const pane = (t: ProjectTab) => (tab === t ? "" : "hidden");
  const tools = Object.entries(p.tools).sort((x, y) => y[1] - x[1]).map(([t]) => titleCase(t)).join(", ");
  const histState = hist.err ? <p className="text-[13px] text-err">{hist.err}</p>
    : !hist.doc ? <div className="flex items-center gap-2 text-[14px] text-text-muted"><Loader2 className="h-4 w-4 animate-spin" />Reading your prompts</div>
    : hist.sittings.length === 0 ? <p className="text-[14px] text-text-muted">No prompts found for this project.</p> : null;
  return (
    <div data-testid="project-detail">
      {/* The header and tabs stay pinned while the pane scrolls. */}
      <div className={`sticky top-0 z-10 bg-background ${phone ? "-mx-4 -mt-4 px-4 pt-4" : "-mx-6 -mt-6 px-6 pt-6"}`}>
        <div className="flex items-center gap-3" data-testid="project-header">
          <ProjectBadge domain={p.domain} />
          <div className="min-w-0 flex-1">
            <DetailTitle className="truncate">{displayTitle(p.title)}</DetailTitle>
            <p className={`${META} truncate`}>
              {titleCase(p.status)} · {titleCase(p.domain)} · {nPrompts(p.prompt_count)} · {fmtSpan(p.first_ts, p.last_ts)} · {tools}
            </p>
          </div>
          <TrackButton vaultPath={vaultPath} p={p} phone={phone} />
          {building === p.slug
            ? <span className={`${META} inline-flex shrink-0 items-center gap-1.5`}><Loader2 className="h-3.5 w-3.5 animate-spin" />Rewriting</span>
            : <RowMenu items={[{ icon: RefreshCw, label: "Rewrite brief", disabled: !!building, onClick: onRewrite }]} />}
        </div>
        <div role="tablist" aria-label="Project" className="mt-4 flex overflow-x-auto border-b border-border-subtle">
          {PROJECT_TABS.map((t) => (
            <button key={t.id} role="tab" aria-selected={tab === t.id} data-testid={`project-tab-${t.id}`} onClick={() => go(t.id)}
              className={`-mb-px h-10 shrink-0 border-b-2 ${phone ? "px-2 text-[13px]" : "px-3 text-[14px]"} font-medium transition-colors ${tab === t.id ? "border-accent text-text-primary" : "border-transparent text-text-muted hover:text-text-secondary"}`}>
              {t.label}
              {t.id === "requirements" && r.doc && <span className="ml-1.5 text-[12px] font-normal text-text-muted">{(r.doc.requirements ?? []).length}</span>}
              {t.id === "prompts" && <span className="ml-1.5 text-[12px] font-normal text-text-muted">{p.prompt_count.toLocaleString()}</span>}
            </button>
          ))}
        </div>
      </div>

      <div className={pane("overview")} data-testid="project-overview">
        {p.summary && <p className={`${BODY} mt-5 text-text-secondary`}>{p.summary}</p>}
        <RestartCard r={r} phone={phone} />
        {p.intents.length > 0 && (
          <section className="mt-7">
            <h3 className={`${SECTION_TITLE} mb-1`}>Intents</h3>
            <div className="divide-y divide-border-subtle">
              {p.intents.map((it, i) => (
                <div key={i} className="flex items-start gap-3 py-2.5">
                  <div className="min-w-0 flex-1">
                    <div className="text-[14px] font-medium text-text-primary">{it.title}</div>
                    <div title={it.goal} className={`${META} mt-0.5 line-clamp-2 leading-snug`}>{it.goal}</div>
                  </div>
                  <StatusDot tone={STATUS_DOT[statusKind(it.status)]} label={titleCase(it.status)} className="mt-1" />
                </div>
              ))}
            </div>
          </section>
        )}
        <ListBlock icon={Check} title="Takeaways" items={p.takeaways} />
        <ListBlock icon={Lightbulb} title="Ideas not built yet" items={p.ideas} />
        <ListBlock icon={Target} title="Open questions" items={p.open_questions} />
        <TechnicalDetails r={r} phone={phone} />
      </div>

      <div className={pane("requirements")}><RequirementsPane r={r} phone={phone} /></div>

      <div className={pane("prompts")} data-testid="project-prompts">
        <div className="pt-5">
          {histState ?? (
            <ol className="space-y-4">
              {hist.sittings.map((st) => (
                <li key={st.id} className="border-t border-border-subtle pt-2">
                  <div className={`${META} flex items-center gap-2 py-1`}>
                    <span className="font-medium text-text-secondary">{titleCase(st.tool)}</span><span aria-hidden>·</span><span>{fmtWhen(st.start_ts)}</span>
                  </div>
                  <ul className="divide-y divide-border-subtle">
                    {st.prompts.map((q, i) => (
                      <li key={`${q.ts}-${i}`} data-testid="project-prompt" className="whitespace-pre-wrap break-words py-2 text-[14px] leading-normal text-text-primary">{q.text}</li>
                    ))}
                  </ul>
                </li>
              ))}
            </ol>
          )}
        </div>
      </div>

      <div className={pane("timeline")} data-testid="project-timeline">
        <ActivityChart p={p} />
        <div className="mt-5">
          {histState ?? (
            <ul className="divide-y divide-border-subtle">
              {hist.sittings.map((st) => (
                <li key={st.id} className="flex items-center gap-3 py-2.5 text-[14px]">
                  <span className="w-40 shrink-0 text-[12px] tabular-nums text-text-muted max-sm:w-24">{fmtWhen(st.start_ts)}</span>
                  <span title={st.prompts[0]?.text ?? ""} className="min-w-0 flex-1 truncate text-text-primary">{st.prompts[0]?.text ?? ""}</span>
                  <span className="shrink-0 text-[12px] text-text-muted">{titleCase(st.tool)} · {nPrompts(st.prompts.length)}</span>
                </li>
              ))}
            </ul>
          )}
        </div>
      </div>
    </div>
  );
}

function ListBlock({ icon: Icon, title, items }: { icon: LucideIcon; title: string; items: string[] }) {
  if (!items.length) return null;
  return (
    <section className="mt-7">
      <h3 className={`${SECTION_TITLE} mb-1.5 flex items-center gap-2`}><Icon className="h-4 w-4 text-text-muted" />{title}</h3>
      <ul className="space-y-1.5">
        {items.map((t, i) => <li key={i} className="flex gap-2.5 text-[14px] leading-snug text-text-secondary"><span className="mt-2 h-1 w-1 shrink-0 rounded-full bg-text-muted" />{t}</li>)}
      </ul>
    </section>
  );
}

export function ProjectsView({ vaultPath, initialSlug }: { vaultPath: string; initialSlug?: string }) {
  const phone = useIsPhone();
  // Seeded from the shared cache (the sidebar count reads the same index).
  const [idx, setIdx] = useState<ProjectsIndex | null>(() => peekInvoke<ProjectsIndex>("projects_index", { vault: vaultPath }) ?? null);
  const [loading, setLoading] = useState(() => !hasInvoke("projects_index", { vault: vaultPath }));
  const [err, setErr] = useState<string | null>(null);
  const [sel, setSel] = useState<string | null>(initialSlug ?? null); // slug, or null = overview
  const [show, setShow] = useState<"active" | "all">("all");
  const [building, setBuilding] = useState<string | null>(null);

  const load = () => {
    setLoading(true);
    invokeCached<ProjectsIndex>("projects_index", { vault: vaultPath })
      .then((d) => { setIdx(d); setErr(null); })
      .catch((e) => setErr(String(e)))
      .finally(() => setLoading(false));
  };
  useEffect(load, [vaultPath]);

  const build = async (slug?: string) => {
    setBuilding(slug ?? "all");
    try {
      const d = await invoke<ProjectsIndex>("projects_build", { vault: vaultPath, rebrief: !!slug, only: slug ? [slug] : null });
      setIdx(d); setErr(null);
      setQueryData(invokeKey("projects_index", { vault: vaultPath }), d);
    } catch (e) { setErr(String(e)); }
    finally { setBuilding(null); }
  };

  const projects = useMemo(() => (idx?.projects ?? []).filter((p) => show === "all" || p.status === "active"), [idx, show]);
  const months = useMemo(() => {
    const all = idx?.projects ?? [];
    if (!all.length) return [];
    return monthSpan(Math.min(...all.map((p) => p.first_ts)), Math.max(...all.map((p) => p.last_ts))).slice(-12);
  }, [idx]);
  const cur = (idx?.projects ?? []).find((p) => p.slug === sel) ?? null;

  if (loading && !idx) return <div className="p-8 text-[13px] text-text-muted">Reading your projects…</div>;
  if (!idx || idx.projects.length === 0) {
    return (
      <div className="mx-auto max-w-xl p-8">
        <h2 className={DETAIL_TITLE}>Turn your prompts into projects</h2>
        <p className={`${BODY} mt-2 text-text-secondary`}>
          Glyph Studio reads every prompt you have typed, in every AI tool, groups them by what you were building, and writes each project a replay brief: one prompt that carries every requirement and correction, so a newer model can rebuild it without the back-and-forth. Your original prompts are never changed.
        </p>
        <button onClick={() => build()} disabled={!!building} className="mt-5 inline-flex h-9 items-center gap-2 rounded-lg bg-accent px-4 text-[13px] font-semibold text-on-accent hover:bg-accent-hover disabled:opacity-60">
          {building ? <Loader2 className="h-4 w-4 animate-spin" /> : <Sparkles className="h-4 w-4" />} {building ? "Building. This takes a while the first time." : "Build my projects"}
        </button>
        {err && <div className="mt-4 text-[13px] text-err">{err}</div>}
      </div>
    );
  }

  const list = (
    <div className={`${phone ? "overflow-y-auto bg-surface/40 " : ""}p-2`}>
      <div className="flex items-center gap-1 px-1.5 pb-2 pt-1">
        {(["all", "active"] as const).map((k) => (
          <button key={k} onClick={() => setShow(k)} className={`inline-flex h-7 items-center rounded-md px-2.5 text-[12px] ${show === k ? "bg-surface font-semibold text-text-primary shadow-sm ring-1 ring-black/5" : "text-text-muted hover:text-text-secondary"}`}>
            {k === "all" ? `All ${idx.projects.length}` : `Active ${idx.projects.filter((p) => p.status === "active").length}`}
          </button>
        ))}
      </div>
      <button onClick={() => setSel(null)} className={`mb-1 flex w-full items-center gap-2.5 rounded-lg px-2.5 py-2.5 text-left ${sel === null ? "bg-surface-warm" : "hover:bg-surface-warm/50"}`}>
        <Target className="h-4 w-4 shrink-0 text-accent" />
        <span className={`text-[13px] ${sel === null ? "font-semibold text-text-primary" : "text-text-secondary"}`}>Overview</span>
      </button>
      {projects.map((p) => {
        const on = p.slug === sel;
        return (
          <button key={p.slug} onClick={() => setSel(p.slug)} className={`mb-1 flex w-full items-center gap-3 rounded-lg px-2.5 py-2 text-left transition-colors ${on ? "bg-surface-warm" : "hover:bg-surface-warm/50"}`}>
            <div className="min-w-0 flex-1">
              <div className={`truncate text-[13px] ${on ? "font-semibold text-text-primary" : "text-text-secondary"}`}>{displayTitle(p.title)}</div>
              <div className="mt-0.5 text-[12px] text-text-muted">{nPrompts(p.prompt_count)} · {new Date(p.last_ts).toLocaleDateString(undefined, { month: "short", day: "numeric" })}</div>
            </div>
            <Sparkline monthly={p.monthly} months={months} color={domainColor(p.domain)} />
          </button>
        );
      })}
    </div>
  );

  // The count sits under the column title and Refresh is an icon beside it:
  // no band under the page header. The hover title carries the date.
  const meta = idx.stats ? `${idx.stats.kept.toLocaleString()} prompts · ${idx.projects.length} projects` : `${idx.projects.length} projects`;
  const refreshBtn = (
    <button onClick={() => build()} disabled={!!building} data-testid="projects-refresh" aria-label="Refresh projects"
      title={building === "all" ? "Refreshing" : `Refresh projects · briefs updated ${fmtDay(idx.generated_ts)}`}
      className="rounded-md p-1.5 text-text-muted transition-colors hover:bg-surface-warm hover:text-accent disabled:opacity-60">
      {building === "all" ? <Loader2 className="h-4 w-4 animate-spin" /> : <RefreshCw className="h-4 w-4" />}
    </button>
  );

  const detail = cur ? (
    <ProjectDetail key={cur.slug} vaultPath={vaultPath} p={cur} phone={phone} building={building} onRewrite={() => void build(cur.slug)} />
  ) : (
    <div data-testid="projects-overview">
      <h2 className={DETAIL_TITLE}>Your prompt groups</h2>
      <p className={`${BODY} mt-1.5 text-text-secondary`}>
        {idx.projects.length} projects read from {idx.stats?.kept.toLocaleString() ?? "your"} prompts. Pick one on the left to see its arc and restart brief.
      </p>
      {idx.recommendations.length > 0 && (
        <button data-testid="recs-link" onClick={() => window.dispatchEvent(new CustomEvent("prevail:open-settings", { detail: "recommendations" }))}
          className="mt-4 inline-flex items-center gap-1.5 text-left text-[13px] font-medium text-accent hover:underline">
          <Lightbulb className="h-3.5 w-3.5 shrink-0" />
          <span className="min-w-0">{idx.recommendations.length} next steps from your projects are in For You</span>
          <ArrowRight className="h-3.5 w-3.5 shrink-0" />
        </button>
      )}
    </div>
  );

  return (
    <div className="flex h-full min-h-0 flex-col">
      {err && <div className="border-b border-border-subtle bg-surface px-6 py-2 text-[12px] text-err">{err}</div>}
      <SideSpine storageKey="prevail.intent.spine.projects" title="Prompt groups" label="prompt groups" testId="projects-list" meta={meta} actions={refreshBtn}
        phone={phone} phoneDetail={sel !== null} onBack={() => setSel(null)} backLabel="All projects"
        detail={<div className={phone ? "p-4" : "p-6"}>{detail}</div>}>
        {list}
        {phone && sel === null && <div className="p-4">{detail}</div>}
      </SideSpine>
    </div>
  );
}
