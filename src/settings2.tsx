// Self-contained Settings sections extracted from App.tsx: Daemons, cross-domain
// Tasks, Intents, Memory & Context. vaultPath-driven; no App-root
// state closure.
import { createContext, useContext, useEffect, useState } from "react";
import { Bell, Brain, GraduationCap, Laptop, Lightbulb, ListChecks, Server } from "lucide-react";
import type { LucideIcon } from "lucide-react";
import { invoke } from "./bridge";
import { formatFreshness } from "./format";
import { PREF, cheapModel, getPref, setPref } from "./storage";
import { Toggle } from "./ui";
import { DaemonCard, HeadlessLearnCard } from "./panels";
import { distillCfgFromPrefs, intentDaemonCfgFromPrefs, skillgenCfgFromPrefs, taskgenCfgFromPrefs } from "./daemoncfg";
import { SettingsHeader } from "./sectionutil";
import { SideSpine } from "./sidespine";
import { useIsPhone } from "./useisphone";
import { VENDOR_BRAND, isHarnessRuntime } from "./constants";
import { useDetectedClis } from "./hooks";
import type { DaemonStatus } from "./types";
import { DETAIL_TITLE } from "./typescale";
import { TintIcon } from "./tint";

// One collapsible card per routine. Routes through the canonical CollapsibleSection
// (icon + title left, summary + running dot right, collapsed by default) so the
// Daemons page looks identical to every other collapsible in the app.
// Color-coded "alive" dot so one glance tells running daemons apart from idle/off
// ones. Running = bright green (pulses so it reads as alive); enabled-but-not-
// running = amber (idle but armed); disabled = muted grey.
function DaemonDot({ running, enabled = true }: { running: boolean; enabled?: boolean }) {
  // Green when running or on, grey when off. Warn is kept for trouble.
  const cls = running
    ? "bg-ok pulse-soft"
    : enabled
      ? "bg-ok"
      : "bg-text-muted/40";
  const title = running ? "running" : enabled ? "Idle" : "Off";
  return <span className={`h-2 w-2 shrink-0 rounded-full ${cls}`} title={title} />;
}

// One background routine in the Daemons side column.
type DaemonItem = { id: string; icon: LucideIcon; title: string; summary?: React.ReactNode; running?: boolean; enabled?: boolean; does?: string; hubOnly?: boolean };
const DaemonSel = createContext<{ sel: string; items: DaemonItem[] }>({ sel: "", items: [] });

// The picked routine's detail: its header, what it does in one line, then its
// controls. Every other routine renders nothing.
function DaemonGroup({ id, control, children }: { id: string; control?: React.ReactNode; children: React.ReactNode }) {
  const { sel, items } = useContext(DaemonSel);
  if (sel !== id) return null;
  const it = items.find((x) => x.id === id);
  if (!it) return null;
  const Icon = it.icon;
  return (
    <section data-testid={`daemon-detail-${id}`}>
      <div className="mb-4 flex items-start gap-3">
        <span className="flex h-9 w-9 shrink-0 items-center justify-center rounded-lg bg-accent-soft text-accent"><Icon className="h-5 w-5" /></span>
        <div className="min-w-0 flex-1">
          <h2 className={DETAIL_TITLE}>{it.title}</h2>
          {it.does && <p className="mt-1 text-[14px] text-text-secondary">{it.does}</p>}
          {control && it.hubOnly && <p className="mt-0.5 text-[13px] text-text-muted">Hub only</p>}
          {!control && <div className="mt-1.5 flex items-center gap-2 text-[13px] text-text-muted">
            {it.running !== undefined && <DaemonDot running={it.running} enabled={it.enabled} />}
            {it.running !== undefined && <span>{it.running ? "Running" : it.enabled === false ? "Off" : "Idle"}</span>}
            {it.summary != null && it.summary !== "" && <span>{it.running !== undefined ? "· " : ""}{it.summary}</span>}
            {it.hubOnly && <span>· Hub only</span>}
          </div>}
        </div>
        {control && <div className="shrink-0 pt-1">{control}</div>}
      </div>
      {children}
    </section>
  );
}

// The routines, for a page that lists them in its own column.
export const DAEMON_ROWS: { id: string; title: string; icon: LucideIcon }[] = [
  { id: "distill", title: "Distill", icon: Brain },
  { id: "reminders", title: "Reminders", icon: Bell },
  { id: "taskgen", title: "Task generation", icon: ListChecks },
  { id: "skillgen", title: "Skill learning", icon: GraduationCap },
  { id: "intent", title: "Intent distillation", icon: Lightbulb },
  { id: "headless", title: "Work with the app closed", icon: Server },
  { id: "memory", title: "Memory & Context", icon: Brain },
  { id: "role", title: "Machine role", icon: Laptop },
];

export function DaemonsSection({ vaultPath, embedded = false, sel: selProp }: { vaultPath: string; embedded?: boolean; sel?: string }) {
  // Installed runtimes for the provider dropdown (the global default executor for
  // distill + loops). Only ones actually on the machine; harnesses included so a
  // loop can default to an agent.
  const installedRuntimes = useDetectedClis().filter((c) => c.available);
  const provModels = installedRuntimes.map((c) => c.id).filter((id) => !isHarnessRuntime(id));
  const provHarnesses = installedRuntimes.map((c) => c.id).filter((id) => isHarnessRuntime(id));
  const [distillSt, setDistillSt] = useState<DaemonStatus | null>(null);
  const [remindersSt, setRemindersSt] = useState<DaemonStatus | null>(null);
  const [taskgenSt, setTaskgenSt] = useState<DaemonStatus | null>(null);
  const [taskgenEnabled, setTaskgenEnabled] = useState(() => getPref(PREF.taskgenEnabled, "0") === "1");
  const [taskgenModel, setTaskgenModel] = useState(() => getPref(PREF.taskgenModel, "claude-haiku-4-5"));
  const [taskgenInterval, setTaskgenInterval] = useState(() => getPref(PREF.taskgenIntervalSec, "3600"));
  const [taskgenMax, setTaskgenMax] = useState(() => getPref(PREF.taskgenMaxPerDomain, "3"));
  const [skillgenSt, setSkillgenSt] = useState<DaemonStatus | null>(null);
  const [skillgenEnabled, setSkillgenEnabled] = useState(() => getPref(PREF.skillgenEnabled, "1") === "1");
  const [skillgenModel, setSkillgenModel] = useState(() => getPref(PREF.skillgenModel, "claude-haiku-4-5"));
  const [skillgenInterval, setSkillgenInterval] = useState(() => getPref(PREF.skillgenIntervalSec, "21600"));
  const [skillgenMax, setSkillgenMax] = useState(() => getPref(PREF.skillgenMaxPerDomain, "2"));
  const [skillgenMsg, setSkillgenMsg] = useState("");
  const [skillgenRunning, setSkillgenRunning] = useState(false);
  const [remInterval, setRemInterval] = useState(() => getPref(PREF.remindersIntervalSec, "900"));
  const [taskgenMsg, setTaskgenMsg] = useState("");
  const [running, setRunning] = useState(false);
  const [selOwn, setSel] = useState("distill");
  const sel = selProp ?? selOwn;
  const [picked, setPicked] = useState(false);
  const phone = useIsPhone();
  // Intent distillation routine (automated, default ON).
  const [intentSt, setIntentSt] = useState<{ running?: boolean; last_run_ts?: number | null; distills?: number; last_intent_count?: number } | null>(null);
  const [intentEnabled, setIntentEnabled] = useState(() => getPref(PREF.intentDaemonEnabled, "1") === "1");
  const [intentMinNew, setIntentMinNew] = useState(() => getPref(PREF.intentDaemonMinNew, "10"));
  const [intentInterval, setIntentInterval] = useState(() => getPref(PREF.intentDaemonIntervalSec, "1800"));
  // Distill (memory) tuning - moved here from Memory & Context so all routine
  // operation lives in one place. These write the same prefs distillCfgFromPrefs reads.
  const [dProvider, setDProvider] = useState(() => getPref(PREF.memoryProvider, "claude"));
  const [dModel, setDModel] = useState(() => cheapModel());
  const [dAuto, setDAuto] = useState(() => getPref(PREF.autoCompression, "1") === "1");
  const [dThreshold, setDThreshold] = useState(() => getPref(PREF.compressionThreshold, "0.5"));
  const [dTarget, setDTarget] = useState(() => getPref(PREF.compressionTarget, "0.2"));
  const [dProtected, setDProtected] = useState(() => getPref(PREF.protectedRecent, "20"));
  const [dInterval, setDInterval] = useState(() => getPref(PREF.distillIntervalSec, "900"));
  const [distilling, setDistilling] = useState(false);
  const [distillMsg, setDistillMsg] = useState("");
  async function distillNow() {
    setDistilling(true); setDistillMsg("");
    try {
      const lines = await invoke<number>("distill_run_once", { cfg: distillCfgFromPrefs(vaultPath) });
      setDistillMsg(lines > 0 ? `Distilled ${lines} entr${lines === 1 ? "y" : "ies"} into memory.` : "Nothing new to distill yet.");
    } catch (e) { setDistillMsg(`Failed: ${e}`); }
    finally { setDistilling(false); }
  }

  useEffect(() => {
    let alive = true;
    // Independent reads: all five at once.
    const poll = async () => {
      await Promise.all([
        invoke<DaemonStatus>("distill_status").then((s) => { if (alive) setDistillSt(s); }).catch(() => {}),
        invoke<DaemonStatus>("reminders_daemon_status").then((s) => { if (alive) setRemindersSt(s); }).catch(() => {}),
        invoke<DaemonStatus>("taskgen_status").then((s) => { if (alive) setTaskgenSt(s); }).catch(() => {}),
        invoke<DaemonStatus>("skillgen_status").then((s) => { if (alive) setSkillgenSt(s); }).catch(() => {}),
        invoke<typeof intentSt>("intent_daemon_status").then((s) => { if (alive) setIntentSt(s); }).catch(() => {}),
      ]);
    };
    poll();
    const id = window.setInterval(poll, 2000);
    return () => { alive = false; window.clearInterval(id); };
  }, []);

  // Machine role (hub | client) for a vault shared across two Macs. A client
  // captures prompts only; every processing daemon is disabled here (enforcement
  // lives in the CLI, this is presentation-only). Sourced from `prevail role`.
  const [machineRole, setMachineRoleState] = useState<"hub" | "client">("hub");
  const [roleBusy, setRoleBusy] = useState(false);
  const isClient = machineRole === "client";
  useEffect(() => {
    let alive = true;
    invoke<string>("machine_role_get").then((r) => { if (alive) setMachineRoleState(r === "client" ? "client" : "hub"); }).catch(() => {});
    return () => { alive = false; };
  }, []);
  async function pickRole(next: "hub" | "client") {
    if (next === machineRole || roleBusy) return;
    setRoleBusy(true);
    try {
      await invoke<string>("machine_role_set", { role: next });
      setMachineRoleState(next);
      // Let the bottom trust-bar badge refresh immediately.
      window.dispatchEvent(new Event("prevail:role-changed"));
    } catch { /* leave the previous role selected on failure */ }
    finally { setRoleBusy(false); }
  }

  const Row = ({ title, desc, control }: { title: string; desc: string; control: React.ReactNode }) => (
    <div className="flex items-start justify-between gap-6 border-b border-border-subtle py-4 last:border-0">
      <div className="min-w-0 flex-1">
        <div className="text-sm font-semibold text-text-primary">{title}</div>
        <div className="mt-0.5 text-xs text-text-secondary">{desc}</div>
      </div>
      <div className="shrink-0">{control}</div>
    </div>
  );

  async function runTaskgenNow() {
    setRunning(true); setTaskgenMsg("");
    try {
      const n = await invoke<number>("taskgen_run_once", { cfg: taskgenCfgFromPrefs(vaultPath) });
      setTaskgenMsg(n > 0 ? `Generated ${n} task${n === 1 ? "" : "s"}.` : "No new tasks (domains need memory/state first).");
    } catch (e) { setTaskgenMsg(`Failed: ${e}`); }
    finally { setRunning(false); }
  }

  async function runSkillgenNow() {
    setSkillgenRunning(true); setSkillgenMsg("");
    try {
      const n = await invoke<number>("skillgen_run_once", { cfg: skillgenCfgFromPrefs(vaultPath) });
      setSkillgenMsg(n > 0 ? `Learned ${n} skill${n === 1 ? "" : "s"}.` : "No new skills (domains need conversation history first).");
    } catch (e) { setSkillgenMsg(`Failed: ${e}`); }
    finally { setSkillgenRunning(false); }
  }

  const items: DaemonItem[] = [
    { id: "distill", hubOnly: true, does: "Distills your recent activity into each domain's memory.", icon: Brain, title: "Distill · memory", running: !!distillSt?.running, enabled: dAuto, summary: distillSt?.lines_distilled ? `${distillSt.lines_distilled} lines distilled` : dAuto ? `auto · every ${dInterval}s` : "manual only" },
    { id: "reminders", hubOnly: true, does: "Checks for tasks coming due and reminds you.", icon: Bell, title: "Reminders", running: !!remindersSt?.running, summary: remindersSt?.last_due_count != null ? (remindersSt.last_due_count > 0 ? `${remindersSt.last_due_count} due` : "none due") : `every ${remInterval}s` },
    { id: "taskgen", hubOnly: true, does: "Suggests new tasks from your goals, memory and domain state.", icon: ListChecks, title: "Task generation", running: !!taskgenSt?.running, enabled: taskgenEnabled, summary: taskgenSt?.tasks_generated ? `${taskgenSt.tasks_generated} generated` : taskgenEnabled ? "on" : "off" },
    { id: "skillgen", hubOnly: true, does: "Learns reusable skills from each domain's conversations.", icon: GraduationCap, title: "Skill learning", running: !!skillgenSt?.running, enabled: skillgenEnabled, summary: skillgenSt?.skills_created ? `${skillgenSt.skills_created} learned` : skillgenEnabled ? "on" : "off" },
    { id: "intent", hubOnly: true, does: "Infers your high-level intents from the prompts you type.", icon: Lightbulb, title: "Intent distillation", running: !!intentSt?.running, enabled: intentEnabled, summary: intentSt?.last_intent_count ? `${intentSt.last_intent_count} intents` : intentEnabled ? "Auto" : "Off" },
    { id: "headless", icon: Server, title: "Work with the app closed", does: "Keeps learning in the background after you quit Glyph Studio." },
    { id: "memory", does: "The memory and context these routines produce.", icon: Brain, title: "Memory & Context", summary: "what the daemons produce" },
    { id: "role", icon: isClient ? Laptop : Server, title: "This machine's role", summary: isClient ? "Client" : "Hub", does: "Only the hub runs background automation when two Macs share a vault." },
  ];
  const list = (
    <nav className="space-y-0.5 p-2" aria-label="Daemons">
      {items.map((it) => {
        const on = sel === it.id && (!phone || picked);
        const Icon = it.icon;
        return (
          <button key={it.id} data-testid={`daemon-row-${it.id}`} aria-current={on ? "true" : undefined} onClick={() => { setSel(it.id); setPicked(true); }}
            className={`flex w-full items-center gap-2.5 rounded-lg px-2.5 py-2 text-left transition-colors ${on ? "bg-surface-warm" : "hover:bg-surface-warm/50"}`}>
            <TintIcon icon={Icon} />
            <span className="min-w-0 flex-1">
              <span className={`block truncate text-sm ${on ? "font-semibold text-text-primary" : "text-text-secondary"}`}>{it.title}</span>
              <span className="block truncate text-[12px] text-text-muted">{[it.hubOnly ? "Hub only" : null, typeof it.summary === "string" ? it.summary : null].filter(Boolean).join(" · ")}</span>
            </span>
            {it.running !== undefined && <DaemonDot running={it.running} enabled={it.enabled} />}
          </button>
        );
      })}
    </nav>
  );
  const detailBody = (
    <>

      {/* Machine role picker. When a vault is shared by two Macs, only the hub
          runs background automation; a client captures prompts only. This is a
          per-machine setting (not stored in the vault). */}
      {sel === "role" && (
      <div className="mb-4 rounded-lg border border-border-subtle bg-background p-4" data-testid="daemon-detail-role">
        <div className="flex items-start justify-between gap-4">
          <div className="min-w-0">
            <div className="text-sm font-semibold text-text-primary">This machine's role</div>
            <div className="mt-0.5 text-xs text-text-secondary">
              When one vault is shared by two Macs, only the hub runs background automation. A client captures prompts only. This is a per-machine setting and is not stored in the vault.
            </div>
          </div>
          <div className="flex shrink-0 gap-1 rounded-lg border border-border bg-surface p-1">
            {(["hub", "client"] as const).map((r) => {
              const Icon = r === "hub" ? Server : Laptop;
              const active = machineRole === r;
              return (
                <button
                  key={r}
                  type="button"
                  disabled={roleBusy}
                  onClick={() => pickRole(r)}
                  className={`inline-flex items-center gap-1.5 rounded-md px-3 py-1.5 text-[12px] transition-colors disabled:opacity-40 ${
                    active ? "bg-accent text-white" : "text-text-muted hover:text-accent"
                  }`}
                >
                  <Icon className="h-3.5 w-3.5" />
                  {r === "hub" ? "Hub" : "Client"}
                </button>
              );
            })}
          </div>
        </div>
        {isClient && (
          <div className="mt-3 rounded-md border border-warn/40 bg-warn/10 px-3 py-2 text-xs text-text-secondary">
            This machine is a client. The processing daemons run only on the hub, so they are disabled here. Prompt capture still runs on this machine. Set the role to hub to run automation here.
          </div>
        )}
      </div>
      )}
      {isClient && sel !== "role" && sel !== "memory" && (
        <div className="mb-4 rounded-md border border-warn/40 bg-warn/10 px-3 py-2 text-xs text-text-secondary">This machine is a client, so this routine runs on the hub only.</div>
      )}

      {/* On a client the processing-daemon controls are disabled (presentation
          only; the CLI is the real enforcement). A disabled fieldset natively
          switches off every toggle, select, input and button it contains. */}
      <fieldset disabled={isClient} className={`min-w-0 ${isClient ? "pointer-events-none opacity-50" : ""}`}>
      {/* One collapsible group per routine: status + tuning + run-now together. */}
      <DaemonGroup id="distill" control={<DaemonCard bare
          name="Distill"
          intervalSec={Number(dInterval) || undefined}
          status={distillSt}
          extra={distillSt?.lines_distilled ? `${distillSt.lines_distilled} lines distilled` : null}
          onStop={async () => { await invoke("distill_stop"); }}
          onStart={async () => { await invoke("distill_start", { cfg: distillCfgFromPrefs(vaultPath) }); }}
        />}>
        <div className="mt-3 rounded-lg border border-border-subtle bg-background px-5">
          <Row title="Distill provider" desc="Which agent distills the intent ledger into memory (use a cheap, fast one)."
            control={
              <select value={dProvider} onChange={(e) => { setDProvider(e.target.value); setPref(PREF.memoryProvider, e.target.value); }}
                className="rounded-md border border-border bg-background px-3 py-1.5 text-sm focus:border-accent-border focus:outline-none">
                {provModels.length === 0 && provHarnesses.length === 0 && <option value={dProvider}>{VENDOR_BRAND[dProvider]?.name ?? dProvider}</option>}
                {provModels.length > 0 && (
                  <optgroup label="Models">
                    {provModels.map((id) => <option key={id} value={id}>{VENDOR_BRAND[id]?.name ?? id}</option>)}
                  </optgroup>
                )}
                {provHarnesses.length > 0 && (
                  <optgroup label="Harnesses (agent)">
                    {provHarnesses.map((id) => <option key={id} value={id}>{VENDOR_BRAND[id]?.name ?? id}</option>)}
                  </optgroup>
                )}
              </select>} />
          <Row title="Distill model" desc="Model id used for distillation, e.g. a small, fast model id."
            control={<input value={dModel} onChange={(e) => { setDModel(e.target.value); setPref(PREF.distillModel, e.target.value); }}
              className="w-44 rounded-md border border-border bg-background px-2 py-1.5 text-sm focus:border-accent-border focus:outline-none" />} />
          <Row title="Auto-compression" desc="Run the distill routine on a timer (off = manual passes only)."
            control={<Toggle on={dAuto} onChange={(v) => { setDAuto(v); setPref(PREF.autoCompression, v ? "1" : "0"); }} />} />
          <Row title="Compression threshold" desc="Start distilling once new activity reaches this fraction of the memory budget."
            control={<input type="number" step="0.1" value={dThreshold} onChange={(e) => { setDThreshold(e.target.value); setPref(PREF.compressionThreshold, e.target.value); }}
              className="w-20 rounded-md border border-border bg-background px-2 py-1.5 text-right text-sm focus:border-accent-border focus:outline-none" />} />
          <Row title="Compression target" desc="Compress memory toward this fraction of the budget."
            control={<input type="number" step="0.1" value={dTarget} onChange={(e) => { setDTarget(e.target.value); setPref(PREF.compressionTarget, e.target.value); }}
              className="w-20 rounded-md border border-border bg-background px-2 py-1.5 text-right text-sm focus:border-accent-border focus:outline-none" />} />
          <Row title="Protected recent" desc="Never distill the most-recent N ledger entries: keep them raw."
            control={<input type="number" value={dProtected} onChange={(e) => { setDProtected(e.target.value); setPref(PREF.protectedRecent, e.target.value); }}
              className="w-20 rounded-md border border-border bg-background px-2 py-1.5 text-right text-sm focus:border-accent-border focus:outline-none" />} />
          <Row title="Distill interval" desc="How often the distill routine runs a pass (seconds)."
            control={<div className="flex items-center gap-1.5"><input type="number" value={dInterval} onChange={(e) => { setDInterval(e.target.value); setPref(PREF.distillIntervalSec, e.target.value); }}
              className="w-20 rounded-md border border-border bg-background px-2 py-1.5 text-right text-sm focus:border-accent-border focus:outline-none" /><span className="text-xs text-text-muted">s</span></div>} />
          <Row title="Distill now" desc="Run a distillation pass immediately."
            control={<button onClick={distillNow} disabled={distilling}
              className="rounded-md border border-border bg-background px-3 py-1.5 text-[12px] text-text-muted hover:border-accent-border hover:text-accent disabled:opacity-40">
              {distilling ? "distilling…" : "distill now"}</button>} />
          {distillMsg && <div className="pb-3 text-xs text-text-secondary">{distillMsg}</div>}
        </div>
      </DaemonGroup>

      <DaemonGroup id="reminders" control={<DaemonCard bare
          name="Reminders"
          intervalSec={Number(remInterval) || undefined}
          status={remindersSt}
          extra={remindersSt?.last_due_count != null
            ? remindersSt.last_due_count > 0
              ? `${remindersSt.last_due_count} task${remindersSt.last_due_count === 1 ? "" : "s"} due`
              : "no due tasks"
            : null}
          onStop={async () => { await invoke("reminders_daemon_stop"); }}
          onStart={async () => {
            const sec = Number(getPref(PREF.remindersIntervalSec, "900")) || 900;
            await invoke("reminders_daemon_start", { vault: vaultPath, interval_sec: sec });
          }}
        />}>
        <div className="mt-3 rounded-lg border border-border-subtle bg-background px-5">
          <Row title="Reminders interval" desc="How often the reminders routine checks for due tasks (seconds)."
            control={
              <div className="flex items-center gap-1.5">
                <input type="number" value={remInterval} onChange={(e) => { setRemInterval(e.target.value); setPref(PREF.remindersIntervalSec, e.target.value); }}
                  className="w-20 rounded-md border border-border bg-background px-2 py-1.5 text-right text-sm focus:border-accent-border focus:outline-none" />
                <span className="text-xs text-text-muted">s</span>
              </div>
            } />
        </div>
      </DaemonGroup>

      <DaemonGroup id="taskgen" control={<DaemonCard bare
          name="Task Gen"
          intervalSec={Number(taskgenInterval) || undefined}
          status={taskgenSt}
          extra={taskgenSt?.tasks_generated ? `${taskgenSt.tasks_generated} tasks generated` : null}
          onStop={async () => { await invoke("taskgen_stop"); }}
          onStart={async () => { await invoke("taskgen_start", { cfg: taskgenCfgFromPrefs(vaultPath) }); }}
        />}>
        <div className="mt-3 rounded-lg border border-border-subtle bg-background px-5">
          <Row title="Task generation" desc="Proactively generate new tasks from your goals, memory, and domain state once per day."
            control={<Toggle on={taskgenEnabled} onChange={(v) => { setTaskgenEnabled(v); setPref(PREF.taskgenEnabled, v ? "1" : "0"); if (!v) invoke("taskgen_stop").catch(() => {}); else invoke("taskgen_start", { cfg: taskgenCfgFromPrefs(vaultPath) }).catch(() => {}); }} />} />
          <Row title="Task gen model" desc="Model used to generate task suggestions (use a cheap, fast model)."
            control={<input value={taskgenModel} onChange={(e) => { setTaskgenModel(e.target.value); setPref(PREF.taskgenModel, e.target.value); }}
              className="w-44 rounded-md border border-border bg-background px-2 py-1.5 text-sm focus:border-accent-border focus:outline-none" />} />
          <Row title="Tasks per domain" desc="Maximum tasks generated per domain per day."
            control={<input type="number" value={taskgenMax} onChange={(e) => { setTaskgenMax(e.target.value); setPref(PREF.taskgenMaxPerDomain, e.target.value); }}
              className="w-16 rounded-md border border-border bg-background px-2 py-1.5 text-right text-sm focus:border-accent-border focus:outline-none" />} />
          <Row title="Task gen interval" desc="How often the task-gen routine checks for domains that need new tasks (seconds)."
            control={
              <div className="flex items-center gap-1.5">
                <input type="number" value={taskgenInterval} onChange={(e) => { setTaskgenInterval(e.target.value); setPref(PREF.taskgenIntervalSec, e.target.value); }}
                  className="w-20 rounded-md border border-border bg-background px-2 py-1.5 text-right text-sm focus:border-accent-border focus:outline-none" />
                <span className="text-xs text-text-muted">s</span>
              </div>
            } />
        </div>
        <div className="mt-3 flex flex-wrap items-center gap-2">
          <button onClick={runTaskgenNow} disabled={running}
            className="rounded-md border border-border bg-background px-3 py-1.5 text-[12px] text-text-muted hover:border-accent-border hover:text-accent disabled:opacity-40">
            {running ? "generating…" : "generate tasks now"}
          </button>
          {taskgenMsg && <span className="text-xs text-text-secondary">{taskgenMsg}</span>}
        </div>
      </DaemonGroup>

      <DaemonGroup id="skillgen" control={<DaemonCard bare
          name="Skill Gen"
          intervalSec={Number(skillgenInterval) || undefined}
          status={skillgenSt}
          extra={skillgenSt?.skills_created ? `${skillgenSt.skills_created} skill${skillgenSt.skills_created === 1 ? "" : "s"} learned` : null}
          onStop={async () => { await invoke("skillgen_stop"); }}
          onStart={async () => { await invoke("skillgen_start", { cfg: skillgenCfgFromPrefs(vaultPath) }); }}
        />}>
        <div className="mt-3 rounded-lg border border-border-subtle bg-background px-5">
          <Row title="Skill learning" desc="Self-learning: distill reusable skills (playbooks, checklists, decision frameworks) from each domain's conversations, once per day."
            control={<Toggle on={skillgenEnabled} onChange={(v) => { setSkillgenEnabled(v); setPref(PREF.skillgenEnabled, v ? "1" : "0"); if (!v) invoke("skillgen_stop").catch(() => {}); else invoke("skillgen_start", { cfg: skillgenCfgFromPrefs(vaultPath) }).catch(() => {}); }} />} />
          <Row title="Skill gen model" desc="Model used to learn skills from conversations (use a cheap, fast model)."
            control={<input value={skillgenModel} onChange={(e) => { setSkillgenModel(e.target.value); setPref(PREF.skillgenModel, e.target.value); }}
              className="w-44 rounded-md border border-border bg-background px-2 py-1.5 text-sm focus:border-accent-border focus:outline-none" />} />
          <Row title="Skills per domain" desc="Maximum new skills learned per domain per day."
            control={<input type="number" value={skillgenMax} onChange={(e) => { setSkillgenMax(e.target.value); setPref(PREF.skillgenMaxPerDomain, e.target.value); }}
              className="w-16 rounded-md border border-border bg-background px-2 py-1.5 text-right text-sm focus:border-accent-border focus:outline-none" />} />
          <Row title="Skill gen interval" desc="How often the skill-learning routine scans domains for new lessons (seconds; default 6h)."
            control={
              <div className="flex items-center gap-1.5">
                <input type="number" value={skillgenInterval} onChange={(e) => { setSkillgenInterval(e.target.value); setPref(PREF.skillgenIntervalSec, e.target.value); }}
                  className="w-20 rounded-md border border-border bg-background px-2 py-1.5 text-right text-sm focus:border-accent-border focus:outline-none" />
                <span className="text-xs text-text-muted">s</span>
              </div>
            } />
        </div>
        <div className="mt-3 flex flex-wrap items-center gap-2">
          <button onClick={runSkillgenNow} disabled={skillgenRunning}
            className="rounded-md border border-border bg-background px-3 py-1.5 text-[12px] text-text-muted hover:border-accent-border hover:text-accent disabled:opacity-40">
            {skillgenRunning ? "learning…" : "learn skills now"}
          </button>
          {skillgenMsg && <span className="text-xs text-text-secondary">{skillgenMsg}</span>}
        </div>
      </DaemonGroup>

      <DaemonGroup id="intent">
        {/* Like the other routines: when it last ran + when it runs next. */}
        {(() => {
          const fmt = (sec: number) => new Date(sec * 1000).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
          const last = intentSt?.last_run_ts ?? 0;
          const nextSec = last && intentEnabled ? last + (Number(intentInterval) || 0) : 0;
          return (
            <div className="mb-2 flex items-center gap-2 px-1 text-[12px] text-text-muted">
              <DaemonDot running={!!intentSt?.running} enabled={intentEnabled} />
              <span>
                {intentSt?.running ? "Running" : "Idle"}
                {last ? ` · last pass ${formatFreshness(Math.max(0, Date.now() / 1000 - last))}` : ""}
                {nextSec ? ` · next ~${fmt(nextSec)}` : ""}
              </span>
            </div>
          );
        })()}
        <div className="rounded-lg border border-border-subtle bg-background px-5">
          <Row title="Automatic intent distillation"
            desc="Infer your high-level intents + recommended actions automatically, with no manual click. Runs on a cadence and whenever enough new prompts pile up."
            control={<Toggle on={intentEnabled} onChange={(v) => {
              setIntentEnabled(v); setPref(PREF.intentDaemonEnabled, v ? "1" : "0");
              if (v) invoke("intent_daemon_start", { cfg: intentDaemonCfgFromPrefs(vaultPath) }).catch(() => {});
              else invoke("intent_daemon_stop").catch(() => {});
            }} />} />
          <Row title="Distill after N new prompts"
            desc="Re-distill once this many new prompts have been logged since the last pass."
            control={<input type="number" value={intentMinNew} onChange={(e) => { setIntentMinNew(e.target.value); setPref(PREF.intentDaemonMinNew, e.target.value); }}
              className="w-20 rounded-md border border-border bg-background px-2 py-1.5 text-right text-sm focus:border-accent-border focus:outline-none" />} />
          <Row title="Check interval"
            desc="How often the routine checks whether a re-distill is due (a check with nothing new costs no model call). It also re-distills at least daily."
            control={<div className="flex items-center gap-1.5"><input type="number" value={intentInterval} onChange={(e) => { setIntentInterval(e.target.value); setPref(PREF.intentDaemonIntervalSec, e.target.value); }}
              className="w-24 rounded-md border border-border bg-background px-2 py-1.5 text-right text-sm focus:border-accent-border focus:outline-none" /><span className="text-xs text-text-muted">s</span></div>} />
        </div>
        <p className="mt-2 px-1 text-[12px] text-text-muted">View the distilled intents in Configuration → Intents. Uses the same provider/model as Distill.</p>
      </DaemonGroup>

      {/* image #29: Memory & Context is what these routines PRODUCE, so it lives
          here as a peer collapsible group, not a divider-separated orphan page. */}
      <DaemonGroup id="memory">
        <MemoryContextSection vaultPath={vaultPath} headerless />
      </DaemonGroup>

      {/* "Keep working with the app closed" is always-expanded (a single toggle, not
          collapsible), so it sits LAST - below the collapsible routine rows. */}
      {sel === "headless" && <DaemonGroup id="headless"><HeadlessLearnCard vaultPath={vaultPath} /></DaemonGroup>}
      </fieldset>
    </>
  );
  // Embedded in the Settings page: that page's column lists the routines, so
  // this renders only the picked one.
  if (embedded) return <DaemonSel.Provider value={{ sel, items }}>{detailBody}</DaemonSel.Provider>;
  return (
    <DaemonSel.Provider value={{ sel, items }}>
      <SettingsHeader
        title="Daemons"
        subtitle="The background workers, and what each is doing."
      />
      <SideSpine storageKey="prevail.daemons.spine" title="Daemons" label="daemons" testId="daemons-list"
        phone={phone} phoneDetail={phone && picked} onBack={() => setPicked(false)} backLabel="All daemons"
        detail={<div className={phone ? "px-4 py-4" : "w-full px-8 py-6"}>{detailBody}</div>}>
        {list}
      </SideSpine>
    </DaemonSel.Provider>
  );
}

// Shared settings Row used by the Phase 3 sections.

// OpenAI dropped its logo from simple-icons (trademark), so we keep the glyph
// path inline (same one ProviderMark uses for Codex).

// Map an ideal-state section heading to an icon matching its theme, so the
// rendered constitution reads as a visual map rather than a text wall.

export function MemoryContextSection({ headerless }: { vaultPath: string; headerless?: boolean }) {
  const [persistent, setPersistent] = useState(() => getPref(PREF.persistentMemory, "1") === "1");
  const [memBudget, setMemBudget] = useState(() => getPref(PREF.memoryBudgetChars, "4000"));
  const [routeOn, setRouteOn] = useState(() => getPref(PREF.routeDomains, "1") === "1");
  const [routeMin, setRouteMin] = useState(() => getPref(PREF.routeThreshold, "0.75"));
  const [status, setStatus] = useState<{ running?: boolean; last_run_ts?: number | null; last_error?: string | null; lines_distilled?: number } | null>(null);

  useEffect(() => {
    let alive = true;
    const poll = async () => {
      try { const s = await invoke<typeof status>("distill_status"); if (alive) setStatus(s); } catch { /* routine not started */ }
    };
    poll();
    const id = window.setInterval(poll, 4000);
    return () => { alive = false; window.clearInterval(id); };
  }, []);

  const Row = ({ title, desc, control }: { title: string; desc: string; control: React.ReactNode }) => (
    <div className="flex items-start justify-between gap-6 border-b border-border-subtle py-4 last:border-0">
      <div className="min-w-0 flex-1">
        <div className="text-sm font-semibold text-text-primary">{title}</div>
        <div className="mt-0.5 text-xs text-text-secondary">{desc}</div>
      </div>
      <div className="shrink-0">{control}</div>
    </div>
  );
  const Num = ({ value, set, pref, w = "w-20", step }: { value: string; set: (v: string) => void; pref: string; w?: string; step?: string }) => (
    <input type="number" step={step} value={value}
      onChange={(e) => { set(e.target.value); setPref(pref, e.target.value); }}
      className={`${w} rounded-md border border-border bg-background px-2 py-1.5 text-right text-sm focus:border-accent-border focus:outline-none`} />
  );

  return (
    <>
      {/* B2-10: skip the header when wrapped in a CollapsibleSection that already
          shows the "Memory & Context" title (avoids the duplicate title). */}
      {!headerless && (
        <SettingsHeader
          title="Memory & Context"
          subtitle="What Glyph Studio has learned about you."
        />
      )}
      {/* The distiller runs on the Daemons page; this is its outcome view. A
          live status chip links across so the two pages are clearly related. */}
      <button
        onClick={() => window.dispatchEvent(new CustomEvent("prevail:settings-section", { detail: "daemons" }))}
        className="mb-4 flex w-full items-center gap-2 rounded-lg border border-border-subtle bg-surface px-4 py-2.5 text-left hover:border-accent-border"
      >
        <Brain className="h-3.5 w-3.5 shrink-0 text-accent" />
        <span className="text-[12px] text-text-secondary">Distiller</span>
        <span className="text-[12px] text-text-muted">
          {status?.running ? "Running" : "Idle"}
          {/* B2-19: last_run_ts is in SECONDS (treating it as ms gave "20601 days");
              formatFreshness already returns "... ago" (don't append a second one). */}
          {status?.last_run_ts ? ` · last pass ${formatFreshness(Math.max(0, Date.now() / 1000 - status.last_run_ts))}` : ""}
          {status?.lines_distilled ? ` · ${status.lines_distilled} lines` : ""}
        </span>
        <span className="ml-auto text-[12px] text-accent">Schedule & controls in Daemons →</span>
      </button>
      <div>
        <Row title="Persistent memory" desc="Distill the intent ledger into per-domain memory and prepend it to prompts. Master switch."
          control={<Toggle on={persistent} onChange={(v) => { setPersistent(v); setPref(PREF.persistentMemory, v ? "1" : "0"); }} />} />
        <Row title="Memory budget" desc="Hard cap (characters) on the distilled memory injected into each prompt."
          control={<Num value={memBudget} set={setMemBudget} pref={PREF.memoryBudgetChars} w="w-24" />} />
        <Row title="File General chats in domains" desc="When a General conversation is about a domain, tag it there and include that domain's context. Only the message text is sent to the routing model."
          control={<Toggle on={routeOn} onChange={(v) => { setRouteOn(v); setPref(PREF.routeDomains, v ? "1" : "0"); }} />} />
        <Row title="Filing confidence" desc="How sure routing must be (0 to 1) before it files a conversation. Below this it only suggests."
          control={<Num value={routeMin} set={setRouteMin} pref={PREF.routeThreshold} w="w-24" step="0.05" />} />
        <Row title="Context engine" desc="Strategy for managing long conversations near the context limit."
          control={
            <select value={getPref(PREF.contextEngine, "compressor")} onChange={(e) => setPref(PREF.contextEngine, e.target.value)}
              className="rounded-md border border-border bg-background px-3 py-1.5 text-sm focus:border-accent-border focus:outline-none">
              <option value="compressor">Compressor</option>
            </select>
          } />
      </div>
      <div className="mt-3 rounded-lg border border-border-subtle bg-surface px-4 py-2.5 text-xs text-text-muted">
        The distiller (its provider, interval, threshold, and a manual "distill now") is configured on the Daemons page. This page is what it produces.
      </div>
    </>
  );
}

// ── Daemon card ───────────────────────────────────────────────────────────────


// ── Daemons settings panel ────────────────────────────────────────────────────
// Run the self-learning loop with the desktop CLOSED, via a launchd agent
// (engine `daemon install`). When on, the in-app distiller defers to it.

