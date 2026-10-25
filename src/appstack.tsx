// Apps > Stack (apps plan A2 to A4): every app and service the user uses, in
// one place. The column picks a list: what needs you (the stack's cards),
// all apps, each category, and the signals that matched no app. The detail is
// one full-width column of rows; a row opens inline (no drawers) with the
// signals that matched it, renewal, trial, price history, its health checks
// and a drafted offboarding checklist. Everything comes from
// `prevail apps stack`; answers go back through the engine.
import { useEffect, useMemo, useState, type ReactNode } from "react";
import { AlertTriangle, Archive, Check, ChevronDown, ChevronRight, Clock, Download, FileDiff, FileText, HelpCircle, Inbox, Layers, Loader2, Plug, RefreshCw, Stethoscope, Wrench, type LucideIcon } from "lucide-react";
import { ImportsView, StackDiffView } from "./appsimports";
import { AppsMirrorPanel } from "./appsmirror";
import { MIRROR_SELECT_KEY } from "./appsmirror-parts";
import { SpineTabs } from "./sidespine";
import { invoke, isBrowser } from "./bridge";
import { invalidateQueries, useInvokeQuery } from "./query";
import { toast } from "./toast";
import { SettingsHeader } from "./sectionutil";
import { SideSpine } from "./sidespine";
import { useIsPhone } from "./useisphone";
import { BODY, DETAIL_TITLE, META, ROW_TITLE } from "./typescale";
import { REVEAL, RowMenu } from "./ui";
import {
  ACTION_LABEL, HEALTH_LABEL, VERDICT_LABEL, activeShare, appsIn, healthTone, money, needsFda, stackSubtitle,
  type Stack, type StackApp, type StackCard, type UnknownSignal,
} from "./stackmodel";
import { TintIcon } from "./tint";

const iconBtn = "flex h-8 w-8 shrink-0 items-center justify-center rounded-md text-text-muted transition-colors hover:bg-surface-warm hover:text-accent disabled:opacity-40";
const ACTION_ICON: Record<string, LucideIcon> = { keep: Check, snooze: Clock, "cancel-steps": FileText, archive: Archive, fix: Wrench, review: HelpCircle, done: Check };
const TONE_DOT: Record<string, string> = { good: "bg-ok", warn: "bg-warn", bad: "bg-err", none: "bg-border" };

export function HealthDot({ app }: { app: Pick<StackApp, "health"> }) {
  const tone = healthTone(app.health);
  return (
    <span className="inline-flex min-w-0 items-center gap-1.5 text-[12px] text-text-muted" data-testid="stack-health">
      <span className={`h-1.5 w-1.5 shrink-0 rounded-full ${TONE_DOT[tone]}`} aria-hidden />
      <span className="truncate">{app.health ? HEALTH_LABEL[app.health] : "Not checked"}</span>
    </span>
  );
}

function UsageBar({ app }: { app: StackApp }) {
  const share = activeShare(app.usage);
  const d = app.usage?.active_days.d30 ?? 0;
  return (
    <span className="flex min-w-0 items-center gap-2" title={`${d} of the last 30 days`}>
      <span className="h-1.5 w-20 shrink-0 overflow-hidden rounded-full bg-surface-warm" aria-hidden>
        <span className="block h-full rounded-full bg-accent" style={{ width: `${Math.round(share * 100)}%` }} />
      </span>
      <span className="text-[12px] tabular-nums text-text-muted">{d} day{d === 1 ? "" : "s"}</span>
    </span>
  );
}

function AppRow({ app, vaultPath, open, onToggle }: { app: StackApp; vaultPath: string; open: boolean; onToggle: () => void }) {
  const [busy, setBusy] = useState(false);
  const u = app.usage;
  const offboard = async () => {
    setBusy(true);
    try { await invoke("engine_apps_offboard", { vault: vaultPath, id: app.id }); toast.success(`Drafted an offboarding checklist in ${app.name}'s notes. Nothing was cancelled or sent.`); }
    catch (e) { toast.error(String(e)); } finally { setBusy(false); }
  };
  const detail = (label: string, value: ReactNode) => (
    <div className="flex flex-col gap-0.5 sm:flex-row sm:gap-3"><span className={`${META} w-28 shrink-0 sm:pt-px`}>{label}</span><span className={`${BODY} min-w-0 break-words text-text-secondary`}>{value}</span></div>
  );
  return (
    <li data-testid={`stack-row-${app.id}`} className="border-b border-border-subtle last:border-b-0">
      <button type="button" onClick={onToggle} aria-expanded={open} className="block w-full min-w-0 py-3 text-left hover:bg-surface-warm/40">
        <span className="flex min-w-0 items-center gap-3">
          {open ? <ChevronDown className="h-4 w-4 shrink-0 text-text-muted" /> : <ChevronRight className="h-4 w-4 shrink-0 text-text-muted" />}
          <span title={app.name} className={`${ROW_TITLE} min-w-0 flex-1 truncate`}>{app.name}</span>
          <span className="shrink-0 text-[14px] tabular-nums text-text-primary">{app.monthly !== null ? `${money(app.monthly)}/mo` : ""}</span>
          <span className={`w-16 shrink-0 text-right text-[12px] font-medium ${app.verdict === "keep" ? "text-text-muted" : app.verdict === "cancel" ? "text-err" : "text-warn"}`}>{VERDICT_LABEL[app.verdict]}</span>
        </span>
        <span className={`${META} mt-1 flex min-w-0 flex-wrap items-center gap-x-1.5 gap-y-1 pl-7 tabular-nums`}>
          <UsageBar app={app} />
          {u?.minutes_30d ? <><span aria-hidden>·</span><span>{u.minutes_30d} min</span></> : null}
          {app.value_multiple !== undefined && <><span aria-hidden>·</span><span>{app.value_multiple}x value</span></>}
          <span aria-hidden>·</span><HealthDot app={app} />
        </span>
      </button>
      {open && (
        <div data-testid="stack-detail" className="space-y-1.5 pb-4 pl-7">
          {app.why.length > 0 && detail("Why", app.why.join("; "))}
          {detail("Use, 30 days", u ? `${u.active_days.d30} active days${u.minutes_30d ? `, ${u.minutes_30d} minutes` : ""}${u.web_visits_30d ? `, ${u.web_visits_30d} web visits` : ""}${u.ai_sessions_30d ? `, ${u.ai_sessions_30d} AI sessions` : ""}; trend ${u.trend}` : "No use seen")}
          {u && Object.keys(u.device_minutes_30d).length > 0 && detail("By device", Object.entries(u.device_minutes_30d).map(([d, m]) => `${d === "mac" ? "Mac" : "Phone"} ${Math.round(m)} min`).join(", "))}
          {u && u.signals.length > 0 && detail("Seen as", u.signals.map((s) => `${s.kind} ${s.value}`).join(", "))}
          {app.monthly !== null && detail("Cost", `${money(app.monthly)} a month${app.cost_per_active_day ? `, ${money(app.cost_per_active_day)} per active day` : ""}${app.cost_source ? ` (${app.cost_source})` : ""}`)}
          {app.renewal && detail("Renews", `${app.renewal.next} (${app.renewal.period})`)}
          {app.trial && detail("Trial ends", app.trial.ends)}
          {app.price_up && detail("Price", `up from ${money(app.price_up.from)} to ${money(app.price_up.to)} on ${app.price_up.date}`)}
          {app.api_equivalent_month !== undefined && detail("AI use", `${money(app.api_equivalent_month)} at API prices this month${app.value_multiple !== undefined ? `, ${app.value_multiple}x what you pay` : ""}`)}
          {app.health && app.health !== "ok" && detail("Health", app.health_detail ?? HEALTH_LABEL[app.health])}
          <div className="pt-1.5">
            <button type="button" onClick={() => void offboard()} disabled={busy || isBrowser()} data-testid="stack-offboard" title="Draft offboarding: a checklist and a message, never sent" aria-label={`Draft offboarding for ${app.name}`}
              className="inline-flex items-center gap-1.5 text-[13px] font-medium text-accent hover:underline disabled:opacity-45 disabled:no-underline">
              {busy ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <FileText className="h-3.5 w-3.5" />} Draft offboarding
            </button>
          </div>
        </div>
      )}
    </li>
  );
}

function CardRow({ card, vaultPath, onDone }: { card: StackCard; vaultPath: string; onDone: () => void }) {
  const [busy, setBusy] = useState<string | null>(null);
  const answer = async (a: string) => {
    setBusy(a);
    try {
      const r = await invoke<{ draft?: string; archived?: string }>("engine_apps_card", { vault: vaultPath, key: card.key, answer: a });
      if (r?.draft) toast.success("Drafted the cancel steps in the app's notes. Nothing was cancelled or sent.");
      else if (r?.archived) toast.success("Archived. It stays in the vault.");
      onDone();
    } catch (e) { toast.error(String(e)); } finally { setBusy(null); }
  };
  return (
    <li data-testid="stack-card" data-kind={card.kind} className="group flex items-start gap-3 border-b border-border-subtle py-2.5 last:border-b-0">
      {card.urgent ? <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0 text-err" /> : <span className="mt-[7px] h-1.5 w-1.5 shrink-0 rounded-full bg-accent" aria-hidden />}
      <div className="min-w-0 flex-1">
        <p title={card.title} className={`${ROW_TITLE} line-clamp-2 break-words`}>{card.title}</p>
        <p title={card.why} className={`${META} mt-0.5 truncate`}>{card.why}</p>
      </div>
      {/* Progressive reveal: the first answer on hover (always on touch), the rest in the menu. */}
      <span className={`flex shrink-0 items-center gap-0.5 ${REVEAL}`}>
        {card.actions.slice(0, 1).map((a) => {
          const Icon = ACTION_ICON[a] ?? Check;
          return (
            <button key={a} type="button" onClick={() => void answer(a)} disabled={!!busy || isBrowser()} title={ACTION_LABEL[a] ?? a} aria-label={`${ACTION_LABEL[a] ?? a}: ${card.title}`} data-testid={`card-${a}`} className={iconBtn}>
              {busy === a ? <Loader2 className="h-4 w-4 animate-spin" /> : <Icon className="h-4 w-4" />}
            </button>
          );
        })}
        {card.actions.length > 1 && <RowMenu items={card.actions.slice(1).map((a) => ({ icon: ACTION_ICON[a] ?? Check, label: ACTION_LABEL[a] ?? a, disabled: !!busy || isBrowser(), onClick: () => void answer(a) }))} />}
      </span>
    </li>
  );
}

function UnknownRow({ sig, apps, vaultPath, onDone }: { sig: UnknownSignal; apps: { id: string; name: string }[]; vaultPath: string; onDone: () => void }) {
  const [busy, setBusy] = useState(false);
  const map = async (target: string) => {
    if (!target) return;
    setBusy(true);
    try { await invoke("engine_apps_map", { vault: vaultPath, kind: sig.kind, value: sig.value, target }); toast.success(target === "ignore" ? `Ignoring ${sig.value}` : `${sig.value} is ${target} from now on`); onDone(); }
    catch (e) { toast.error(String(e)); } finally { setBusy(false); }
  };
  return (
    <li data-testid="stack-unknown" className="flex flex-wrap items-center gap-x-3 gap-y-2 border-b border-border-subtle py-2.5 last:border-b-0">
      <div className="min-w-0 flex-1 basis-56">
        <p title={sig.value} className={`${ROW_TITLE} truncate`}>{sig.value}</p>
        <p className={META}>{sig.kind === "domain" ? "Website" : sig.kind === "merchant" ? "Card charge" : sig.kind} · {sig.days} day{sig.days === 1 ? "" : "s"}{sig.freq ? ` · ${sig.freq}` : ""} · last {sig.last}</p>
      </div>
      <select aria-label={`Which app is ${sig.value}`} data-testid="unknown-map" disabled={busy || isBrowser()} defaultValue="" onChange={(e) => void map(e.target.value)}
        className="h-8 min-w-0 max-w-full rounded-md border border-border bg-background px-2 text-[13px] text-text-primary">
        <option value="">{sig.suggestion ? `Maybe ${sig.suggestion}` : "Which app is this?"}</option>
        {sig.suggestion && <option value={sig.suggestion}>{sig.suggestion}</option>}
        {apps.filter((a) => a.id !== sig.suggestion).map((a) => <option key={a.id} value={a.id}>{a.name}</option>)}
        <option value="ignore">Ignore it</option>
      </select>
    </li>
  );
}

/** The stack view, with the page header (tabs come from the Apps page). */
export function AppStackView({ vaultPath, tabs }: { vaultPath: string; tabs: ReactNode }) {
  const phone = useIsPhone();
  const desktop = !isBrowser();
  // A review line can open a section here ("Said vs used"); read once.
  const [sel, setSel] = useState(() => { try { const k = localStorage.getItem("prevail.apps.stack.sel"); localStorage.removeItem("prevail.apps.stack.sel"); return k || "needs"; } catch { return "needs"; } });
  const [picked, setPicked] = useState(false);
  const [open, setOpen] = useState<string | null>(null);
  const [checking, setChecking] = useState(false);
  const q = useInvokeQuery<Stack>("engine_apps_stack", { vault: vaultPath }, { staleMs: 5 * 60_000 });
  const uq = useInvokeQuery<UnknownSignal[]>("engine_apps_unknown", { vault: vaultPath }, { staleMs: 5 * 60_000 });
  const s = q.data ?? null;
  const cards = s?.cards ?? [];
  const unknown = Array.isArray(uq.data) ? uq.data : [];
  const refresh = () => { invalidateQueries("engine_apps_stack"); invalidateQueries("engine_apps_unknown"); void q.refresh(); void uq.refresh(); };
  const fda = needsFda(s);
  const dq = useInvokeQuery<{ items?: unknown[]; accepted?: number } | null>("engine_apps_stack_diff", { vault: vaultPath }, { staleMs: 5 * 60_000 });
  const diffWaiting = dq.data && !dq.data.accepted ? dq.data.items?.length ?? 0 : 0;
  const choose = (k: string) => { setSel(k); setPicked(true); };
  const isOn = (k: string) => sel === k && (!phone || picked);
  const row = (k: string, label: string, Icon: LucideIcon, count?: number) => (
    <button key={k} type="button" data-testid={`stack-spine-${k}`} aria-current={isOn(k) ? "true" : undefined} onClick={() => choose(k)}
      className={`flex w-full items-center gap-2.5 rounded-lg px-2.5 py-2 text-left transition-colors ${isOn(k) ? "bg-surface-warm" : "hover:bg-surface-warm/50"}`}>
      <TintIcon icon={Icon} />
      <span className={`min-w-0 flex-1 truncate text-[14px] ${isOn(k) ? "font-semibold text-text-primary" : "text-text-secondary"}`}>{label}</span>
      {count !== undefined && <span className="shrink-0 text-[12px] tabular-nums text-text-muted">{count}</span>}
    </button>
  );
  const column = (
    <nav className="space-y-0.5 p-2" aria-label="Stack">
      {row("needs", "Needs you", Inbox, cards.length)}
      {row("all", "All apps", Layers, s?.apps.length ?? 0)}
      {(s?.categories ?? []).length > 0 && <div className="px-2.5 pb-1 pt-3 text-[13px] font-semibold text-text-secondary">Categories</div>}
      {(s?.categories ?? []).map((c) => row(`cat:${c.id}`, c.title, Plug, c.count))}
      <div className="pt-2" />
      {row("unknown", "Unknown", HelpCircle, unknown.length)}
      {row("said", "Said vs used", FileDiff, diffWaiting || undefined)}
      {row("imports", "Imports", Download)}
    </nav>
  );
  const recordIds = useMemo(() => (s?.apps ?? []).map((a) => ({ id: a.id, name: a.name })).sort((a, b) => a.name.localeCompare(b.name)), [s]);
  const runDoctor = async () => {
    setChecking(true);
    try { await invoke("engine_apps_doctor", { vault: vaultPath }); refresh(); toast.success("Checked every connection on this Mac"); }
    catch (e) { toast.error(String(e)); } finally { setChecking(false); }
  };

  let body: ReactNode;
  if (q.error) body = <p className="text-[13px] text-err">Could not read the stack: {String(q.error)}</p>;
  else if (!s) body = <p className={`${BODY} flex items-center gap-2 text-text-muted`}><Loader2 className="h-4 w-4 animate-spin" /> Reading your stack</p>;
  else if (sel === "needs") body = (
    <section data-testid="stack-needs">
      <h2 className={DETAIL_TITLE}>Needs you</h2>
      <p className={`${META} mt-1`}>Only a broken capture interrupts you; the rest waits here, in the weekly review and the monthly stack review.</p>
      {cards.length ? <ul className="mt-3 max-w-5xl">{cards.map((c) => <CardRow key={c.key} card={c} vaultPath={vaultPath} onDone={refresh} />)}</ul>
        : <p className={`${META} mt-3`}>Nothing needs you.</p>}
    </section>
  );
  else if (sel === "said") body = <StackDiffView vaultPath={vaultPath} />;
  else if (sel === "imports") body = <ImportsView vaultPath={vaultPath} />;
  else if (sel === "unknown") body = (
    <section data-testid="stack-unknown-list">
      <h2 className={DETAIL_TITLE}>Unknown</h2>
      <p className={`${META} mt-1`}>Signals that matched no app. Mapping one makes a rule on that app's record.</p>
      {unknown.length ? <ul className="mt-3 max-w-5xl">{unknown.map((u) => <UnknownRow key={`${u.kind}:${u.value}`} sig={u} apps={recordIds} vaultPath={vaultPath} onDone={refresh} />)}</ul>
        : <p className={`${META} mt-3`}>Every signal matched an app.</p>}
    </section>
  );
  else {
    const list = appsIn(s, sel);
    const title = sel === "all" ? "All apps" : s.categories.find((c) => `cat:${c.id}` === sel)?.title ?? "Apps";
    body = (
      <section data-testid="stack-apps">
        <h2 className={DETAIL_TITLE}>{title}</h2>
        <p className={`${META} mt-1`}>Active days, minutes, what you pay a month, value and health, last 30 days.</p>
        <ul className="mt-3 max-w-6xl">{list.map((a) => <AppRow key={a.id} app={a} vaultPath={vaultPath} open={open === a.id} onToggle={() => setOpen(open === a.id ? null : a.id)} />)}</ul>
      </section>
    );
  }

  return (
    <div className="flex h-full min-h-0 flex-col" data-testid="apps-view">
      <SettingsHeader title="Apps" icon={Plug} subtitle={stackSubtitle(s)} tabs={tabs}
        right={desktop ? <span className="flex items-center gap-0.5">
          <button type="button" onClick={() => void runDoctor()} disabled={checking} title="Check every connection now" aria-label="Check every connection now" data-testid="stack-doctor" className={iconBtn}>
            {checking ? <Loader2 className="h-4 w-4 animate-spin" /> : <Stethoscope className="h-4 w-4" />}
          </button>
          <button type="button" onClick={refresh} title="Refresh" aria-label="Refresh the stack" className={iconBtn}><RefreshCw className="h-4 w-4" /></button>
        </span> : undefined} />
      {fda.length > 0 && (
        <p data-testid="stack-fda" className={`shrink-0 ${phone ? "px-4 pt-3" : "px-8 pt-3"} flex items-start gap-2 text-[13px] text-warn`}>
          <AlertTriangle className="mt-0.5 h-3.5 w-3.5 shrink-0" aria-hidden />
          <span className="min-w-0 break-words">Screen Time needs Full Disk Access for Glyph Studio: System Settings, Privacy and Security, Full Disk Access.</span>
        </p>
      )}
      <SideSpine storageKey="prevail.stack.spine" title="Stack" label="the stack" testId="stack-list" meta={s ? `${s.apps.length} apps` : undefined}
        phone={phone} phoneDetail={phone && picked} onBack={() => setPicked(false)} backLabel="Stack"
        detail={<div className={phone ? "px-4 py-4" : "w-full px-8 py-6"}>{body}</div>}>
        {column}
      </SideSpine>
    </div>
  );
}

type AppsView = "stack" | "connectors";

/** The Apps page: the stack (default) and the connectors mirror, picked by the header tabs. A connector picked in the sidebar opens Connectors. */
export function AppsPage({ vaultPath }: { vaultPath: string }) {
  const [view, setView] = useState<AppsView>(() => { try { return sessionStorage.getItem(MIRROR_SELECT_KEY) ? "connectors" : "stack"; } catch { return "stack"; } });
  useEffect(() => {
    const on = () => setView("connectors");
    window.addEventListener("prevail:mirror-select", on);
    return () => window.removeEventListener("prevail:mirror-select", on);
  }, []);
  const tabs = <SpineTabs label="Apps view" value={view} onChange={setView} tabs={[{ id: "stack", label: "Stack" }, { id: "connectors", label: "Connectors" }]} />;
  return view === "stack" ? <AppStackView vaultPath={vaultPath} tabs={tabs} /> : <AppsMirrorPanel vaultPath={vaultPath} tabs={tabs} />;
}
