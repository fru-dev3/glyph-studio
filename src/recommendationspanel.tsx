// Recommendations: the one "what to do next" home. Everything Prevail notices
// (Intent findings, project next steps, stuck projects, connectors, recurring
// people and places, model benchmarks, context gaps) arrives from the engine
// as one list ranked by leverage. The page is the canonical template: a
// sticky header, a SideSpine of categories with counts, and one full-width
// column. "Start here" is the top five.
import { useCallback, useEffect, useMemo, useState } from "react";
import { FilingCard } from "./filingplan";
import { YearLine } from "./yearline";
import {
  ArrowRight, ArrowUpRight, BarChart3, Bookmark, Check, ChevronDown, ClipboardCopy, Compass, Flag, FolderKanban,
  EyeOff, Gauge, LayoutList, Shapes, Lightbulb, ListTodo, Loader2, Play, Plug, RotateCcw, RotateCw, ScrollText, Sparkles, Users, X,
  type LucideIcon,
} from "lucide-react";
import { invoke } from "./bridge";
import { hasInvoke, invokeCached, peekInvoke } from "./query";
import { relTime, titleCase } from "./format";
import { modelLabel } from "./helpers2";
import { distillCfgFromPrefs } from "./daemoncfg";
import { SideSpine } from "./sidespine";
import { SettingsHeader } from "./sectionutil";
import { useIsPhone } from "./useisphone";
import { PREF, setPref } from "./storage";
import { toast } from "./toast";
import { StructureCards } from "./structurecards";
import { RECS_CATEGORY_EVENT, useStructureSuggestions } from "./missions";
import { META, ROW_TITLE, SCORE, SECTION_TITLE } from "./typescale";
import { REVEAL, RowMenu } from "./ui";
import {
  addTask, applyRec, copyInstruction, doItLabel, loadSet, openEvidence, recsFor, REC_DISMISSED, REC_SAVED,
  SPINE, setDomainModel, spineCounts, START_N, storeSet, visibleRecs, normalizeRec,
  type Rec, type RecCategory, type RecRow, type SpineKey,
} from "./recmodel";
import { TintIcon } from "./tint";

export { applyRec } from "./recmodel";
export type { Rec } from "./recmodel";

type DistillStatus = { running: boolean; last_run_ts?: number | null; interval_sec?: number | null };

const SPINE_ICON: Record<SpineKey, LucideIcon> = {
  all: LayoutList, start: Flag, rules: ScrollText, projects: FolderKanban, structure: Shapes, apps: Plug,
  people: Users, models: BarChart3, context: Gauge,
};
const CAT_LABEL: Record<RecCategory, string> = {
  rules: "Rules", projects: "Prompt groups", structure: "Structure", apps: "Apps", people: "People and places", models: "Models", context: "Context",
};
// Dismissing a recommendation anywhere (this page or the Home Briefing) writes
// the one shared set and announces it, so both agree.
export const RECS_CHANGED = "prevail:recs-changed";
const iconBtn = "inline-flex h-7 w-7 items-center justify-center rounded-md text-text-muted transition-colors hover:bg-surface-warm hover:text-accent disabled:opacity-40";

function IconAction({ label, icon: Icon, onClick, busy, done, tone, pressed, className = "", testId }: {
  label: string; icon: LucideIcon; onClick: () => void; busy?: boolean; done?: boolean; tone?: "danger"; pressed?: boolean; className?: string; testId?: string;
}) {
  return (
    <button onClick={onClick} disabled={busy} title={label} aria-label={label} aria-pressed={pressed} data-testid={testId}
      className={`${iconBtn} ${done || pressed ? "text-accent" : ""} ${tone === "danger" ? "hover:text-err" : ""} ${className}`}>
      {busy ? <Loader2 className="h-4 w-4 animate-spin" /> : done ? <Check className="h-4 w-4" /> : <Icon className="h-4 w-4" fill={pressed ? "currentColor" : "none"} />}
    </button>
  );
}

function ModelTable({ rows, onApply, applied }: { rows: RecRow[]; onApply: (r: RecRow) => void; applied: Set<string> }) {
  return (
    <div className="mt-3 overflow-x-auto">
      <table className="w-full text-left text-[13px]" data-testid="model-table">
        <thead className="border-b border-border-subtle text-[12px] text-text-muted">
          <tr><th className="px-3 py-2 font-medium">Domain</th><th className="px-3 py-2 font-medium">Current</th><th className="px-3 py-2 font-medium">Suggested</th><th className="px-3 py-2 text-right font-medium">Score</th><th className="w-10" /></tr>
        </thead>
        <tbody className="divide-y divide-border-subtle">
          {rows.map((r) => (
            <tr key={r.id} data-testid="model-row">
              <td className="px-3 py-2 font-medium text-text-primary">{titleCase(r.domain)}</td>
              <td className="px-3 py-2 text-text-muted">{r.current ? modelLabel(undefined, r.current) || r.current : "Not set"}</td>
              <td className="px-3 py-2 text-text-secondary">{modelLabel(r.cli, r.suggested ?? "") || r.suggested_label}</td>
              <td className="px-3 py-2 text-right tabular-nums text-text-secondary" title={r.models_tested ? `Best of ${r.models_tested} models tested` : undefined}>{r.score != null ? `${r.score.toFixed(1)}/10` : ""}</td>
              <td className="px-1 py-1">
                <IconAction label={`Apply for ${titleCase(r.domain)}`} icon={Play} onClick={() => onApply(r)} done={applied.has(r.id)} />
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function RecItem({ r, rank, vaultPath, saved, dismissed, onSave, onDismiss, onRestore, onChanged }: {
  r: Rec; rank?: number; vaultPath: string; saved: boolean; dismissed: boolean;
  onSave: () => void; onDismiss: () => void; onRestore: () => void; onChanged: () => void; phone: boolean;
}) {
  const [busy, setBusy] = useState<string | null>(null);
  const [msg, setMsg] = useState<{ text: string; ok: boolean } | null>(null);
  const [open, setOpen] = useState(false);
  const [applied, setApplied] = useState<Set<string>>(new Set());
  const run = async (key: string, f: () => Promise<string | void>) => {
    setBusy(key);
    try { const t = await f(); if (t) setMsg({ text: t, ok: true }); }
    catch (e) { setMsg({ text: `Could not do that: ${e}`, ok: false }); }
    finally { setBusy(null); }
  };
  const isModels = r.action.kind === "set_domain_models";
  const hasTable = isModels && (r.rows?.length ?? 0) > 0;
  const canCopy = !!r.instruction || r.action.kind === "project_rec";
  const canTask = !!r.task;
  return (
    <li data-testid="rec-item" data-rec-id={r.id} className={`group py-3 ${dismissed ? "opacity-50" : ""}`}>
      <div className="flex items-start gap-3">
        <div className="min-w-0 flex-1">
          <div className="flex items-baseline gap-3">
            {r.metric && (
              <span className={`${SCORE} shrink-0 text-accent`} title={r.metric.unit} data-testid="rec-metric">
                {r.metric.value.toLocaleString()}
              </span>
            )}
            <h3 title={r.title} className={`${ROW_TITLE} min-w-0 line-clamp-2`}>
              {rank ? <span className="sr-only">{`${rank}. `}</span> : null}{r.title}
            </h3>
          </div>
          {r.metric && <div className={`${META} mt-0.5`}>{r.metric.unit}</div>}
          <p title={r.detail} className="mt-0.5 line-clamp-2 text-[14px] leading-snug text-text-secondary">{r.detail}</p>
          <div className="mt-1 flex flex-wrap items-center gap-x-4 gap-y-1 text-[12px]">
            {r.evidence && (
              <button onClick={() => openEvidence(r.evidence!)} className="inline-flex items-center gap-1 text-accent underline decoration-accent-border underline-offset-[3px] hover:decoration-accent">
                {r.evidence.label}<ArrowUpRight className="h-3.5 w-3.5" />
              </button>
            )}
            {hasTable && (
              <button onClick={() => setOpen((v) => !v)} aria-expanded={open} className="inline-flex items-center gap-1 text-text-secondary hover:text-accent">
                <ChevronDown className={`h-3.5 w-3.5 transition-transform ${open ? "" : "-rotate-90"}`} />{open ? "Hide domains" : `Show ${r.rows!.length} domains`}
              </button>
            )}
            {!isModels && r.rows && r.rows.length > 0 && (
              <span className="text-text-muted">{r.rows.slice(0, 8).map((x) => titleCase(x.domain)).join(", ")}{r.rows.length > 8 ? ` and ${r.rows.length - 8} more` : ""}</span>
            )}
          </div>
          {msg && <p className={`mt-1.5 inline-flex items-center gap-1 text-[13px] ${msg.ok ? "text-ok" : "text-err"}`}>{msg.ok && <Check className="h-3.5 w-3.5" />}{msg.text}</p>}
        </div>
        {/* One primary action on hover (always on touch); the rest in the menu. */}
        <div className={`flex shrink-0 items-center gap-0.5 ${busy ? "" : REVEAL}`} role="group" aria-label="Actions">
          {saved && <Bookmark className="mr-1 h-3.5 w-3.5 text-accent" fill="currentColor" aria-label="Saved" />}
          {!dismissed && (
            <IconAction label={doItLabel(r)} icon={isModels ? Play : ArrowRight} busy={busy === "do"}
              onClick={() => void run("do", async () => { const t = await applyRec(r, vaultPath); onChanged(); return t; })} />
          )}
          <RowMenu items={[
            ...(canTask && !dismissed ? [{ icon: ListTodo, label: `Add a task to ${titleCase(r.task!.domain)}`, onClick: () => void run("task", async () => { await addTask(r, vaultPath); return `Added to the ${titleCase(r.task!.domain)} board.`; }) }] : []),
            ...(canCopy && !dismissed ? [{ icon: ClipboardCopy, label: "Copy an instruction for an agent", onClick: () => void run("copy", async () => { await copyInstruction(r, vaultPath); return "Copied."; }) }] : []),
            { icon: Bookmark, label: saved ? "Unsave" : "Save for later", checked: saved, onClick: onSave },
            dismissed ? { icon: RotateCcw, label: "Restore", onClick: onRestore } : { icon: X, label: "Dismiss", danger: true, onClick: onDismiss },
          ]} />
        </div>
      </div>
      {hasTable && open && (
        <ModelTable rows={r.rows!} applied={applied} onApply={(row) => {
          setDomainModel(row);
          setApplied((s) => new Set(s).add(row.id));
          setMsg({ text: `${titleCase(row.domain)} now uses ${modelLabel(row.cli, row.suggested ?? "") || row.suggested_label}.`, ok: true });
        }} />
      )}
    </li>
  );
}

function SpineList({ counts, sel, onSelect }: { counts: Record<SpineKey, number>; sel: SpineKey; onSelect: (k: SpineKey) => void }) {
  return (
    <nav className="p-2" aria-label="Recommendation categories">
      {SPINE.map(({ key, label }) => {
        const Icon = SPINE_ICON[key];
        const on = sel === key;
        return (
          <button key={key} onClick={() => onSelect(key)} aria-current={on ? "page" : undefined} data-testid={`spine-${key}`}
            className={`mb-0.5 flex w-full items-center gap-2.5 rounded-lg px-2.5 py-2 text-left transition-colors ${on ? "bg-surface-warm" : "hover:bg-surface-warm/50"}`}>
            <TintIcon icon={Icon} />
            <span className={`min-w-0 flex-1 truncate text-[14px] ${on ? "font-semibold text-text-primary" : "text-text-secondary"}`}>{label}</span>
            <span className="text-[13px] tabular-nums text-text-muted">{counts[key]}</span>
          </button>
        );
      })}
    </nav>
  );
}

export function RecommendationsPanel({ vaultPath }: { vaultPath: string }) {
  const phone = useIsPhone();
  const [recs, setRecs] = useState<Rec[] | null>(() => {
    if (!hasInvoke("engine_recommendations", { vault: vaultPath })) return null;
    const c = peekInvoke<{ recommendations?: Rec[] }>("engine_recommendations", { vault: vaultPath });
    return Array.isArray(c?.recommendations) ? c!.recommendations!.map(normalizeRec) : [];
  });
  const [dismissed, setDismissed] = useState<Set<string>>(() => loadSet(REC_DISMISSED));
  const [saved, setSaved] = useState<Set<string>>(() => loadSet(REC_SAVED));
  const [sel, setSel] = useState<SpineKey>(() => {
    try { const v = localStorage.getItem("prevail.recs.category"); return (SPINE.some((s) => s.key === v) ? v : "all") as SpineKey; } catch { return "all"; }
  });
  const select = (k: SpineKey) => { setSel(k); try { localStorage.setItem("prevail.recs.category", k); } catch { /* storage off */ } };
  // The Domains dot (and a structure item on the Briefing) opens Structure.
  useEffect(() => {
    const f = (e: Event) => { const k = (e as CustomEvent<string>).detail; if (SPINE.some((s) => s.key === k)) setSel(k as SpineKey); };
    window.addEventListener(RECS_CATEGORY_EVENT, f);
    return () => window.removeEventListener(RECS_CATEGORY_EVENT, f);
  }, []);
  // Structure suggestions come with their evidence from `suggest structure`;
  // the feed's own structure items would only repeat them.
  const { suggestions } = useStructureSuggestions(vaultPath);
  const [showDismissed, setShowDismissed] = useState(false);
  const [savedOnly, setSavedOnly] = useState(false);
  const [tick, setTick] = useState(0); // re-read local model defaults after an apply
  const [daemon, setDaemon] = useState<DistillStatus | null>(null);
  const [running, setRunning] = useState(false);

  // The two reads are independent: run them together.
  const load = useCallback(async () => {
    await Promise.all([
      invokeCached<{ ok: boolean; recommendations?: Rec[] }>("engine_recommendations", { vault: vaultPath }, { force: true })
        .then((r) => setRecs(Array.isArray(r?.recommendations) ? r.recommendations.map(normalizeRec) : []))
        .catch(() => setRecs([])),
      invoke<DistillStatus>("distill_status").then(setDaemon).catch(() => { /* daemon not started */ }),
    ]);
  }, [vaultPath]);
  useEffect(() => { void load(); }, [load]);

  const runNow = useCallback(async () => {
    setRunning(true);
    try { await invoke("distill_run_once", { cfg: distillCfgFromPrefs(vaultPath) }); } catch { /* surfaced by reload */ }
    finally { setRunning(false); await load(); }
  }, [vaultPath, load]);

  const persistDismissed = (s: Set<string>) => { setDismissed(new Set(s)); storeSet(REC_DISMISSED, s); window.dispatchEvent(new Event(RECS_CHANGED)); };
  // A dismiss on the Home Briefing lands here too.
  useEffect(() => {
    const f = () => setDismissed(loadSet(REC_DISMISSED));
    window.addEventListener(RECS_CHANGED, f);
    return () => window.removeEventListener(RECS_CHANGED, f);
  }, []);
  const toggle = (set: Set<string>, id: string) => { const s = new Set(set); if (s.has(id)) s.delete(id); else s.add(id); return s; };

  // eslint-disable-next-line react-hooks/exhaustive-deps
  const live = useMemo(() => (recs ? visibleRecs(recs, dismissed, { showDismissed, savedOnly, saved }).filter((r) => r.category !== "structure") : []), [recs, dismissed, showDismissed, savedOnly, saved, tick]);
  const counts = useMemo(() => {
    const c = spineCounts(live.filter((r) => !dismissed.has(r.id)));
    return { ...c, structure: suggestions.length, all: c.all + suggestions.length };
  }, [live, dismissed, suggestions.length]);
  const shown = recsFor(live, sel);
  const dismissedCount = (recs ?? []).filter((r) => dismissed.has(r.id)).length;
  const savedCount = (recs ?? []).filter((r) => saved.has(r.id)).length;
  const isLearning = running || !!daemon?.running;

  const item = (r: Rec, rank?: number) => (
    <RecItem key={r.id} r={r} rank={rank} vaultPath={vaultPath} phone={phone}
      saved={saved.has(r.id)} dismissed={dismissed.has(r.id)}
      onSave={() => { const s = toggle(saved, r.id); setSaved(s); storeSet(REC_SAVED, s); }}
      onDismiss={() => persistDismissed(new Set(dismissed).add(r.id))}
      onRestore={() => { const s = new Set(dismissed); s.delete(r.id); for (const x of r.rows ?? []) s.delete(x.id); persistDismissed(s); }}
      onChanged={() => setTick((n) => n + 1)} />
  );
  const list = (rs: Rec[], ranked = false) => (
    <ul className="divide-y divide-border-subtle">{rs.map((r, i) => item(r, ranked ? i + 1 : undefined))}</ul>
  );
  const sectionHead = (label: string, n: number, Icon: LucideIcon) => (
    <h2 className={`${SECTION_TITLE} mb-1 flex items-center gap-2`}>
      <Icon className="h-4 w-4 text-text-muted" />{label}<span className="text-[12px] font-normal tabular-nums text-text-muted">{n}</span>
    </h2>
  );

  let body: React.ReactNode;
  const structure = (
    <section data-testid="section-structure">{sectionHead("Structure", suggestions.length, Shapes)}<StructureCards suggestions={suggestions} vaultPath={vaultPath} /></section>
  );
  if (sel === "structure") body = structure;
  else if (recs === null) body = <div className={META}>Reading your vault...</div>;
  else if (!live.length && !suggestions.length) {
    body = (
      <div className="py-6">
        <p className="text-[14px] text-text-secondary">{savedOnly ? "Nothing saved yet." : "Nothing to do right now."}</p>
        <p className={`${META} mt-0.5`}>Recommendations appear as Glyph Studio reads your prompts, projects, apps and benchmarks.</p>
      </div>
    );
  } else if (sel === "all") {
    const start = live.slice(0, START_N);
    const rest = live.slice(START_N);
    body = (
      <div className="space-y-8">
        {start.length > 0 && <section data-testid="section-start">{sectionHead("Start here", start.length, Flag)}{list(start, true)}</section>}
        {(Object.keys(CAT_LABEL) as RecCategory[]).map((c) => {
          if (c === "structure") return suggestions.length ? <div key={c}>{structure}</div> : null;
          const rs = rest.filter((r) => r.category === c);
          return rs.length ? <section key={c} data-testid={`section-${c}`}>{sectionHead(CAT_LABEL[c], rs.length, SPINE_ICON[c])}{list(rs)}</section> : null;
        })}
      </div>
    );
  } else {
    const label = SPINE.find((s) => s.key === sel)!.label;
    body = shown.length
      ? <section data-testid={`section-${sel}`}>{sectionHead(label, shown.length, SPINE_ICON[sel])}{list(shown, sel === "start")}</section>
      : <p className={META}>Nothing in {label} right now.</p>;
  }

  const toolbar = (
    <div className={`${META} mb-4 flex flex-wrap items-center gap-x-4 gap-y-1`}>
      <span>{counts.all ? `${counts.all} to consider, ranked by leverage` : ""}</span>
      <span className="ml-auto flex items-center gap-4">
        {savedCount > 0 && (
          <button onClick={() => setSavedOnly((v) => !v)} aria-pressed={savedOnly}
            className={`inline-flex items-center gap-1.5 hover:text-accent ${savedOnly ? "font-medium text-accent" : ""}`}>
            <Bookmark className="h-3.5 w-3.5" />Saved {savedCount}
          </button>
        )}
        {dismissedCount > 0 && (
          <button onClick={() => setShowDismissed((v) => !v)} aria-pressed={showDismissed}
            className={`inline-flex items-center gap-1.5 hover:text-accent ${showDismissed ? "font-medium text-accent" : ""}`}>
            {showDismissed ? "Hide" : "Show"} dismissed {dismissedCount}
          </button>
        )}
      </span>
    </div>
  );
  const detail = <div className={phone ? "px-4 py-4" : "w-full px-8 py-6"}>{sel === "all" && <YearLine vaultPath={vaultPath} />}<FilingCard vaultPath={vaultPath} />{toolbar}{body}</div>;
  // When it last learned, and Learn now: under the column title, never a
  // lone button in the page header.
  const learned = isLearning ? "Learning now" : daemon?.last_run_ts ? `Learned ${relTime(daemon.last_run_ts * 1000)}` : "Not learned yet";
  const learnBtn = (
    <button onClick={() => void runNow()} disabled={isLearning} title="Learn now and refresh" aria-label="Learn now and refresh" className={iconBtn}>
      {isLearning ? <Loader2 className="h-4 w-4 animate-spin" /> : <RotateCw className="h-4 w-4" />}
    </button>
  );

  return (
    <div className="flex min-h-0 flex-1 flex-col" data-testid="recommendations-page">
      <SettingsHeader icon={Lightbulb} title="For You" subtitle="Next steps learned from your prompts, projects, apps and benchmarks." />
      {phone ? (
        <>
          <div className="flex items-center justify-between gap-2 px-4 pt-2 text-[13px] text-text-muted"><span>{learned}</span>{learnBtn}</div>
          {/* Categories with nothing in them are not offered; with nothing at all, no tab row. */}
          {SPINE.some(({ key }) => key !== "all" && counts[key]) && <div className="flex gap-1.5 overflow-x-auto border-b border-border-subtle px-4 py-2" role="tablist" aria-label="Recommendation categories">
            {SPINE.filter(({ key }) => key === "all" || counts[key] || sel === key).map(({ key, label }) => (
              <button key={key} role="tab" aria-selected={sel === key} onClick={() => select(key)}
                className={`inline-flex h-9 shrink-0 items-center gap-1.5 rounded-lg px-3 text-[13px] ${sel === key ? "bg-surface-warm font-semibold text-text-primary" : "text-text-muted"}`}>
                {label}<span className="tabular-nums text-text-muted">{counts[key]}</span>
              </button>
            ))}
          </div>}
          <div className="min-h-0 flex-1 overflow-y-auto">{detail}</div>
        </>
      ) : (
        <SideSpine storageKey="prevail.recs.spine" title="Categories" label="categories" testId="recs-spine" detail={detail} meta={learned} actions={learnBtn}>
          <SpineList counts={counts} sel={sel} onSelect={select} />
        </SideSpine>
      )}
    </div>
  );
}

// The compact home Briefing: the top three next moves plus recent intents.
// The full logic lives in RecommendationsPanel; this is only a glance.
type BriefIntent = { title?: string; goal?: string };
const BRIEF_ICON: Record<RecCategory, LucideIcon> = { rules: ScrollText, projects: FolderKanban, structure: Shapes, apps: Plug, people: Users, models: BarChart3, context: Gauge };
export function HomeBriefing({ vaultPath }: { vaultPath: string }) {
  const [raw, setRaw] = useState<Rec[] | null>(() => {
    if (!hasInvoke("engine_recommendations", { vault: vaultPath })) return null;
    const c = peekInvoke<{ recommendations?: Rec[] }>("engine_recommendations", { vault: vaultPath });
    return Array.isArray(c?.recommendations) ? c!.recommendations! : [];
  });
  const [dismissed, setDismissed] = useState<Set<string>>(() => loadSet(REC_DISMISSED));
  const [intents, setIntents] = useState<BriefIntent[]>([]);
  const [busy, setBusy] = useState<string | null>(null);
  const [done, setDone] = useState<Record<string, boolean>>({});
  const [cleared, setCleared] = useState<Set<string>>(new Set());
  const [hidden, setHidden] = useState(false);
  useEffect(() => {
    let alive = true;
    invokeCached<{ ok: boolean; recommendations?: Rec[] }>("engine_recommendations", { vault: vaultPath })
      .then((r) => { if (alive) setRaw(Array.isArray(r?.recommendations) ? r.recommendations : []); })
      .catch(() => { if (alive) setRaw([]); });
    invoke<{ intents?: BriefIntent[] }>("intents_distilled_read", { vault: vaultPath })
      .then((d) => { if (alive) setIntents(Array.isArray(d?.intents) ? d.intents : []); })
      .catch(() => { if (alive) setIntents([]); });
    return () => { alive = false; };
  }, [vaultPath]);
  useEffect(() => {
    const f = () => setDismissed(loadSet(REC_DISMISSED));
    window.addEventListener(RECS_CHANGED, f);
    return () => window.removeEventListener(RECS_CHANGED, f);
  }, []);

  const recs = useMemo(() => visibleRecs(raw ?? [], dismissed), [raw, dismissed]);
  const top = recs.filter((r) => !cleared.has(r.id)).slice(0, 3);
  const intentLine = intents.slice(0, 3).map((it) => it.title || it.goal || "").filter(Boolean).join(" · ");
  const openRecs = () => window.dispatchEvent(new CustomEvent("prevail:open-settings", { detail: "recommendations" }));
  const openIntents = () => window.dispatchEvent(new CustomEvent("prevail:open-settings", { detail: "intents" }));
  const act = useCallback(async (rec: Rec) => {
    setBusy(rec.id);
    try {
      await applyRec(rec, vaultPath);
      setDone((d) => ({ ...d, [rec.id]: true }));
      window.setTimeout(() => setCleared((c) => new Set(c).add(rec.id)), 1100);
    } catch { /* surfaced in the full panel */ }
    finally { setBusy(null); }
  }, [vaultPath]);
  // Same dismissed set as the Recommendations page; the next one moves up.
  const dismiss = (rec: Rec) => {
    const next = new Set(loadSet(REC_DISMISSED)).add(rec.id);
    storeSet(REC_DISMISSED, next);
    setDismissed(next);
    window.dispatchEvent(new Event(RECS_CHANGED));
  };
  // The Settings switch that shows the Briefing; it turns back on there.
  const hide = () => {
    setPref(PREF.showHomeBriefing, "0");
    setHidden(true);
    toast("Briefing hidden. Turn it back on in Settings.");
  };

  const everyDismissed = top.length === 0 && (raw?.length ?? 0) > 0;
  if (hidden || raw === null || (top.length === 0 && !everyDismissed && intentLine === "")) return null;
  // Row actions sit quietly until hover; on touch there is no hover, so they show.
  const quiet = "opacity-0 group-hover:opacity-100 focus-visible:opacity-100 [@media(pointer:coarse)]:opacity-100";
  return (
    <div className="mt-8 w-full max-w-5xl" data-testid="home-briefing">
      <div className="group mb-1.5 flex items-center justify-between">
        <div className={`${SECTION_TITLE} flex items-center gap-2`}>
          <Sparkles className="h-3.5 w-3.5 text-accent" /> Briefing
        </div>
        <IconAction label="Hide briefing" icon={EyeOff} onClick={hide} className={quiet} testId="briefing-hide" />
      </div>
      <div className="border-t border-border-subtle">
        {everyDismissed && <p data-testid="briefing-empty" className={`${META} py-3`}>Nothing new to suggest right now.</p>}
        {top.map((r, i) => {
          const Icon = BRIEF_ICON[r.category] ?? Compass;
          const tip = doItLabel(r);
          return (
            <div key={r.id} data-testid="briefing-row" data-rec={r.id} className={`group flex items-center gap-3 py-2.5 ${i > 0 ? "border-t border-border-subtle" : ""}`}>
              <Icon className="h-4 w-4 shrink-0 text-text-muted" />
              <div className="min-w-0 flex-1">
                <div title={r.title} className="truncate text-[14px] font-medium text-text-primary">{r.title}</div>
                <div title={r.detail} className={`${META} truncate`}>{r.detail}</div>
              </div>
              <IconAction label="Dismiss" icon={X} tone="danger" onClick={() => dismiss(r)} className={quiet} testId="briefing-dismiss" />
              {done[r.id] ? <Check className="h-4 w-4 shrink-0 text-ok" /> : (
                <button onClick={() => void act(r)} disabled={busy === r.id} title={tip} aria-label={tip}
                  className="flex h-7 w-7 shrink-0 items-center justify-center rounded-md text-text-muted transition-colors hover:bg-surface-warm hover:text-accent disabled:opacity-40">
                  {busy === r.id ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <ArrowRight className="h-3.5 w-3.5" />}
                </button>
              )}
            </div>
          );
        })}
        {intentLine !== "" && (
          <button onClick={openIntents} className={`group flex w-full items-center gap-3 py-2.5 text-left ${top.length > 0 || everyDismissed ? "border-t border-border-subtle" : ""}`}>
            <Compass className="h-4 w-4 shrink-0 text-text-muted" />
            <span className="min-w-0 flex-1 truncate text-[12px] text-text-secondary"><span className="font-medium text-text-primary">Recent intents:</span> {intentLine}</span>
            <span className="shrink-0 text-[12px] text-text-muted group-hover:text-accent">See all</span>
          </button>
        )}
        {top.length > 0 && (
          <button onClick={openRecs} className="flex items-center gap-1 pt-1 text-[12px] font-medium text-accent hover:underline">
            See all in For You <ArrowRight className="h-3 w-3" />
          </button>
        )}
      </div>
    </div>
  );
}
