import { PhoneGlance, isGlanceView } from "./metricsfamily";
import { Component, Suspense, lazy, useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { invoke, listen, isBrowser, getWebToken, pendingPairCode, redeemPairCode, type UnlistenFn } from "./bridge";
import { invokeCached } from "./query";
import { lazyPanel, loadBenchmarkPanel, loadChatPanel, loadCouncilPanel, loadSettingsPanel, loadWorkPanel, prefetchPanelsWhenIdle } from "./prefetch";
import { useIsPhone, useVisualViewportHeight } from "./useisphone";
import { open } from "@tauri-apps/plugin-dialog";
import { revealItemInDir } from "@tauri-apps/plugin-opener";
import { USE_COUNCIL_EVENT } from "./council";
import { titleCase } from "./format";
import type { CliInfo, Domain, DomainTab, EngineApp, TabId, ThreadMeta } from "./types";
import { BUNKER_LS, LS, PREF, getPref, hydrateUiPrefs, hydrateProfilePrefs, saveProfilePrefs, isBunkerOn, lsGet, lsSet } from "./storage";
import { track } from "./telemetry";
import { ensureDefaultProfile, getOwnedProfile, isDemoVaultPath, nameFromUserMd, reconcileProductionProfiles, setProfilesProduction } from "./profiles";
import { QuickCapture } from "./quickcapture";
import { BridgeStatusChips, DemoRibbon, ResizeHandle } from "./widgets";
import { useProcesses } from "./processes";
import { OnboardingModal } from "./panels3";
import { BunkerRibbon, VaultWizard } from "./shell";
import { PhoneVoiceBar } from "./phonevoice";
// Heavy surfaces are code-split: each loads its own chunk on first use instead of
// inflating the initial bundle (and the live memory footprint). SettingsPanel
// alone transitively pulls in every settings section, so deferring it is the
// biggest single win. Mirrors how the engine spawns work lazily.
// The loaders live in prefetch.ts so the sidebar can start them on hover.
const ChatPanel = lazyPanel(loadChatPanel, (m) => m.ChatPanel);
const CouncilPanel = lazyPanel(loadCouncilPanel, (m) => m.CouncilPanel);
const SettingsPanel = lazyPanel(loadSettingsPanel, (m) => m.SettingsPanel);
const WorkPanel = lazyPanel(loadWorkPanel, (m) => m.WorkPanel);
const BenchmarkPanel = lazyPanel(loadBenchmarkPanel, (m) => m.BenchmarkPanel);
// The phone frame (bottom tab bar, big header, one full-width surface). Only
// fetched at phone width, so the desktop bundle stays as it was.
const PhoneShell = lazy(() => import("./phoneshell").then((m) => ({ default: m.PhoneShell })));
import { Sidebar } from "./sidebar";
import { ObsidianImportModal } from "./obsidianmodal";
import { useAppearance, useFrameworkLens } from "./hooks";
import { distillCfgFromPrefs, intentDaemonCfgFromPrefs, skillgenCfgFromPrefs, taskgenCfgFromPrefs } from "./daemoncfg";
import { autoVerifyClis } from "./verify";
import { bumpBackupChangeCount, startBackupScheduler } from "./backup";
import { startLoopsScheduler } from "./loops";
import { startAppsScheduler } from "./appstatus";
import { startOmegaScheduler } from "./omega";
import { OnboardingTour } from "./onboarding";
import { VaultEncryptPrompt, vaultEncryptOffered } from "./vault-encrypt-prompt";
import { migrateModelPrefs } from "./helpers2";
import { AppHeaderBar, DomainActionsMenu, LockScreen, PairingScreen, QuickSwitcher, ThreadsRail, WebLogin, WebVaultLinking } from "./panels";
import { CommandPalette, type Command } from "./commandpalette";
import { EDITOR_NAV, REMOVED_SECTIONS, WORK_NAV, noteCompassFocus, noteToolkitGroup, workSection } from "./navdefs";
import { GROUP_LABEL as IA_GROUP_LABEL, KINDS as IA_KINDS, kindOfId, noteIaKind, openKind } from "./ia";
import { loadEntities, requestEntity, setEntityVault, useEntityStore } from "./entitystore";
import { openMission, useMissions } from "./missions";

// Single source of truth for the version chip in title bar.

// Canonical on/off toggle. Track 36×20px, thumb 16×16px, slides
// 18px. Every switch in the app routes through this so we never
// drift back into bespoke implementations that misalign the thumb.

// VS Code-style quick switcher modal. Centered overlay, single
// search input at the top, combined list of domains + recent
// threads (loaded async from each domain's _threads/ dir).
//
// Arrow keys navigate, Enter picks, Esc dismisses. Click outside
// also dismisses. Items are sorted: domains first, then threads
// newest-first, with fuzzy substring filtering.

// Per-CLI model quickpicks. Picked in Settings → Defaults and per-
// session in Council. Display labels are friendly, ids are passed
// through to the CLI's --model flag.

// Live-discovered models per provider (filled at runtime by the engine's
// `models` command). Merged with the curated  catalog so newly released
// models surface without a code change. OpenRouter's catalog is huge (300+), so
// its extras are exposed via search in the provider card, not merged into the
// inline list. Module-level so every reader sees the latest; a
// `prevail:models-refreshed` event tells components to re-render.

/** Curated catalog for a provider, plus any live-discovered models not already
 *  in it. OpenRouter stays curated inline (search surfaces the rest). */


// Models a ChatGPT-login Codex account rejects (verified). A previously
// saved pick like "gpt-5-codex" persists in localStorage and keeps
// failing even after we trim the dropdown - so heal it on launch.

// One-time migration: reset any stale per-CLI model pick that's no longer
// in and replace any known-dead model id (global or per-domain)
// with the working gpt-5.5. Safe + idempotent.
import {
  
  
  
  
  
  
  
  
  
  
  
  
  
  

  
  
  MessageSquare,
  
  
  
  
  
  
  
  Scale,
  
  Swords,

  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  X,
  
  
  
  Layers,

  Inbox,
  Plug,
  ChevronsRight,
  ChevronsLeft,
  MessageSquarePlus,
  ListChecks,
  Blocks,
  Compass,
  ShieldCheck,
  Power,
  Settings as SettingsIcon,
} from "lucide-react";

// X8: fire a foreground Web Notification (the WebUI, on a phone/laptop). Asks
// permission the first time; silently no-ops if denied or unsupported.
function showWebNotification(title: string, body: string) {
  // Prefer the service worker registration (persists / shows when backgrounded);
  // fall back to a page Notification.
  try {
    if (navigator.serviceWorker?.ready) {
      void navigator.serviceWorker.ready.then((reg) => {
        if (reg?.showNotification) reg.showNotification(title, { body, icon: "/logo-512.png", tag: "prevail" });
        else new Notification(title, { body });
      }).catch(() => { try { new Notification(title, { body }); } catch { /* noop */ } });
    } else {
      new Notification(title, { body });
    }
  } catch { /* noop */ }
}
function notifyWeb(title: string, body: string) {
  try {
    if (typeof Notification === "undefined") return;
    if (Notification.permission === "granted") { showWebNotification(title, body); return; }
    if (Notification.permission !== "denied") {
      void Notification.requestPermission().then((p) => { if (p === "granted") showWebNotification(title, body); });
    }
  } catch { /* notifications unavailable */ }
}

// Friendly one-line descriptions for the domain cards - plain, warm, no jargon.
// Shown as the card subtitle; falls back to a generic line for unknown domains.



// Top-level tabs. Council is NOT its own tab (a mode toggle inside Chat) and
// Tools is NOT its own tab (a section inside Settings), keeping the surface
// count low so each tab has a clear job.
// B2-25: Chat + Council are the prominent primary tabs on the LEFT. Benchmark and
// the rest live in the smaller, de-emphasized right cluster.
const TABS: { id: TabId; label: string; icon: typeof MessageSquare }[] = [
  { id: "chat", label: "Chat", icon: MessageSquare },
  { id: "council", label: "Council", icon: Scale },
];

// Keep nav badges to a single digit: anything over 9 shows "9+" so the top bar
// never reads as an overwhelming "137". The full number lives on the page itself.
const cap9 = (n: number): string => (n > 9 ? "9+" : String(n));

// Suspense fallback for the code-split panels. Quiet and centered - a lazy chunk
// loads in a few ms off local disk, so this should flash only on the very first
// open of a surface.
function PanelLoading() {
  return (
    <div className="flex h-full w-full items-center justify-center">
      <span className="h-5 w-5 animate-spin rounded-full border-2 border-border border-t-accent" aria-label="Loading" />
    </div>
  );
}

// Per-panel error boundary: a lazy chunk that fails to load (a stale chunk after
// the app auto-updated while open, or a transient read) throws inside <Suspense>,
// which does NOT catch load errors - so without this the throw bubbles to the top
// boundary and drops the WHOLE app to the fatal screen. Here it degrades just this
// one panel with a "Reload this section" reset; a resetKey change auto-clears it.
class PanelBoundary extends Component<{ resetKey: unknown; children: ReactNode }, { err: unknown }> {
  state = { err: null as unknown };
  static getDerivedStateFromError(err: unknown) { return { err }; }
  componentDidUpdate(prev: { resetKey: unknown }) {
    if (prev.resetKey !== this.props.resetKey && this.state.err) this.setState({ err: null });
  }
  render() {
    if (!this.state.err) return this.props.children;
    return (
      <div className="flex h-full w-full flex-col items-center justify-center gap-3 px-6 text-center">
        <div className="text-sm font-medium text-text-primary">This section didn't load</div>
        <div className="max-w-sm text-xs text-text-muted">The rest of Glyph Studio is fine and your vault is safe. This can happen if the app updated while it was open.</div>
        <button onClick={() => this.setState({ err: null })} className="rounded-lg border border-border bg-surface px-3 py-1.5 text-xs font-medium text-text-primary hover:bg-surface-strong focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent">Reload this section</button>
      </div>
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// localStorage keys + helpers


// ── Bunker  (app-wide local-only trust mode) ──
// Providers that serve models from this machine only - mirror bunker.rs LOCAL_CLIS.
// Bunker  auto-switch target: the local provider to fall back to when a
// cloud CLI is selected. First *available* local CLI, or null if none is
// installed/running. Mirrors bunker.rs `preferred_local_cli` (Ollama today;
// LM Studio / MLX detection is a recorded deferred refinement).

// Does a prompt look like a judgment call worth convening the council for, vs a
// quick factual question a single model handles? Used by Auto-council's "smart"
// mode (the user's expectation: spin off a council only when the question needs
// it). Heuristic, deliberately transparent.

export default function App() {
  const appearance = useAppearance();
  // Fetch the code-split panels once the window is idle, so the first visit
  // to a page does not wait on its chunk. Desktop only (a phone on the tunnel
  // loads what it opens).
  useEffect(() => { if (!isBrowser()) prefetchPanelsWhenIdle(); }, []);
  // WebUI login gate - in a browser tab the app must authenticate to the
  // bridge server before any invoke works. On the desktop this is always true.
  const [webAuthed, setWebAuthed] = useState(() => !isBrowser() || !!getWebToken());
  // Arriving from a scanned QR code: the address carries a one-shot pairing
  // code, which we trade for a session token before anything renders, so the
  // phone never sees a password field. A code always wins over a stored token,
  // because the usual reason to re-scan is that the old token went stale when
  // the Mac's bridge restarted.
  const [pairing, setPairing] = useState(() => isBrowser() && !!pendingPairCode());
  useEffect(() => {
    if (!pairing) return;
    let alive = true;
    void redeemPairCode().then((ok) => {
      if (!alive) return;
      if (ok) setWebAuthed(true);
      setPairing(false);
    });
    return () => { alive = false; };
  }, [pairing]);
  // A stored token goes stale whenever the Mac's bridge restarts. Until now the
  // phone kept showing the app while every request failed with 401, which
  // looked like "send does nothing". The bridge clears the token and raises
  // this event; the sign-in screen comes back with an explanation.
  useEffect(() => {
    if (!isBrowser()) return;
    const onUnauth = () => setWebAuthed(false);
    window.addEventListener("prevail:web-unauthorized", onUnauth);
    return () => window.removeEventListener("prevail:web-unauthorized", onUnauth);
  }, []);
  // Desktop app lock (F4 Phase 0). If a passcode is set we gate the whole app
  // behind a lock screen until it's entered this session. Browser sessions use
  // the WebUI login instead, so the lock only applies on the desktop.
  const [lockSet, setLockSet] = useState(false);
  const [unlocked, setUnlocked] = useState(false);
  const [vaultEncrypted, setVaultEncrypted] = useState(false);
  // Has the engine_vault_status check completed? Gates the first-run encrypt
  // prompt so it never flashes before we know whether the vault is encrypted.
  const [vaultStatusChecked, setVaultStatusChecked] = useState(false);
  const [encryptPromptClosed, setEncryptPromptClosed] = useState(false);
  // Track demo vs production so we never offer to encrypt (with a passcode +
  // recovery code the user must save) over throwaway sample data. The offer
  // belongs at the demo-to-production graduation, not in the sandbox.
  const [appMode, setAppMode] = useState<"demo" | "production" | null>(null);
  useEffect(() => {
    const load = () =>
      invoke<{ mode: "demo" | "production" }>("engine_appmode_get")
        .then((m) => { if (!m?.mode) return; setProfilesProduction(m.mode === "production"); setAppMode(m.mode); window.dispatchEvent(new CustomEvent("prevail:profiles-changed")); })
        .catch(() => {});
    void load();
    window.addEventListener("prevail:appmode", load);
    return () => window.removeEventListener("prevail:appmode", load);
  }, []);
  useEffect(() => {
    if (isBrowser()) return;
    (async () => {
      try { const s = await invoke<{ set: boolean }>("engine_lock_status"); setLockSet(!!s.set); } catch { /* engine not ready */ }
    })();
  }, []);
  // On the desktop, the chosen vault lives in localStorage. In the browser the
  // vault physically lives on the desktop machine, so the browser's own
  // localStorage path is meaningless - start empty and always inherit the
  // desktop's authoritative vault from the backend (see the effect below).
  // The phone has no vault of its own and never should: the vault lives on the
  // Mac, and this client is a window onto it. So in a browser we wait for the
  // Mac to tell us its vault rather than ever asking the user to pick a folder.
  const [webVaultTried, setWebVaultTried] = useState(false);
  const webVaultPull = useRef<null | (() => Promise<void>)>(null);
  const [vaultPath, setVaultPath] = useState<string | null>(() =>
    isBrowser() ? null : localStorage.getItem(LS.vault),
  );
  // Force the clean per-domain layout on disk, once per vault per launch. The
  // migration is idempotent (already-clean domains are skipped) and non-
  // destructive (originals archived), and only MOVES files, so it's safe to run
  // before unlock and on every load. This is the forced vault reorganization:
  // hanging files -> source/·memory/·.system/, raw prompt ledger -> journal.
  const migratedVaults = useRef<Set<string>>(new Set());
  useEffect(() => {
    if (isBrowser() || !vaultPath) return;
    if (migratedVaults.current.has(vaultPath)) return;
    migratedVaults.current.add(vaultPath);
    void invoke("engine_vault_migrate_v4", { vault: vaultPath })
      .then(() => window.dispatchEvent(new CustomEvent("prevail:vault-migrated")))
      .catch((e) => console.error("vault migrate-v4", e));
  }, [vaultPath]);
  // Is this vault encrypted (F4 Phase 1)? Checked once the vault path resolves.
  // If it is, the LockScreen unlocks the keyring (sets the DEK) before the app
  // renders. If the engine reports the session already unlocked, skip the gate.
  useEffect(() => {
    if (isBrowser() || !vaultPath) return;
    (async () => {
      try {
        const s = await invoke<{ encrypted: boolean; unlocked: boolean }>("engine_vault_status", { vault: vaultPath });
        setVaultEncrypted(!!s.encrypted);
        if (s.unlocked) setUnlocked(true);
      } catch { /* engine not ready */ } finally { setVaultStatusChecked(true); }
    })();
  }, [vaultPath]);
  // Profiles (2026 redesign): on first run, adopt the current vault as a default
  // "Personal" profile so existing users keep working with zero setup. Idempotent.
  useEffect(() => {
    if (isBrowser() || !vaultPath) return;
    ensureDefaultProfile(vaultPath);
  }, [vaultPath]);
  // Switch profile = swap the active vault. Each profile has its own vault, so
  // this re-points the whole app (domains, threads, loops, notes) at it and
  // re-locks (encrypted vaults re-gate via the LockScreen). The vaultPath effect
  // propagates the change to the engine/config. The passcode gate (if any) was
  // already cleared by the switcher before this event fired.
  useEffect(() => {
    const onSwitch = (e: Event) => {
      const vp = (e as CustomEvent<{ vaultPath?: string; profileId?: string }>).detail?.vaultPath;
      if (!vp || vp === vaultPath) return;
      if (isDemoVaultPath(vp) && appMode === "production") return;
      const prevVault = vaultPath;
      setSelectedApp(null);
      setAppView(false);
      setSelectedDomain(null);
      setActiveThreadPath(null);
      setChatViewNonce((n) => n + 1);
      setUnlocked(false);
      setVaultStatusChecked(false);
      // Profile isolation: snapshot the profile we're LEAVING into its vault, then
      // load the profile we're ENTERING from its vault, so each profile's toggles /
      // model picks / policy travel with its own vault instead of the machine.
      void (async () => {
        await saveProfilePrefs(prevVault);
        await hydrateProfilePrefs(vp);
        setVaultPath(vp);
        lsSet(LS.vault, vp);
        setTab("chat");
        setUiPrefsNonce((n) => n + 1);
        // The entered profile's theme/palette are now in localStorage; tell the
        // appearance hook to re-read them so the look follows the profile.
        window.dispatchEvent(new Event("prevail:appearance-reload"));
        window.dispatchEvent(new Event("prevail:domains-changed"));
      })();
    };
    window.addEventListener("prevail:switch-profile", onSwitch as EventListener);
    return () => window.removeEventListener("prevail:switch-profile", onSwitch as EventListener);
  }, [vaultPath, appMode]);
  const [domains, setDomains] = useState<Domain[]>([]);
  const [selectedDomain, setSelectedDomain] = useState<string | null>(null);
  // Obsidian import modal, opened from the sidebar's Obsidian icon (or Vault
  // settings). Hosted at the app root so any surface can open it via an event.
  const [obImportOpen, setObImportOpen] = useState(false);
  // App view - clicking an app in the sidebar opens it in the canvas: a detail
  // bar (schedule, cadence, last run, vault paths, domains) above a chat scoped
  // to the app's primary domain, so you converse against the app's own data
  // exactly like a domain. Cleared whenever you navigate to a domain/General.
  const [selectedApp, setSelectedApp] = useState<EngineApp | null>(null);
  const [appView, setAppView] = useState(false);
  // Thread scope - WHERE conversations are stored/listed. An open app gets its
  // OWN thread space (`_app-<id>`) that's INDEPENDENT of any domain, so you can
  // hold several ongoing conversations with an app over time without them
  // being tied to (or scattered across) the app's many bound domains. A plain
  // domain (or General) scopes to the domain itself. This is distinct from the
  // GROUNDING domain (what the model reads) - app chats still ground in the
  // app's primary domain so engine_chat has real state to reason over.
  const threadScope = useMemo(
    () =>
      appView && selectedApp
        ? `_app-${selectedApp.id.replace(/[^a-z0-9_-]/gi, "-")}`
        : selectedDomain,
    [appView, selectedApp, selectedDomain],
  );
  // True when an app is open in the canvas. An app is isolated: it does NOT
  // borrow the active domain's chrome (hero header, "apps refreshing this
  // domain" strip, Benchmark tab). Those are domain concepts; an app feeds
  // domains, it isn't one.
  const onApp = appView && !!selectedApp;
  // Open an app in the canvas. Shared by the sidebar and the per-domain Apps
  // strip so "click an app anywhere → jump to it" works the same everywhere.
  const openApp = useCallback((app: EngineApp) => {
    setSelectedApp(app);
    setAppView(true);
    setSelectedDomain(app.domains[0] ?? "");
    setActiveThreadPath(null);
    setChatViewNonce((n) => n + 1);
    setDomainTab("chat");
    setTab("chat");
  }, []);
  // Navigate to a domain's own chat, leaving app view. The mirror of openApp:
  // app detail links to its domains, domain Apps strip links to its apps.
  const openDomain = useCallback((name: string) => {
    setSelectedApp(null);
    setAppView(false);
    setSelectedDomain(name);
    setActiveThreadPath(null);
    setChatViewNonce((n) => n + 1);
    setDomainTab("chat");
    setTab("chat");
  }, []);
  // Enable / disable an app's autonomous sync. Disabled apps stay configured
  // and chattable; the sync daemon simply skips them. The apps-changed event
  // refreshes the open record so the UI reflects the new state.
  const [togglingEnabled, setTogglingEnabled] = useState(false);
  const toggleAppEnabled = useCallback(async () => {
    if (!selectedApp) return;
    const next = !(selectedApp.enabled ?? true);
    setTogglingEnabled(true);
    try {
      await invoke("engine_app_set_enabled", { id: selectedApp.id, enabled: next });
      window.dispatchEvent(new CustomEvent("prevail:apps-changed"));
    } catch (e) { console.error("set app enabled", e); }
    finally { setTogglingEnabled(false); }
  }, [selectedApp]);
  // The domain Apps strip lives deep in the tree; let it open an app via a
  // window event instead of threading a callback through every layer.
  useEffect(() => {
    const onOpen = (e: Event) => {
      const app = (e as CustomEvent).detail as EngineApp | undefined;
      if (app && app.id) openApp(app);
    };
    window.addEventListener("prevail:open-app", onOpen);
    return () => window.removeEventListener("prevail:open-app", onOpen);
  }, [openApp]);
  // Broadcast which app is active so deeply-nested views (e.g. the per-domain
  // Apps strip) can highlight it without prop-drilling.
  useEffect(() => {
    window.dispatchEvent(new CustomEvent("prevail:active-app", { detail: appView && selectedApp ? selectedApp.id : null }));
  }, [appView, selectedApp]);
  // When an app's binding changes (e.g. domains added/removed on its canvas),
  // refresh the OPEN app record in place so grounding + the detail bar stay
  // current - WITHOUT re-opening it (which would reset the conversation).
  useEffect(() => {
    const onAppsChanged = () => {
      if (!appView || !selectedApp) return;
      const id = selectedApp.id;
      invoke<EngineApp[]>("engine_apps_list")
        .then((list) => {
          const fresh = (list ?? []).find((a) => a.id === id);
          if (fresh) setSelectedApp(fresh);
        })
        .catch(() => {});
    };
    window.addEventListener("prevail:apps-changed", onAppsChanged);
    return () => window.removeEventListener("prevail:apps-changed", onAppsChanged);
  }, [appView, selectedApp]);
  // Quick Capture floating widget — opt-in (default OFF). Tracks
  // PREF.quickCaptureEnabled and reacts live to the General-settings toggle via
  // the "prevail:quickcapture-changed" event so the widget appears/disappears
  // without a reload.
  const [quickCaptureOn, setQuickCaptureOn] = useState(() => getPref(PREF.quickCaptureEnabled, "0") === "1");
  useEffect(() => {
    const sync = () => setQuickCaptureOn(getPref(PREF.quickCaptureEnabled, "0") === "1");
    window.addEventListener("prevail:quickcapture-changed", sync);
    return () => window.removeEventListener("prevail:quickcapture-changed", sync);
  }, []);
  // Threads - backed by <vault>/<domain>/_threads/<slug>.md files.
  // Active thread defines what's loaded into the chat transcript.
  const [threads, setThreads] = useState<ThreadMeta[]>([]);
  const [activeThreadPath, setActiveThreadPath] = useState<string | null>(null);
  // Bumped on every thread pick so the chat panel returns to the chat view even
  // when the same thread is re-clicked (e.g. to escape the Preferences view).
  const [chatViewNonce, setChatViewNonce] = useState(0);
  // Per-domain import counts shown as a tiny badge in the sidebar.
  // Refreshed when ingestion:artifact fires (any tier writes a file)
  // or when the domain list changes.
  const [domainStats, setDomainStats] = useState<Record<string, number>>({});
  const domainsRef = useRef<Domain[]>([]);
  useEffect(() => { domainsRef.current = domains; }, [domains]);
  // Heal stale/unsupported model picks (e.g. gpt-5-codex → gpt-5.5) once on launch.
  useEffect(() => { migrateModelPrefs(); }, []);
  // Vault resolution.
  // - Browser (WebUI): the desktop is the source of truth. Always pull the
  //   desktop's current vault from the backend, and refresh on window focus so
  //   a vault changed on the desktop propagates to the web view without a
  //   reload (fixes the web view showing none of the desktop's domains).
  // - Desktop: if localStorage was wiped (e.g. webview cache clear) but we
  //   remembered a vault on disk, restore it so the user isn't bounced back to
  //   first-launch.
  useEffect(() => {
    if (isBrowser()) {
      // Every one of these calls needs a session. Running them before sign-in
      // made each 401, left webVaultTried true with no vault, and parked the
      // phone on "Your Mac has no vault yet" with nothing but a Try again
      // button - the app looked broken and half its features looked missing.
      // The webAuthed dep re-runs this the moment sign-in (or QR pairing)
      // completes.
      if (!webAuthed) return;
      const pull = async () => {
        try {
          const bp = await invoke<string | null>("bootstrap_vault");
          if (bp) setVaultPath((cur) => (cur === bp ? cur : bp));
          setWebVaultTried(true);
        } catch { setWebVaultTried(true); }
      };
      webVaultPull.current = pull;
      // Mirror the desktop's pins / model picks / toggles, then pull its vault,
      // then nudge a re-render so the hydrated prefs take effect.
      void hydrateUiPrefs().then(() => pull()).then(() => setUiPrefsNonce((n) => n + 1));
      window.addEventListener("focus", pull);
      return () => window.removeEventListener("focus", pull);
    }
    (async () => {
      try {
        // Auto-enter DEMO with the bundled sample vault so a fresh (or healed)
        // launch lands in a populated app, never an empty/broken vault. Seeds
        // the bundled resources/sample-vault and marks it demo. (F3 auto-demo.)
        // Check the persisted app mode. Production mode with a live vault is
        // the only case where we skip demo - the user explicitly set it up.
        // Demo mode (or no mode yet) always re-seeds so the user always lands
        // in the populated sandbox with the latest bundled sample data.
        const mode = await invoke<{ mode: "demo" | "production" }>("engine_appmode_get").catch(() => null);
        // A failed mode read (the engine is slow on a cold boot) must not drop
        // into the demo branch below, which opened the startup profile's vault
        // over the config vault: with a config vault, trust it.
        const cfgFirst = mode ? null : await invoke<string | null>("engine_config_vault").catch(() => null);
        if (mode?.mode === "production" || cfgFirst) {
          // config.json is the SINGLE source of truth for the active vault: the
          // engine and the headless daemons read it. Prefer it over localStorage
          // so the UI can never strand on a different vault than the engine (the
          // bug behind blank history/activity/usage + mismatched domains). Sync
          // localStorage so the rest of the app agrees.
          if (mode?.mode === "production") setProfilesProduction(true);
          const cfgVault = cfgFirst ?? await invoke<string | null>("engine_config_vault").catch(() => null);
          if (cfgVault) {
            // The profile follows the config vault, never the reverse: a demo
            // profile left active must not head (or write back over) it.
            const md = await invoke<string>("read_user_md", { vault: cfgVault }).catch(() => "");
            reconcileProductionProfiles(cfgVault, nameFromUserMd(md));
            window.dispatchEvent(new CustomEvent("prevail:profiles-changed"));
            // Config.json is THE source of truth in production. Trust it even if
            // the existence probe flakes during boot - otherwise we strand on a
            // stale localStorage vault (the demo-vault revert bug) and the sync
            // effect writes that wrong path back into config. Mirror it to
            // localStorage so the rest of the UI agrees.
            setVaultPath(cfgVault);
            lsSet(LS.vault, cfgVault);
            return;
          }
          // Fallbacks if config has no usable vault: the last UI pick, then the
          // on-disk bootstrap mirror.
          if (vaultPath) {
            const ok = await invoke<boolean>("vault_exists", { path: vaultPath }).catch(() => false);
            if (ok) return;
            lsSet(LS.vault, "");
            setVaultPath(null);
          }
          const bp = await invoke<string | null>("bootstrap_vault");
          if (bp) {
            const ok = await invoke<boolean>("vault_exists", { path: bp }).catch(() => false);
            if (ok) { setVaultPath(bp); lsSet(LS.vault, bp); return; }
          }
        }
        // Demo mode (default). If the user has taken ownership of a profile
        // (switching to one makes it the default) and its vault still exists,
        // honor that vault so the active profile survives restarts instead of
        // being reverted to the sample sandbox on every launch. A fresh,
        // never-switched sandbox falls through and re-seeds below.
        const owned = getOwnedProfile();
        if (owned?.vaultPath) {
          const ok = await invoke<boolean>("vault_exists", { path: owned.vaultPath }).catch(() => false);
          if (ok) {
            setVaultPath(owned.vaultPath);
            lsSet(LS.vault, owned.vaultPath);
            setSelectedDomain(null);
            return;
          }
        }
        // No owned profile (or its vault is gone). Per user preference we no
        // longer auto-import the bundled sample vault on a fresh install (it read
        // as the user's own data and caused confusion). Land on the VaultWizard so
        // the user points at their own folder. Sample data stays available on
        // demand from Settings -> Workspace.
        setVaultPath(null);
      } catch { /* fall through to the VaultWizard if setup fails */ }
    })();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [webAuthed]);
  // Keep the desktop's remembered vault (bootstrap-vault.txt) in lockstep with
  // whatever vault is actually active, so the WebUI - which inherits via
  // bootstrap_vault - always mirrors what's open on the desktop, not a stale
  // earlier pick. Desktop only; the browser is a consumer, never the source.
  const vaultSyncReady = useRef(false);
  useEffect(() => {
    if (isBrowser() || !vaultPath) return;
    // CRITICAL: skip the FIRST run. On mount, vaultPath is the UNCONFIRMED
    // localStorage value; writing it to config here races ahead of the boot
    // resolution and clobbers config.json (the demo-vault revert bug). Only
    // boot-confirmed or user-chosen vault changes should propagate to config.
    if (!vaultSyncReady.current) {
      vaultSyncReady.current = true;
      return;
    }
    void invoke("remember_vault", { path: vaultPath }).catch(() => {});
    // Keep config.json (the engine/daemon source of truth) in lockstep with the
    // active vault, so switching vaults in the UI moves the engine + daemons too
    // instead of stranding them on a stale folder.
    // In production this moves only the UI's engine calls (VAULT_ROOT):
    // config.json keeps the main vault, so capture and the daemons stay on it.
    // A production config refuses a demo vault outright; the UI then follows
    // the config instead of showing a vault the engine is not using.
    void invoke("engine_set_config_vault", { path: vaultPath }).catch(async () => {
      const cfg = await invoke<string | null>("engine_config_vault").catch(() => null);
      if (cfg && cfg !== vaultPath) { lsSet(LS.vault, cfg); setVaultPath(cfg); }
    });
  }, [vaultPath]);
  const refreshDomainStats = useCallback(async (names: string[]) => {
    const results = await Promise.all(
      names.map(async (n) => {
        try {
          const s = await invoke<{ imports: number }>("ingestion_domain_stats", { domain: n });
          return [n, s.imports] as const;
        } catch { return [n, 0] as const; }
      }),
    );
    setDomainStats(Object.fromEntries(results));
  }, []);
  const [, setDueTasks] = useState<Record<string, number>>({});
  const checkReminders = useCallback(async (vault: string) => {
    try {
      const due = await invoke<{ domain: string }[]>("reminders_check", { vault });
      const counts: Record<string, number> = {};
      for (const t of due) counts[t.domain] = (counts[t.domain] ?? 0) + 1;
      setDueTasks(counts);
    } catch { /* ignore */ }
  }, []);
  // Fire reminders_check once when the vault becomes known, then again on
  // every window focus (catches a new day without a relaunch).
  useEffect(() => {
    if (isBrowser() || !vaultPath) return;
    void checkReminders(vaultPath);
    const onFocus = () => void checkReminders(vaultPath);
    window.addEventListener("focus", onFocus);
    return () => window.removeEventListener("focus", onFocus);
  }, [vaultPath, checkReminders]);
  // Refresh sidebar badge counts silently after any task write (no new
  // notifications - just update the counts so checking a box clears the badge).
  useEffect(() => {
    if (isBrowser() || !vaultPath) return;
    const refresh = async () => {
      try {
        const due = await invoke<{ domain: string }[]>("reminders_due_today", { vault: vaultPath });
        const counts: Record<string, number> = {};
        for (const t of due) counts[t.domain] = (counts[t.domain] ?? 0) + 1;
        setDueTasks(counts);
      } catch { /* ignore */ }
    };
    window.addEventListener("prevail:tasks-changed", refresh);
    return () => window.removeEventListener("prevail:tasks-changed", refresh);
  }, [vaultPath]);
  // Onboarding flow - opt-in only, opened manually via "Set up domains".
  // It never auto-appears (the old auto-open raced the scan and popped over
  // a populated vault). The dismissed flag is retained so manual closes are
  // tracked even though nothing auto-reopens.
  const [onboardOpen, setOnboardOpen] = useState(false);
  const [, setUiPrefsNonce] = useState(0); // browser: re-render after prefs hydrate
  const [, setOnboardDismissed] = useState(false);
  // Tracks whether the first scan_vault for the current vault has resolved.
  const [, setDomainsLoaded] = useState(false);
  // Reusable vault re-scan (used by onboarding apply + archive/restore).
  const refreshDomains = useCallback(async () => {
    if (!vaultPath) return;
    try {
      const d = await invokeCached<Domain[]>("scan_vault", { path: vaultPath }, { force: true });
      setDomains(Array.isArray(d) ? d : []);
      setVaultError(null);
      setDomainsLoaded(true);
      void refreshDomainStats(d.map((x) => x.name));
    } catch (e) {
      console.error("refreshDomains", e);
    }
  }, [vaultPath, refreshDomainStats]);
  // Rescan when a starter pack is imported (from Settings → Demo Mode) so the
  // new domains show up in the sidebar immediately, no reload needed.
  useEffect(() => {
    const h = () => void refreshDomains();
    window.addEventListener("prevail:domains-changed", h);
    return () => window.removeEventListener("prevail:domains-changed", h);
  }, [refreshDomains]);
  // WebUI host bridge: when running as the DESKTOP host (not a browser tab),
  // execute proxied invokes from web clients and forward events to them. This
  // is what lets the same UI run in a browser with zero duplicate code - the
  // host window is the executor (webview-proxy). No-op in a browser tab.
  useEffect(() => {
    if (isBrowser()) return;
    let unlistens: UnlistenFn[] = [];
    (async () => {
      unlistens.push(await listen<{ id: number; cmd: string; args: Record<string, unknown> }>("webui:invoke", async (e) => {
        const { id, cmd, args } = e.payload;
        try {
          const data = await invoke(cmd, args);
          await invoke("webui_resolve", { id, ok: true, data });
        } catch (err) {
          await invoke("webui_resolve", { id, ok: false, error: String(err) });
        }
      }));
      // Forward the event channels the UI listens to → web clients.
      const channels = ["chat:chunk", "chat:done", "engine-chat:line", "engine-chat:done", "engine-agent:line", "engine-agent:done", "engine-skill:line", "engine-skill:done", "benchmark:chunk", "benchmark:done", "ingestion:artifact", "ingestion:browser", "connector_learn:line", "connector_learn:done", "connector_run:line", "connector_run:done", "tg:message_in", "tg:message_out"];
      for (const ch of channels) {
        unlistens.push(await listen<unknown>(ch, (e) => { void invoke("webui_event", { event: ch, payload: e.payload }); }));
      }
    })();
    return () => { unlistens.forEach((u) => u()); unlistens = []; };
  }, []);
  // Start/stop background daemons (distill + reminders + task-gen) when vault is known.
  useEffect(() => {
    if (!vaultPath) return;
    if (isBrowser()) return;
    (async () => {
    // One-time, idempotent: migrate a legacy vault to the v3 layout (apps/ +
    // domains/ as siblings). Safe - only moves real domains, never overwrites,
    // never deletes. New + already-migrated vaults are a no-op.
    await invoke<number>("vault_migrate_layout", { path: vaultPath }).catch(() => 0);
    // If the headless learn agent (launchd) is installed, it owns distillation -
    // the in-app distiller defers so the two never double-run on the same vault.
    const headless = await invoke<boolean>("headless_learn_status").catch(() => false);
    // Distill
    const on = !headless && getPref(PREF.persistentMemory, "1") === "1" && getPref(PREF.autoCompression, "1") === "1";
    if (on) {
      invoke("distill_start", { cfg: distillCfgFromPrefs(vaultPath) }).catch((e) => console.error("distill_start", e));
    } else {
      invoke("distill_stop").catch(() => {});
    }
    })();
    // Reminders
    const remInterval = Number(getPref(PREF.remindersIntervalSec, "900")) || 900;
    invoke("reminders_daemon_start", { vault: vaultPath, interval_sec: remInterval }).catch(() => {});
    // Task generation
    if (getPref(PREF.taskgenEnabled, "0") === "1") {
      invoke("taskgen_start", { cfg: taskgenCfgFromPrefs(vaultPath) }).catch((e) => console.error("taskgen_start", e));
    }
    // Scheduled vault backups (data protection) - same pattern.
    startBackupScheduler(vaultPath);
    // Domain Loops - advance due loops behind the scenes (self-driving), not just
    // on the "Run loops now" button. Tick re-reads the enabled pref.
    startLoopsScheduler(vaultPath);
    // Apps - keep connected apps fresh on their own schedule while open.
    startAppsScheduler(vaultPath);
    // Omega - auto-distill the app-wide learned layer on a slow cadence (daily).
    // Tick re-reads the enabled pref, so toggling needs no restart.
    startOmegaScheduler(vaultPath);
    // Skill generation (self-learning) - on by default so the app learns
    // skills from conversations out of the box; togglable in Settings.
    if (getPref(PREF.skillgenEnabled, "1") === "1") {
      invoke("skillgen_start", { cfg: skillgenCfgFromPrefs(vaultPath) }).catch((e) => console.error("skillgen_start", e));
    } else {
      invoke("skillgen_stop").catch(() => {});
    }
    // Intent distillation (self-learning) - on by default so high-level intents
    // + recommendations stay fresh automatically (cadence + new-prompt trigger),
    // with no manual button press.
    if (getPref(PREF.intentDaemonEnabled, "1") === "1") {
      invoke("intent_daemon_start", { cfg: intentDaemonCfgFromPrefs(vaultPath) }).catch((e) => console.error("intent_daemon_start", e));
    } else {
      invoke("intent_daemon_stop").catch(() => {});
    }
  }, [vaultPath]);
  useEffect(() => {
    let unl: UnlistenFn | null = null;
    (async () => {
      unl = await listen("ingestion:artifact", () => {
        void refreshDomainStats(domainsRef.current.map((d) => d.name));
      });
    })();
    return () => { if (unl) unl(); };
  }, [refreshDomainStats]);
  // B2-30: tray-menu quick actions (emitted from the Rust tray after revealing
  // the window). Route each to the matching surface.
  useEffect(() => {
    let unl: UnlistenFn | null = null;
    (async () => {
      unl = await listen<string>("prevail:tray-action", (e) => {
        switch (e.payload) {
          case "new-chat":
            setTab("chat"); setDomainTab("chat");
            setActiveThreadPath(null); setChatViewNonce((n) => n + 1);
            break;
          case "council":
            setTab("council");
            break;
          case "briefing":
            setTab("chat"); setDomainTab("insights");
            break;
          case "incognito": {
            const next = getPref(PREF.incognito, "0") === "1" ? "0" : "1";
            lsSet(PREF.incognito, next);
            window.dispatchEvent(new Event("prevail:incognito-changed"));
            break;
          }
        }
      });
    })();
    return () => { if (unl) unl(); };
  }, []);
  // F8: bridge the native global-hotkey + deep-link Tauri events to DOM events
  // the rest of the app already listens for (Quick Capture summon, connect flows).
  useEffect(() => {
    let unlA: UnlistenFn | null = null;
    let unlB: UnlistenFn | null = null;
    (async () => {
      unlA = await listen("prevail:quick-capture", () => window.dispatchEvent(new Event("prevail:quick-capture")));
      unlB = await listen<string[]>("prevail:deep-link", (e) => window.dispatchEvent(new CustomEvent("prevail:deep-link", { detail: e.payload })));
    })();
    return () => { if (unlA) unlA(); if (unlB) unlB(); };
  }, []);
  // Switching domains never drags the previous domain's thread pointer
  // along (the next auto-save would write into the wrong domain folder),
  // but returning to a domain lands on what you were working on: a stream
  // that's still running there first, else the thread you last had open.
  useEffect(() => {
    const scope = threadScope;
    if (!scope) { setActiveThreadPath(null); return; }
    const running = runningStreams.find((s) => s.threadPath && s.threadPath.includes(`/${scope}/`));
    const remembered = lsGet(`prevail.domain.${scope}.lastThread`);
    setActiveThreadPath(
      running?.threadPath
        ?? (remembered && remembered.includes(`/${scope}/`) ? remembered : null),
    );
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [threadScope]);
  // Cross-domain streaming awareness - App-level map of in-flight
  // streams. Sidebar + ThreadsRail read this to pulse domains/threads
  // that have work happening in the background.
  type RunningStream = {
    sessionId: string;
    domain: string | null;
    threadPath: string | null;
    title: string;
    startedAt: number;
  };
  const [runningStreams, setRunningStreams] = useState<RunningStream[]>([]);
  // Domains whose background run finished while you were looking elsewhere.
  // The live amber pulse vanishes the instant a stream ends; this keeps a
  // steady "ready" marker on the domain until you actually open it, so a
  // finished run is never silently lost when several are in flight at once.
  const [finishedDomains, setFinishedDomains] = useState<Record<string, number>>({});
  const notifyPermissionRef = useRef<NotificationPermission | "unknown">(typeof Notification !== "undefined" ? Notification.permission : "unknown");
  useEffect(() => {
    if (typeof Notification === "undefined") return;
    if (notifyPermissionRef.current === "default") {
      Notification.requestPermission().then((p) => { notifyPermissionRef.current = p; }).catch(() => {});
    }
  }, []);
  function notifyDone(title: string, body: string) {
    if (lsGet(PREF.desktopNotif) !== "1") return;
    if (typeof Notification === "undefined") return;
    if (notifyPermissionRef.current === "granted") {
      try { new Notification(title, { body }); } catch {}
    }
  }
  // Memory watchdog surface. The Rust watchdog emits `system:memory-warning`
  // when Prevail's footprint approaches a machine-freezing fraction of RAM;
  // kind "killed" means it already stopped the largest runaway task to protect
  // the Mac. This is a SAFETY alert, so it shows regardless of the routine
  // notification pref. The banner auto-clears; the native notification reaches
  // the user even if they've switched to another app (when a freeze would hit).
  const [memoryAlert, setMemoryAlert] = useState<{ kind: string; message: string } | null>(null);
  useEffect(() => {
    let un: UnlistenFn | undefined;
    listen<{ kind: string; message: string }>("system:memory-warning", (e) => {
      const { kind, message } = e.payload;
      console.warn(`[memory ${kind}] ${message}`);
      setMemoryAlert({ kind, message });
      if (typeof Notification !== "undefined" && notifyPermissionRef.current === "granted") {
        try {
          new Notification(kind === "killed" ? "Glyph Studio stopped a runaway task" : "Glyph Studio memory is high", { body: message });
        } catch {}
      }
    }).then((f) => { un = f; }).catch(() => {});
    return () => { un?.(); };
  }, []);
  // Auto-dismiss the banner a while after the latest alert.
  useEffect(() => {
    if (!memoryAlert) return;
    const t = setTimeout(() => setMemoryAlert(null), 20000);
    return () => clearTimeout(t);
  }, [memoryAlert]);
  function playDoneChime() {
    if (lsGet(PREF.soundOnDone) !== "1") return;
    try {
      const AC = (window as unknown as { AudioContext?: typeof AudioContext; webkitAudioContext?: typeof AudioContext }).AudioContext
        || (window as unknown as { AudioContext?: typeof AudioContext; webkitAudioContext?: typeof AudioContext }).webkitAudioContext;
      if (!AC) return;
      const ctx = new AC();
      const o = ctx.createOscillator();
      const g = ctx.createGain();
      o.frequency.value = 880;
      o.type = "sine";
      g.gain.setValueAtTime(0.0001, ctx.currentTime);
      g.gain.exponentialRampToValueAtTime(0.08, ctx.currentTime + 0.02);
      g.gain.exponentialRampToValueAtTime(0.0001, ctx.currentTime + 0.32);
      o.connect(g).connect(ctx.destination);
      o.start();
      o.stop(ctx.currentTime + 0.34);
      o.onended = () => ctx.close();
    } catch {}
  }
  const markStreamStart = useCallback((s: RunningStream) => {
    setRunningStreams((cur) => [...cur.filter((x) => x.sessionId !== s.sessionId), s]);
  }, []);
  const selectedDomainRef = useRef<string | null>(null);
  useEffect(() => { selectedDomainRef.current = selectedDomain; }, [selectedDomain]);
  const markStreamEnd = useCallback((sessionId: string) => {
    setRunningStreams((cur) => {
      const ended = cur.find((x) => x.sessionId === sessionId);
      if (ended) {
        playDoneChime();
        if (ended.domain !== selectedDomainRef.current) {
          const where = ended.domain ? titleCase(ended.domain) : "no domain";
          notifyDone(`Reply ready · ${where}`, ended.title || "Your conversation just finished.");
          // Leave a persistent "ready" marker on the domain you weren't watching.
          if (ended.domain) {
            const dom = ended.domain;
            setFinishedDomains((m) => ({ ...m, [dom]: Date.now() }));
          }
        }
      }
      return cur.filter((x) => x.sessionId !== sessionId);
    });
  }, []);
  // A domain reads as "running" if it has a live chat/council stream OR a loop
  // running (so a loop firing lights up its domain in the sidebar, and the dot
  // persists when you navigate away and back).
  const liveProcs = useProcesses();
  const runningDomains = useMemo(
    () => new Set([
      ...runningStreams.map((s) => s.domain ?? ""),
      ...liveProcs.filter((p) => p.kind === "loop" && p.domain).map((p) => p.domain as string),
    ]),
    [runningStreams, liveProcs],
  );
  const runningThreadPaths = useMemo(() => new Set(runningStreams.map((s) => s.threadPath ?? "").filter(Boolean)), [runningStreams]);
  // Opening a domain clears its "ready" marker - you've now seen it.
  useEffect(() => {
    if (!selectedDomain) return;
    setFinishedDomains((m) => {
      if (!(selectedDomain in m)) return m;
      const next = { ...m };
      delete next[selectedDomain];
      return next;
    });
  }, [selectedDomain]);
  // A domain shows "ready" only when it's done AND not currently re-running.
  const finishedDomainSet = useMemo(
    () => new Set(Object.keys(finishedDomains).filter((d) => !runningDomains.has(d))),
    [finishedDomains, runningDomains],
  );
  // Persisted rail widths. Min/max enforced when dragging.
  const [domainRailWidth, setDomainRailWidth] = useState<number>(() => {
    const v = parseInt(lsGet("prevail.domainRailWidth"), 10);
    return Number.isFinite(v) && v > 0 ? v : 256;
  });

  useEffect(() => { lsSet("prevail.domainRailWidth", String(domainRailWidth)); }, [domainRailWidth]);
  const refreshThreads = useCallback(async () => {
    if (!vaultPath) return;
    try {
      const list = await invoke<ThreadMeta[]>("list_threads", { vault: vaultPath, domain: threadScope || null });
      // Null-tolerant: a null body from the engine must not crash the shell.
      setThreads(Array.isArray(list) ? list : []);
    } catch (e) { console.error("list_threads", e); }
  }, [vaultPath, threadScope]);
  useEffect(() => { void refreshThreads(); }, [refreshThreads]);
  // Conversations saved elsewhere (an entity chat) show in the rail at once.
  useEffect(() => {
    const f = () => { void refreshThreads(); };
    window.addEventListener("prevail:threads-changed", f);
    return () => window.removeEventListener("prevail:threads-changed", f);
  }, [refreshThreads]);
  const [clis, setClis] = useState<CliInfo[]>([]);
  // O1/F6: once runtime detection has run, know whether ANY model is usable, so
  // we can prompt a new user to set one up instead of letting chat fail silently.
  const [clisDetected, setClisDetected] = useState(false);
  const [noModelDismissed, setNoModelDismissed] = useState(false);
  const noModelConfigured = clisDetected && clis.length > 0 && !clis.some((c) => c.available);
  const [tab, setTab] = useState<TabId>("chat");
  // T18: record which primary surface is in use (inert until keys exist;
  // default-OFF; "settings" is not a tracked feature so it's simply skipped).
  useEffect(() => {
    if (tab === "chat" || tab === "council" || tab === "benchmark") track("feature_used", { feature: tab });
  }, [tab]);
  // Cross-domain Decision Inbox count — surfaced as a top-bar pill so pending
  // approvals / AI reviews are visible without opening Settings. Cheap call
  // (list_domain_names, no state reads); refreshed slowly + on task/loop events.
  const [decisionsCount, setDecisionsCount] = useState(0);
  // F7: remember the last count so a RISE (the AI newly blocked, waiting on you)
  // fires a native notification - the one "needs you" moment that previously
  // surfaced only as an in-app pill. -1 = not yet polled, so the first load
  // never notifies for pre-existing decisions.
  const prevDecisionsRef = useRef<number>(-1);
  useEffect(() => {
    if (!vaultPath) return;
    let alive = true;
    const poll = () => invoke<unknown[]>("decisions_pending", { vault: vaultPath })
      .then((d) => {
        if (!alive) return;
        const n = Array.isArray(d) ? d.length : 0;
        setDecisionsCount(n);
        const prev = prevDecisionsRef.current;
        if (prev >= 0 && n > prev) {
          const added = n - prev;
          const title = "Glyph Studio needs your approval";
          const body = added === 1 ? "An automation is waiting for you to approve an action." : `${n} actions are waiting for your approval.`;
          if (isBrowser()) {
            // X8: mobile/web (WebUI) - foreground browser notification so a phone
            // or laptop gets the approval alert too, no native host needed.
            notifyWeb(title, body);
          } else {
            void invoke("notify_user", { title, body }).catch(() => {});
          }
        }
        prevDecisionsRef.current = n;
      })
      .catch(() => {});
    void poll();
    const id = window.setInterval(poll, 60000);
    const onEvt = () => poll();
    window.addEventListener("prevail:tasks-changed", onEvt);
    window.addEventListener("prevail:loops-advanced", onEvt);
    return () => { alive = false; window.clearInterval(id); window.removeEventListener("prevail:tasks-changed", onEvt); window.removeEventListener("prevail:loops-advanced", onEvt); };
  }, [vaultPath]);

  // Due/critical alerting — a top-bar pill counting tasks that need attention NOW:
  // overdue, due today, or flagged critical (open, not trashed). Visible app-wide so
  // time-sensitive work (tax this quarter, a critical item) surfaces without opening
  // the board. Cheap-ish read, slow poll + event refresh, same as the decisions pill.
  // Count open work by reading each domain's _tasks.md DIRECTLY (same proven
  // read_file + domain.path mechanism the Loop count uses). tasks_read_all was
  // returning empty at app scope for some vault layouts, so the badge never lit;
  // reading the files we know exist is layout-proof. Task line format:
  //   `- [ ] text @<due> +<added> ~daemon ~id:xxx`  (@ = due date)
  const [dueAlert, setDueAlert] = useState<{ overdue: number; today: number; open: number }>({ overdue: 0, today: 0, open: 0 });
  useEffect(() => {
    if (!vaultPath) return;
    let alive = true;
    // Scope the Work count to the domain the user is on (global only on General /
    // no domain), so switching wealth -> tax -> health shows that domain's count.
    const poll = () => invoke<{ open?: number; overdue?: number; today?: number }>("work_count", { vault: vaultPath, today: new Date().toISOString().slice(0, 10), domain: selectedDomain ?? null })
      .then((r) => { if (alive) setDueAlert({ open: r?.open ?? 0, overdue: r?.overdue ?? 0, today: r?.today ?? 0 }); })
      .catch(() => {});
    void poll();
    const id = window.setInterval(poll, 60000);
    const onEvt = () => poll();
    window.addEventListener("prevail:tasks-changed", onEvt);
    window.addEventListener("prevail:loops-advanced", onEvt);
    return () => { alive = false; window.clearInterval(id); window.removeEventListener("prevail:tasks-changed", onEvt); window.removeEventListener("prevail:loops-advanced", onEvt); };
  }, [vaultPath, selectedDomain]);
  // X1 (heartbeat): ambient proactivity. On a slow tick, during active hours, if
  // things need you (pending approvals or overdue work) and we haven't nudged in
  // a while, fire ONE consolidated native notification - so Prevail reaches out
  // instead of waiting to be opened. Config via prefs; on by default. (A full
  // background heartbeat that runs agent turns on a checklist is a follow-on that
  // rides the loop-run engine.)
  useEffect(() => {
    if (isBrowser()) return;
    const HEARTBEAT_KEY = "prevail.heartbeat.lastNudge";
    const tick = () => {
      if (getPref(PREF.heartbeatEnabled, "1") !== "1") return;
      const now = new Date();
      const hour = now.getHours();
      const startH = parseInt(getPref(PREF.heartbeatActiveStart, "8"), 10) || 8;
      const endH = parseInt(getPref(PREF.heartbeatActiveEnd, "22"), 10) || 22;
      if (hour < startH || hour >= endH) return; // quiet outside active hours
      const needs = decisionsCount + (dueAlert.overdue || 0);
      if (needs <= 0) return;
      const last = parseInt(lsGet(HEARTBEAT_KEY) || "0", 10) || 0;
      const minGapMs = (parseInt(getPref(PREF.heartbeatIntervalHours, "3"), 10) || 3) * 3600_000;
      if (now.getTime() - last < minGapMs) return;
      const parts: string[] = [];
      if (decisionsCount > 0) parts.push(`${decisionsCount} waiting on your approval`);
      if (dueAlert.overdue > 0) parts.push(`${dueAlert.overdue} overdue`);
      void invoke("notify_user", { title: "Glyph Studio check-in", body: `${parts.join(" · ")}. Open Glyph Studio when you have a moment.` }).catch(() => {});
      lsSet(HEARTBEAT_KEY, String(now.getTime()));
    };
    const id = window.setInterval(tick, 10 * 60_000); // evaluate every 10 min
    return () => window.clearInterval(id);
  }, [decisionsCount, dueAlert]);
  // Insights (recommendations) count, surfaced as an always-visible badge on the
  // top-nav tab so the user sees how much is waiting. Computed in the background on
  // a slow poll + event refresh, same cadence as the decisions/due pills.
  const [recCount, setRecCount] = useState(0);
  useEffect(() => {
    if (!vaultPath) return;
    let alive = true;
    // Scope Insights to the selected domain so the badge matches what that domain
    // actually has (global only on General / no domain).
    const poll = () => invoke<{ ok?: boolean; recommendations?: { domain?: string }[] }>("engine_recommendations", { vault: vaultPath })
      .then((r) => {
        if (!alive) return;
        const recs = Array.isArray(r?.recommendations) ? r!.recommendations : [];
        const scoped = selectedDomain
          ? recs.filter((x) => (x?.domain ?? "").toLowerCase() === selectedDomain.toLowerCase())
          : recs;
        setRecCount(scoped.length);
      })
      .catch(() => {});
    void poll();
    const id = window.setInterval(poll, 120000);
    const onEvt = () => poll();
    window.addEventListener("prevail:recommendations-changed", onEvt);
    window.addEventListener("prevail:loops-advanced", onEvt);
    return () => { alive = false; window.clearInterval(id); window.removeEventListener("prevail:recommendations-changed", onEvt); window.removeEventListener("prevail:loops-advanced", onEvt); };
  }, [vaultPath, selectedDomain]);

  // Lets in-app links (e.g. the Demo ribbon) open a specific Settings section.
  const [settingsJump, setSettingsJump] = useState<{ section: string; n: number } | null>(null);
  const openSettingsAt = (raw: string) => {
    noteToolkitGroup(raw);
    // The raw id travels on: SettingsPanel resolves it to a page and, for the
    // pages that gather several sections, the side row to open.
    const section = raw;
    setSettingsJump((j) => ({ section, n: (j?.n ?? 0) + 1 }));
    setTab("settings");
  };
  // The old top-level Retrospect tab is Intent now.
  useEffect(() => { if (tab === "retrospect") openSettingsAt("intent"); }, [tab]); // eslint-disable-line react-hooks/exhaustive-deps
  // Work mode jump: the operational sections live in Home (Work mode), so
  // deep links to them route here.
  const [workJump, setWorkJump] = useState<{ section: string; n: number } | null>(null);
  const openWorkAt = (raw: string) => {
    noteCompassFocus(raw);
    noteIaKind(raw);
    const section = workSection(raw) ?? raw;
    setWorkJump((j) => ({ section, n: (j?.n ?? 0) + 1 }));
    setTab("work");
  };
  // Route a section name to whichever mode now owns it. Removed screens
  // (Source Map, Spark, Automations, Calendar, Notes) land on Home.
  const openSectionAt = (section: string) => {
    if (REMOVED_SECTIONS.has(section)) { setSelectedDomain(""); setTab("chat"); }
    else if (workSection(section)) openWorkAt(section);
    else openSettingsAt(section);
  };
  // Window-event form of the same jump, for module-scope UI (sidebar
  // indicators) that has no prop line to the App.
  useEffect(() => {
    const onOpen = (e: Event) => {
      const s = (e as CustomEvent<string>).detail;
      if (s) openSectionAt(s);
    };
    window.addEventListener("prevail:open-settings", onOpen as EventListener);
    // The sidebar's search field opens the command palette.
    const onOpenPalette = () => setCmdPaletteOpen(true);
    window.addEventListener("prevail:open-palette", onOpenPalette);
    // The shared sidebar's Work surfaces dispatch this. Route through openWorkAt
    // so the section reaches WorkPanel via jumpTo even when it's mounting fresh
    // (a plain event would fire before its listener attaches).
    const onWorkSection = (e: Event) => {
      const s = (e as CustomEvent<string>).detail;
      if (s) openSectionAt(s);
    };
    window.addEventListener("prevail:work-section", onWorkSection as EventListener);
    // The Editor sidebar needs the same treatment, and did not have it: its
    // items dispatched a bare event that SettingsPanel answers from its own
    // listener. Switch to Editor and click an item before that lazy panel has
    // mounted and the event lands on nobody, dropping the user on General.
    // Routing through openSettingsAt carries the section in as a prop instead,
    // so it survives the mount. SettingsPanel keeps its listener for
    // in-settings deep links, which arrive when it is already up.
    const onEditorSection = (e: Event) => {
      const s = (e as CustomEvent<string>).detail;
      if (s && !s.includes(":")) openSectionAt(s);
    };
    window.addEventListener("prevail:settings-section", onEditorSection as EventListener);
    // Jump straight to a domain (from the Recommendations "Open" action or the
    // Loop Board). "" = General (a real domain now), so accept any string.
    const onOpenDomain = (e: Event) => {
      const d = (e as CustomEvent<string>).detail;
      if (typeof d === "string") openDomain(d);
    };
    window.addEventListener("prevail:open-domain", onOpenDomain as EventListener);
    // Switch the active domain sub-tab (e.g. Loop Board "open in domain" -> Loops).
    const onDomainTabEvt = (e: Event) => {
      const t = (e as CustomEvent<string>).detail as DomainTab;
      if (t) { setTab("chat"); setDomainTab(t); }
    };
    window.addEventListener("prevail:domain-tab", onDomainTabEvt as EventListener);
    // Fresh chat - reset the running conversation (context meter "start fresh").
    // Long-term memory + domain context carry over; only the thread resets.
    const onNewChat = () => { setActiveThreadPath(null); setChatViewNonce((n) => n + 1); };
    window.addEventListener("prevail:new-chat", onNewChat);
    // Seeding the composer (e.g. a task's "Discuss with AI") must also LEAVE any
    // settings/council/arena view and land on Chat so the seeded composer is
    // visible. ChatPanel reads the pending seed on mount (survives this nav).
    const onComposeSeed = () => { setTab("chat"); setDomainTab("chat"); };
    window.addEventListener("prevail:compose-seed", onComposeSeed);
    // Obsidian icon (sidebar footer) / Vault settings -> open the import config.
    const onImportObsidian = () => setObImportOpen(true);
    window.addEventListener("prevail:import-obsidian", onImportObsidian);
    // Count vault-affecting changes for the change-based backup trigger.
    const bump = () => bumpBackupChangeCount();
    window.addEventListener("prevail:context-changed", bump);
    window.addEventListener("prevail:tasks-changed", bump);
    return () => {
      window.removeEventListener("prevail:open-settings", onOpen as EventListener);
      window.removeEventListener("prevail:open-palette", onOpenPalette);
      window.removeEventListener("prevail:work-section", onWorkSection as EventListener);
      window.removeEventListener("prevail:settings-section", onEditorSection as EventListener);
      window.removeEventListener("prevail:open-domain", onOpenDomain as EventListener);
      window.removeEventListener("prevail:domain-tab", onDomainTabEvt as EventListener);
      window.removeEventListener("prevail:new-chat", onNewChat);
      window.removeEventListener("prevail:compose-seed", onComposeSeed);
      window.removeEventListener("prevail:import-obsidian", onImportObsidian);
      window.removeEventListener("prevail:context-changed", bump);
      window.removeEventListener("prevail:tasks-changed", bump);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
  useEffect(() => {
    // A file link in a reply (prevail://file/<path>, or a relative .md link from
    // an Obsidian import) carries a vault-relative path; read it and show it in
    // the canvas pane.
    const onOpenVaultFile = (e: Event) => {
      const rel = (e as CustomEvent<string>).detail;
      if (!vaultPath || typeof rel !== "string" || !rel || rel.startsWith("/") || rel.split("/").includes("..")) return;
      const full = `${vaultPath.replace(/\/+$/, "")}/${rel}`;
      invoke<string>("read_text_file", { path: full })
        .then((body) => window.dispatchEvent(new CustomEvent("prevail:open-canvas", { detail: { title: rel.split("/").pop() || rel, body } })))
        .catch((err) => window.dispatchEvent(new CustomEvent("prevail:open-canvas", { detail: { title: rel, body: `Could not open ${rel}: ${String(err)}` } })));
    };
    window.addEventListener("prevail:open-vault-file", onOpenVaultFile as EventListener);
    return () => window.removeEventListener("prevail:open-vault-file", onOpenVaultFile as EventListener);
  }, [vaultPath]);
  // An entity's "Mentioned in" row (Entities view) opens that chat thread in its domain.
  useEffect(() => {
    const onOpenThread = (e: Event) => {
      const d = (e as CustomEvent<{ domain?: string; ref?: string }>).detail;
      if (!vaultPath || !d?.domain || !d.ref || d.ref.startsWith("/") || d.ref.split("/").includes("..")) return;
      const full = `${vaultPath.replace(/\/+$/, "")}/${d.ref}`;
      // "general" names General, which the shell opens as "" (a conversation
      // schedule carries the engine's domain name).
      const dom = d.domain === "general" ? "" : d.domain;
      if (dom) { try { localStorage.setItem(`prevail.domain.${dom}.lastThread`, full); } catch { /* storage off */ } }
      openDomain(dom);
      window.setTimeout(() => setActiveThreadPath(full), 0);
    };
    window.addEventListener("prevail:open-thread", onOpenThread as EventListener);
    return () => window.removeEventListener("prevail:open-thread", onOpenThread as EventListener);
  }, [vaultPath, openDomain]);
  // Entity chips read the vault's pages (for the green dot and the chat
  // directive) from one shared store.
  useEffect(() => { setEntityVault(vaultPath || null); }, [vaultPath]);
  // Lifted from ChatPanel so the top bar owns the domain Insights / Preferences
  // toggles. ChatPanel receives these as props and renders the matching view.
  const [domainTab, setDomainTab] = useState<DomainTab>("chat");
  // Collapse the top-right tab cluster (Work/Insights/.../Archive) into a single
  // chevron at the right edge for a cleaner top bar; expands back leftward.
  // Collapsed by default for a cleaner top bar; only stays expanded if the user
  // explicitly opened it (stored "0").
  const [navCollapsed, setNavCollapsed] = useState<boolean>(() => localStorage.getItem("prevail.nav.collapsed") !== "0");
  const toggleNavCollapsed = () => setNavCollapsed((v) => { const n = !v; localStorage.setItem("prevail.nav.collapsed", n ? "1" : "0"); return n; });
  // Bunker Mode: backend is the source of truth; mirror it into localStorage on
  // mount so synchronous reads (isBunkerOn) everywhere stay correct, and into
  // React state so the persistent ribbon re-renders on toggle.
  const [bunkerEnabled, setBunkerEnabled] = useState<boolean>(isBunkerOn);
  const [bunkerLocalOk, setBunkerLocalOk] = useState<boolean>(true); // assume ok until checked
  useEffect(() => {
    // The synchronous mirror defaults to ON so that an unknown state fails
    // closed for anything that READS it. Displaying that guess is a different
    // matter: in a browser this ran before sign-in, 401'd into the silent
    // catch, and left the Privacy screen and the ribbon both announcing
    // "fully local, nothing leaves your machine" while the engine had Bunker
    // Mode off. A safety control must never claim protection it does not have,
    // so the backend answer is fetched again the moment sign-in completes.
    if (isBrowser() && !webAuthed) return;
    invoke<{ enabled: boolean; local_available: boolean }>("bunker_status")
      .then((s) => {
        const on = !!s.enabled;
        lsSet(BUNKER_LS, on ? "1" : "0");
        setBunkerEnabled(on);
        setBunkerLocalOk(!!s.local_available);
      })
      .catch(() => {});
  }, [webAuthed]);
  // Called by the Privacy & Connectivity section after a confirmed toggle.
  const applyBunker = useCallback((on: boolean) => {
    lsSet(BUNKER_LS, on ? "1" : "0");
    setBunkerEnabled(on);
  }, []);
  // A domain can launch a scoped benchmark; it dispatches this event and we
  // jump to the Benchmark page pre-scoped to that domain.
  const [benchScope, setBenchScope] = useState<string | null>(null);
  // The Benchmark panel stays mounted (hidden) on other tabs so an in-flight run
  // keeps its live progress when you navigate away. But it's a heavy lazy chunk,
  // so don't load it until the tab is first opened - if it was never visited,
  // there's no run to preserve. Once true, it stays mounted for the session.
  const [benchEverVisited, setBenchEverVisited] = useState(false);
  useEffect(() => { if (tab === "benchmark") setBenchEverVisited(true); }, [tab]);
  // Same treatment for the council: a convened council is a long-running stream,
  // so once you've opened the tab keep the panel MOUNTED (hidden) on other tabs.
  // Otherwise switching to chat unmounts it and the in-flight run + verdict are
  // lost. Lazy-mount on first visit so there's nothing to preserve before then.
  const [councilEverVisited, setCouncilEverVisited] = useState(false);
  useEffect(() => { if (tab === "council") setCouncilEverVisited(true); }, [tab]);
  useEffect(() => {
    const onBench = (e: Event) => {
      const d = (e as CustomEvent<string>).detail || null;
      setBenchScope(d);
      setTab("benchmark");
    };
    window.addEventListener("prevail:benchmark-domain", onBench as EventListener);
    return () => window.removeEventListener("prevail:benchmark-domain", onBench as EventListener);
  }, []);
  // I4: a high-stakes quick-action (Decision / Risks) routes to the Council. The
  // card dispatches this event; we switch the domain + Council tab and seed the
  // question so the user just picks panelists and convenes.
  const [councilSeed, setCouncilSeed] = useState<string | null>(null);
  const [councilAutoConvene, setCouncilAutoConvene] = useState(false);
  // Auto-council: a chat send in a domain with the toggle on routes its
  // question here: seed the Council tab and convene without another click.
  useEffect(() => {
    const onAuto = (e: Event) => {
      const q = (e as CustomEvent<{ prompt?: string }>).detail?.prompt;
      if (!q) return;
      setCouncilSeed(q);
      setCouncilAutoConvene(true);
      setTab("council");
    };
    window.addEventListener("prevail:auto-council", onAuto as EventListener);
    return () => window.removeEventListener("prevail:auto-council", onAuto as EventListener);
  }, []);
  useEffect(() => {
    const onSeed = (e: Event) => {
      const detail = (e as CustomEvent<{ domain?: string; prompt: string }>).detail;
      if (!detail?.prompt) return;
      if (detail.domain) setSelectedDomain(detail.domain);
      setCouncilSeed(detail.prompt);
      setTab("council");
    };
    window.addEventListener("prevail:council-seed", onSeed as EventListener);
    return () => window.removeEventListener("prevail:council-seed", onSeed as EventListener);
  }, []);
  // "Use in chat" on a council (Settings > Council) opens the Council tab,
  // which picks that council up.
  useEffect(() => {
    const onUse = () => setTab("council");
    window.addEventListener(USE_COUNCIL_EVENT, onUse);
    return () => window.removeEventListener(USE_COUNCIL_EVENT, onUse);
  }, []);
  const [vaultError, setVaultError] = useState<string | null>(null);
  // Phone layout: below PHONE_MAX_PX the desktop cockpit is replaced by the
  // PhoneShell (bottom tab bar + one full-width surface, see phoneshell.tsx).
  const phone = useIsPhone();
  // With the keyboard up, size the shell to what is visible so the composer
  // sits on the keyboard and nothing scrolls out from under the header.
  const visibleHeight = useVisualViewportHeight(phone);
  const [sidebarCollapsed, setSidebarCollapsed] = useState<boolean>(
    () => lsGet("prevail.sidebarCollapsed") === "1",
  );
  useEffect(() => {
    lsSet("prevail.sidebarCollapsed", sidebarCollapsed ? "1" : "0");
  }, [sidebarCollapsed]);
  const fwLens = useFrameworkLens();

  const selectedDomainPath = useMemo(() => {
    if (selectedDomain) return domains.find((d) => d.name === selectedDomain)?.path ?? null;
    // General is a first-class domain at data/domains/general on a v4 vault (one
    // whose domains live under data/domains/), else the legacy vault root. Mirrors
    // the engine's generalDir() / paths.rs general_dir().
    if (!vaultPath) return null;
    const v4 = domains.some((d) => d.path.replace(/\\/g, "/").includes("/data/domains/"));
    return v4 ? `${vaultPath.replace(/\/+$/, "")}/data/domains/general` : vaultPath;
  }, [domains, selectedDomain, vaultPath]);

  // Quick switcher (⌘P) - fuzzy finder over all domains + recent
  // threads across all domains. Modal owns its own state when open.
  const [quickSwitcherOpen, setQuickSwitcherOpen] = useState(false);
  const [cmdPaletteOpen, setCmdPaletteOpen] = useState(false);

  // F1: the command palette's item list - actions, navigation to every section,
  // and every domain. Rebuilt when the domains change.
  const iaStore = useEntityStore();
  const iaMissions = useMissions(cmdPaletteOpen ? vaultPath : null);
  useEffect(() => { if (cmdPaletteOpen && vaultPath) void loadEntities(vaultPath); }, [cmdPaletteOpen, vaultPath]);
  const paletteCommands = useMemo<Command[]>(() => {
    const cmds: Command[] = [];
    // Actions.
    cmds.push(
      { id: "act:new-chat", label: "New chat", hint: "⌘K", group: "Actions", icon: MessageSquarePlus, keywords: "conversation ask", run: () => { setSelectedDomain(""); setActiveThreadPath(null); setTab("chat"); } },
      { id: "act:inbox", label: "Open inbox", group: "Actions", icon: Inbox, keywords: "decisions approvals needs you", run: () => openWorkAt("inbox") },
      { id: "act:tasks", label: "Open tasks", group: "Actions", icon: ListChecks, keywords: "tasks todo work board", run: () => openWorkAt("task-list") },
      { id: "act:apps", label: "Open apps", group: "Actions", icon: Plug, keywords: "apps connectors", run: () => openWorkAt("apps") },
      { id: "act:toggle-rail", label: "Toggle domain rail", hint: "⌘B", group: "Actions", icon: ChevronsLeft, keywords: "sidebar hide show", run: () => setSidebarCollapsed((v) => !v) },
      { id: "act:settings", label: "Open settings", hint: "⌘,", group: "Actions", icon: SettingsIcon, keywords: "preferences config", run: () => setTab("settings") },
    );
    // Navigation to every Work + Editor section.
    for (const grp of WORK_NAV) for (const it of grp.items) {
      cmds.push({ id: `nav:w:${it.id}`, label: it.label, hint: "Go to", group: `Go to · ${grp.heading}`, icon: it.icon, run: () => openWorkAt(it.id) });
    }
    for (const grp of EDITOR_NAV) for (const it of grp.items) {
      cmds.push({ id: `nav:e:${it.id}`, label: it.label, hint: "Go to", group: `Go to · ${grp.heading}`, icon: it.icon, run: () => openSettingsAt(it.id) });
    }
    // Every domain.
    for (const d of domains) {
      cmds.push({ id: `dom:${d.name}`, label: titleCase(d.name), hint: "Domain", group: "Domains", icon: Compass, keywords: d.name, run: () => openDomain(d.name) });
    }
    // Entities and Activities: each kind's page, then (as you type) the
    // objects themselves under their kind, each with its icon.
    for (const k of IA_KINDS) {
      cmds.push({ id: `kind:${k.id}`, label: k.label, hint: "Go to", group: `Go to · ${IA_GROUP_LABEL[k.group]}`, icon: k.icon, keywords: `${k.singular} ${IA_GROUP_LABEL[k.group]}`, run: () => openKind(k.id) });
    }
    const objects = (iaStore.list?.entities ?? []).filter((e) => e.kind !== "project" && e.relation !== "reference")
      .sort((a, b) => Number(b.saved) - Number(a.saved) || b.conversations - a.conversations).slice(0, 400);
    for (const e of objects) {
      const k = kindOfId(e.kind);
      if (!k) continue;
      cmds.push({ id: `obj:${e.id}`, label: e.name, hint: k.singular, group: k.label, icon: k.icon, keywords: e.aliases.join(" "), searchOnly: true, run: () => requestEntity({ kind: e.kind, value: e.id.slice(e.id.indexOf("/") + 1) }) });
    }
    for (const m of iaMissions.missions.filter((x) => x.status !== "archived")) {
      cmds.push({ id: `obj:mission/${m.slug}`, label: m.name, hint: "Project", group: "Projects", icon: kindOfId("mission")!.icon, keywords: m.outcome ?? "", searchOnly: true, run: () => openMission(m.slug) });
    }
    return cmds;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [domains, iaStore.list, iaMissions.missions]);

  // Keyboard shortcuts - global. Skip when a text input has focus
  // (so typing ⌘B in the composer doesn't toggle the sidebar).
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (!(e.metaKey || e.ctrlKey)) return;
      const target = e.target as HTMLElement | null;
      const tag = target?.tagName?.toLowerCase() ?? "";
      const editable = tag === "input" || tag === "textarea" || target?.isContentEditable;
      // Allow the global shortcuts that are clearly intentional even
      // when in a field (Cmd+,, Cmd+K, Cmd+P).
      const k = e.key.toLowerCase();
      if (editable && k !== "," && k !== "k" && k !== "p") return;
      switch (k) {
        case "k": // ⌘K - command palette; ⌘⇧K - new chat (no domain)
          e.preventDefault();
          if (e.shiftKey) {
            setSelectedDomain("");
            setActiveThreadPath(null);
            setTab("chat");
          } else {
            setCmdPaletteOpen((v) => !v);
          }
          break;
        case ",": // ⌘, - open settings
          e.preventDefault();
          setTab("settings");
          break;
        case "b": // ⌘B - toggle the domain rail
          e.preventDefault();
          setSidebarCollapsed((v) => !v);
          break;
        case "p": // ⌘P - quick switcher
          e.preventDefault();
          setQuickSwitcherOpen(true);
          break;
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  async function openInFinder(path: string | null) {
    if (!path) return;
    // Use the opener plugin's reveal-in-Finder (entitlement-safe under the
    // notarized build, and it selects the item in Finder). Fall back to the
    // shell-based command if the plugin reveal ever fails.
    try {
      await revealItemInDir(path);
    } catch (e) {
      console.error("revealItemInDir", e);
      try { await invoke("open_in_finder", { path }); } catch (e2) { console.error("open_in_finder", e2); }
    }
  }

  // Re-detectable so saving a provider key (OpenRouter) or starting a local
  // server can refresh the picker without a reload. Returns the fresh list.
  const refreshClis = useCallback(async (): Promise<CliInfo[]> => {
    try {
      const list = await invokeCached<CliInfo[]>("detect_clis", undefined, { force: true });
      setClis(Array.isArray(list) ? list : []);
      setClisDetected(true);
      // Validate every detected provider right away (once per session), so
      // valid / not-valid marks are visible without expanding anything.
      autoVerifyClis(list);
      return list;
    } catch {
      return [];
    }
  }, []);
  useEffect(() => {
    void refreshClis();
  }, [refreshClis]);

  // Re-detect runtimes on demand (the Runtimes "Re-check" button), so repairing
  // a broken install clears its BROKEN/not-installed state without an app restart.
  useEffect(() => {
    const onRescan = () => { void refreshClis(); };
    window.addEventListener("prevail:rescan-clis", onRescan);
    return () => window.removeEventListener("prevail:rescan-clis", onRescan);
  }, [refreshClis]);

  useEffect(() => {
    if (!vaultPath) return;
    // In a browser tab, wait until authenticated - otherwise the scan fires a
    // pre-login invoke that 401s and leaves a stale "unauthorized" error. The
    // webAuthed dep re-runs this once sign-in completes.
    if (isBrowser() && !webAuthed) return;
    let cancelled = false;
    let attempts = 0;
    setDomainsLoaded(false);
    const tryScan = async () => {
      while (!cancelled && attempts < 5) {
        try {
          const d = await invokeCached<Domain[]>("scan_vault", { path: vaultPath }, { force: true });
          if (cancelled) return;
          setDomains(Array.isArray(d) ? d : []);
          setVaultError(null);
          setDomainsLoaded(true);
          void refreshDomainStats(d.map((x) => x.name));
          // Land on no-domain chat by default. User picks a domain
          // from the sidebar to enter its context.
          return;
        } catch (e) {
          attempts++;
          const msg = String(e);
          // Transient macOS EINTR - wait briefly and retry.
          if (msg.includes("os error 4") || msg.toLowerCase().includes("interrupted")) {
            await new Promise((r) => setTimeout(r, 100 * attempts));
            continue;
          }
          if (!cancelled) {
            setVaultError(msg);
            setDomains([]);
          }
          return;
        }
      }
      if (!cancelled) {
        setVaultError("vault scan failed after retries: try toggling vault in Settings");
      }
    };
    tryScan();
    return () => { cancelled = true; };
  }, [vaultPath, webAuthed]);

  // Onboarding auto-open REMOVED. It raced the vault scan (firing while
  // domains were still loading) and popped a modal over an already-populated
  // vault, then never auto-closed. Onboarding is now opt-in only via the
  // explicit "Set up domains" control; it never auto-appears.

  async function pickVault() {
    // The native folder picker (tauri-plugin-dialog) only exists in the
    // desktop runtime; calling it in a browser throws "Cannot read properties
    // of undefined (reading 'invoke')". In the WebUI the browser inherits the
    // desktop's vault automatically (bootstrap_vault), so this path is a
    // fallback - guide the user to the desktop instead of crashing. (B4)
    if (isBrowser()) {
      window.alert(
        "Pick your vault from the Glyph Studio desktop app on this Mac: a browser can't open a native folder picker. The web view then syncs to it automatically.",
      );
      return;
    }
    const dir = await open({ directory: true, multiple: false });
    if (typeof dir === "string") {
      // Picking the vault here is the owner choosing the main vault.
      await invoke("engine_set_config_vault", { path: dir, main: true }).catch(() => {});
      setVaultPath(dir);
      lsSet(LS.vault, dir);
      void invoke("remember_vault", { path: dir }).catch(() => {});
      setSelectedDomain(null);
    }
  }

  if (isBrowser() && pairing) return <PairingScreen />;
  if (isBrowser() && !webAuthed) return <WebLogin onAuthed={() => setWebAuthed(true)} />;
  if (!isBrowser() && (lockSet || vaultEncrypted) && !unlocked) return <LockScreen vault={vaultPath} encrypted={vaultEncrypted} onUnlock={() => setUnlocked(true)} />;
  // A browser client never picks a vault. It either has the Mac's vault or it
  // is still asking for it; a folder picker here would offer to choose a
  // directory on a phone, which is meaningless.
  if (isBrowser() && !vaultPath) {
    return <WebVaultLinking resolving={!webVaultTried} onRetry={() => { setWebVaultTried(false); void webVaultPull.current?.(); }} />;
  }
  if (!vaultPath) return <VaultWizard onPick={pickVault} />;

  // The left Sidebar is shared across every mode (chat, Work, Editor) so the
  // Work/Editor toggle + profile switcher are always present and switching
  // between modes is one click — no "Back to app" needed.
  const sidebarEl = (
    <Sidebar
      collapsed={sidebarCollapsed}
      setCollapsed={setSidebarCollapsed}
      vaultPath={vaultPath}
      domains={domains}
      vaultError={vaultError}
      selectedDomain={selectedDomain}
      setSelectedDomain={(name) => { setSelectedApp(null); setAppView(false); setSelectedDomain(name); }}
      openInFinder={openInFinder}
      tab={tab}
      setTab={setTab}
      onDomainCreated={(d) => {
        setDomains((cur) => [...cur, d].sort((a, b) => a.name.localeCompare(b.name)));
        setSelectedApp(null); setAppView(false);
        setSelectedDomain(d.name);
      }}
      runningDomains={runningDomains}
      finishedDomains={finishedDomainSet}
      domainStats={domainStats}
      railWidth={domainRailWidth}
      onOpenOnboarding={() => { setOnboardDismissed(false); setOnboardOpen(true); }}
      onDomainsChanged={() => void refreshDomains()}
    />
  );

  // PERF: one persistent shell for ALL modes. Editor (settings) and Work used to
  // be separate early-return trees, so every Work<->Editor<->Chat switch
  // unmounted and remounted the whole app (sidebar's ~18 effects, threads, apps,
  // the lazy panels) - the cause of the "mode switch feels slow" report. Now the
  // shell + sidebar stay mounted and only the CENTER region swaps by tab.
  const isMainMode = tab !== "settings" && tab !== "work";
  const editorCenter = (
    <PanelBoundary resetKey={tab}>
    <Suspense fallback={<PanelLoading />}>
      <SettingsPanel
        appearance={appearance}
        vaultPath={vaultPath}
        clis={clis}
        onRefreshClis={refreshClis}
        bunkerEnabled={bunkerEnabled}
        onBunkerChange={applyBunker}
        onSetupDomains={() => { setOnboardDismissed(false); setOnboardOpen(true); }}
        onVaultMoved={(p) => {
          // Settings' vault actions are the owner changing the main vault.
          void invoke("engine_set_config_vault", { path: p, main: true }).catch(() => {});
          setVaultPath(p);
          lsSet(LS.vault, p);
          void invoke("remember_vault", { path: p }).catch(() => {});
          setSelectedDomain(null);
          // Force every panel that listens for domain changes (sidebar, stats,
          // threads, …) to re-scan the NEW vault instead of showing stale data.
          window.dispatchEvent(new Event("prevail:domains-changed"));
        }}
        jumpTo={settingsJump}
        onStartChatWith={(cliId, modelId) => {
          lsSet(LS.defaultChatCli, cliId);
          if (modelId) lsSet(`prevail.model.${cliId}`, modelId);
          setSelectedDomain("");
          setTab("chat");
        }}
      />
    </Suspense>
    </PanelBoundary>
  );
  const workCenter = (
    <PanelBoundary resetKey={tab}>
    <Suspense fallback={<PanelLoading />}>
      <WorkPanel vaultPath={vaultPath} clis={clis} jumpTo={workJump} />
    </Suspense>
    </PanelBoundary>
  );

  // "+" in the threads rail (and the phone Threads sheet): create the thread
  // file immediately so the user gets a renameable entry BEFORE typing the
  // first prompt. Backend accepts empty turns. Scoped to the active app's own
  // thread space when an app is open.
  const newThread = async () => {
    try {
      const path = await invoke<string>("save_thread", {
        vault: vaultPath,
        domain: threadScope || null,
        slug: null,
        title: "Untitled",
        turns: [],
      });
      setActiveThreadPath(path);
      await refreshThreads();
    } catch (e) {
      console.error("create thread stub", e);
      // Fall back to the old behavior on failure so + at
      // least clears the chat for a fresh start.
      setActiveThreadPath(null);
    }
  };

  // The conversation surface (chat / council / arena / retrospect / tools /
  // map), shared by the desktop main column and the phone shell's Chat screen.
  const conversationCenter = (
          <div className="min-h-0 flex-1 overflow-y-auto">
            <PanelBoundary resetKey={tab}>
            <Suspense fallback={<PanelLoading />}>
            {tab === "chat" && (
              <ChatPanel
                // Scope the chat view to its domain: a fresh instance per domain
                // (and per app) so a stream running in one domain can't bleed its
                // session/messages into another's view when you switch. The old
                // domain's stream keeps running in the engine and re-hydrates from
                // its thread when you return.
                key={`chat:${threadScope ?? "general"}`}
                active={tab === "chat"}
                domain={selectedDomain}
                // The space each turn runs in: a domain's context is built by the
                // engine (chatscope.ts); an open app keeps its own prompt.
                scope={onApp && selectedApp ? { kind: "app", id: selectedApp.id } : selectedDomain ? { kind: "domain", slug: selectedDomain } : { kind: "general" }}
                domainPath={selectedDomainPath}
                threadDomain={threadScope}
                isApp={onApp}
                appId={onApp && selectedApp ? selectedApp.id : null}
                appAccount={onApp && selectedApp ? selectedApp.account?.label ?? null : null}
                appRuntime={onApp && selectedApp ? selectedApp.runtime ?? null : null}
                vaultPath={vaultPath}
                clis={clis}
                fwLens={fwLens}
                onSwitchToCouncil={() => setTab("council")}
                activeThreadPath={activeThreadPath}
                chatViewNonce={chatViewNonce}
                onActiveThreadChange={setActiveThreadPath}
                onThreadsChanged={() => void refreshThreads()}
                onStreamStart={markStreamStart}
                onStreamEnd={markStreamEnd}
                domains={domains}
                domainStats={domainStats}
                runningDomains={runningDomains}
                finishedDomains={finishedDomainSet}
                onPickDomain={(name) => setSelectedDomain(name)}
                domainTab={domainTab}
                setDomainTab={setDomainTab}
                phone={phone}
                phoneMic={phone ? <PhoneVoiceBar vaultPath={vaultPath} domain={selectedDomain} /> : undefined}
              />
            )}
            {/* Council STAYS MOUNTED (hidden) on other tabs so a convened council
                keeps streaming and holds its replies/verdict when you navigate to
                chat and back. Lazy-mounted on first visit. */}
            {councilEverVisited && (
              <div className={tab === "council" ? "h-full" : "hidden"}>
                <CouncilPanel
                  domain={selectedDomain}
                  domainPath={selectedDomainPath}
                  threadDomain={threadScope}
                  vaultPath={vaultPath}
                  clis={clis}
                  fwLens={fwLens}
                  activeThreadPath={activeThreadPath}
                  onActiveThreadChange={setActiveThreadPath}
                  onOpenInFinder={() => openInFinder(selectedDomainPath)}
                  onSwitchToChat={() => setTab("chat")}
                  onThreadsChanged={() => void refreshThreads()}
                  seedPrompt={councilSeed}
                  seedAutoConvene={councilAutoConvene}
                  onSeedConsumed={() => { setCouncilSeed(null); setCouncilAutoConvene(false); }}
                  active={tab === "council"}
                  phone={phone}
                />
              </div>
            )}
            {/* Per-domain benchmark, full screen - scoped to whatever domain
                you're in. Remounts (via key) when you switch domains so it
                re-scopes cleanly. STAYS MOUNTED (hidden) on other tabs so an
                in-flight run keeps its live progress when you navigate away
                and back. The global cockpit lives in the configuration page. */}
            {benchEverVisited && (
              <div className={tab === "benchmark" ? "h-full" : "hidden"}>
                <BenchmarkPanel
                  key={selectedDomain || benchScope || "all"}
                  vaultPath={vaultPath}
                  initialDomain={selectedDomain || benchScope}
                />
              </div>
            )}
            </Suspense>
            </PanelBoundary>
          </div>
  );

  // Footer ribbons (demo sandbox / Bunker). On a phone they sit above the tab bar.
  const ribbons = (
    <>
      {/* Desktop only. Three tiny mono labels is a poor use of the ~30px it
          costs on a phone, and every one of them is reachable in Settings. */}
      {!phone && <BunkerRibbon enabled={bunkerEnabled} compact={false} />}
      <DemoRibbon onSwitch={() => openSettingsAt("demo")} />
    </>
  );

  return (
    <div
      className={`relative flex ${phone ? "h-full" : "h-screen"} flex-col overflow-hidden bg-background text-text-primary`}
      style={phone && visibleHeight ? { height: visibleHeight } : undefined}
    >
      {/* O1 (Monday feedback): first-run onboarding tour (dismissible, replayable). */}
      <OnboardingTour />
      {/* C4: first-run encrypt-at-rest prompt (default-ON). Only for a fresh,
          confirmed-unencrypted vault the user hasn't been offered yet. Never in
          the demo sandbox (C6): encrypting throwaway sample data would ask the
          user to save a passcode + recovery code for data they'll discard. */}
      {!isBrowser() && vaultPath && vaultStatusChecked && appMode === "production" && !vaultEncrypted && !encryptPromptClosed && !vaultEncryptOffered() && (
        <VaultEncryptPrompt vaultPath={vaultPath} onClose={() => setEncryptPromptClosed(true)} />
      )}
      {memoryAlert && (
        <div className="fixed left-1/2 top-3 z-[100] flex max-w-xl -translate-x-1/2 items-start gap-2.5 rounded-lg border border-warn/40 bg-warn/10 px-4 py-2.5 shadow-lg backdrop-blur">
          <span className="mt-1 h-2 w-2 shrink-0 rounded-full bg-warn" />
          <div className="min-w-0 flex-1 text-[13px]">
            <div className="font-semibold text-warn">{memoryAlert.kind === "killed" ? "Runaway task stopped to protect your Mac" : "Memory is running high"}</div>
            <div className="text-text-secondary">{memoryAlert.message}</div>
          </div>
          <button onClick={() => setMemoryAlert(null)} title="Dismiss" className="shrink-0 rounded p-0.5 text-text-muted hover:text-text-primary"><X className="h-4 w-4" /></button>
        </div>
      )}
      {bunkerEnabled && !bunkerLocalOk && (
        <div className="flex shrink-0 items-center justify-center gap-2 border-b border-warn/30 bg-warn/10 px-4 py-1.5 text-xs text-warn">
          <ShieldCheck className="h-3.5 w-3.5" />
          <span>Bunker Mode needs a local model provider, but none was detected.</span>
          <a href="https://ollama.com/download" target="_blank" rel="noreferrer" className="font-medium underline">Install Ollama ›</a>
        </div>
      )}
      {/* O1/F6: no usable model - guide the user to set one up rather than letting
          the first chat fail with a raw spawn error. Suppressed when the Bunker
          banner above is already explaining the same absence: two stacked
          banners saying nearly the same thing is a lot of a phone screen, and
          "Set up a model" is the wrong advice when Bunker is what is blocking
          them. Install a local one, or leave Bunker. */}
      {noModelConfigured && !noModelDismissed && !(bunkerEnabled && !bunkerLocalOk) && (
        <div className="flex shrink-0 items-center justify-center gap-2 border-b border-accent-border bg-accent-soft px-4 py-1.5 text-xs text-text-primary">
          <Layers className="h-3.5 w-3.5 text-accent" />
          <span>No AI model is set up yet, so chat can't run.</span>
          <button onClick={() => openSettingsAt("models")} className="font-semibold text-accent underline underline-offset-2 hover:opacity-80">Set up a model ›</button>
          <button onClick={() => setNoModelDismissed(true)} aria-label="Dismiss" className="ml-1 rounded p-0.5 text-text-muted hover:text-text-primary"><X className="h-3.5 w-3.5" /></button>
        </div>
      )}
      {phone && isGlanceView() ? (
        // /?view=glance: the week at a glance on its own (Add to Home Screen).
        <PhoneGlance vaultPath={vaultPath} standalone />
      ) : phone ? (
        <Suspense fallback={<PanelLoading />}>
          <PhoneShell
            vaultPath={vaultPath}
            domains={domains}
            selectedDomain={selectedDomain}
            onOpenDomain={openDomain}
            onDomainCreated={(d) => {
              setDomains((cur) => [...cur, d].sort((a, b) => a.name.localeCompare(b.name)));
              openDomain(d.name);
            }}
            scopeLabel={onApp && selectedApp ? selectedApp.title : null}
            onCloseApp={() => { setSelectedApp(null); setAppView(false); }}
            tab={tab}
            setTab={setTab}
            setDomainTab={setDomainTab}
            clis={clis}
            runningDomains={runningDomains}
            finishedDomains={finishedDomainSet}
            threads={threads}
            activeThreadPath={activeThreadPath}
            onPickThread={(p) => { setActiveThreadPath(p); setChatViewNonce((n) => n + 1); setTab("chat"); }}
            onNewThread={() => void newThread()}
            decisionsCount={decisionsCount}
            onOpenSettingsAt={openSettingsAt}
            settingsJump={settingsJump}
            onOpenWorkAt={openWorkAt}
            workJump={workJump}
            conversation={conversationCenter}
            settings={editorCenter}
            work={workCenter}
            footer={ribbons}
          />
        </Suspense>
      ) : (
      <div className="flex min-h-0 flex-1">
        {sidebarEl}
        {/* Center region swaps by mode; the sidebar above stays mounted. */}
        {!isMainMode ? (tab === "settings" ? editorCenter : workCenter) : (<>
        {!phone && !sidebarCollapsed && (
          <ResizeHandle
            ariaLabel="Resize domain rail"
            onChange={(dx) => setDomainRailWidth((w) => Math.max(180, Math.min(420, w + dx)))}
          />
        )}

        {/* Threads rail - visible on every tab so the domain's conversation
            history stays one click away and the left chrome doesn't vanish
            when you switch to Benchmark. Picking a thread on Benchmark jumps
            back to Chat with that thread open.
            On a phone the rail cannot share the width with the conversation, so
            it is hidden; threads stay reachable from the drawer's domain view. */}
        {!phone && (
          <>
            <ThreadsRail
              threads={threads}
              activePath={activeThreadPath}
              selectedDomain={selectedDomain}
              scopeLabel={appView && selectedApp ? selectedApp.title : null}
              vaultPath={vaultPath}
              onPick={(p) => { setActiveThreadPath(p); setChatViewNonce((n) => n + 1); if (tab === "benchmark") setTab("chat"); }}
              onNew={() => void newThread()}
              onRefresh={() => void refreshThreads()}
              runningThreadPaths={runningThreadPaths}
            />
          </>
        )}

        <main className="flex min-w-0 flex-1 flex-col">
          <div data-tour="nav" className="relative flex shrink-0 items-center gap-1 border-b border-border-subtle bg-background pl-1.5 pr-4">
            {/* DEV-only marker: lets you tell THIS live window apart from a stale
                installed build. Absolutely positioned at the bottom-right corner so
                it never pushes the first icon off the left edge. */}
            {import.meta.env.DEV && (
              <span className="pointer-events-none absolute bottom-0.5 right-1.5 z-10 rounded bg-err px-1 py-0 text-[11px] font-bold tracking-wide text-background opacity-70">DEV</span>
            )}
            {/* Quick visual cue: are we in an APP or a DOMAIN? An icon (no text)
                at the far left, so the two contexts are instantly distinguishable.
                App = plug, domain/general = layers. */}
            <span
              title={onApp ? `App: ${selectedApp?.title ?? ""}` : `Domain: ${titleCase(selectedDomain || "general")}`}
              className={`mr-1 flex h-7 w-7 shrink-0 items-center justify-center rounded-lg ${onApp ? "bg-accent-soft text-accent" : "bg-surface-warm text-text-secondary"}`}
            >
              {onApp ? <Plug className="h-4 w-4" /> : <Layers className="h-4 w-4" />}
            </span>
            {/* Chat + Council sit on the LEFT for BOTH apps and domains, so the
                conversation is always in the same place. The app's / domain's
                OTHER views (Runs / Settings / Domains, or Insights / Preferences)
                live in the right cluster below. */}
            {TABS.map((t) => {
              const Icon = t.icon;
              const active = t.id === "chat"
                ? tab === "chat" && (onApp || domainTab === "chat")
                : tab === t.id;
              return (
                <button
                  key={t.id}
                  onClick={() => {
                    setTab(t.id);
                    // Chat is also the way back from a sub-view (app Runs/Settings,
                    // or domain Insights/Preferences) to the conversation.
                    if (t.id === "chat" && !onApp) setDomainTab("chat");
                  }}
                  className={`my-1.5 flex items-center gap-2 rounded-lg px-3.5 py-1.5 text-sm font-medium transition-colors ${
                    active
                      ? "bg-accent text-background shadow-sm"
                      : "text-text-muted hover:bg-surface-warm hover:text-text-secondary"
                  }`}
                >
                  <Icon className="h-4 w-4" />
                  {t.label}
                </button>
              );
            })}
            <div className="flex-1" />
            {/* Insights / Preferences / actions - available for General too,
                not just domains. They toggle the Chat sub-view (jumping to Chat
                first if you're on Council/Benchmark). The actions menu hides
                "archive" for General (you can't archive your whole workspace),
                keeping just back up / export. */}
            <div className="flex items-center gap-1">
              {/* Collapse the cluster into this chevron for a cleaner top bar;
                  click again to expand the tabs back leftward. */}
              <button
                onClick={toggleNavCollapsed}
                title={navCollapsed ? "Show tabs" : "Hide tabs for a cleaner top bar"}
                className="flex h-6 w-6 items-center justify-center rounded text-text-muted transition-colors hover:bg-surface-warm hover:text-accent"
              >
                {navCollapsed ? <ChevronsLeft className="h-4 w-4" /> : <ChevronsRight className="h-4 w-4" />}
              </button>
              {!navCollapsed && (<>
              {onApp ? (
                // An open app shows ITS OWN controls, independent of the domain it
                // grounds in. Details opens the Apps screen, where connectors,
                // recipes and the browser lane live.
                <>
                  <button
                    onClick={() => window.dispatchEvent(new CustomEvent("prevail:open-settings", { detail: "apps" }))}
                    title="Open Apps: connectors, sync recipes and sites"
                    className="flex items-center gap-1.5 rounded px-2.5 py-1.5 text-[13px] text-text-muted transition-colors hover:bg-surface-warm hover:text-accent"
                  >
                    <Layers className="h-4 w-4" /> Details
                  </button>
                  <button
                    onClick={toggleAppEnabled}
                    disabled={togglingEnabled}
                    title={(selectedApp.enabled ?? true) ? "Disable autonomous sync (stays configured and chattable)" : "Enable autonomous sync"}
                    className={`flex items-center gap-1.5 rounded px-2.5 py-1.5 text-[13px] transition-colors disabled:opacity-50 ${
                      (selectedApp.enabled ?? true)
                        ? "text-text-muted hover:bg-surface-warm hover:text-accent"
                        : "text-warn hover:bg-surface-warm hover:text-warn"
                    }`}
                  >
                    <Power className="h-4 w-4" /> {(selectedApp.enabled ?? true) ? "Enabled" : "Disabled"}
                  </button>
                </>
              ) : (
                // Insights / Usage / Preferences / Apps - available for General
                // too, not just domains. They toggle the Chat sub-view (jumping
                // to Chat first if you're on Council/Benchmark).
                <>
                  {/* Workflows-Kanban: a pill appears only when AI work needs your
                      call; opens the Inbox. */}
                  {decisionsCount > 0 && (
                    <button
                      onClick={() => window.dispatchEvent(new CustomEvent("prevail:open-settings", { detail: "inbox" }))}
                      title={`${decisionsCount} decision${decisionsCount === 1 ? "" : "s"} need you`}
                      className="flex items-center gap-1 whitespace-nowrap rounded px-1.5 py-0.5 text-[11px] text-warn transition-colors hover:bg-surface-warm"
                    >
                      <Inbox className="h-3.5 w-3.5" /> Needs you
                      <span className="inline-flex min-w-[16px] items-center justify-center rounded-full bg-accent px-1 font-mono text-[10px] font-bold text-background">{cap9(decisionsCount)}</span>
                    </button>
                  )}
                  {/* A single Details entry into the unified domain-detail surface,
                      mirroring how the app view now uses one Details entry + its own
                      tab bar. It opens the tabbed shell (Welcome / Ideal State /
                      Journal / Skills / Loops / Work / Insights / Apps / Settings /
                      Chat) rendered by ChatPanel; every former facet button now lives
                      as a tab there. The Work badge (overdue/due) rides along so it
                      stays visible. General is a first-class domain too, so it uses
                      the exact same Details button and tabbed shell. */}
                  <button
                    onClick={() => { setTab("chat"); setDomainTab(tab === "chat" && domainTab !== "chat" ? "chat" : "welcome"); }}
                    title="Details: ideal state, journal, skills, loops, work, insights, apps, and settings"
                    className={`relative flex items-center gap-1.5 rounded px-2.5 py-1.5 text-[13px] transition-colors ${
                      tab === "chat" && domainTab !== "chat"
                        ? "bg-accent text-background shadow-sm"
                        : "text-text-muted hover:bg-surface-warm hover:text-accent"
                    }`}
                  >
                    <Layers className="h-4 w-4" /> Details
                    {(dueAlert.open > 0 || recCount > 0) && (
                      <span className="inline-flex h-[18px] min-w-[18px] items-center justify-center rounded-full bg-ai px-1.5 font-mono text-[10px] font-bold leading-none text-white">{cap9(dueAlert.open + recCount)}</span>
                    )}
                  </button>
                  <button
                    onClick={() => setTab("benchmark")}
                    title="Arena: score models head-to-head on your questions"
                    className={`flex items-center gap-1 rounded whitespace-nowrap px-1.5 py-0.5 text-[11px] transition-colors ${
                      tab === "benchmark" ? "bg-accent text-background shadow-sm" : "text-text-muted hover:bg-surface-warm hover:text-accent"
                    }`}
                  >
                    <Swords className="h-3.5 w-3.5" /> Arena
                  </button>
                  <button
                    onClick={() => openSettingsAt("tools")}
                    title="Toolkit: the skills, tools and frameworks your models can use"
                    className="flex items-center gap-1 whitespace-nowrap rounded px-1.5 py-0.5 text-[11px] text-text-muted transition-colors hover:bg-surface-warm hover:text-accent"
                  >
                    <Blocks className="h-3.5 w-3.5" /> Toolkit
                  </button>
                </>
              )}
              <DomainActionsMenu
                domain={selectedDomain || "general"}
                vaultPath={vaultPath}
                label={selectedDomain ? "Archive" : "Back up"}
                canArchive={!!selectedDomain}
                onArchived={(name) => {
                  if (selectedDomain === name) setSelectedDomain("");
                  void refreshDomains();
                }}
              />
              </>)}
            </div>
          </div>

          {/* App view: a slim, always-visible identity bar above the canvas.
              Full-width chrome (not inside the chat scroll) so ChatPanel's own
              layout is untouched. The rich detail lives in the unified AppDetail
              surface (embedded, so it suppresses its own header), reached via the
              Details tab in the top bar. */}
          {appView && selectedApp && (
            <AppHeaderBar
              app={selectedApp}
              enabled={selectedApp.enabled ?? true}
              onOpenDomain={openDomain}
              onClose={() => { setSelectedApp(null); setAppView(false); }}
            />
          )}
          {conversationCenter}
        </main>
        </>)}
      </div>
      )}
      {!phone && ribbons}
      {/* A7: live bridge/WebUI chips - bottom-left, follow you across the app */}
      <BridgeStatusChips />
      {quickSwitcherOpen && (
        <QuickSwitcher
          vaultPath={vaultPath}
          domains={domains}
          onClose={() => setQuickSwitcherOpen(false)}
          onPickDomain={(name) => {
            setSelectedApp(null); setAppView(false);
            setSelectedDomain(name);
            setActiveThreadPath(null);
            setTab("chat");
            setQuickSwitcherOpen(false);
          }}
          onPickThread={(domain, path) => {
            setSelectedApp(null); setAppView(false);
            setSelectedDomain(domain ?? "");
            setActiveThreadPath(path);
            setTab("chat");
            setQuickSwitcherOpen(false);
          }}
        />
      )}
      {cmdPaletteOpen && (
        <CommandPalette commands={paletteCommands} onClose={() => setCmdPaletteOpen(false)} />
      )}
      {onboardOpen && (
        <OnboardingModal
          vaultPath={vaultPath}
          onClose={() => { setOnboardOpen(false); setOnboardDismissed(true); }}
          onApplied={() => void refreshDomains()}
        />
      )}
      {obImportOpen && (
        <ObsidianImportModal
          vaultPath={vaultPath}
          domains={domains.map((d) => ({ slug: d.name, label: titleCase(d.name) }))}
          onClose={() => setObImportOpen(false)}
          onDone={() => { setObImportOpen(false); window.dispatchEvent(new Event("prevail:apps-changed")); void refreshDomains(); }}
        />
      )}
      {quickCaptureOn && <QuickCapture vaultPath={vaultPath} />}
    </div>
  );
}

// Title-case helper. 'real-estate' → 'Real Estate', 'tax' → 'Tax'.
// Used to render life domain labels in the UI without mutating the
// underlying folder names that drive everything else.

// ─────────────────────────────────────────────────────────────────────
// Vault wizard

// Always-visible "the gateway is live" indicator: external messages can
// reach this app right now. Polls the bridge every 30s; click jumps to the
// Gateway settings.


// One row per live benchmark run, pinned above the Settings strip. The data
// lives in the module-scope registry, so the rows persist (and progress)
// across every navigation; each row can cancel its run.
































































































