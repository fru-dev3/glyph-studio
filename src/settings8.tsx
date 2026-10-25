// Settings sections extracted from App.tsx: Appearance (theme + palette), Demo
// Mode (sample-vault sandbox), and Vault settings (path + the backup-automation
// card).
import { useEffect, useState } from "react";
import { confirm as tauriConfirm, open } from "@tauri-apps/plugin-dialog";
import { Archive, DatabaseBackup, ExternalLink, FolderCog, FolderOpen, FolderTree, Loader2, Monitor, Moon, RotateCw, ShieldCheck, Sparkles, Sun } from "lucide-react";
import type { LucideIcon } from "lucide-react";
import { invoke } from "./bridge";
import { PALETTES } from "./constants";
import { LS, lsGet, lsSet } from "./storage";
import { Toggle } from "./ui";
import { PaletteCard } from "./panels3";
import { useAppearance } from "./hooks";
import { ObsidianCard } from "./settings4";
import { SettingsHeader } from "./sectionutil";
import { BACKUP_CFG, backupFreqMs, backupVaultNow } from "./backup";
import type { Mode } from "./types";

export function AppearanceSection({ appearance }: { appearance: ReturnType<typeof useAppearance> }) {
  return (
    <section>
      <SettingsHeader title="Appearance" subtitle="Mode controls brightness; theme controls the accent palette and surface styling." />

      {/* Color Mode segmented control */}
      <div className="mt-6 border-t border-border-subtle pt-4">
        <div className="flex items-start justify-between gap-4">
          <div>
            <div className="font-medium">Color Mode</div>
            <div className="mt-1 text-sm text-text-secondary">
              Pick a fixed mode or let Glyph Studio follow your system setting.
            </div>
          </div>
          <div className="inline-flex shrink-0 items-center rounded-md border border-border bg-background p-1 text-xs">
            {[
              { id: "light", label: "Light", icon: Sun },
              { id: "dark", label: "Dark", icon: Moon },
              { id: "system", label: "System", icon: Monitor },
            ].map((m) => {
              const Icon = m.icon;
              const active = appearance.mode === m.id;
              return (
                <button
                  key={m.id}
                  onClick={() => appearance.setMode(m.id as Mode)}
                  className={`inline-flex items-center gap-1.5 rounded px-3 py-1.5 transition-colors ${
                    active
                      ? "bg-accent text-background shadow-sm"
                      : "text-text-secondary hover:bg-surface-warm"
                  }`}
                >
                  <Icon className="h-3.5 w-3.5" />
                  {m.label}
                </button>
              );
            })}
          </div>
        </div>
      </div>

      {/* Theme palette cards */}
      <div className="mt-6">
        <div className="mb-1 font-medium">Theme</div>
        <p className="mb-4 text-sm text-text-secondary">
          Desktop palettes. The selected mode is applied on top.
        </p>
        <div className="grid grid-cols-1 gap-3">
          {PALETTES.map((p) => (
            <PaletteCard
              key={p.id}
              palette={p}
              active={appearance.palette === p.id}
              onSelect={() => appearance.setPalette(p.id)}
            />
          ))}
        </div>
      </div>
    </section>
  );
}


// Council config - its own first-class section. You pick the EXACT models on the
// default panel (per-provider, multiple models allowed) and which one chairs.

export function DemoModeSection({ vaultPath, onVaultMoved, onSetupDomains, headerless }: { vaultPath: string; onVaultMoved?: (path: string) => void; onSetupDomains?: () => void; headerless?: boolean }) {
  const [appMode, setAppMode] = useState<"demo" | "production" | null>(null);
  const [switchingMode, setSwitchingMode] = useState(false);
  const [note, setNote] = useState<string | null>(null);
  // B2-16: per-vault backup toggle on the active card. Backup snapshots the
  // ACTIVE vault, so this reflects/controls BACKUP_CFG.enabled.
  const [backupOn, setBackupOn] = useState(() => lsGet(BACKUP_CFG.enabled, "0") === "1");
  const toggleBackup = (v: boolean) => { setBackupOn(v); lsSet(BACKUP_CFG.enabled, v ? "1" : "0"); window.dispatchEvent(new Event("prevail:bench-sched")); };
  // Backup status surfaced next to the toggle: schedule, next-run, run-now, folder.
  const [backupTick, setBackupTick] = useState(0);
  const [backupBusy, setBackupBusy] = useState(false);
  const [backupFreq, setBackupFreqState] = useState(() => lsGet(BACKUP_CFG.freq, "weekly") || "weekly");
  const setBackupFreq = (v: string) => { setBackupFreqState(v); lsSet(BACKUP_CFG.freq, v); window.dispatchEvent(new Event("prevail:bench-sched")); setBackupTick((t) => t + 1); };
  const customDays = /^custom:(\d+)$/.exec(backupFreq)?.[1] ?? "2";
  const backupNextLabel = (() => {
    void backupTick; // re-evaluate after a manual backup
    const last = Number(lsGet(BACKUP_CFG.lastRun, "0")) || 0;
    if (!last) return "on next check";
    const next = last + backupFreqMs(backupFreq);
    return new Date(next).toLocaleString([], { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
  })();
  const backupNow = async () => {
    setBackupBusy(true);
    try { await backupVaultNow(vaultPath); setBackupTick((t) => t + 1); } finally { setBackupBusy(false); }
  };
  const openBackupsFolder = async () => {
    try {
      // Prefer an existing backup's folder; fall back to the effective backup dir
      // so this works even before the first backup has been written.
      const list = await invoke<{ path: string }[]>("vault_backups_list", { destDir: lsGet(BACKUP_CFG.dest) || null });
      const p = (Array.isArray(list) && list[0]?.path) || (await invoke<string>("vault_backup_dir", { destDir: lsGet(BACKUP_CFG.dest) || null }));
      if (p) await invoke("open_in_finder", { path: p });
    } catch (e) { console.error("open backups folder", e); }
  };
  // The folder backups are actually written to: a saved override (BACKUP_CFG.dest)
  // or the default app-support/backups. Shown + changeable right on the card.
  const [backupDir, setBackupDir] = useState<string>("");
  const [backupDirCustom, setBackupDirCustom] = useState<boolean>(() => !!lsGet(BACKUP_CFG.dest));
  useEffect(() => {
    invoke<string>("vault_backup_dir", { destDir: lsGet(BACKUP_CFG.dest) || null }).then(setBackupDir).catch(() => {});
  }, [backupTick]);
  const changeBackupDir = async () => {
    const picked = await open({ directory: true, multiple: false, title: "Choose a backup folder" });
    if (typeof picked === "string" && picked) {
      lsSet(BACKUP_CFG.dest, picked);
      setBackupDirCustom(true);
      setBackupTick((t) => t + 1);
      window.dispatchEvent(new Event("prevail:backup-done"));
    }
  };
  const resetBackupDir = () => {
    lsSet(BACKUP_CFG.dest, "");
    setBackupDirCustom(false);
    setBackupTick((t) => t + 1);
    window.dispatchEvent(new Event("prevail:backup-done"));
  };
  // Rescan the workspace: re-read domains/apps from disk (picks up anything added
  // outside the app, or a file that went missing) and refresh every surface.
  const [rescanning, setRescanning] = useState(false);
  const [rescanNote, setRescanNote] = useState<string | null>(null);
  const rescanVault = async () => {
    setRescanning(true); setRescanNote(null);
    try {
      const ds = await invoke<{ name: string }[]>("scan_vault", { path: vaultPath });
      window.dispatchEvent(new Event("prevail:domains-changed"));
      window.dispatchEvent(new Event("prevail:apps-changed"));
      window.dispatchEvent(new Event("prevail:tasks-changed"));
      const n = Array.isArray(ds) ? ds.length : 0;
      setRescanNote(`Rescanned: ${n} domain${n === 1 ? "" : "s"} found.`);
      window.setTimeout(() => setRescanNote(null), 4000);
    } catch (e) {
      setRescanNote(`Rescan failed: ${e}`);
    } finally { setRescanning(false); }
  };
  const BackupStatusLine = () => (
    backupOn ? (
      // Schedule on the left; actions as right-aligned icon buttons (with tooltips)
      // that match the path row's icon-button style for an even, clean layout.
      <div className="mt-1.5 flex flex-wrap items-center gap-2 font-mono text-[12px] text-text-muted">
        {/* Editable schedule, right here: daily / weekly / monthly / every N days
            (every other day = 2, every other week = 14). */}
        <select
          value={/^custom:/.test(backupFreq) ? "custom" : backupFreq}
          onChange={(e) => setBackupFreq(e.target.value === "custom" ? `custom:${customDays}` : e.target.value)}
          title="How often automatic backups run"
          className="rounded border border-border bg-background px-1.5 py-0.5 font-mono text-[12px] text-text-secondary focus:border-accent-border focus:outline-none"
        >
          <option value="daily">Daily</option>
          <option value="weekly">Weekly</option>
          <option value="monthly">Monthly</option>
          <option value="custom">every N days</option>
        </select>
        {/^custom:/.test(backupFreq) && (
          <span className="inline-flex items-center gap-1">
            <input type="number" min={1} max={365} value={customDays}
              onChange={(e) => setBackupFreq(`custom:${Math.max(1, Math.min(365, parseInt(e.target.value, 10) || 1))}`)}
              className="w-12 rounded border border-border bg-background px-1.5 py-0.5 text-right font-mono text-[12px] text-text-secondary focus:border-accent-border focus:outline-none" />
            <span>Days</span>
          </span>
        )}
        <span className="min-w-0 flex-1 truncate" title="Next scheduled backup">· next ~{backupNextLabel}</span>
        <div className="flex shrink-0 items-center gap-0.5">
          <button onClick={backupNow} disabled={backupBusy} title="Back up now" className="flex h-7 w-7 items-center justify-center rounded-md text-text-muted transition-colors hover:bg-surface-warm hover:text-accent disabled:opacity-40">
            {backupBusy ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <DatabaseBackup className="h-3.5 w-3.5" />}
          </button>
          <button onClick={changeBackupDir} title={`Change backup folder (now: ${backupDir || "default"})`} className="flex h-7 w-7 items-center justify-center rounded-md text-text-muted transition-colors hover:bg-surface-warm hover:text-accent">
            <FolderCog className="h-3.5 w-3.5" />
          </button>
          <button onClick={openBackupsFolder} title="Open backups folder" className="flex h-7 w-7 items-center justify-center rounded-md text-text-muted transition-colors hover:bg-surface-warm hover:text-accent">
            <Archive className="h-3.5 w-3.5" />
          </button>
        </div>
        {/* Where backups land, visible + changeable right here. Kept OUTSIDE the
            vault (a backup inside what it backs up is circular). */}
        <div className="flex w-full items-center gap-1.5 text-[12px] text-text-muted">
          <FolderOpen className="h-3 w-3 shrink-0" />
          <span className="min-w-0 flex-1 truncate" title={backupDir}>{backupDir || "default location"}{backupDirCustom ? "" : " · default"}</span>
          <button onClick={changeBackupDir} className="shrink-0 hover:text-accent">Change</button>
          {backupDirCustom && <button onClick={resetBackupDir} className="shrink-0 hover:text-accent">Reset</button>}
        </div>
      </div>
    ) : null
  );
  // The remembered production vault path, so switching demo<->production never
  // re-asks for the folder, and both locations can be shown.
  const [prodVault, setProdVault] = useState<string>(() => lsGet(LS.vaultProduction) || "");
  useEffect(() => {
    const loadMode = () =>
      invoke<{ mode: "demo" | "production" }>("engine_appmode_get").then((m) => setAppMode(m.mode)).catch(() => {});
    loadMode();
    window.addEventListener("prevail:appmode", loadMode);
    return () => window.removeEventListener("prevail:appmode", loadMode);
  }, []);
  // In production the main vault is config.json's, not whichever profile the
  // UI shows: remembering the UI vault here made a switched-to profile the
  // "production vault".
  useEffect(() => {
    if (appMode !== "production") return;
    void invoke<string | null>("engine_config_vault").then((cfg) => {
      if (cfg && cfg !== prodVault) { setProdVault(cfg); lsSet(LS.vaultProduction, cfg); }
    }).catch(() => {});
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [appMode, vaultPath]);

  // Point the app at a chosen folder as the production vault. `runOnboarding`
  // controls whether an empty vault triggers the domain setup flow.
  async function enterProduction(picked: string, runOnboarding: boolean) {
    // Snapshot before clearing the demo sandbox (a pre-event backup).
    await backupVaultNow(vaultPath);
    await invoke<{ vault: string; demoCleared: boolean }>("engine_production_init", { vault: picked, clearDemo: vaultPath });
    await invoke("engine_appmode_set", { mode: "production", vault: picked }).catch(() => {});
    setProdVault(picked); lsSet(LS.vaultProduction, picked);
    setAppMode("production");
    window.dispatchEvent(new Event("prevail:appmode"));
    onVaultMoved?.(picked);
    // Only onboard a genuinely EMPTY vault. If the folder you pointed at already
    // has domains, it's ready to use - scan it and skip the setup modal entirely.
    if (runOnboarding) {
      const existing = await invoke<{ name: string }[]>("scan_vault", { path: picked }).catch(() => [] as { name: string }[]);
      if (!existing || existing.length === 0) onSetupDomains?.();
    }
  }

  // Leave the demo sandbox for your own vault. If a production vault is already
  // remembered, just switch back to it (no re-pick, no onboarding); otherwise
  // pick a fresh folder and run setup.
  async function switchToProduction() {
    // Already have a production vault on disk? Round-trip straight back to it.
    if (prodVault) {
      const ok = await invoke<boolean>("vault_exists", { path: prodVault }).catch(() => false);
      if (ok) {
        setSwitchingMode(true); setNote(null);
        try {
          await invoke("engine_appmode_set", { mode: "production", vault: prodVault }).catch(() => {});
          setAppMode("production");
          window.dispatchEvent(new Event("prevail:appmode"));
          onVaultMoved?.(prodVault);
          setNote(`Back in your own vault (${prodVault}).`);
        } catch (e) { setNote(`Could not switch: ${String(e)}`); }
        finally { setSwitchingMode(false); }
        return;
      }
    }
    const confirmOk = await tauriConfirm(
      "Ready to set up your own vault? You'll choose a folder for it, then set up your domains. The demo sample data is cleared.",
      { title: "Use your own vault", kind: "info", okLabel: "Choose my vault folder", cancelLabel: "Stay in demo" },
    );
    if (!confirmOk) return;
    const picked = await open({ directory: true, multiple: false, title: "Choose a folder for your own vault" });
    if (!picked || typeof picked !== "string") return;
    setSwitchingMode(true);
    setNote(null);
    try {
      await enterProduction(picked, true);
    } catch (e) {
      setNote(`Could not set up your vault: ${String(e)}`);
    } finally {
      setSwitchingMode(false);
    }
  }
  // B2-15: change the vault folder from the card icon, pick a new directory and
  // point the app at it (same path the 3-step setup uses).
  async function changeVaultPath() {
    const picked = await open({ directory: true, multiple: false, title: "Choose your vault folder" });
    if (!picked || typeof picked !== "string") return;
    setSwitchingMode(true);
    setNote(null);
    try { await enterProduction(picked, true); }
    catch (e) { setNote(`Could not switch vault: ${String(e)}`); }
    finally { setSwitchingMode(false); }
  }
  // Return to the demo sandbox: repoint the app at the demo vault (re-seeding
  // the bundled sample data) and flip the flag. The production vault is
  // remembered, untouched, and one click away.
  async function switchToDemo() {
    setSwitchingMode(true);
    setNote(null);
    try {
      const demoPath = await invoke<string>("import_sample_vault");
      await invoke("engine_appmode_set", { mode: "demo", vault: demoPath }).catch(() => {});
      await invoke("engine_appmode_mark_demo", { vault: demoPath }).catch(() => {});
      setAppMode("demo");
      window.dispatchEvent(new Event("prevail:appmode"));
      onVaultMoved?.(demoPath);
      setNote("You're back in the demo sandbox. Your own vault is remembered and one click away.");
    } catch (e) {
      setNote(`Could not switch: ${String(e)}`);
    } finally {
      setSwitchingMode(false);
    }
  }
  const isDemo = appMode === "demo";
  return (
    <>
      {/* "Sandbox" - the throwaway exploration space. Your vault vs the demo
          vault as MUTUALLY-EXCLUSIVE toggles. */}
      {!headerless && (
        <SettingsHeader
          icon={Sparkles}
          title="Sandbox"
          subtitle="Explore with sample data before using your own."
        />
      )}
      <div className="mb-5 grid grid-cols-1 gap-3">
        <div className={`rounded-xl border p-4 transition-all ${!isDemo ? "border-2 border-warn bg-warn/10 shadow-sm" : "border border-border bg-surface opacity-55"}`}>
          {/* Header: shield + title + Active, toggle hard-right. */}
          <div className="flex items-center gap-2">
            <ShieldCheck className={`h-4 w-4 shrink-0 ${!isDemo ? "text-warn" : "text-text-muted"}`} />
            <span className="text-sm font-semibold text-text-primary">Your vault</span>
            {!isDemo && <span className="rounded-full bg-warn px-1.5 py-0.5 text-[12px] font-bold text-background">Active</span>}
            <span className="ml-auto"><Toggle on={!isDemo} disabled={switchingMode} onChange={(v) => { if (v) void switchToProduction(); else void switchToDemo(); }} label="Use my own vault" /></span>
          </div>
          {/* Path + an even, aligned row of icon actions: rescan, change folder, open. */}
          <div className="mt-2 flex items-center gap-2">
            <span className="min-w-0 flex-1 truncate text-[12px] text-text-secondary" title={prodVault || "not set up yet"}>{prodVault || (isDemo ? "not set up yet - toggle on to set up" : vaultPath)}</span>
            <div className="flex shrink-0 items-center gap-0.5">
              <button onClick={rescanVault} disabled={rescanning} title="Rescan the workspace for the canonical structure" className="flex h-7 w-7 items-center justify-center rounded-md text-text-muted transition-colors hover:bg-surface-warm hover:text-accent disabled:opacity-40"><RotateCw className={`h-3.5 w-3.5 ${rescanning ? "animate-spin" : ""}`} /></button>
              <button onClick={changeVaultPath} disabled={switchingMode} title="Change vault folder" className="flex h-7 w-7 items-center justify-center rounded-md text-text-muted transition-colors hover:bg-surface-warm hover:text-accent disabled:opacity-40"><FolderOpen className="h-3.5 w-3.5" /></button>
              {(prodVault || !isDemo) && (
                <button onClick={() => void invoke("open_in_finder", { path: prodVault || vaultPath }).catch(() => {})} title="Open in Finder" className="flex h-7 w-7 items-center justify-center rounded-md text-text-muted transition-colors hover:bg-surface-warm hover:text-accent"><ExternalLink className="h-3.5 w-3.5" /></button>
              )}
            </div>
          </div>
          <div className="mt-1 text-[12px] leading-relaxed text-text-muted">Real data, backed up. {isDemo && !prodVault ? "Toggling on walks you through a quick 3-step setup." : "Switching to demo never touches it."}</div>
          {rescanNote && <div className="mt-1.5 font-mono text-[12px] text-accent">{rescanNote}</div>}
          {/* Per-vault backup toggle (active vault only). */}
          {!isDemo && (
            <div className="mt-3 border-t border-border-subtle/60 pt-2.5">
              <div className="flex items-center gap-2">
                <span className="flex-1 text-[12px] text-text-secondary">Automatic backups</span>
                <Toggle on={backupOn} onChange={toggleBackup} label="Back up your vault" />
              </div>
              <BackupStatusLine />
            </div>
          )}
        </div>
        <div className={`rounded-xl border p-4 transition-all ${isDemo ? "border-2 border-accent bg-accent-soft shadow-sm" : "border border-border bg-surface opacity-55"}`}>
          <div className="flex items-center gap-2">
            <Sparkles className={`h-4 w-4 ${isDemo ? "text-accent" : "text-text-muted"}`} />
            <span className="text-sm font-semibold text-text-primary">Demo vault</span>
            {isDemo && <span className="rounded-full bg-accent px-1.5 py-0.5 text-[12px] font-bold text-background">Active</span>}
            <span className="ml-auto"><Toggle on={isDemo} disabled={switchingMode} onChange={(v) => { if (v) void switchToDemo(); else void switchToProduction(); }} label="Explore the demo sandbox" /></span>
          </div>
          <div className="mt-1.5 flex items-center gap-1.5">
            <span className="min-w-0 flex-1 truncate text-[12px] text-text-secondary" title={isDemo ? vaultPath : "sample data"}>{isDemo ? vaultPath : "throwaway sample data"}</span>
            {isDemo && (
              <button onClick={() => void invoke("open_in_finder", { path: vaultPath }).catch(() => {})} title="Open in Finder" className="shrink-0 rounded p-1 text-text-muted hover:text-accent"><ExternalLink className="h-3.5 w-3.5" /></button>
            )}
          </div>
          <div className="mt-0.5 text-[12px] text-text-muted">Sample data, re-seeded. Safe to explore; nothing here is your real data.</div>
          {isDemo && (
            <div className="mt-2 border-t border-border-subtle/60 pt-2">
              <div className="flex items-center gap-2">
                <span className="flex-1 text-[12px] text-text-muted">Automatic backups</span>
                <Toggle on={backupOn} onChange={toggleBackup} label="Back up demo vault" />
              </div>
              <BackupStatusLine />
            </div>
          )}
        </div>
      </div>
      {switchingMode && <div className="mb-4 text-xs text-text-muted">Switching…</div>}
      {/* Switch feedback (set by switchToProduction / switchToDemo). */}
      {note && (
        <div className="flex items-start gap-2 rounded-lg border border-accent-border bg-accent-soft px-3 py-2 text-xs text-text-primary">
          <span>{note}</span>
        </div>
      )}
    </>
  );
}

// IA-1: "Workspace" is the single umbrella area covering where data lives (vault,
// domains, backups) + the throwaway Sandbox. Replaces the separate "Vault" and
// "Demo Mode" nav entries, composing the (headerless) Vault + Sandbox sections
// under one header with sub-labels.
function WorkspaceSubLabel({ icon: Icon, label, desc }: { icon: LucideIcon; label: string; desc: string }) {
  return (
    <div className="mb-2 mt-1 flex items-center gap-2 px-1">
      <Icon className="h-3.5 w-3.5 text-accent" />
      <h3 className="text-sm font-semibold text-text-primary">{label}</h3>
      <span className="ml-auto text-[12px] text-text-muted">{desc}</span>
    </div>
  );
}


export function WorkspaceSection({ vaultPath, onSetupDomains, onVaultMoved }: { vaultPath: string; onSetupDomains?: () => void; onVaultMoved?: (path: string) => void }) {
  return (
    <>
      <SettingsHeader icon={FolderTree} title="Workspace" subtitle="Where your data lives." />
      <ObsidianCard />
      {/* ONE Vault section = the Your/Demo vault cards (inline change+open icons and
          a per-vault backup toggle), plus a copy-safe filename normalizer. */}
      <div>
        <WorkspaceSubLabel icon={FolderOpen} label="Vault" desc="your vault · demo vault · backups" />
        <DemoModeSection vaultPath={vaultPath} onVaultMoved={onVaultMoved} onSetupDomains={onSetupDomains} headerless />
      </div>
      {/* One-button structure normalizer for legacy / hand-edited vaults. */}
    </>
  );
}
