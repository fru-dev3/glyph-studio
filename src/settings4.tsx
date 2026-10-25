// Settings sections extracted from App.tsx: Safety (approvals/guardrails),
// Ideal State (life-pillar alignment), and the General section (appearance,
// start-on-boot, embedded Shortcuts).
import { useEffect, useMemo, useState } from "react";
import { FilingSettings } from "./filingplan";
import { disable as autostartDisable, enable as autostartEnable, isEnabled as autostartIsEnabled } from "@tauri-apps/plugin-autostart";
import { Activity, Clock, Compass, Eye, EyeOff, FileClock, FolderOpen, Globe, History, Lock, Monitor, Moon, Palette, PenLine, RefreshCw, ShieldAlert, ShieldCheck, SlidersHorizontal, Sun, Terminal } from "lucide-react";
import { open as openDialog } from "@tauri-apps/plugin-dialog";
import { ObsidianLogo, getObsidianPath, setObsidianPath } from "./obsidianmodal";
import type { LucideIcon } from "lucide-react";
import { CollapsibleSection } from "./collapsible";
import { ALLOWED_EVENTS, clearTelemetryLog, crashOn, setCrash, setUsage, telemetryConfigured, telemetryLog, usageOn } from "./telemetry";
import { invoke } from "./bridge";
import { PALETTES } from "./constants";
import { LS, PREF, getPref, lsGet, setPref } from "./storage";
import { Toggle } from "./ui";
import { Markdown } from "./Markdown";
import { AlignmentCard, AppLockCard, SettingsRowLite } from "./panels";
import { PaletteCard } from "./panels3";
import { useAppearance } from "./hooks";
import { SettingsHeader, idealSectionIcon } from "./sectionutil";
import { VaultEncryptionCard } from "./settings3";
import type { Mode } from "./types";
import { DETAIL_TITLE, SECTION_TITLE } from "./typescale";

// SAFETY-1: a labelled cluster header so the panel reads as deliberate groups
// (Access protection vs Agent guardrails) instead of one flat stack of rows.
function SafetyGroup({ icon: Icon, label, desc, children }: { icon: LucideIcon; label: string; desc?: string; children: React.ReactNode }) {
  return (
    <div className="mb-6">
      <div className="mb-2 flex items-center gap-2 px-1">
        <Icon className="h-3.5 w-3.5 text-accent" />
        <h3 className="text-sm font-semibold text-text-primary">{label}</h3>
        {desc && <span className="ml-auto text-[12px] text-text-muted">{desc}</span>}
      </div>
      {children}
    </div>
  );
}

// SAFETY-1: a guardrail row with a leading state icon (lit when active) so each
// control reads as a deliberate, premium switch rather than a bare label row.
function GuardRow({ icon: Icon, title, desc, control, active }: { icon: LucideIcon; title: string; desc?: string; control: React.ReactNode; active?: boolean }) {
  return (
    <div className="flex items-start gap-3 border-b border-border-subtle px-4 py-3.5 last:border-0">
      <span className={`mt-0.5 flex h-8 w-8 shrink-0 items-center justify-center rounded-lg transition-colors ${active ? "bg-accent-soft text-accent" : "bg-surface-warm text-text-muted"}`}>
        <Icon className="h-4 w-4" />
      </span>
      <div className="min-w-0 flex-1">
        <div className="text-sm font-semibold text-text-primary">{title}</div>
        {desc && <div className="mt-0.5 text-xs text-text-muted">{desc}</div>}
      </div>
      <div className="shrink-0 self-center">{control}</div>
    </div>
  );
}

// part: one sub-section on its own (the Privacy & Safety page gives each a row).
export function SafetySection({ vaultPath, part }: { vaultPath: string; part?: "access" | "guardrails" }) {
  const [approvalMode, setApprovalMode] = useState(() => getPref(PREF.approvalMode, "manual"));
  const [approvalTimeout, setApprovalTimeout] = useState(() => getPref(PREF.approvalTimeoutSec, "60"));
  const [confirmMcp, setConfirmMcp] = useState(() => getPref(PREF.confirmMcpReloads, "1") === "1");
  const [allowlist, setAllowlist] = useState(() => getPref(PREF.commandAllowlist, ""));
  const [redact, setRedact] = useState(() => getPref(PREF.redactSecrets, "1") !== "0");
  const [allowPrivate, setAllowPrivate] = useState(() => getPref(PREF.allowPrivateUrls, "0") === "1");
  const [checkpoints, setCheckpoints] = useState(() => getPref(PREF.fileCheckpoints, "0") === "1");
  return (
    <>
      <SettingsHeader icon={ShieldCheck} title={part === "access" ? "Access protection" : part === "guardrails" ? "Agent guardrails" : "Safety"}
        subtitle={part === "access" ? "Lock the app and encrypt the vault at rest." : part === "guardrails" ? "What the agent may do without asking." : "What the agent may do, and what gets stored."} />
      {part !== "guardrails" && <SafetyGroup icon={Lock} label="Access protection" desc="Lock the app · encrypt the vault at rest">
        {/* D3: two compact columns instead of two tall stacked blocks. */}
        <div className="grid grid-cols-1 gap-3">
          <AppLockCard />
          <VaultEncryptionCard vaultPath={vaultPath} />
        </div>
      </SafetyGroup>}
      {part !== "access" && <SafetyGroup icon={ShieldAlert} label="Agent guardrails" desc="">
        <div>
          <GuardRow icon={ShieldAlert} active={approvalMode === "manual"} title="Approval mode" desc=""
            control={
              <select value={approvalMode} onChange={(e) => { setApprovalMode(e.target.value); setPref(PREF.approvalMode, e.target.value); }}
                className="rounded-md border border-border bg-background px-3 py-1.5 text-sm focus:border-accent-border focus:outline-none">
                <option value="manual">Manual</option>
                <option value="auto">Auto</option>
              </select>
            } />
          <GuardRow icon={Clock} title="Approval timeout" desc=""
            control={<div className="flex items-center gap-1.5"><input type="number" value={approvalTimeout} onChange={(e) => { setApprovalTimeout(e.target.value); setPref(PREF.approvalTimeoutSec, e.target.value); }} className="w-20 rounded-md border border-border bg-background px-2 py-1.5 text-right text-sm focus:border-accent-border focus:outline-none" /><span className="font-mono text-xs text-text-muted">s</span></div>} />
          <GuardRow icon={RefreshCw} active={confirmMcp} title="Confirm MCP reloads" desc=""
            control={<Toggle on={confirmMcp} onChange={(v) => { setConfirmMcp(v); setPref(PREF.confirmMcpReloads, v ? "1" : "0"); }} />} />
          <GuardRow icon={Terminal} active={!!allowlist.trim()} title="Command allowlist" desc="Run without prompting."
            control={<input value={allowlist} placeholder="git, ls, cat" onChange={(e) => { setAllowlist(e.target.value); setPref(PREF.commandAllowlist, e.target.value); }} className="w-56 rounded-md border border-border bg-background px-2 py-1.5 text-sm focus:border-accent-border focus:outline-none" />} />
          <GuardRow icon={EyeOff} active={redact} title="Redact secrets" desc="Keys and passwords never reach a saved transcript."
            control={<Toggle on={redact} onChange={(v) => { setRedact(v); setPref(PREF.redactSecrets, v ? "1" : "0"); }} />} />
          <GuardRow icon={Globe} active={allowPrivate} title="Allow private URLs" desc="Reach localhost and your private network."
            control={<Toggle on={allowPrivate} onChange={(v) => { setAllowPrivate(v); setPref(PREF.allowPrivateUrls, v ? "1" : "0"); }} />} />
          <GuardRow icon={FileClock} active={checkpoints} title="File checkpoints" desc="Edits can be rolled back."
            control={<Toggle on={checkpoints} onChange={(v) => { setCheckpoints(v); setPref(PREF.fileCheckpoints, v ? "1" : "0"); }} />} />
        </div>
      </SafetyGroup>}
    </>
  );
}

// Anonymous telemetry governance. Usage default ON (opt-out), crash default OFF,
// and a fully transparent "what we collect" list + local log. See telemetry.ts
// and docs/TELEMETRY-PLAN.md. Network sends stay inert until build-time keys exist.
export function TelemetrySettings() {
  const [usage, setUsageState] = useState(() => usageOn());
  const [crash, setCrashState] = useState(() => crashOn());
  const [showLog, setShowLog] = useState(false);
  const [, force] = useState(0);
  const log = telemetryLog();
  return (
    <div className="mt-6 border-t border-border-subtle pt-5">
      {/* Minimal: a one-line label (the page is already "Privacy"), two toggles,
          and the collapsed "what we collect" list. Anonymous, on by default, opt-out. */}
      <div className="mb-2 flex items-baseline justify-between">
        <h3 className="text-sm font-semibold text-text-primary">Telemetry</h3>
        <span className="font-mono text-[12px] text-text-muted">anonymous · on by default · one-tap opt-out</span>
      </div>
      <p className="mb-3 text-xs text-text-secondary">Never your prompts, your vault, or anything you named. Off the moment you say so, and Bunker Mode blocks it regardless.</p>
      <div className="mb-3 ">
        <SettingsRowLite title="Usage analytics (anonymous)" desc="Coarse, anonymous events (app opened, which features are used, OS) via PostHog. No content, ever."
          control={<Toggle on={usage} onChange={(v) => { setUsage(v); setUsageState(v); }} />} />
        <SettingsRowLite title="Crash & error reports" desc="Send anonymized crash stack traces (scrubbed of paths/PII) via Sentry so bugs get fixed faster."
          control={<Toggle on={crash} onChange={(v) => { setCrash(v); setCrashState(v); }} />} />
      </div>
      {!telemetryConfigured() && (usage || crash) && (
        <p className="mb-3 px-1 text-[12px] text-text-muted">
          Telemetry is enabled but no analytics keys are built into this release, so nothing is transmitted yet. Events are still recorded to the local log below so you can see exactly what would be sent.
        </p>
      )}
      <CollapsibleSection icon={Activity} title="What we collect" summary={`${ALLOWED_EVENTS.length} event types`}
        subtitle="The complete, exhaustive list. Anything not here is never sent.">
        {/* B2-14: a clean two-column table - event name as a chip, what it carries
            on the right - instead of a plain dash-list. */}
        <div className="overflow-hidden rounded-lg border border-border-subtle bg-background">
          {([
            ["app_opened", "app version, OS family (mac/win)"],
            ["feature_used", "which feature area (chat, council, benchmark…), nothing typed"],
            ["benchmark_run", "counts only (number of models, number of domains)"],
            ["provider_configured", "provider name (e.g. openrouter), never the key"],
            ["daemon_toggled", "which daemon, on/off"],
            ["crash reports", "error type + scrubbed stack trace + app version"],
          ] as [string, string][]).map(([name, desc], i) => (
            <div key={name} className={`flex items-baseline gap-3 px-3 py-2 ${i > 0 ? "border-t border-border-subtle" : ""}`}>
              <span className="w-40 shrink-0 text-[12px] text-text-primary">{name}</span>
              <span className="flex-1 text-[12px] leading-snug text-text-secondary">{desc}</span>
            </div>
          ))}
        </div>
        <div className="mt-3 rounded-md border border-border-subtle bg-background p-2 text-[12px] text-text-muted">
          Never collected: prompts, replies, vault contents, file paths, names of domains/apps/skills you created, API keys, email, name, machine name, or precise location.
        </div>
        <div className="mt-3 flex items-center gap-2">
          <button onClick={() => setShowLog((s) => !s)}
            className="rounded-md border border-border px-2.5 py-1 text-[12px] text-text-secondary hover:border-accent-border hover:text-accent">
            {showLog ? "Hide" : "View"} local log · {log.length}
          </button>
          {log.length > 0 && (
            <button onClick={() => { clearTelemetryLog(); force((n) => n + 1); }}
              className="rounded-md border border-border px-2.5 py-1 text-[12px] text-text-muted hover:border-err hover:text-err">
              Clear log
            </button>
          )}
        </div>
        {showLog && (
          <div className="mt-2 max-h-48 overflow-auto rounded-md border border-border-subtle bg-background p-2 text-[12px] text-text-secondary">
            {log.length === 0 ? <div className="text-text-muted">No events recorded.</div> : log.slice().reverse().map((e, i) => (
              <div key={i} className="border-b border-border-subtle/40 py-0.5 last:border-0">
                <span className={e.sent ? "text-accent" : "text-text-muted"}>{e.sent ? "sent" : "local"}</span>{" "}
                <span className="text-text-primary">{e.event}</span> {JSON.stringify(e.props)}
              </div>
            ))}
          </div>
        )}
      </CollapsibleSection>
    </div>
  );
}

// WhatsApp is rendered as its own (fuller) card below, so it's excluded here.

export function IdealStateSection({ vaultPath, headerless = false }: { vaultPath: string; headerless?: boolean }) {
  const [body, setBody] = useState<string>("");
  const [loaded, setLoaded] = useState(false);
  const [saving, setSaving] = useState(false);
  const [savedAt, setSavedAt] = useState<number | null>(null);
  const [editing, setEditing] = useState(false);
  const [versions, setVersions] = useState<{ name: string; path: string }[]>([]);
  const loadVersions = () =>
    invoke<{ name: string; path: string }[]>("ideal_state_versions", { vault: vaultPath })
      .then((v) => setVersions(Array.isArray(v) ? v : []))
      .catch(() => {});
  useEffect(() => {
    invoke<string>("read_ideal_state", { vault: vaultPath })
      .then((s) => { setBody(typeof s === "string" ? s : ""); setLoaded(true); })
      .catch(() => setLoaded(true));
    void loadVersions();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [vaultPath]);
  async function save() {
    setSaving(true);
    try {
      await invoke("write_ideal_state", { vault: vaultPath, body });
      setSavedAt(Date.now());
      setEditing(false);
      void loadVersions();
    } finally {
      setSaving(false);
    }
  }

  // Split the markdown into an intro plus one block per `## ` heading, so the
  // default view is a structured, icon-marked map of the constitution.
  const parsed = useMemo(() => {
    const lines = body.split("\n");
    let title = "";
    const intro: string[] = [];
    const sections: { title: string; body: string[] }[] = [];
    let cur: { title: string; body: string[] } | null = null;
    for (const line of lines) {
      const h2 = line.match(/^##\s+(.+)/);
      const h1 = line.match(/^#\s+(.+)/);
      if (h2) { cur = { title: h2[1].trim(), body: [] }; sections.push(cur); continue; }
      if (h1 && !cur && !title) { title = h1[1].trim(); continue; }
      (cur ? cur.body : intro).push(line);
    }
    return {
      title,
      intro: intro.join("\n").trim(),
      sections: sections.map((s) => ({ title: s.title, body: s.body.join("\n").trim() })),
    };
  }, [body]);

  return (
    <>
      {!headerless && (
        <SettingsHeader
          title="Ideal State"
          icon={Compass}
          subtitle="The vision everything here optimizes for."
        />
      )}
      <AlignmentCard vaultPath={vaultPath} />
      <div className="mb-4 flex items-center justify-between gap-2">
        <span className="text-[12px] text-text-muted">
          {editing
            ? "Editing markdown"
            : parsed.sections.length > 0
              ? `${parsed.sections.length} section${parsed.sections.length === 1 ? "" : "s"} · highest precedence everywhere`
              : "Highest precedence everywhere"}
        </span>
        <div className="flex items-center gap-2">
          {savedAt && !editing && (
            <span className="text-[12px] text-ok">✓ saved</span>
          )}
          {loaded && (
            <button
              onClick={() => setEditing((e) => !e)}
              className="inline-flex items-center gap-1.5 rounded-md border border-border px-2.5 py-1 text-[12px] text-text-secondary hover:border-accent-border hover:text-accent"
            >
              {editing ? <Eye className="h-3.5 w-3.5" /> : <PenLine className="h-3.5 w-3.5" />}
              {editing ? "View" : "Edit"}
            </button>
          )}
        </div>
      </div>
      {editing ? (
        <div>
          <textarea
            value={body}
            onChange={(e) => setBody(e.target.value)}
            placeholder={"# Operating Vision\n\n## Values\n\n- What every decision should honor\n\n## Wealth\n\n- The position you are building toward"}
            rows={24}
            className="w-full resize-y rounded-lg bg-transparent p-4 text-sm leading-relaxed text-text-primary placeholder:text-text-muted focus:outline-none"
          />
          <div className="flex items-center justify-between gap-2 border-t border-border-subtle px-4 py-2">
            <span className="text-[12px] text-text-muted">
              {body.length.toLocaleString()} chars · sections start with ## headings
            </span>
            <button
              onClick={save}
              disabled={saving || !loaded}
              className="inline-flex items-center gap-1.5 rounded-md bg-accent px-3 py-1.5 text-sm font-medium text-background hover:bg-accent-hover disabled:bg-surface-strong disabled:text-text-muted"
            >
              {saving ? "saving…" : "Save"}
            </button>
          </div>
        </div>
      ) : !loaded ? null : body.trim() === "" ? (
        <div className="flex flex-col items-center gap-3 rounded-xl border border-dashed border-border bg-surface px-6 py-10 text-center">
          <Compass className="h-8 w-8 text-accent" />
          <div className="text-base font-semibold">No Ideal State yet</div>
          <p className="max-w-md text-sm text-text-secondary">
            Write the life you are building and the principles every decision should honor.
            Use ## headings (Values, Wealth, Health, Family) and the page renders them as a map.
          </p>
          <button
            onClick={() => setEditing(true)}
            className="inline-flex items-center gap-1.5 rounded-md bg-accent px-3 py-1.5 text-sm font-medium text-background hover:bg-accent-hover"
          >
            <PenLine className="h-3.5 w-3.5" /> Start writing
          </button>
        </div>
      ) : (
        // M2 (Monday feedback): scratched the bordered-cards layout. Fresh take -
        // an editorial "manifesto": a large vision hero, then each pillar as a
        // numbered chapter with a left accent rule and flowing prose. Single column.
        <div>
          <div className="rounded-2xl border border-border bg-gradient-to-b from-accent-soft/40 to-surface px-6 py-7">
            {!headerless && (
              <div className="text-[12px] font-bold text-accent">My constitution</div>
            )}
            {parsed.title && (
              <h2 className={headerless ? SECTION_TITLE : `mt-2 ${DETAIL_TITLE}`}>{parsed.title}</h2>
            )}
            {parsed.intro && (
              <div className="mt-3 text-[14px] leading-normal text-text-secondary">
                <Markdown source={parsed.intro} compact />
              </div>
            )}
          </div>
          {/* Pillars as numbered chapters - typographic, not card-y. */}
          {parsed.sections.length > 0 ? (
            <div className="mt-7 space-y-7">
              {parsed.sections.map((s, idx) => {
                const Icon = idealSectionIcon(s.title);
                return (
                  <section key={s.title} className="relative border-l-2 border-accent-border/60 pl-5">
                    <div className="flex items-center gap-2.5">
                      <span className="flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-accent text-[12px] font-bold text-background">{idx + 1}</span>
                      <Icon className="h-4 w-4 shrink-0 text-accent" />
                      <h3 className="text-[15px] font-semibold text-text-primary">{s.title}</h3>
                    </div>
                    {s.body && (
                      <div className="mt-2 text-[14px] leading-normal text-text-secondary">
                        <Markdown source={s.body} compact />
                      </div>
                    )}
                  </section>
                );
              })}
            </div>
          ) : (
            <div className="mt-5 rounded-xl border border-border bg-surface p-4 text-sm leading-relaxed text-text-secondary">
              <Markdown source={body} compact />
            </div>
          )}
          {/* Version history: the one canonical collapsible, collapsed by default. */}
          {versions.length > 0 && (
            <CollapsibleSection
              icon={History}
              title="History"
              subtitle="Every edit is snapshotted: nothing is ever lost."
              summary={`${versions.length} version${versions.length === 1 ? "" : "s"}`}
              className="mt-4"
            >
              <div className="flex flex-col gap-1">
                {versions.map((v) => (
                  <div key={v.path} className="flex items-center gap-2 py-1">
                    <span className="flex-1 text-[12px] text-text-secondary">{v.name.replace("_", " · ")}</span>
                    <button
                      onClick={async () => {
                        try {
                          const old = await invoke<string>("read_text_file", { path: v.path });
                          if (window.confirm("Restore this version? The current text is snapshotted first.")) {
                            setBody(old);
                            await invoke("write_ideal_state", { vault: vaultPath, body: old });
                            setSavedAt(Date.now());
                            void loadVersions();
                          }
                        } catch (e) { console.error("restore ideal state", e); }
                      }}
                      className="rounded-md border border-border px-2 py-0.5 text-[12px] text-text-muted hover:border-accent-border hover:text-accent"
                    >
                      Restore
                    </button>
                  </div>
                ))}
              </div>
            </CollapsibleSection>
          )}
        </div>
      )}
    </>
  );
}

// "Demo & Production" - its own top-level Settings section (sibling of Vault):
// the demo/production mode toggle (with the real clean-slate production switch)
// plus the importable starter packs. Kept separate from Vault so the mode
// control is easy to find.


// Obsidian is a file SOURCE: a folder on disk that Prevail reads notes from.
// It lives on the Workspace (vault) screen with the other places data comes
// from, not under General, where it sat between "start on boot" and sound
// effects and nobody would think to look.
export function ObsidianCard() {
  const [obPath, setObPath] = useState<string>(() => getObsidianPath());
  const pickObsidian = async () => {
    try {
      const p = await openDialog({ directory: true, multiple: false, title: "Choose your Obsidian vault folder" });
      if (typeof p === "string") { setObsidianPath(p); setObPath(p); }
    } catch { /* dialog cancelled or unavailable */ }
  };
  return (
      <div className="mb-2 border-t border-border-subtle pt-4">
        <div className="mb-1 flex items-center gap-2">
          <ObsidianLogo className="h-4 w-4" />
          <h3 className="text-sm font-semibold text-text-primary">Obsidian vault</h3>
        </div>
        <p className="mb-3 text-[12px] leading-relaxed text-text-muted">
          Imports your notes as AI-readable source. One-way: Glyph Studio never writes to Obsidian.
        </p>
        <div className="flex flex-wrap items-center gap-2">
          <button onClick={() => void pickObsidian()} className="flex items-center gap-2 rounded-md border border-border bg-background px-3 py-1.5 text-left text-sm text-text-secondary transition-colors hover:border-accent-border">
            <FolderOpen className="h-4 w-4 shrink-0 text-text-muted" />
            <span className="max-w-[280px] truncate">{obPath || "Choose folder..."}</span>
          </button>
          <button disabled={!obPath} onClick={() => window.dispatchEvent(new Event("prevail:import-obsidian"))} className="rounded-md bg-accent px-3 py-1.5 text-sm text-background transition-opacity hover:opacity-90 disabled:opacity-50">
            Import now
          </button>
          {obPath && (
            <button onClick={() => { setObsidianPath(""); setObPath(""); }} className="text-[12px] text-text-muted underline hover:text-accent">Clear</button>
          )}
        </div>
      </div>
  );
}

// part: one sub-section on its own (the Settings page gives each a row).
export function GeneralSection({ appearance, part, vaultPath = "" }: { appearance?: ReturnType<typeof useAppearance>; part?: "main" | "appearance"; vaultPath?: string }) {
  const [startOnBoot, setStartOnBoot] = useState(false);
  useEffect(() => { autostartIsEnabled().then(setStartOnBoot).catch(() => {}); }, []);
  const [closeToTray, setCloseToTray] = useState(() => getPref(PREF.closeToTray, "0") === "1");
  useEffect(() => { invoke("set_close_to_tray", { enabled: closeToTray }).catch(() => {}); }, [closeToTray]);
  const [sendKey, setSendKeyState] = useState(() => getPref(PREF.sendKey, "enter"));
  const [desktopNotif, setDesktopNotif] = useState(() => getPref(PREF.desktopNotif, "0") === "1");
  const [heartbeat, setHeartbeat] = useState(() => getPref(PREF.heartbeatEnabled, "1") === "1");
  const [soundDone, setSoundDone] = useState(() => getPref(PREF.soundOnDone, "0") === "1");
  const [autoConvert, setAutoConvert] = useState(() => getPref(PREF.autoConvertLongPaste, "1") === "1");
  const [stripSyc, setStripSyc] = useState(() => getPref(PREF.stripSycophancy, "0") === "1");
  const [showThinking, setShowThinking] = useState(() => getPref(PREF.showThinking, "1") === "1");
  const [showBriefing, setShowBriefing] = useState(() => getPref(PREF.showHomeBriefing, "0") === "1");
  const [copyOnSelect, setCopyOnSelect] = useState(() => getPref(PREF.copyOnSelect, "1") === "1");
  const [showQuickCapture, setShowQuickCapture] = useState(() => getPref(PREF.quickCaptureEnabled, "0") === "1");
  // Linking: which entities get their own page as you chat. Engine config.
  const [autosave, setAutosave] = useState<string>("yours");
  const [autosaveErr, setAutosaveErr] = useState<string | null>(null);
  useEffect(() => { invoke<string>("engine_config_autosave_get").then((v) => { if (v) setAutosave(v); }).catch(() => {}); }, []);
  const changeAutosave = async (v: string) => {
    const prev = autosave;
    setAutosave(v);
    setAutosaveErr(null);
    try { await invoke("engine_config_autosave_set", { value: v }); }
    catch (e) { setAutosave(prev); setAutosaveErr(String(e)); }
  };
  const [promptTimeout, setPromptTimeout] = useState<string>(() => getPref(PREF.llmPromptTimeoutSec, "300"));
  const [budgetCap, setBudgetCap] = useState<string>(() => getPref(PREF.budgetMonthlyCapUsd, ""));
  // Running spend estimate. Display-only for now: seeded from localStorage. A
  // live engine-backed budget (real per-loop/per-domain spend with hard stops)
  // is tracked separately; until that engine command lands there is nothing to
  // poll, so we do not call one.
  // X4: real month-to-date spend from the engine's usage ledger (falls back to
  // the last-known estimate if the engine is unavailable).
  const [budgetSpent, setBudgetSpent] = useState<number>(() => {
    const v = parseFloat(getPref(PREF.budgetSpentUsd, "0"));
    return Number.isFinite(v) ? v : 0;
  });
  useEffect(() => {
    const vault = lsGet(LS.vault);
    if (!vault) return;
    let alive = true;
    invoke<{ spent_usd?: number }>("engine_budget_status", { vault, domain: null })
      .then((s) => {
        if (!alive || typeof s?.spent_usd !== "number") return;
        setBudgetSpent(s.spent_usd);
        setPref(PREF.budgetSpentUsd, String(s.spent_usd));
      })
      .catch(() => { /* keep the cached estimate */ });
    return () => { alive = false; };
  }, []);
  const capNum = parseFloat(budgetCap);
  const hasCap = Number.isFinite(capNum) && capNum > 0;
  const pct = hasCap ? Math.min(100, Math.round((budgetSpent / capNum) * 100)) : 0;
  const meterColor = pct >= 90 ? "var(--color-err, #d24b4b)" : pct >= 70 ? "var(--color-warn, #c98a2b)" : "var(--color-ok, #2e9e5b)";

  // `desc` is optional on purpose: a switch whose name already says what it
  // does ("Sound effects", "Start on boot") gets no second line, and the row
  // tightens up rather than leaving a gap where the sentence used to be.
  const Row = ({
    title, desc, control,
  }: { title: string; desc?: string; control: React.ReactNode }) => (
    <div className="flex items-center justify-between gap-6 border-b border-border-subtle py-3.5 last:border-0">
      <div className="min-w-0 flex-1">
        <div className="text-sm font-semibold text-text-primary">{title}</div>
        {desc && <div className="mt-0.5 text-xs text-text-muted">{desc}</div>}
      </div>
      <div className="shrink-0">{control}</div>
    </div>
  );

  const Switch = ({ on, onChange }: { on: boolean; onChange: (v: boolean) => void }) => (
    <Toggle on={on} onChange={onChange} />
  );

  // General's three sub-sections route through the canonical CollapsibleSection
  // so they match every other collapsible in the app (icon + title left, summary
  // right, collapsed by default, open state persisted per section).
  const GenSub = ({ id, title, icon, summary, children }: { id: "main" | "appearance" | "shortcuts"; title: string; icon: LucideIcon; summary?: string; children: React.ReactNode }) => (
    part ? (part === id ? <>{children}</> : null) : (
    <CollapsibleSection icon={icon} title={title} summary={summary} defaultOpen={id === "main"} storageKey={`prevail.settings.general.${id}`}>
      {children}
    </CollapsibleSection>
    )
  );

  return (
    <>
      <SettingsHeader
        title={part === "main" ? "Behavior" : part === "appearance" ? "Appearance" : "General"}
        subtitle={part === "main" ? "How the app starts, sends, notifies and spends." : part === "appearance" ? "Color mode and theme." : "App-wide behavior, appearance, and keyboard shortcuts."}
      />
      <div className="space-y-2">
      <GenSub id="main" title="Main" icon={SlidersHorizontal} summary="behavior & defaults">
      <div>
        <Row
          title="Start on boot"
          control={<Switch on={startOnBoot} onChange={async (v) => { try { if (v) await autostartEnable(); else await autostartDisable(); setStartOnBoot(v); } catch (e) { console.error("autostart", e); } }} />}
        />
        <Row
          title="Copy text when you select it"
          desc="Selected text in replies and pages goes straight to the clipboard. Text boxes are left alone."
          control={<Switch on={copyOnSelect} onChange={(v) => { setCopyOnSelect(v); setPref(PREF.copyOnSelect, v ? "1" : "0"); }} />}
        />
        <Row
          title="Show Briefing on home"
          desc="Top recommendations and what Glyph Studio learned, on the home screen."
          control={<Switch on={showBriefing} onChange={(v) => { setShowBriefing(v); setPref(PREF.showHomeBriefing, v ? "1" : "0"); }} />}
        />
        <Row
          title="Show Quick Capture"
          desc="A mic pinned to the edge of the screen, for a note from anywhere."
          control={<Switch on={showQuickCapture} onChange={(v) => { setShowQuickCapture(v); setPref(PREF.quickCaptureEnabled, v ? "1" : "0"); window.dispatchEvent(new Event("prevail:quickcapture-changed")); }} />}
        />
        <Row
          title="Close to tray"
          desc="Closing the window leaves Glyph Studio in the menu bar."
          control={<Switch on={closeToTray} onChange={(v) => { setCloseToTray(v); setPref(PREF.closeToTray, v ? "1" : "0"); }} />}
        />
        <Row
          title="Send messages with"
          desc="Shift+Enter makes a new line either way."
          control={
            <select
              value={sendKey}
              onChange={(e) => { setSendKeyState(e.target.value); setPref(PREF.sendKey, e.target.value); }}
              className="rounded-md border border-border bg-background px-3 py-1.5 text-sm focus:border-accent-border focus:outline-none"
            >
              <option value="enter">Enter</option>
              <option value="cmd-enter">⌘ + Enter</option>
            </select>
          }
        />
        <Row
          title="Save entities as you chat"
          desc={autosaveErr ?? "Which people, places and things get their own page. Only mine keeps essays and histories out."}
          control={
            <select
              data-testid="autosave-select"
              aria-label="Save entities as you chat"
              value={autosave}
              onChange={(e) => { void changeAutosave(e.target.value); }}
              className="rounded-md border border-border bg-background px-3 py-1.5 text-sm focus:border-accent-border focus:outline-none"
            >
              <option value="off">Off</option>
              <option value="yours">Only mine (recommended)</option>
              <option value="all">Everything</option>
            </select>
          }
        />
        <Row
          title="Desktop notifications"
          control={<Switch on={desktopNotif} onChange={(v) => { setDesktopNotif(v); setPref(PREF.desktopNotif, v ? "1" : "0"); }} />}
        />
        <Row
          title="Proactive check-ins"
          desc="Glyph Studio nudges you when approvals or overdue work are waiting."
          control={<Switch on={heartbeat} onChange={(v) => { setHeartbeat(v); setPref(PREF.heartbeatEnabled, v ? "1" : "0"); }} />}
        />
        <Row
          title="Sound effects"
          control={<Switch on={soundDone} onChange={(v) => { setSoundDone(v); setPref(PREF.soundOnDone, v ? "1" : "0"); }} />}
        />
        <Row
          title="Auto-convert long paste"
          desc="A paste over 5000 characters becomes an attachment."
          control={<Switch on={autoConvert} onChange={(v) => { setAutoConvert(v); setPref(PREF.autoConvertLongPaste, v ? "1" : "0"); }} />}
        />
        <Row
          title={`Strip "You're absolutely right!" sycophancy`}
          desc="Filters fluff openers out of replies as they stream."
          control={<Switch on={stripSyc} onChange={(v) => { setStripSyc(v); setPref(PREF.stripSycophancy, v ? "1" : "0"); }} />}
        />
        <Row
          title="Show model thinking"
          desc="Reasoning appears in a collapsible block above the answer."
          control={<Switch on={showThinking} onChange={(v) => { setShowThinking(v); setPref(PREF.showThinking, v ? "1" : "0"); }} />}
        />
        <Row
          title="LLM prompt timeout"
          desc="A single call is killed after this long."
          control={
            <div className="flex items-center gap-1.5">
              <input
                type="number"
                min={10}
                max={3600}
                value={promptTimeout}
                onChange={(e) => { setPromptTimeout(e.target.value); setPref(PREF.llmPromptTimeoutSec, e.target.value); }}
                className="w-20 rounded-md border border-border bg-background px-2 py-1.5 text-right text-sm focus:border-accent-border focus:outline-none"
              />
              <span className="text-xs text-text-muted">s</span>
            </div>
          }
        />
        <Row
          title="Monthly budget cap"
          desc="A soft cap for model spend. Blank means none."
          control={
            <div className="flex items-center gap-1.5">
              <span className="text-xs text-text-muted">$</span>
              <input
                type="number"
                min={0}
                step="1"
                value={budgetCap}
                placeholder="0"
                onChange={(e) => { setBudgetCap(e.target.value); setPref(PREF.budgetMonthlyCapUsd, e.target.value); }}
                className="w-24 rounded-md border border-border bg-background px-2 py-1.5 text-right text-sm focus:border-accent-border focus:outline-none"
              />
            </div>
          }
        />
      </div>

      {/* Budget meter */}
      <div className="mt-4 border-t border-border-subtle pt-4">
        <div className="mb-2 flex items-center justify-between">
          <div className="text-[14px] font-semibold text-text-primary">Budget this month</div>
          <div className="text-xs text-text-secondary">
            ${budgetSpent.toFixed(2)}{hasCap ? ` / $${capNum.toFixed(2)}` : " spent"}
          </div>
        </div>
        <div className="h-2 w-full overflow-hidden rounded-full bg-surface-strong">
          <div className="h-full rounded-full transition-all" style={{ width: hasCap ? `${pct}%` : "0%", background: meterColor }} />
        </div>
        <div className="mt-1.5 text-[12px] text-text-muted">
          {hasCap ? `${pct}% of cap used${pct >= 90 ? " · approaching limit" : ""}` : "Set a cap above to track usage against it."}
        </div>
      </div>
      </GenSub>
      {/* Outside GenSub: GenSub is redefined per render, so anything inside
          it remounts and would lose the plan's edits. */}
      {part === "main" && vaultPath && <FilingSettings vaultPath={vaultPath} />}
      {appearance && (
        <GenSub id="appearance" title="Appearance" icon={Palette} summary={appearance?.mode ? `${appearance.mode} theme` : "theme & palette"}>
          <div className="mb-6 border-t border-border-subtle pt-4">
            <div className="mb-1 font-medium">Color Mode</div>
            <div className="mb-4 text-sm text-text-secondary">Pick a fixed mode or let Glyph Studio follow your system setting.</div>
            <div className="inline-flex items-center rounded-md border border-border bg-background p-1 text-xs">
              {([{ id: "light", label: "Light", icon: Sun }, { id: "dark", label: "Dark", icon: Moon }, { id: "system", label: "System", icon: Monitor }] as const).map((m) => {
                const Icon = m.icon; const active = appearance.mode === m.id;
                return (
                  <button key={m.id} onClick={() => appearance.setMode(m.id as Mode)}
                    className={`inline-flex items-center gap-1.5 rounded px-3 py-1.5 transition-colors ${active ? "bg-accent text-background shadow-sm" : "text-text-secondary hover:bg-surface-warm"}`}>
                    <Icon className="h-3.5 w-3.5" />{m.label}
                  </button>
                );
              })}
            </div>
          </div>
          <div>
            <div className="mb-1 font-medium">Theme</div>
            <p className="mb-4 text-sm text-text-secondary">Desktop palettes. The selected mode is applied on top.</p>
            <div className="grid grid-cols-3 gap-3">
              {PALETTES.map((p) => (
                <PaletteCard key={p.id} palette={p} active={appearance.palette === p.id} onSelect={() => appearance.setPalette(p.id)} />
              ))}
            </div>
          </div>
        </GenSub>
      )}
      </div>
    </>
  );
}
