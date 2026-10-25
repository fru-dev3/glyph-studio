// Components extracted from App.tsx.
import React, { Fragment, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { VirtualRows } from "./virtualrows";
import { confirm as tauriConfirm, open as openFileDialog } from "@tauri-apps/plugin-dialog";
import { SpineColumn, useSpineCollapsed } from "./sidespine";
import { RowAction } from "./rowaction";
import { WaitingChip } from "./actcard";
import { entitySnapshot } from "./entitystore";
import { useWaitingState, waitingThreadPaths } from "./waiting";
import { Archive, Settings2, ArrowRight, Check, ChevronDown, ChevronRight, Cpu, Download, Folder, Lightbulb, Link2, Loader2, LucideIcon, Mail, MessagesSquare, PenLine, Pencil, Plus, RefreshCw, Search, Shield, Sparkles, Trash2, UserRound, Wrench, X } from "lucide-react";
import { siWhatsapp } from "simple-icons";
import { PrevailLogo } from "./PrevailLogo";
import { ProviderMark } from "./marks";
import { invoke, setWebToken } from "./bridge";
import { INTEGRATION_LABEL, STATUS_TINT } from "./constants";
import { favKeyOf, useFavorites } from "./appfavorites";
import { formatFreshness, scoreColor, titleCase } from "./format";
import { track } from "./telemetry";
import { Toggle } from "./ui";

// T18: map a DaemonCard display name to the telemetry enum vocabulary. Off-list
// names are skipped (no event) so nothing novel leaks. Inert until keys exist.
const TELEMETRY_DAEMONS: Record<string, string> = {
  "Distill": "distill", "Reminders": "reminders", "Task Gen": "taskgen", "Skill Gen": "skillgen",
};
import { bytesHuman, compactNum, fmtCost, formatAuditedAt } from "./helpers";
import { LS, PREF, cheapModel, getPref, lsGet, lsSet, setPref } from "./storage";
import { Markdown } from "./Markdown";
import { ErrorLine } from "./errorline";
import { InsightsDisclosure } from "./widgets";
import { AppRowLogo } from "./panels3";
import type { AlignmentReport, BackupResult, ContextScore, DaemonStatus, Domain, DomainTask, EngineApp, PreambleOption, SkillEntry, SurfaceResult, TabId, ThreadMeta, UsageBucket } from "./types";

export function QuickSwitcher({
  vaultPath,
  domains,
  onClose,
  onPickDomain,
  onPickThread,
}: {
  vaultPath: string;
  domains: Domain[];
  onClose: () => void;
  onPickDomain: (name: string) => void;
  onPickThread: (domain: string | null, path: string) => void;
}) {
  const [query, setQuery] = useState("");
  const [allThreads, setAllThreads] = useState<Array<{ domain: string | null; meta: ThreadMeta }>>([]);
  const [cursor, setCursor] = useState(0);
  const inputRef = useRef<HTMLInputElement>(null);
  const listRef = useRef<HTMLDivElement>(null);

  // Load every domain's threads once on mount. Vault-root threads
  // (no-domain) are loaded with domain=null.
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const collected: Array<{ domain: string | null; meta: ThreadMeta }> = [];
      const tasks: Promise<void>[] = [];
      const fetchOne = async (name: string | null) => {
        try {
          const rows = await invoke<ThreadMeta[]>("list_threads", { vault: vaultPath, domain: name });
          for (const r of rows) collected.push({ domain: name, meta: r });
        } catch { /* ignore: empty dir is fine */ }
      };
      tasks.push(fetchOne(null));
      for (const d of domains) tasks.push(fetchOne(d.name));
      await Promise.all(tasks);
      if (cancelled) return;
      collected.sort((a, b) => b.meta.updated - a.meta.updated);
      setAllThreads(collected);
    })();
    return () => { cancelled = true; };
  }, [vaultPath, domains]);

  useEffect(() => { inputRef.current?.focus(); }, []);

  // Combined filtered list. Domains first, then threads. Each item
  // gets a stable id so cursor highlight survives filter changes.
  type Item =
    | { kind: "domain"; id: string; label: string; sub: string }
    | { kind: "thread"; id: string; label: string; sub: string; domain: string | null; path: string };
  const items: Item[] = useMemo(() => {
    const q = query.trim().toLowerCase();
    const matches = (s: string) => !q || s.toLowerCase().includes(q);
    const out: Item[] = [];
    for (const d of domains) {
      const label = titleCase(d.name);
      const sub = d.state_preview ? d.state_preview.slice(0, 80).replace(/\n/g, " ") : "domain";
      if (matches(label) || matches(d.name) || matches(sub)) {
        out.push({ kind: "domain", id: `d:${d.name}`, label, sub });
      }
    }
    for (const t of allThreads) {
      const label = t.meta.title || t.meta.slug;
      const where = t.domain ? titleCase(t.domain) : "no domain";
      const sub = `${where} · ${t.meta.turn_count} turns`;
      if (matches(label) || matches(t.meta.preview) || matches(where)) {
        out.push({ kind: "thread", id: `t:${t.meta.path}`, label, sub, domain: t.domain, path: t.meta.path });
      }
    }
    return out;
  }, [query, domains, allThreads]);

  useEffect(() => { setCursor(0); }, [query]);
  useEffect(() => {
    // Scroll selected into view.
    const el = listRef.current?.querySelector<HTMLElement>(`[data-idx="${cursor}"]`);
    el?.scrollIntoView({ block: "nearest" });
  }, [cursor]);

  function pick(it: Item) {
    if (it.kind === "domain") onPickDomain(it.id.slice(2));
    else onPickThread(it.domain, it.path);
  }

  return (
    <div
      className="fixed inset-0 z-50 flex items-start justify-center bg-background/70 backdrop-blur-sm"
      onClick={(e) => { if (e.target === e.currentTarget) onClose(); }}
      onKeyDown={(e) => {
        if (e.key === "Escape") { e.preventDefault(); onClose(); }
        else if (e.key === "ArrowDown") { e.preventDefault(); setCursor((c) => Math.min(items.length - 1, c + 1)); }
        else if (e.key === "ArrowUp") { e.preventDefault(); setCursor((c) => Math.max(0, c - 1)); }
        else if (e.key === "Enter") { e.preventDefault(); const it = items[cursor]; if (it) pick(it); }
      }}
    >
      <div className="mt-24 w-[560px] max-w-[90vw] overflow-hidden rounded-2xl border border-border bg-surface shadow-2xl">
        <div className="flex items-center gap-2 border-b border-border-subtle px-4 py-2.5">
          <span className="text-text-muted">⌕</span>
          <input
            ref={inputRef}
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="Jump to a domain or thread…"
            className="w-full bg-transparent text-sm text-text-primary placeholder:text-text-muted focus:outline-none"
          />
          <span className="font-mono text-[12px] text-text-muted">⌘P</span>
        </div>
        <div ref={listRef} className="max-h-[60vh] overflow-y-auto py-1">
          {items.length === 0 && (
            <div className="px-4 py-6 text-center text-sm text-text-muted">
              {allThreads.length === 0 && domains.length === 0 ? "loading…" : "no matches"}
            </div>
          )}
          {items.map((it, i) => {
            const active = i === cursor;
            return (
              <button
                key={it.id}
                data-idx={i}
                onClick={() => pick(it)}
                onMouseEnter={() => setCursor(i)}
                className={`flex w-full items-center gap-3 px-4 py-2 text-left transition-colors ${
                  active ? "bg-accent-soft" : "hover:bg-surface-warm"
                }`}
              >
                <span className={`flex h-7 w-7 shrink-0 items-center justify-center rounded-md font-mono text-[12px] ${
                  it.kind === "domain"
                    ? "bg-accent-soft text-accent"
                    : "bg-surface-warm text-text-secondary"
                }`}>
                  {it.kind === "domain" ? "◆" : "▶"}
                </span>
                <div className="min-w-0 flex-1">
                  <div className={`truncate text-sm font-semibold ${active ? "text-accent" : "text-text-primary"}`}>
                    {it.label}
                  </div>
                  <div className="truncate text-[12px] text-text-muted">{it.sub}</div>
                </div>
                <span className="font-mono text-[12px] text-text-muted">
                  {it.kind}
                </span>
              </button>
            );
          })}
        </div>
        <div className="flex items-center justify-between border-t border-border-subtle px-4 py-1.5 text-[12px] text-text-muted">
          <span>↑↓ navigate · ↵ open · ⎋ close</span>
          <span>{items.length} {items.length === 1 ? "result" : "results"}</span>
        </div>
      </div>
    </div>
  );
}

export function LockScreen({ vault, encrypted, onUnlock }: { vault: string | null; encrypted: boolean; onUnlock: () => void }) {
  const [pass, setPass] = useState("");
  const [err, setErr] = useState("");
  const [busy, setBusy] = useState(false);
  // "passcode" is the normal unlock; "recovery" is the forgot-passcode escape,
  // offered only for an encrypted vault (the recovery code unwraps the DEK).
  const [mode, setMode] = useState<"passcode" | "recovery">("passcode");
  const [recoveryCode, setRecoveryCode] = useState("");
  const [newPass, setNewPass] = useState("");
  const [confirmPass, setConfirmPass] = useState("");
  // Touch ID is offered only for the plaintext app lock - it authenticates the
  // user but doesn't release an encryption key, so an encrypted vault still
  // needs the passcode to derive the DEK.
  const touchIdOn = !encrypted && lsGet(PREF.touchIdLock) === "1";
  async function tryTouchId() {
    setErr("");
    try {
      const ok = await invoke<boolean>("engine_biometric_authenticate", { reason: "unlock Glyph Studio" });
      if (ok) onUnlock();
      else setErr("Touch ID didn't match.");
    } catch (e) { setErr(`Touch ID unavailable: ${String(e)}`); }
  }
  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setErr("");
    try {
      const r = encrypted
        ? await invoke<{ ok: boolean }>("engine_vault_unlock", { vault, passcode: pass })
        : await invoke<{ ok: boolean }>("engine_lock_verify", { passcode: pass });
      if (r.ok) onUnlock();
      else setErr("Incorrect passcode.");
    } catch (e2) {
      setErr(`Could not verify: ${String(e2)}`);
    } finally {
      setBusy(false);
    }
  }
  async function submitRecovery(e: React.FormEvent) {
    e.preventDefault();
    if (newPass.length < 8) { setErr("Your new passcode must be at least 8 characters."); return; }
    if (newPass !== confirmPass) { setErr("The new passcodes do not match."); return; }
    setBusy(true);
    setErr("");
    try {
      const r = await invoke<{ ok: boolean; error?: string }>("engine_vault_recover", {
        vault,
        recoveryCode: recoveryCode.trim(),
        newPasscode: newPass,
      });
      if (r.ok) onUnlock();
      else setErr(r.error === "wrong recovery code" ? "That recovery code is not correct." : (r.error ?? "Could not recover the vault."));
    } catch (e2) {
      setErr(`Could not recover: ${String(e2)}`);
    } finally {
      setBusy(false);
    }
  }
  const inputCls = "rounded-lg border border-border bg-surface px-3 py-2 text-sm focus:border-accent-border focus:outline-none";
  return (
    <div className="flex h-screen flex-col items-center justify-center bg-background text-text-primary">
      <PrevailLogo size={64} src="/logo-512.png" />
      <h1 className="mt-5 font-display text-2xl font-semibold">Locked</h1>
      {mode === "passcode" ? (
        <>
          <p className="mt-1 text-sm text-text-muted">
            {encrypted ? "Enter your passcode to unlock your encrypted vault." : "Enter your passcode to open Glyph Studio."}
          </p>
          <form onSubmit={submit} className="mt-6 flex w-72 flex-col gap-3">
            <input
              type="password"
              autoFocus
              value={pass}
              onChange={(e) => setPass(e.target.value)}
              placeholder="Passcode"
              className={inputCls}
            />
            {err && <div className="text-xs text-err">{err}</div>}
            <button
              type="submit"
              disabled={busy || !pass}
              className="inline-flex items-center justify-center gap-2 rounded-lg bg-accent px-3 py-2 text-sm font-semibold text-background hover:opacity-90 disabled:opacity-50"
            >
              {busy ? <Loader2 className="h-4 w-4 animate-spin" /> : null}
              Unlock
            </button>
            {touchIdOn && (
              <button
                type="button"
                onClick={tryTouchId}
                className="inline-flex items-center justify-center gap-2 rounded-lg border border-border bg-surface px-3 py-2 text-sm hover:bg-surface-warm"
              >
                <Shield className="h-4 w-4" /> Use Touch ID
              </button>
            )}
            {encrypted && (
              <button
                type="button"
                onClick={() => { setErr(""); setMode("recovery"); }}
                className="mt-1 text-xs text-text-muted underline decoration-dotted hover:text-text-secondary"
              >
                Forgot your passcode? Use your recovery code.
              </button>
            )}
          </form>
        </>
      ) : (
        <>
          <p className="mt-1 max-w-sm text-center text-sm text-text-muted">
            Enter the one-time recovery code you saved when you encrypted this vault, then choose a new passcode.
          </p>
          <form onSubmit={submitRecovery} className="mt-6 flex w-80 flex-col gap-3">
            <input
              type="text"
              autoFocus
              autoCapitalize="characters"
              spellCheck={false}
              value={recoveryCode}
              onChange={(e) => setRecoveryCode(e.target.value)}
              placeholder="Recovery code (XXXXX-XXXXX-XXXXX-XXXXX)"
              className={`${inputCls}`}
            />
            <input
              type="password"
              value={newPass}
              onChange={(e) => setNewPass(e.target.value)}
              placeholder="New passcode (min 8 characters)"
              className={inputCls}
            />
            <input
              type="password"
              value={confirmPass}
              onChange={(e) => setConfirmPass(e.target.value)}
              placeholder="Confirm new passcode"
              className={inputCls}
            />
            {err && <div className="text-xs text-err">{err}</div>}
            <button
              type="submit"
              disabled={busy || !recoveryCode || !newPass || !confirmPass}
              className="inline-flex items-center justify-center gap-2 rounded-lg bg-accent px-3 py-2 text-sm font-semibold text-background hover:opacity-90 disabled:opacity-50"
            >
              {busy ? <Loader2 className="h-4 w-4 animate-spin" /> : null}
              Reset passcode and unlock
            </button>
            <button
              type="button"
              onClick={() => { setErr(""); setMode("passcode"); }}
              className="text-xs text-text-muted underline decoration-dotted hover:text-text-secondary"
            >
              Back to passcode
            </button>
          </form>
        </>
      )}
    </div>
  );
}

// The browser client has no vault of its own: the vault lives on the Mac and
// this is a window onto it. While we ask the Mac which vault it is using, and
// if that ever fails, the phone gets this instead of the desktop's folder
// picker, which would be asking someone to choose a directory on a phone.
export function WebVaultLinking({ resolving, onRetry }: { resolving: boolean; onRetry: () => void }) {
  return (
    <div className="flex h-full flex-col items-center justify-center bg-background px-6 text-center">
      <PrevailLogo size={64} src="/logo-512.png" animated={resolving} />
      {resolving ? (
        <>
          <h1 className="mt-5 font-display text-2xl font-semibold tracking-tight">Connecting to your Mac</h1>
          <p className="mt-1 text-sm text-text-muted">Loading your domains and agents.</p>
        </>
      ) : (
        <>
          <h1 className="mt-5 font-display text-2xl font-semibold tracking-tight">Your Mac has no vault yet</h1>
          <p className="mt-1 max-w-xs text-sm text-text-muted">
            Finish setting Glyph Studio up on the Mac, then come back. Nothing needs to be set up on this phone.
          </p>
          <button onClick={onRetry} className="mt-5 rounded-md bg-accent px-4 py-2 text-sm font-semibold text-on-accent">
            Try again
          </button>
        </>
      )}
    </div>
  );
}

// Shown for the moment it takes a scanned QR code to become a session. It
// exists so the phone never flashes a password form on its way in.
export function PairingScreen() {
  return (
    <div className="flex h-screen flex-col items-center justify-center bg-background px-6">
      <PrevailLogo size={64} src="/logo-512.png" animated />
      <h1 className="mt-5 font-display text-2xl font-semibold tracking-tight">Pairing your phone</h1>
      <p className="mt-1 text-sm text-text-muted">Signing in from the code you scanned.</p>
    </div>
  );
}

export function WebLogin({ onAuthed }: { onAuthed: () => void }) {
  const [user, setUser] = useState("");
  const [pass, setPass] = useState("");
  const [err, setErr] = useState("");
  const [busy, setBusy] = useState(false);
  async function login() {
    setBusy(true); setErr("");
    try {
      const res = await fetch("/api/login", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ user, pass }) });
      if (!res.ok) { setErr("Invalid username or password"); return; }
      const j = (await res.json()) as { token?: string };
      if (!j.token) { setErr("Login failed"); return; }
      setWebToken(j.token);
      onAuthed();
    } catch (e) { setErr(String(e)); } finally { setBusy(false); }
  }
  return (
    <div className="flex h-screen flex-col items-center justify-center bg-background px-6">
      <PrevailLogo size={64} src="/logo-512.png" animated={false} />
      <h1 className="mt-5 font-display text-2xl font-semibold tracking-tight">Glyph Studio Web</h1>
      <p className="mt-1 text-sm text-text-muted">Sign in to your remote agent.</p>
      <div className="mt-6 w-full max-w-xs space-y-2">
        <input value={user} onChange={(e) => setUser(e.target.value)} placeholder="Username" className="w-full rounded-md border border-border bg-surface px-3 py-2 text-sm focus:border-accent-border focus:outline-none" />
        <input type="password" value={pass} onChange={(e) => setPass(e.target.value)} onKeyDown={(e) => { if (e.key === "Enter") void login(); }} placeholder="Password" className="w-full rounded-md border border-border bg-surface px-3 py-2 text-sm focus:border-accent-border focus:outline-none" />
        <button onClick={login} disabled={busy || !user || !pass} className="w-full rounded-md bg-accent py-2 text-sm font-medium text-background hover:opacity-90 disabled:opacity-50">{busy ? "Signing in…" : "Sign in"}</button>
        {err && <div className="rounded-md border border-warn/40 bg-warn/10 px-3 py-2 text-xs text-warn">{err}</div>}
        <p className="pt-2 text-center text-xs text-text-muted">
          Rather not type this on a phone? On your Mac open <span className="font-medium text-text-secondary">Settings, Phone</span> and scan the QR code.
        </p>
      </div>
    </div>
  );
}

export function SidebarGatewayLive({ collapsed }: { collapsed: boolean }) {
  const [live, setLive] = useState(false);
  const [webLive, setWebLive] = useState(false);
  useEffect(() => {
    let alive = true;
    const check = async () => {
      try {
        const t = await invoke<{ running: boolean }>("telegram_bridge_status");
        if (alive) setLive(!!t.running);
      } catch { if (alive) setLive(false); }
      try {
        const w = await invoke<{ running: boolean }>("webui_status");
        if (alive) setWebLive(!!w.running);
      } catch { if (alive) setWebLive(false); }
    };
    void check();
    const id = window.setInterval(() => void check(), 30_000);
    return () => { alive = false; window.clearInterval(id); };
  }, []);
  if (!live && !webLive) return null;
  const goGateway = () => window.dispatchEvent(new CustomEvent("prevail:open-settings", { detail: live ? "gateway" : "remote" }));
  const label = [live ? "Telegram" : null, webLive ? "WebUI" : null].filter(Boolean).join(" + ");
  const dot = (
    <span className="relative flex h-2 w-2 shrink-0">
      <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-ai opacity-60" />
      <span className="relative inline-flex h-2 w-2 rounded-full bg-ai" />
    </span>
  );
  if (collapsed) {
    return (
      <button onClick={goGateway} title={`LIVE: ${label} can reach this app externally. Click for settings.`} className="flex w-full justify-center border-t border-border-subtle px-2 py-2">
        {dot}
      </button>
    );
  }
  return (
    <button onClick={goGateway} className="flex w-full items-center gap-2 border-t border-border-subtle px-3 py-2 text-left hover:bg-surface-warm" title="External messages can reach this app right now. Click for Gateway settings.">
      {dot}
      <span className="flex-1 truncate text-[12px] tracking-wide text-ai">Live · {label}</span>
      <MessagesSquare className="h-3 w-3 shrink-0 text-text-muted" />
    </button>
  );
}

export function SidebarMcpLive({ collapsed, setTab }: { collapsed: boolean; setTab: (t: TabId) => void }) {
  const [live, setLive] = useState(false);
  useEffect(() => {
    let alive = true;
    const check = async () => {
      // Respect the in-app MCP toggle: if the user turned it off, don't show "Live"
      // just because the CLI can still handshake an MCP server out of process.
      if (lsGet(LS.mcpEnabled) !== "1") { if (alive) setLive(false); return; }
      try {
        // "Live" means the CLI can actually handshake an MCP server right now.
        const h = await invoke<{ ok: boolean }>("mcp_test_handshake", { vault: "" });
        if (alive) setLive(!!h.ok);
      } catch { if (alive) setLive(false); }
    };
    void check();
    const id = window.setInterval(() => void check(), 30_000);
    return () => { alive = false; window.clearInterval(id); };
  }, []);
  if (!live) return null;
  const goMcp = () => {
    setTab("settings");
    window.setTimeout(() => window.dispatchEvent(new CustomEvent("prevail:settings-section", { detail: "mcp" })), 50);
  };
  const dot = (
    <span className="relative flex h-2 w-2 shrink-0">
      <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-accent opacity-60" />
      <span className="relative inline-flex h-2 w-2 rounded-full bg-accent" />
    </span>
  );
  if (collapsed) {
    return (
      <button onClick={goMcp} title="MCP server is live. Click for settings." className="flex w-full justify-center border-t border-border-subtle px-2 py-2">
        {dot}
      </button>
    );
  }
  return (
    <button onClick={goMcp} className="flex w-full items-center gap-2 border-t border-border-subtle px-3 py-2 text-left hover:bg-surface-warm" title="MCP server live. Click for MCP settings.">
      {dot}
      <span className="flex-1 truncate text-[12px] tracking-wide text-accent">Live · MCP</span>
      <Wrench className="h-3 w-3 shrink-0 text-text-muted" />
    </button>
  );
}

// An entity-tagged thread's chip: the entity's name when the store knows it,
// else its slug made readable.
function entityLabel(id: string): string {
  const known = entitySnapshot().byId.get(id);
  if (known) return known.name;
  return titleCase((id.split("/")[1] ?? id).replace(/[-_]+/g, " "));
}

export function ThreadsRail({
  threads,
  activePath,
  selectedDomain,
  scopeLabel,
  vaultPath,
  onPick,
  onNew,
  onRefresh,
  runningThreadPaths,
}: {
  threads: ThreadMeta[];
  activePath: string | null;
  selectedDomain: string | null;
  // When set (e.g. an open app's title), the rail header labels the scope with
  // this instead of the domain - the conversations belong to the app, not a
  // domain.
  scopeLabel?: string | null;
  vaultPath: string;
  onPick: (path: string) => void;
  onNew: () => void;
  onRefresh: () => void;
  runningThreadPaths: Set<string>;
}) {
  // Threads held on the user (an approval waiting in them). Clears on its own
  // when the shared waiting store refreshes.
  const { waiting, acts } = useWaitingState(vaultPath);
  const waitingPaths = useMemo(() => waitingThreadPaths(waiting.items, acts, threads), [waiting, acts, threads]);
  // Collapse state persisted across launches.
  const [collapsed, toggleCollapsed] = useSpineCollapsed("prevail.threads.spine");
  const [renaming, setRenaming] = useState<string | null>(null);
  const [threadFilter, setThreadFilter] = useState("");
  const filteredThreads = useMemo(() => {
    const q = threadFilter.trim().toLowerCase();
    if (!q) return threads;
    return threads.filter((t) =>
      t.title.toLowerCase().includes(q) ||
      t.preview.toLowerCase().includes(q));
  }, [threads, threadFilter]);
  const [renameInput, setRenameInput] = useState("");
  async function applyRename(path: string) {
    if (!renameInput.trim()) { setRenaming(null); return; }
    try {
      await invoke("rename_thread", { path, newTitle: renameInput.trim() });
      onRefresh();
    } catch (e) { console.error("rename_thread", e); }
    setRenaming(null);
  }
  async function deleteThread(path: string) {
    try {
      await invoke("delete_thread", { path });
      onRefresh();
    } catch (e) { console.error("delete_thread", e); }
  }
  function fmtRelative(secs: number): string {
    const delta = Date.now() / 1000 - secs;
    if (delta < 60) return "just now";
    if (delta < 3600) return `${Math.floor(delta / 60)}m ago`;
    if (delta < 86400) return `${Math.floor(delta / 3600)}h ago`;
    if (delta < 86400 * 7) return `${Math.floor(delta / 86400)}d ago`;
    return new Date(secs * 1000).toLocaleDateString();
  }
  return (
    <SpineColumn collapsed={collapsed} onToggle={toggleCollapsed} testId="threads-list" label="threads"
      title={`Threads, ${scopeLabel ?? (selectedDomain ? titleCase(selectedDomain) : "General")}`}
      actions={
        <button onClick={onNew} title="New thread" aria-label="New thread"
          className="rounded-md p-1.5 text-text-muted transition-colors hover:bg-surface-warm hover:text-accent">
          <Plus className="h-4 w-4" />
        </button>
      }
      toolbar={threads.length > 0 ? (
          <div className="relative">
            <Search className="pointer-events-none absolute left-2.5 top-1/2 h-4 w-4 -translate-y-1/2 text-text-muted" aria-hidden />
            <input
              value={threadFilter}
              onChange={(e) => setThreadFilter(e.target.value)}
              placeholder="Search threads" aria-label="Search threads"
              className="h-9 w-full rounded-lg border border-border bg-background pl-8 pr-7 text-[14px] text-text-primary placeholder:text-text-muted focus:border-accent-border focus:outline-none"
            />
            {threadFilter && (
              <button
                onClick={() => setThreadFilter("")}
                className="absolute right-2 top-1/2 -translate-y-1/2 text-[14px] text-text-muted hover:text-warn" aria-label="Clear search"
                title="Clear filter"
              >×</button>
            )}
          </div>
      ) : undefined}>
      <div className="px-2 py-2">
        {threads.length === 0 && (
          <div className="px-2 py-3 text-xs text-text-muted">
            No threads yet. Press + to start one.
          </div>
        )}
        {threads.length > 0 && filteredThreads.length === 0 && (
          <div className="px-2 py-3 text-xs text-text-muted">
            Nothing matches {threadFilter}
          </div>
        )}
        <ul className="space-y-0.5">
          <VirtualRows items={filteredThreads} estimate={52} gap={2} getKey={(t) => t.path} render={(t) => {
            const active = t.path === activePath;
            const isRenaming = renaming === t.path;
            return (
              <li key={t.path} className="group">
                <div
                  className={`relative rounded-md px-2 py-1.5 transition-colors ${
                    active ? "bg-surface-strong" : "hover:bg-surface-warm"
                  }`}
                >
                  {isRenaming ? (
                    <input
                      autoFocus
                      value={renameInput}
                      onChange={(e) => setRenameInput(e.target.value)}
                      onKeyDown={(e) => {
                        if (e.key === "Enter") applyRename(t.path);
                        if (e.key === "Escape") setRenaming(null);
                      }}
                      onBlur={() => applyRename(t.path)}
                      className="w-full rounded border border-accent-border bg-background px-1 py-0.5 text-sm focus:outline-none"
                    />
                  ) : (
                    <button
                      onClick={() => onPick(t.path)}
                      onDoubleClick={() => { setRenameInput(t.title); setRenaming(t.path); }}
                      className="block w-full text-left"
                      title="double-click to rename"
                    >
                      <div className="flex items-center gap-1.5">
                        {t.cli && (
                          <span className="shrink-0" title={`Last model: ${t.model || t.cli}`}>
                            <ProviderMark vendor={t.cli} size={14} />
                          </span>
                        )}
                        <span className={`truncate text-sm ${active ? "font-medium text-text-primary" : "text-text-secondary"}`}>
                          {t.title}
                        </span>
                        {t.entity && (
                          <span data-testid="thread-entity-chip" title={`A conversation about ${entityLabel(t.entity)}`}
                            className="ml-auto inline-flex max-w-[45%] shrink-0 items-center gap-1 truncate rounded-full bg-accent-soft px-1.5 text-[12px] text-accent">
                            <UserRound className="h-2.5 w-2.5 shrink-0" /><span className="truncate">{entityLabel(t.entity)}</span>
                          </span>
                        )}
                        {t.linked_from && (
                          <span data-testid="thread-linked" className="ml-auto inline-flex shrink-0 items-center gap-0.5 text-[12px] text-text-muted" title={`Lives in ${titleCase(t.linked_from)} and is filed here. Same conversation, not a copy.`}>
                            <Link2 className="h-2.5 w-2.5" />{t.filed_as === "also" ? "Also filed here" : `from ${titleCase(t.linked_from)}`}
                          </span>
                        )}
                      </div>
                      <div className="mt-0.5 flex items-center gap-1.5 text-[12px] text-text-muted">
                        {runningThreadPaths.has(t.path) ? (
                          <span className="inline-flex items-center gap-1 rounded-full bg-accent-soft px-1.5 py-0 text-[12px] text-accent">
                            <span className="pulse-soft inline-block h-1 w-1 rounded-full bg-accent" />
                            writing
                          </span>
                        ) : waitingPaths.has(t.path) ? (
                          <WaitingChip />
                        ) : (
                          <>
                            <span>{t.turn_count} turns</span>
                            <span>·</span>
                            <span>{fmtRelative(t.updated)}</span>
                          </>
                        )}
                      </div>
                      {/* Only show the preview when it adds information, for a
                          fresh thread the title IS the first prompt, so showing
                          the preview too just repeats it. */}
                      {t.preview && t.preview.trim().toLowerCase() !== t.title.trim().toLowerCase() && (
                        <div className="mt-0.5 line-clamp-1 text-[12px] text-text-muted">
                          {t.preview}
                        </div>
                      )}
                    </button>
                  )}
                  {!isRenaming && (
                    <div className="absolute right-1 top-1 flex gap-0.5 rounded-md bg-surface/90 opacity-0 transition-opacity focus-within:opacity-100 group-hover:opacity-100">
                      <RowAction icon={PenLine} label="Rename thread" onClick={() => { setRenameInput(t.title); setRenaming(t.path); }} />
                      <RowAction icon={Trash2} label="Delete thread" onClick={async () => {
                        const ok = await tauriConfirm(`Delete "${t.title}"?`, { title: "Delete thread", kind: "warning" });
                        if (ok) await deleteThread(t.path);
                      }} />
                    </div>
                  )}
                </div>
              </li>
            );
          }} />
        </ul>
      </div>
    </SpineColumn>
  );
}

export function PreamblePicker({
  glyph,
  label,
  options,
  selectedId,
  onSelect,
}: {
  glyph: string;
  label: string;
  options: readonly { id: string; label: string; blurb: string }[];
  selectedId: string;
  onSelect: (id: string) => void;
}) {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    const onDoc = (e: MouseEvent) => { if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false); };
    document.addEventListener("mousedown", onDoc);
    return () => document.removeEventListener("mousedown", onDoc);
  }, [open]);
  const active = options.find((o) => o.id === selectedId);
  const on = selectedId !== "none";
  return (
    <div ref={ref} className="relative inline-flex">
      <button
        onClick={() => setOpen((v) => !v)}
        title={`${label}: ${active?.blurb ?? "off"}`}
        className={`inline-flex items-center gap-1.5 rounded-md border px-2 py-1 text-[12px] transition-colors ${
          on || open
            ? "border-accent-border bg-accent-soft text-accent"
            : "border-border bg-surface text-text-muted hover:bg-surface-warm hover:text-text-secondary"
        }`}
      >
        <span>{glyph}</span>
        {on ? (
          <span>
            <span className="opacity-60">{label}:</span> <span>{active?.label}</span>
          </span>
        ) : (
          <span>{label}</span>
        )}
        <ChevronDown className="h-3 w-3 opacity-60" />
      </button>
      {open && (
        <div className="absolute bottom-full left-0 z-50 mb-2 max-h-[60vh] w-80 overflow-y-auto rounded-xl border border-border bg-surface p-1.5 shadow-xl">
          <div className="px-2.5 py-1.5 text-[12px] font-bold text-text-muted">
            <span className="text-accent">{glyph}</span> {label}
          </div>
          {options.map((o) => {
            const sel = o.id === selectedId;
            return (
              <button
                key={o.id}
                onClick={() => { onSelect(o.id); setOpen(false); }}
                className={`flex w-full items-start gap-2.5 rounded-lg px-2.5 py-2 text-left transition-colors ${sel ? "bg-accent-soft" : "hover:bg-surface-warm"}`}
              >
                <span className="min-w-0 flex-1">
                  <span className="flex items-center gap-2">
                    <span className={`font-mono text-sm font-semibold ${sel ? "text-accent" : "text-text-primary"}`}>{o.label}</span>
                    {sel && <Check className="ml-auto h-3.5 w-3.5 shrink-0 text-accent" strokeWidth={3} />}
                  </span>
                  <span className="mt-0.5 block text-[12px] leading-snug text-text-secondary">{o.blurb}</span>
                </span>
              </button>
            );
          })}
        </div>
      )}
    </div>
  );
}

export function TasksPanel({ vaultPath, domain, nonce }: { vaultPath: string; domain: string; nonce: number }) {
  const [tasks, setTasks] = useState<DomainTask[]>([]);
  const [adding, setAdding] = useState("");
  useEffect(() => {
    invoke<DomainTask[]>("tasks_read", { vault: vaultPath, domain }).then((v) => setTasks(Array.isArray(v) ? v : [])).catch(() => {});
  }, [vaultPath, domain, nonce]);
  async function persist(next: DomainTask[]) {
    setTasks(Array.isArray(next) ? next : []);
    try {
      await invoke("tasks_set", { vault: vaultPath, domain, tasks: next });
      window.dispatchEvent(new Event("prevail:tasks-changed"));
    } catch (e) { console.error("tasks_set", e); }
  }
  if (tasks.length === 0 && !adding) {
    return (
      <div className="mb-4">
        <button onClick={() => setAdding(" ")} data-testid="add-goal-task" className="inline-flex items-center gap-1 text-[13px] text-text-muted hover:text-accent"><Plus className="h-3.5 w-3.5" aria-hidden />Add a goal or task</button>
      </div>
    );
  }
  const openCount = tasks.filter((t) => !t.done).length;
  return (
    <div className="mb-4">
      <InsightsDisclosure
        title={`Tasks · ${titleCase(domain)}`}
        icon={Check}
        count={openCount}
        meta={tasks.length > openCount ? `${tasks.length - openCount} done` : undefined}
      >
      <div className="flex flex-col gap-1">
        {tasks.map((t, i) => (
          <label
            key={i}
            title={`${t.added ? `added ${t.added}` : "added before tracking"} · by ${t.source === "daemon" ? "the task routine" : t.source === "surface" ? "an accepted suggestion" : "you"}${t.due ? ` · due ${t.due}` : ""}`}
            className="flex cursor-pointer items-center gap-2 text-sm"
          >
            <input type="checkbox" checked={t.done} onChange={() => persist(tasks.map((x, j) => j === i ? { ...x, done: !x.done } : x))} />
            <span className={t.done ? "text-text-muted line-through" : "text-text-primary"}>{t.text}</span>
            {t.source && t.source !== "user" && (
              <span className="rounded bg-surface-warm px-1.5 py-0.5 font-mono text-[12px] text-text-muted">{t.source === "daemon" ? "auto" : "suggested"}</span>
            )}
            {t.due && !t.done && (() => {
              const today = new Date().toISOString().slice(0, 10);
              const overdue = t.due < today, due = t.due === today;
              return <span className={`rounded px-1.5 py-0.5 font-mono text-[12px] ${overdue ? "bg-warn/15 text-warn" : due ? "bg-accent-soft text-accent" : "bg-surface-warm text-text-muted"}`}>{overdue ? "overdue" : due ? "today" : t.due}</span>;
            })()}
            <span className="ml-auto shrink-0 font-mono text-[12px] text-text-muted/60">{t.added ?? ""}</span>
            <button onClick={() => persist(tasks.filter((_, j) => j !== i))} className="shrink-0 text-text-muted/50 hover:text-warn">✕</button>
          </label>
        ))}
      </div>
      <div className="mt-2 flex gap-2">
        <input value={adding} placeholder="add a task…  (optional due: @2026-04-15)" onChange={(e) => setAdding(e.target.value)}
          onKeyDown={async (e) => { if (e.key === "Enter" && adding.trim()) { const txt = adding.trim(); setAdding(""); try { const next = await invoke<DomainTask[]>("tasks_add", { vault: vaultPath, domain, text: txt, source: "user" }); setTasks(Array.isArray(next) ? next : []); } catch (err) { console.error("tasks_add", err); } } }}
          className="flex-1 rounded-md border border-border bg-background px-2 py-1 text-sm focus:border-accent-border focus:outline-none" />
      </div>
      </InsightsDisclosure>
    </div>
  );
}

export function AppHeaderBar({ app, enabled, onOpenDomain, onClose }: { app: EngineApp; enabled: boolean; onOpenDomain: (d: string) => void; onClose: () => void }) {
  const tint = STATUS_TINT[app.status] ?? "#9aa0a6";
  // Show the app's brand logo (same mark the sidebar and Apps panel render) so
  // it's instantly clear which app this conversation is in. Loaded once; the
  // command is cheap and cached engine-side.
  return (
    <div className="shrink-0 border-b border-border-subtle bg-surface px-4 py-2.5">
      <div className="flex items-center gap-2.5">
        <span className="h-2.5 w-2.5 shrink-0 rounded-full" style={{ backgroundColor: enabled ? tint : "#9aa0a6" }} title={enabled ? app.status : "disabled"} />
        <AppRowLogo app={app} size={22} fallback="letter" />
        <div className="flex min-w-0 flex-1 flex-col">
          <div className="flex items-center gap-2">
            <span className="truncate text-base font-semibold text-text-primary">{app.account?.label ? `${app.title} · ${app.account.label}` : app.title}</span>
            <span className="shrink-0 rounded-full border border-border-subtle px-2 py-0.5 text-[12px] text-text-muted">{INTEGRATION_LABEL[app.integration] ?? app.integration}</span>
            {!enabled && <span className="shrink-0 rounded-full border border-warn/40 bg-warn/10 px-2 py-0.5 text-[12px] text-warn">Disabled</span>}
          </div>
          {app.domains.length > 0 && (
            <div className="mt-0.5 flex flex-wrap items-center gap-x-1.5 gap-y-0.5">
              <span className="font-mono text-[12px] text-text-muted/70">Feeds</span>
              {app.domains.map((d, i) => (
                <span key={d} className="inline-flex items-center gap-1.5">
                  <button onClick={() => onOpenDomain(d)} className="rounded px-1 text-[12px] font-medium text-accent hover:bg-accent-soft hover:underline" title={`Open ${titleCase(d)} and chat there`}>{titleCase(d)}</button>
                  {i < app.domains.length - 1 && <span className="text-text-muted/40">·</span>}
                </span>
              ))}
            </div>
          )}
        </div>
        <button onClick={onClose} title="Close app view" className="shrink-0 rounded p-1 text-text-muted hover:bg-surface-warm hover:text-text-primary"><X className="h-4 w-4" /></button>
      </div>
    </div>
  );
}

export function SurfacePanel({ vaultPath, domain, onPick, onAddTask }: { vaultPath: string; domain: string; onPick: (t: string) => void; onAddTask: (t: string) => void }) {
  const [data, setData] = useState<SurfaceResult | null>(null);
  const [loading, setLoading] = useState(false);
  const [err, setErr] = useState<string>("");
  // Dismissed insights stay hidden (persisted per domain).
  const DISMISS_KEY = `prevail.surface.dismissed.${domain}`;
  const [dismissed, setDismissed] = useState<Set<string>>(() => {
    try { return new Set(JSON.parse(lsGet(DISMISS_KEY) || "[]")); } catch { return new Set(); }
  });
  const dismiss = (item: string) => setDismissed((d) => { const n = new Set(d); n.add(item); lsSet(DISMISS_KEY, JSON.stringify([...n])); return n; });
  const [saved, setSaved] = useState<Set<string>>(() => new Set());
  const load = useCallback(async (force: boolean) => {
    // Off when persistent memory is disabled (it's the proactive layer).
    if (getPref(PREF.persistentMemory, "1") !== "1") return;
    setLoading(true); setErr("");
    try {
      const r = await invoke<SurfaceResult>("domain_surface", {
        vault: vaultPath,
        domain,
        provider: getPref(PREF.memoryProvider, "claude"),
        model: cheapModel(),
        force,
      });
      setData(r);
    } catch (e) { setErr(String(e)); } finally { setLoading(false); }
  }, [vaultPath, domain]);
  useEffect(() => { void load(false); }, [load]);

  if (getPref(PREF.persistentMemory, "1") !== "1") return null;
  const hasContent = data && (data.questions.length > 0 || data.actions.length > 0);
  if (!hasContent && !loading && !err) return null;

  const freshMeta = data?.generated_at
    ? `refreshed ${formatFreshness(Math.max(0, (Date.now() - data.generated_at) / 1000))} ago · auto every 6h`
    : "";
  return (
    <div className="mb-4 rounded-xl border border-accent-border/40 bg-accent-soft/40 px-4 py-3">
      <div className="mb-2 flex items-baseline gap-2.5">
        <Sparkles className="h-4 w-4 shrink-0 self-center text-accent" />
        <span className="text-[15px] font-semibold text-text-primary">For you · {titleCase(domain)}</span>
        {freshMeta && <span className="font-mono text-[12px] text-text-muted">{freshMeta}</span>}
        <button onClick={() => void load(true)} disabled={loading}
          className="ml-auto text-[12px] text-text-muted hover:text-accent disabled:opacity-40">
          {loading ? "Thinking…" : "Refresh"}
        </button>
      </div>
      {err && (/Bunker/i.test(err)
        ? <div className="text-[13px] text-text-muted">Bunker Mode is on. Start a local model (Ollama) and insights will surface on-device.</div>
        : <div data-testid="surface-error" className="flex items-start gap-2">
            <ErrorLine error={err} className="min-w-0 flex-1" />
            <button onClick={() => void load(true)} disabled={loading} className="shrink-0 text-[13px] font-medium text-accent hover:underline disabled:opacity-40">Retry</button>
          </div>)}
      {hasContent && (() => {
        const questions = data!.questions.filter((q) => !dismissed.has(q));
        const actions = data!.actions.filter((a) => !dismissed.has(a));
        if (questions.length === 0 && actions.length === 0) {
          return <div className="py-2 text-xs text-text-muted">All caught up: nothing surfaced right now. <button onClick={() => void load(true)} className="text-accent hover:underline">Refresh</button> for more.</div>;
        }
        return (
          <div className="flex flex-col gap-2">
            {questions.length > 0 && (
              <InsightsDisclosure title="Questions worth asking" icon={Lightbulb} count={questions.length}>
                {/* F1: numbered, scannable rows. A subtle "Ask" stays visible (not
                    hover-only) so the action is discoverable; dismiss reveals on hover. */}
                <div className="flex flex-col gap-2">
                  {questions.map((q, i) => (
                    <div key={i} className="group flex items-start gap-3 rounded-lg border border-border-subtle bg-surface p-3 transition-colors hover:border-accent-border">
                      <span className="mt-0.5 flex h-5 w-5 shrink-0 items-center justify-center rounded-full bg-accent-soft text-[12px] font-semibold text-accent">{i + 1}</span>
                      <button onClick={() => onPick(q)} className="min-w-0 flex-1 text-left text-sm leading-snug text-text-primary hover:text-accent" title="Ask this in chat">{q}</button>
                      <div className="flex shrink-0 items-center gap-1">
                        <button onClick={() => onPick(q)} title="Ask this in chat" className="inline-flex items-center gap-1 rounded-md border border-accent-border px-2 py-1 text-[12px] text-accent transition-colors hover:bg-accent hover:text-background">Ask <ArrowRight className="h-2.5 w-2.5" /></button>
                        <button onClick={() => dismiss(q)} title="Dismiss" className="flex h-6 w-6 items-center justify-center rounded-md text-text-muted opacity-0 transition-opacity hover:bg-surface-warm hover:text-warn group-hover:opacity-100"><X className="h-3.5 w-3.5" /></button>
                      </div>
                    </div>
                  ))}
                </div>
              </InsightsDisclosure>
            )}
            {actions.length > 0 && (
              <InsightsDisclosure title="Suggested next steps" icon={ArrowRight} count={actions.length}>
                <div className="flex flex-col gap-2">
                  {actions.map((a, i) => (
                    <div key={i} className="group flex items-start gap-3 rounded-lg border border-border-subtle bg-surface p-3 transition-colors hover:border-accent-border">
                      <p className="min-w-0 flex-1 text-sm leading-snug text-text-primary">{a}</p>
                      <div className="flex shrink-0 items-center gap-1 opacity-0 transition-opacity group-hover:opacity-100">
                        <button onClick={() => { onAddTask(a); setSaved((s) => new Set(s).add(a)); }} title="Save as task" className={`inline-flex items-center gap-1 rounded-md border px-2 py-1 text-[12px] ${saved.has(a) ? "border-accent-border bg-accent-soft text-accent" : "border-border text-text-muted hover:border-accent-border hover:text-accent"}`}>
                          {saved.has(a) ? <><Check className="h-2.5 w-2.5" /> Saved</> : <><Plus className="h-2.5 w-2.5" /> Task</>}
                        </button>
                        <button onClick={() => onPick(a)} title="Work on this in chat" className="inline-flex items-center gap-1 rounded-md bg-accent px-2 py-1 text-[12px] text-background hover:bg-accent-hover">Do <ArrowRight className="h-2.5 w-2.5" /></button>
                        <button onClick={() => dismiss(a)} title="Dismiss" className="flex h-6 w-6 items-center justify-center rounded-md text-text-muted hover:bg-surface-warm hover:text-warn"><X className="h-3.5 w-3.5" /></button>
                      </div>
                    </div>
                  ))}
                </div>
              </InsightsDisclosure>
            )}
          </div>
        );
      })()}
    </div>
  );
}

// The HOME apps strip - the user's starred apps as one horizontal chip row at
// the top of the home canvas, so home reads consistently with the in-domain
// Apps strip (feedback: apps rendered vertically in the sidebar while domain
// chips read horizontally). Same source as the home sidebar (favorites only),
// same chip language as DomainAppsStrip, click opens the app. The Editor app
// view stays vertical by design.
export function HomeAppsStrip() {
  const [apps, setApps] = useState<EngineApp[]>([]);
  const favs = useFavorites();
  useEffect(() => {
    invoke<EngineApp[]>("engine_apps_list").then((all) => setApps(all ?? [])).catch(() => {});
  }, []);
  const starred = apps
    .filter((a) => favs.has(favKeyOf(a.title || a.id)) || favs.has(favKeyOf(a.id)))
    .sort((a, b) => a.title.localeCompare(b.title));
  if (starred.length === 0) return null;
  return (
    <div className="flex w-full max-w-2xl flex-wrap items-center justify-center gap-2">
      <span className="text-[12px] text-text-muted">Apps</span>
      {starred.map((a) => {
        const tint = STATUS_TINT[a.status] ?? "#9aa0a6";
        return (
          <button
            key={a.id}
            onClick={() => window.dispatchEvent(new CustomEvent("prevail:open-app", { detail: a }))}
            title={`Open ${a.title} · ${a.status}${a.lastError ? ": " + a.lastError : ""}`}
            className="inline-flex items-center gap-1.5 text-text-secondary transition-colors hover:text-accent"
          >
            <span className="h-1.5 w-1.5 rounded-full" style={{ backgroundColor: tint }} />
            <span className="text-[12px]">{a.account?.label ? `${a.title} · ${a.account.label}` : a.title}</span>
          </button>
        );
      })}
    </div>
  );
}

export function DomainAppsStrip({ domain }: { domain: string }) {
  const [apps, setApps] = useState<EngineApp[]>([]);
  // Mirror the sidebar's active-app highlight here so it's obvious which app
  // (if any) you're currently inside while standing in this domain.
  const [activeId, setActiveId] = useState<string | null>(null);
  useEffect(() => {
    invoke<EngineApp[]>("engine_apps_list")
      .then((all) => setApps((all ?? []).filter((a) => a.domains?.includes(domain))))
      .catch(() => {});
  }, [domain]);
  useEffect(() => {
    const onActive = (e: Event) => setActiveId(((e as CustomEvent).detail as string | null) ?? null);
    window.addEventListener("prevail:active-app", onActive);
    return () => window.removeEventListener("prevail:active-app", onActive);
  }, []);
  if (apps.length === 0) return null;
  return (
    <div className="mb-4 flex flex-wrap items-center gap-x-3 gap-y-1">
      <span className="text-[12px] text-text-muted">Apps</span>
      {apps.map((a) => {
        const tint = STATUS_TINT[a.status] ?? "#9aa0a6";
        const active = activeId === a.id;
        return (
          <button
            key={a.id}
            onClick={() => window.dispatchEvent(new CustomEvent("prevail:open-app", { detail: a }))}
            title={`Open ${a.title} · ${a.status}${a.lastError ? ": " + a.lastError : ""}`}
            className={`inline-flex items-center gap-1.5 transition-colors ${active ? "font-medium text-text-primary" : "text-text-secondary hover:text-accent"}`}
          >
            <span
              className="h-1.5 w-1.5 rounded-full"
              style={active ? { backgroundColor: tint, boxShadow: `0 0 0 3px color-mix(in srgb, ${tint} 28%, transparent)` } : { backgroundColor: tint }}
            />
            <span className="text-[13px]">{a.account?.label ? `${a.title} · ${a.account.label}` : a.title}</span>
          </button>
        );
      })}
      {/* Straight to the Apps page, without the Settings round-trip. */}
      <button onClick={() => window.dispatchEvent(new CustomEvent("prevail:open-settings", { detail: "apps" }))} title="Manage apps" aria-label="Manage apps"
        className="flex h-6 w-6 items-center justify-center rounded-md text-text-muted hover:bg-surface-warm hover:text-text-primary"><Settings2 className="h-3.5 w-3.5" /></button>
    </div>
  );
}

// A skill drafted or imported as a full SKILL.md carries a frontmatter block and
// a "# Title" heading; skill_create re-adds both when it saves. Peel them back to
// the inner prompt body (and lift the title, if we don't already have a name) so
// the editor shows a clean prompt and saving never double-wraps the frontmatter.
function splitSkillMd(raw: string): { title: string; body: string } {
  let text = (raw ?? "").trim();
  let title = "";
  const fm = text.match(/^---\s*\n([\s\S]*?)\n---\s*\n?/);
  if (fm) {
    // Lift a `description:` as a fallback title source only if the heading is missing.
    text = text.slice(fm[0].length).trim();
  }
  const heading = text.match(/^#\s+(.+?)\s*\n+/);
  if (heading) {
    title = heading[1]!.trim();
    text = text.slice(heading[0].length).trim();
  }
  return { title, body: text };
}

type SkillIdea = { name: string; describe: string };
type SkillMode = "describe" | "write";

export function NewSkillForm({ vaultPath, domain, seed, onCreated }: { vaultPath: string; domain: string; seed?: string | null; onCreated: () => void }) {
  const [open, setOpen] = useState(false);
  const [mode, setMode] = useState<SkillMode>("describe");
  const [name, setName] = useState("");
  const [describe, setDescribe] = useState("");
  const [body, setBody] = useState("");
  const [saving, setSaving] = useState(false);
  const [drafting, setDrafting] = useState(false);
  const [err, setErr] = useState("");
  // Proactive suggestions: name + one-line ideas, on demand. Never auto-created.
  const [ideas, setIdeas] = useState<SkillIdea[] | null>(null);
  const [suggesting, setSuggesting] = useState(false);
  // Open + pre-fill when a "Save as skill" seed arrives from the composer. A
  // seed is a ready prompt body, so jump straight to the write-it-yourself path.
  useEffect(() => {
    if (seed != null) { setOpen(true); setMode("write"); setBody(seed); }
  }, [seed]);

  function reset() {
    setName(""); setDescribe(""); setBody(""); setErr(""); setIdeas(null); setMode("describe");
  }

  // Path 1: draft a complete, valid skill from a plain-language description,
  // grounded in the domain's context. Fills the body editor for review, then the
  // existing Save writes it via skill_create.
  async function draftWithAI() {
    setErr("");
    if (!name.trim() || !describe.trim()) { setErr("Give the skill a name and describe what it should do."); return; }
    setDrafting(true);
    try {
      const provider = getPref(PREF.memoryProvider, "claude");
      const model = cheapModel();
      const md = await invoke<string>("engine_skill_draft", { vault: vaultPath, domain, name: name.trim(), describe: describe.trim(), provider, model });
      const { title, body: inner } = splitSkillMd(md);
      if (title && !name.trim()) setName(title);
      setBody(inner || md.trim());
      setMode("write"); // hand off to the review/edit + Save editor
    } catch (e) { setErr(String(e)); }
    finally { setDrafting(false); }
  }

  // Import an existing skill file: read it, peel the frontmatter/heading, and
  // load the prompt into the editor for review (reuses read_file + the native
  // open dialog, same pattern as the bench importer).
  async function importSkill() {
    setErr("");
    try {
      const picked = await openFileDialog({ filters: [{ name: "Skill", extensions: ["md", "markdown", "txt"] }], multiple: false });
      const path = typeof picked === "string" ? picked : null;
      if (!path) return;
      const raw = await invoke<string>("read_file", { path });
      const { title, body: inner } = splitSkillMd(raw);
      if (title) setName(title);
      setBody(inner || raw.trim());
      setMode("write");
    } catch (e) { setErr(`Import failed: ${e}`); }
  }

  // Path 3 (suggest, never auto-create): ask the model for a few skill ideas for
  // this domain. Clicking one seeds the describe path so the user can draft it.
  async function suggest() {
    setErr(""); setSuggesting(true);
    try {
      const provider = getPref(PREF.memoryProvider, "claude");
      const model = cheapModel();
      const res = await invoke<{ ok: boolean; ideas?: SkillIdea[]; error?: string }>("engine_skill_ideas", { vault: vaultPath, domain, provider, model });
      if (res?.ok) setIdeas(res.ideas ?? []);
      else setErr(res?.error || "Could not suggest skills right now.");
    } catch (e) { setErr(String(e)); }
    finally { setSuggesting(false); }
  }

  function useIdea(idea: SkillIdea) {
    setName(idea.name); setDescribe(idea.describe); setMode("describe"); setIdeas(null);
  }

  async function create() {
    setErr("");
    if (!name.trim() || !body.trim()) { setErr("Give the skill a name and a body."); return; }
    setSaving(true);
    try {
      await invoke("skill_create", { vault: vaultPath, domain, name: name.trim(), body: body.trim() });
      reset(); setOpen(false);
      onCreated();
    } catch (e) { setErr(String(e)); }
    finally { setSaving(false); }
  }

  if (!open) {
    return (
      <div className="mb-3 flex w-full items-center justify-between">
        <p className="text-xs text-text-muted">Skills are reusable prompts Glyph Studio runs on demand (<span className="font-mono text-accent">/name</span> in chat). Pin your favorites to auto-attach.</p>
        <button onClick={() => setOpen(true)} className="inline-flex shrink-0 items-center gap-1.5 rounded-md border border-border bg-surface px-2.5 py-1 text-[12px] text-text-muted hover:border-accent-border hover:bg-accent-soft hover:text-accent">
          <Sparkles className="h-3 w-3" /> New skill
        </button>
      </div>
    );
  }

  const tabBtn = (m: SkillMode, label: string, Icon: LucideIcon) => (
    <button
      onClick={() => setMode(m)}
      className={`inline-flex items-center gap-1.5 rounded-md px-2.5 py-1 text-[12px] transition-colors ${
        mode === m ? "border border-accent-border bg-accent-soft text-accent" : "border border-transparent text-text-muted hover:text-text-secondary"
      }`}
    >
      <Icon className="h-3 w-3" /> {label}
    </button>
  );

  return (
    <div className="mb-3 w-full rounded-xl border border-accent-border bg-surface p-4">
      <div className="mb-3 flex items-center justify-between gap-2">
        <div className="font-mono text-[14px] font-semibold text-text-primary">New skill · {titleCase(domain)}</div>
        <div className="flex items-center gap-1">
          {tabBtn("describe", "Describe it", Sparkles)}
          {tabBtn("write", "Write it yourself", PenLine)}
        </div>
      </div>

      <input
        value={name}
        onChange={(e) => setName(e.target.value)}
        placeholder="Skill name (e.g. Weekly review)"
        className="mb-2 w-full rounded-md border border-border bg-background px-3 py-2 text-sm focus:border-accent-border focus:outline-none"
      />

      {mode === "describe" ? (
        <>
          <textarea
            value={describe}
            onChange={(e) => setDescribe(e.target.value)}
            rows={4}
            placeholder="Describe what you want this skill to do. Glyph Studio drafts it in the right format, grounded in this domain, for you to review."
            className="mb-2 w-full rounded-md border border-border bg-background px-3 py-2 text-sm focus:border-accent-border focus:outline-none"
          />
          {err && <div className="mb-2 text-xs text-warn">{err}</div>}
          <div className="flex flex-wrap items-center gap-2">
            <button onClick={draftWithAI} disabled={drafting} className="inline-flex items-center gap-1.5 rounded-md bg-accent px-3 py-1.5 text-sm font-semibold text-background hover:bg-accent-hover disabled:opacity-40">
              {drafting ? <><Loader2 className="h-4 w-4 animate-spin" /> Drafting…</> : <><Sparkles className="h-4 w-4" /> Create with AI</>}
            </button>
            <button onClick={importSkill} className="inline-flex items-center gap-1.5 rounded-md border border-border px-3 py-1.5 text-sm text-text-secondary hover:bg-surface-warm">
              <Download className="h-4 w-4" /> Import
            </button>
            <button onClick={() => { reset(); setOpen(false); }} className="rounded-md border border-border px-3 py-1.5 text-sm text-text-muted hover:bg-surface-warm">Cancel</button>
          </div>
        </>
      ) : (
        <>
          <textarea
            value={body}
            onChange={(e) => setBody(e.target.value)}
            rows={7}
            placeholder="What should this skill do? Write it as a prompt the model will follow."
            className="mb-2 w-full rounded-md border border-border bg-background px-3 py-2 text-[13px] focus:border-accent-border focus:outline-none"
          />
          {err && <div className="mb-2 text-xs text-warn">{err}</div>}
          <div className="flex flex-wrap items-center gap-2">
            <button onClick={create} disabled={saving} className="inline-flex items-center gap-1.5 rounded-md bg-accent px-3 py-1.5 text-sm font-semibold text-background hover:bg-accent-hover disabled:opacity-40">
              {saving ? <Loader2 className="h-4 w-4 animate-spin" /> : <Check className="h-4 w-4" />} Save skill
            </button>
            <button onClick={importSkill} className="inline-flex items-center gap-1.5 rounded-md border border-border px-3 py-1.5 text-sm text-text-secondary hover:bg-surface-warm">
              <Download className="h-4 w-4" /> Import
            </button>
            <button onClick={() => { reset(); setOpen(false); }} className="rounded-md border border-border px-3 py-1.5 text-sm text-text-muted hover:bg-surface-warm">Cancel</button>
          </div>
        </>
      )}

      {/* Proactive suggestions: ideas only, turned into a draft on click. Never auto-created. */}
      <div className="mt-3 border-t border-border-subtle pt-3">
        <div className="flex items-center justify-between gap-2">
          <span className="text-xs text-text-muted">Not sure what to add? Glyph Studio can suggest skills for this domain.</span>
          <button onClick={suggest} disabled={suggesting} className="inline-flex shrink-0 items-center gap-1.5 rounded-md border border-border bg-surface px-2.5 py-1 text-[12px] text-text-muted hover:border-accent-border hover:bg-accent-soft hover:text-accent disabled:opacity-40">
            {suggesting ? <Loader2 className="h-3 w-3 animate-spin" /> : <Lightbulb className="h-3 w-3" />} Suggest skills
          </button>
        </div>
        {ideas != null && (
          <div className="mt-2 space-y-1.5">
            {ideas.length === 0 && <p className="text-xs text-text-muted">No suggestions right now. Add more to this domain and try again.</p>}
            {ideas.map((idea, i) => (
              <button
                key={i}
                onClick={() => useIdea(idea)}
                className="flex w-full items-start gap-2 rounded-md border border-border-subtle bg-background px-3 py-2 text-left transition-colors hover:border-accent-border hover:bg-accent-soft"
              >
                <Plus className="mt-0.5 h-3.5 w-3.5 shrink-0 text-accent" />
                <span className="min-w-0">
                  <span className="block text-sm text-text-primary">{idea.name}</span>
                  <span className="block text-xs text-text-muted">{idea.describe}</span>
                </span>
              </button>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}

export function SkillsList({
  skills,
  onInsert,
  preferredSet,
  onTogglePreferred,
}: {
  skills: SkillEntry[];
  onInsert: (name: string) => void;
  preferredSet?: Set<string>;
  onTogglePreferred?: (name: string) => void;
}) {
  const [expanded, setExpanded] = useState<string | null>(null);
  const [content, setContent] = useState<Record<string, string>>({});
  const [loading, setLoading] = useState<string | null>(null);
  async function toggle(path: string) {
    if (expanded === path) { setExpanded(null); return; }
    setExpanded(path);
    if (!content[path]) {
      setLoading(path);
      try {
        const body = await invoke<string>("read_skill", { path });
        setContent((c) => ({ ...c, [path]: body }));
      } catch (e) {
        setContent((c) => ({ ...c, [path]: `(error reading: ${e})` }));
      } finally {
        setLoading(null);
      }
    }
  }
  async function openFolder(path: string) {
    try { await invoke("open_in_finder", { path }); } catch {}
  }
  return (
    <ul className="flex w-full flex-col gap-2">
      {skills.map((s) => {
        const open = expanded === s.path;
        return (
          <li key={s.path}>
            <div className={`rounded-lg border bg-surface transition-colors ${open ? "border-accent-border" : "border-border-subtle"}`}>
              {/* Single-line row - same dimensions as every other settings list. */}
              <div className="flex w-full items-center gap-2">
                <button
                  onClick={() => toggle(s.path)}
                  className="flex min-w-0 flex-1 items-center gap-3 px-4 py-3 text-left hover:bg-surface-warm rounded-l-lg"
                >
                  <Sparkles className="h-4 w-4 shrink-0 text-accent" />
                  <span className="shrink-0 font-mono text-sm font-semibold text-accent">/{s.name}</span>
                  {(() => {
                    const cleaned = (s.description ?? "").replace(/^[>*\-\s]+/, "").trim();
                    if (cleaned.length < 3) return null;
                    return <span className="truncate text-xs text-text-muted">{cleaned}</span>;
                  })()}
                  <span className="ml-auto shrink-0 text-xs text-text-muted">{open ? "▾" : "▸"}</span>
                </button>
                {onTogglePreferred && (
                  <button
                    onClick={() => onTogglePreferred(s.name)}
                    title={preferredSet?.has(s.name) ? "Unpin: won't auto-attach to new chats" : "Pin: auto-attach to new chats in this domain"}
                    className={`mr-2 mt-2 inline-flex h-7 w-7 shrink-0 items-center justify-center rounded-md border transition-colors ${
                      preferredSet?.has(s.name)
                        ? "border-accent-border bg-accent-soft text-accent"
                        : "border-border bg-background text-text-muted hover:border-accent-border hover:text-accent"
                    }`}
                  >
                    {preferredSet?.has(s.name) ? "★" : "☆"}
                  </button>
                )}
              </div>
              {open && (
                <div className="border-t border-border-subtle px-4 py-3">
                  {loading === s.path ? (
                    <div className="text-xs text-text-muted">loading…</div>
                  ) : content[s.path] ? (
                    <div className="max-h-80 overflow-y-auto rounded-md border border-border-subtle bg-background px-3 py-2">
                      <Markdown source={content[s.path]} compact />
                    </div>
                  ) : null}
                  <div className="mt-3 flex items-center gap-2">
                    <button
                      onClick={() => onInsert(s.name)}
                      className="rounded-md border border-accent-border bg-accent-soft px-2.5 py-1 text-[12px] text-accent hover:bg-accent hover:text-background"
                    >
                      insert /{s.name}
                    </button>
                    <button
                      onClick={() => openFolder(s.path)}
                      className="inline-flex items-center gap-1 rounded-md border border-border bg-background px-2.5 py-1 text-[12px] text-text-muted hover:border-accent-border hover:text-accent"
                    >
                      <Folder className="h-3 w-3" />
                      open folder
                    </button>
                  </div>
                </div>
              )}
            </div>
          </li>
        );
      })}
    </ul>
  );
}

export function DrawerImportsSection({
  domain,
  onInject,
  onPreview,
}: {
  domain: string;
  onInject: (body: string, label: string) => void;
  // When set, a click previews the import instead of adding it to the chat.
  onPreview?: (title: string, body: string) => void;
}) {
  const [items, setItems] = useState<{ path: string; name: string; size: number; mtime: number }[]>([]);
  useEffect(() => {
    let mounted = true;
    invoke<{ path: string; name: string; size: number; mtime: number }[]>(
      "ingestion_list_artifacts",
      { domain },
    )
      .then((rows) => { if (mounted) setItems(Array.isArray(rows) ? rows : []); })
      .catch(() => { if (mounted) setItems([]); });
    return () => { mounted = false; };
  }, [domain]);

  async function vacuum(days: number) {
    const ok = await tauriConfirm(`Delete imports older than ${days} days from ${titleCase(domain)}?`, { title: "Prune imports", kind: "warning" }).catch(() => false);
    if (!ok) return;
    try {
      const n = await invoke<number>("ingestion_vacuum_imports", { domain, olderThanDays: days });
      if (n > 0) {
        // Reload the list - easier than diffing.
        const next = await invoke<{ path: string; name: string; size: number; mtime: number }[]>(
          "ingestion_list_artifacts", { domain },
        );
        setItems(Array.isArray(next) ? next : []);
      }
    } catch (e) { console.error(e); }
  }
  if (items.length === 0) return null;
  return (
    <div className="border-b border-border-subtle">
      <div className="flex w-full items-center justify-between gap-2 px-4 py-2.5 text-left">
        <span className="flex items-center gap-2 text-[12px] text-text-secondary">
          <span className="text-accent">▾</span> Imports
          <span className="text-text-muted">· {items.length}</span>
        </span>
        <button
          onClick={() => void vacuum(90)}
          title="Delete imports older than 90 days"
          className="rounded border border-border bg-background px-1.5 py-0.5 text-[12px] text-text-muted hover:border-warn hover:text-warn"
        >
          vacuum 90d
        </button>
      </div>
      <div className="px-4 pb-2">
        <ul className="space-y-1">
          {items.slice(0, 12).map((it) => (
            <li key={it.path} className="flex items-stretch gap-1">
              <button
                onClick={async () => {
                  try {
                    const body = await invoke<string>("read_file", { path: it.path });
                    if (onPreview) onPreview(it.name, body);
                    else onInject(body.slice(0, 6000), it.name);
                  } catch (e) { console.error(e); }
                }}
                className="flex-1 rounded border border-border-subtle bg-background px-2 py-1.5 text-left hover:border-accent-border hover:bg-surface-warm"
              >
                <div className="truncate text-[12px] text-text-primary">{it.name}</div>
                <div className="font-mono text-[12px] text-text-muted">
                  {(it.size / 1024).toFixed(1)} KB
                </div>
              </button>
              <button
                onClick={() => invoke("open_in_finder", { path: it.path })}
                title="Reveal in Finder"
                className="shrink-0 rounded border border-border-subtle bg-background px-2 text-[12px] text-text-muted hover:border-accent-border hover:text-accent"
              >
                ↗
              </button>
            </li>
          ))}
        </ul>
      </div>
    </div>
  );
}

export function DomainActionsMenu({
  domain,
  vaultPath,
  onArchived,
  label,
  canArchive = true,
}: {
  domain: string;
  vaultPath: string;
  onArchived: (name: string) => void;
  label?: string;
  canArchive?: boolean;
}) {
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState<null | "backup" | "archive">(null);
  const [note, setNote] = useState<string | null>(null);
  const [confirmArchive, setConfirmArchive] = useState(false);
  const ref = useRef<HTMLDivElement | null>(null);
  useEffect(() => {
    if (!open) return;
    const onDoc = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) {
        setOpen(false);
        setConfirmArchive(false);
      }
    };
    document.addEventListener("mousedown", onDoc);
    return () => document.removeEventListener("mousedown", onDoc);
  }, [open]);

  async function backup() {
    setBusy("backup");
    setNote(null);
    try {
      const res = await invoke<BackupResult>("engine_vault_backup", {
        vault: vaultPath,
        domainOpt: domain,
      });
      const files = res.file_count ?? 0;
      setNote(
        res.ok
          ? `Backed up ${files} file${files === 1 ? "" : "s"} (${bytesHuman(res.bytes ?? 0)})`
          : `Backup failed: ${res.error ?? "unknown error"}`,
      );
    } catch (e) {
      setNote(`Backup failed: ${String(e)}`);
    } finally {
      setBusy(null);
    }
  }

  async function archive() {
    setBusy("archive");
    setNote(null);
    try {
      await invoke("engine_vault_archive", { vault: vaultPath, domain });
      setOpen(false);
      setConfirmArchive(false);
      onArchived(domain);
    } catch (e) {
      setNote(`Archive failed: ${String(e)}`);
    } finally {
      setBusy(null);
    }
  }

  return (
    <div ref={ref} className="relative">
      <button
        onClick={() => setOpen((v) => !v)}
        title="Back up / Archive domain"
        className={`flex items-center gap-1.5 rounded text-text-muted transition-colors hover:bg-surface-warm hover:text-accent ${
          label ? "px-2.5 py-1.5 text-[13px]" : "h-6 w-6 justify-center"
        }`}
      >
        <Archive className="h-3.5 w-3.5" />
        {label}
      </button>
      {open && (
        <div className="absolute right-0 top-7 z-40 w-56 rounded-lg border border-border bg-surface p-1.5 shadow-xl">
          <button
            onClick={backup}
            disabled={busy !== null}
            className="flex w-full items-center gap-2 rounded-md px-2 py-1.5 text-left text-sm text-text-primary hover:bg-surface-warm disabled:opacity-50"
          >
            {busy === "backup" ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <Download className="h-3.5 w-3.5" />}
            {canArchive ? "Back up this domain" : "Back up the workspace"}
          </button>
          {canArchive && (!confirmArchive ? (
            <button
              onClick={() => setConfirmArchive(true)}
              disabled={busy !== null}
              className="flex w-full items-center gap-2 rounded-md px-2 py-1.5 text-left text-sm text-text-primary hover:bg-surface-warm disabled:opacity-50"
            >
              <Archive className="h-3.5 w-3.5" />
              Archive domain…
            </button>
          ) : (
            <div className="rounded-md border border-border-subtle bg-background p-2">
              <div className="mb-1.5 text-xs text-text-secondary">
                Hide <span className="font-semibold">{titleCase(domain)}</span> from the active list? Nothing is deleted: restore it any time.
              </div>
              <div className="flex gap-1.5">
                <button
                  onClick={archive}
                  disabled={busy !== null}
                  className="flex items-center gap-1 rounded bg-warn px-2 py-1 text-[12px] text-background hover:opacity-90 disabled:opacity-50"
                >
                  {busy === "archive" ? <Loader2 className="h-3 w-3 animate-spin" /> : <Archive className="h-3 w-3" />}
                  archive
                </button>
                <button
                  onClick={() => setConfirmArchive(false)}
                  disabled={busy !== null}
                  className="rounded border border-border px-2 py-1 text-[12px] text-text-muted hover:bg-surface-warm"
                >
                  cancel
                </button>
              </div>
            </div>
          ))}
          {note && <div className="mt-1 px-2 py-1 text-[12px] text-text-muted">{note}</div>}
        </div>
      )}
    </div>
  );
}

export function UsageBreakdown({
  title,
  icon: Icon,
  rows,
}: {
  title: string;
  icon: LucideIcon;
  rows: UsageBucket[];
}) {
  if (rows.length === 0) return null;
  const max = Math.max(1, ...rows.map((r) => r.turns));
  return (
    <div className="flex flex-col rounded-xl border border-border-subtle bg-surface p-4">
      <div className="mb-3 flex items-center gap-2 text-[14px] font-semibold text-text-primary">
        <Icon className="h-3.5 w-3.5" />
        {title}
      </div>
      {/* Each row spans the full card width: name + metrics on one baseline,
          a full-width proportional bar beneath. Reads cleanly and fills the
          horizontal space instead of hugging the left edge. */}
      <div className="flex flex-1 flex-col gap-3">
        {rows.slice(0, 6).map((r) => (
          <div key={r.key} className="flex flex-col gap-1.5">
            <div className="flex items-baseline justify-between gap-3">
              <span className="min-w-0 truncate text-xs text-text-primary" title={r.key}>
                {r.key}
              </span>
              <span className="shrink-0 text-[12px] tabular-nums text-text-muted">
                <span className="text-text-secondary">{r.turns}</span> {r.turns === 1 ? "turn" : "turns"}
                <span className="mx-1.5 text-border">·</span>
                {compactNum(r.input_tokens + r.output_tokens)} tok
                <span className="mx-1.5 text-border">·</span>
                <span className="text-text-secondary">{fmtCost(r.cost_usd)}</span>
              </span>
            </div>
            <div className="relative h-2 w-full overflow-hidden rounded-full bg-surface-warm">
              <span
                className="absolute inset-y-0 left-0 rounded-full bg-accent"
                style={{ width: `${(r.turns / max) * 100}%` }}
              />
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

export function ScoreBar({ value, max, color = "var(--color-accent)" }: { value: number | null; max: number; color?: string }) {
  const pct = value === null ? 0 : Math.min(100, (value / max) * 100);
  return (
    <div className="h-1.5 w-full overflow-hidden rounded-full bg-surface-strong">
      <div className="h-full rounded-full transition-all" style={{ width: `${pct}%`, background: color }} />
    </div>
  );
}

export function ContextScoreBadge({
  score,
  onClick,
}: {
  score: ContextScore | null;
  onClick?: () => void;
}) {
  if (!score) return null;
  const color = scoreColor(score.score);
  const tier = score.score >= 80 ? "Strong" : score.score >= 60 ? "Solid" : score.score >= 40 ? "Thin" : "Sparse";
  return (
    <div className="group relative inline-flex">
      <button
        onClick={onClick}
        className="inline-flex cursor-pointer items-center rounded-full px-2 py-0.5 text-[12px] font-semibold tracking-wide transition-colors hover:bg-surface-warm"
      >
        <span className="inline-flex items-center gap-1.5">
          <span className="inline-block h-1.5 w-1.5 rounded-full" style={{ background: color }} />
          <span style={{ color }}>{score.score}<span className="opacity-50">/100</span></span>
        </span>
        {/* Edit affordance is hidden until hover, so the header stays calm. */}
        <Pencil
          className="h-2.5 w-2.5 max-w-0 overflow-hidden text-text-muted opacity-0 transition-all duration-150 group-hover:ml-1.5 group-hover:max-w-[14px] group-hover:opacity-100"
          style={{ color }}
        />
      </button>
      {/* Formatted hover card - replaces the flat native title tooltip. */}
      <div className="pointer-events-none absolute right-0 top-full z-50 mt-2 w-60 translate-y-1 rounded-xl border border-border bg-surface p-3 text-left opacity-0 shadow-xl transition-all duration-150 group-hover:translate-y-0 group-hover:opacity-100">
        <div className="mb-2 flex items-center justify-between">
          <span className="font-mono text-[12px] font-bold text-text-muted">Context score</span>
          <span className="rounded-full px-1.5 py-0.5 text-[12px] font-bold tracking-wider" style={{ color, background: `${color}1a` }}>{tier}</span>
        </div>
        <div className="mb-2 flex items-baseline gap-1 font-mono">
          <span className="text-2xl font-bold leading-none" style={{ color }}>{score.score}</span>
          <span className="text-sm text-text-muted">/ 100</span>
        </div>
        <div className="mb-2.5 h-1.5 w-full overflow-hidden rounded-full bg-surface-warm">
          <div className="h-full rounded-full" style={{ width: `${score.score}%`, background: color }} />
        </div>
        <div className="space-y-1 text-[12px]">
          <div className="flex items-center justify-between">
            <span className="text-text-muted">Updated</span>
            <span className="text-text-secondary">{formatFreshness(score.freshness_secs)}</span>
          </div>
          <div className="flex items-center justify-between">
            <span className="text-text-muted">{score.audited_at ? "Audited" : "Source"}</span>
            <span className="text-text-secondary">{score.audited_at ? formatAuditedAt(score.audited_at) : "heuristic estimate"}</span>
          </div>
        </div>
        <div className="mt-2.5 flex items-center gap-1.5 border-t border-border-subtle pt-2 text-[12px] text-text-muted">
          <Pencil className="h-2.5 w-2.5" />
          Click to review and rescan
        </div>
      </div>
    </div>
  );
}

export function BenchCrumbs({
  items,
  meta,
}: {
  items: { label: string; onClick?: () => void }[];
  meta?: React.ReactNode;
}) {
  return (
    <nav className="mb-4 flex flex-wrap items-baseline gap-x-1.5 gap-y-1">
      {items.map((it, i) => {
        const isLast = i === items.length - 1;
        return (
          <Fragment key={`${it.label}-${i}`}>
            {i > 0 && <ChevronRight className={`shrink-0 ${isLast ? "h-4 w-4 text-text-muted/50" : "h-3.5 w-3.5 text-text-muted/40"}`} />}
            {it.onClick ? (
              <button
                onClick={it.onClick}
                className="font-mono text-sm text-text-muted underline underline-offset-2 decoration-text-muted/40 hover:text-accent hover:decoration-accent transition-colors"
              >
                {it.label}
              </button>
            ) : isLast ? (
              <span className="font-mono text-sm text-text-primary">{it.label}</span>
            ) : (
              <span className="font-mono text-sm text-text-muted">{it.label}</span>
            )}
          </Fragment>
        );
      })}
      {meta != null && <span className="ml-auto shrink-0 text-xs text-text-muted">{meta}</span>}
    </nav>
  );
}

export function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <label className="block">
      <span className="mb-1 block text-[12px] text-text-muted">{label}</span>
      {children}
    </label>
  );
}

export function DaemonCard({
  name,
  status,
  extra,
  onStart,
  onStop,
  intervalSec,
  bare = false,
}: {
  name: string;
  // Bare: just the status line and the switch, for a detail header.
  bare?: boolean;
  status: DaemonStatus | null;
  extra?: string | null;
  onStart?: () => Promise<void>;
  onStop?: () => Promise<void>;
  // B2-23: cadence (seconds) so the card can show when the routine next runs.
  intervalSec?: number;
}) {
  const [phase, setPhase] = useState<"idle" | "starting" | "stopping">("idle");

  // Sync: as soon as the poll confirms the expected state, clear the transition.
  useEffect(() => {
    if (phase === "starting" && status?.running) setPhase("idle");
    if (phase === "stopping" && status?.running === false) setPhase("idle");
  }, [status?.running]); // eslint-disable-line react-hooks/exhaustive-deps

  const isRunning = phase === "starting" || (!!status?.running && phase !== "stopping");
  const busy = phase !== "idle";

  const fmtTs = (ts: number | null | undefined) =>
    ts ? new Date(ts * 1000).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }) : null;

  // B2-23: next run = last run + cadence (only when running + cadence known).
  const nextTs = isRunning && status?.last_run_ts && intervalSec ? status.last_run_ts + intervalSec : null;
  const statusLine = phase === "starting"
    ? "starting…"
    : phase === "stopping"
    ? "stopping…"
    : isRunning
    ? `running${status?.last_run_ts ? ` · last ${fmtTs(status.last_run_ts)}` : ""}${nextTs ? ` · next ~${fmtTs(nextTs)}` : ""}`
    : `idle${status?.last_run_ts ? ` · last ran ${fmtTs(status.last_run_ts)}` : ""}`;

  async function handleStart() {
    setPhase("starting");
    const d = TELEMETRY_DAEMONS[name];
    if (d) track("daemon_toggled", { daemon: d, on: true });
    try { await onStart?.(); } catch {}
    setTimeout(() => setPhase((p) => p === "starting" ? "idle" : p), 4000);
  }
  async function handleStop() {
    setPhase("stopping");
    const d = TELEMETRY_DAEMONS[name];
    if (d) track("daemon_toggled", { daemon: d, on: false });
    try { await onStop?.(); } catch {}
    setTimeout(() => setPhase((p) => p === "stopping" ? "idle" : p), 4000);
  }

  if (bare) {
    return (
      <div className="flex items-center gap-3">
        <span className={`text-[13px] ${status?.last_error ? "text-warn" : "text-text-muted"}`} title={status?.last_error ?? undefined}>
          {statusLine}{!busy && extra ? ` · ${extra}` : ""}
        </span>
        {(onStart || onStop) && (
          <Toggle on={busy ? phase === "starting" : isRunning} disabled={busy} label={`${name} on or off`}
            onChange={(v) => { if (v) void handleStart(); else void handleStop(); }} />
        )}
      </div>
    );
  }
  return (
    <div className={`rounded-lg border px-4 py-3 transition-all duration-300 ${
      isRunning
        ? "border-ok/30 bg-ok/5"
        : busy
        ? "border-accent-border bg-accent-soft/50"
        : "border-border bg-surface"
    }`}>
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2.5">
          <span className="relative inline-flex h-2.5 w-2.5 items-center justify-center">
            {isRunning && (
              <span className="pulse-soft absolute inset-0 rounded-full bg-ok/40" />
            )}
            <span className={`relative inline-block h-2 w-2 rounded-full transition-colors duration-300 ${
              isRunning ? "bg-ok" : busy ? "bg-accent" : "bg-text-muted/30"
            }`} />
          </span>
          <span className={`text-[12px] font-bold ${
            isRunning ? "text-ok" : "text-text-primary"
          }`}>{name}</span>
        </div>
        {/* D1: an On/Off toggle, not Start/Stop text. While a transition is in
            flight the toggle is disabled and reflects the target state. */}
        <div className="flex items-center gap-1.5">
          {(onStart || onStop) && (
            <Toggle
              on={busy ? phase === "starting" : isRunning}
              disabled={busy}
              onChange={(v) => { if (v) void handleStart(); else void handleStop(); }}
            />
          )}
        </div>
      </div>
      <div className={`mt-1.5 text-[12px] ${isRunning ? "text-ok/70" : "text-text-muted"}`}>
        {statusLine}
        {!busy && extra ? <span className="text-text-muted"> · {extra}</span> : null}
        {!busy && status?.last_error ? <span className="text-err"> · {status.last_error}</span> : null}
      </div>
    </div>
  );
}

export function HeadlessLearnCard({ vaultPath }: { vaultPath: string }) {
  const [installed, setInstalled] = useState<boolean | null>(null);
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState<string | null>(null);
  const refresh = () => invoke<boolean>("headless_learn_status").then(setInstalled).catch(() => setInstalled(false));
  useEffect(() => { refresh(); }, []);
  async function toggle() {
    setBusy(true); setNote(null);
    try {
      const r = await invoke<string>("headless_learn_set", { vault: vaultPath, enabled: !installed });
      setNote(r.slice(0, 200) || (installed ? "Stopped." : "Now learning at login."));
      await refresh();
      window.dispatchEvent(new Event("prevail:headless-changed"));
    } catch (e) { setNote(`Failed: ${String(e).slice(0, 200)}`); }
    finally { setBusy(false); }
  }
  return (
    <div className="mb-4 rounded-xl border border-border bg-surface p-4">
      <div className="flex flex-wrap items-center gap-3">
        <Cpu className="h-4 w-4 shrink-0 text-accent" />
        <div className="min-w-0 flex-1">
          <div className="text-sm font-semibold">Keep working with the app closed</div>
          <div className="text-xs text-text-secondary">
            Installs login agents (launchd) that keep Glyph Studio working headlessly when it is not open: self-learning (distill chats from MCP/Telegram/CLI into memory + state), domain loops, and app sync (apps refresh on their schedule). While on, the in-app distiller defers to it.
            {installed === true && " Currently running at login."}
          </div>
        </div>
        {/* B2-21: pill toggle, not On/Off text. */}
        <Toggle on={!!installed} disabled={busy || installed === null} onChange={() => void toggle()} label="Keep working with the app closed" />
      </div>
      {note && (() => {
        // The status string lists each installed launchd agent run-on:
        // "installed: sh.prevail.learn runs 'prevail daemon --learn' at login …".
        // Parse it into one clean row per agent; fall back to plain text otherwise.
        const agents: { id: string; cmd: string }[] = [];
        const re = /installed:\s*(\S+)\s+runs\s+'([^']+)'\s+at login/g;
        let m: RegExpExecArray | null;
        while ((m = re.exec(note)) !== null) agents.push({ id: m[1], cmd: m[2] });
        if (agents.length === 0) {
          return <div className="mt-2 break-words text-[12px] text-text-secondary">{note}</div>;
        }
        return (
          <div className="mt-3 border-t border-border-subtle pt-2.5">
            <div className="mb-1.5 text-[12px] text-text-muted">Login agents · {agents.length}</div>
            <div className="flex flex-col gap-1">
              {agents.map((a) => (
                <div key={a.id} className="flex items-center gap-2 text-[12px]">
                  <span className="h-1.5 w-1.5 shrink-0 rounded-full bg-ok" />
                  <span className="shrink-0 text-text-secondary">{a.id}</span>
                  <code className="min-w-0 flex-1 truncate text-text-muted">{a.cmd}</code>
                  <span className="shrink-0 text-[12px] text-text-muted/70">At login</span>
                </div>
              ))}
            </div>
          </div>
        );
      })()}
    </div>
  );
}

export function SettingsRowLite({ title, desc, control }: { title: string; desc?: string; control: React.ReactNode }) {
  return (
    <div className="flex items-center justify-between gap-6 border-b border-border-subtle py-3.5 last:border-0">
      <div className="min-w-0 flex-1">
        <div className="text-sm font-semibold text-text-primary">{title}</div>
        {desc && <div className="mt-0.5 text-xs text-text-muted">{desc}</div>}
      </div>
      <div className="shrink-0">{control}</div>
    </div>
  );
}

export function AppLockCard() {
  const [lockSet, setLockSet] = useState<boolean | null>(null);
  const [value, setValue] = useState("");
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState<string | null>(null);
  const [showReset, setShowReset] = useState(false);
  const [resetConfirm, setResetConfirm] = useState("");
  useEffect(() => {
    (async () => {
      try { const s = await invoke<{ set: boolean }>("engine_lock_status"); setLockSet(!!s.set); } catch { setLockSet(false); }
    })();
  }, []);
  async function setPasscode() {
    if (value.length < 4) { setNote("Passcode must be at least 4 characters."); return; }
    setBusy(true); setNote(null);
    try {
      const r = await invoke<{ ok: boolean; error?: string }>("engine_lock_set", { passcode: value });
      if (r.ok) { setLockSet(true); setValue(""); setNote("Passcode set. You'll be asked for it next time you open Glyph Studio."); }
      else setNote(r.error ?? "Could not set passcode.");
    } catch (e) { setNote(`Failed: ${String(e)}`); } finally { setBusy(false); }
  }
  async function removePasscode() {
    setBusy(true); setNote(null);
    try {
      const r = await invoke<{ ok: boolean; error?: string }>("engine_lock_clear", { passcode: value });
      if (r.ok) { setLockSet(false); setValue(""); setNote("Passcode removed."); }
      else setNote(r.error ?? "Wrong passcode. If you forgot it, use the Reset option below.");
    } catch (e) { setNote(`Failed: ${String(e)}`); } finally { setBusy(false); }
  }
  async function resetPasscode() {
    if (resetConfirm !== "RESET") { setNote("Type RESET to confirm."); return; }
    setBusy(true); setNote(null);
    try {
      await invoke("engine_lock_reset");
      setLockSet(false); setShowReset(false); setResetConfirm("");
      setNote("App lock removed. Your vault data is unchanged. Set a new passcode below.");
    } catch (e) { setNote(`Reset failed: ${String(e)}`); } finally { setBusy(false); }
  }
  const [touchId, setTouchId] = useState(() => getPref(PREF.touchIdLock, "0") === "1");
  if (lockSet === null) return null;
  return (
    <div className="mb-4 rounded-lg border border-border bg-surface p-5">
      <div className="flex items-center gap-2 text-[14px] font-semibold text-text-primary">
        <Shield className="h-3.5 w-3.5" /> App lock {lockSet ? "· on" : "· off"}
      </div>
      <p className="mt-2 text-xs text-text-muted">
        Require a passcode to open Glyph Studio. This locks the app window. It does <span className="font-semibold">not</span> encrypt your vault files on disk.
      </p>
      <div className="mt-3 flex items-center gap-2">
        <input
          type="password"
          value={value}
          onChange={(e) => setValue(e.target.value)}
          onKeyDown={(e) => { if (e.key === "Enter") { if (lockSet) void removePasscode(); else void setPasscode(); } }}
          placeholder={lockSet ? "Current passcode" : "New passcode (min 4 chars)"}
          className="w-56 rounded-md border border-border bg-background px-3 py-1.5 text-sm focus:border-accent-border focus:outline-none"
        />
        {lockSet ? (
          <button onClick={removePasscode} disabled={busy || !value} className="inline-flex items-center gap-2 rounded-md border border-border bg-background px-3 py-1.5 text-sm hover:bg-surface-warm disabled:opacity-50">
            {busy ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : null} Remove passcode
          </button>
        ) : (
          <button onClick={setPasscode} disabled={busy || value.length < 4} className="inline-flex items-center gap-2 rounded-md border border-accent-border bg-accent px-3 py-1.5 text-sm text-background hover:opacity-90 disabled:opacity-50">
            {busy ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : null} Set passcode
          </button>
        )}
      </div>
      {lockSet && (
        <>
          <label className="mt-3 flex items-center gap-2 text-xs text-text-secondary">
            <input
              type="checkbox"
              checked={touchId}
              onChange={(e) => { setTouchId(e.target.checked); setPref(PREF.touchIdLock, e.target.checked ? "1" : "0"); }}
            />
            Offer Touch ID on the lock screen. The passcode path is always available independently.
          </label>
          {touchId && (
            <div className="mt-2 rounded-md border border-warn/30 bg-warn/5 px-3 py-2 text-[12px] text-warn">
              Known issue: in some cases enabling Touch ID may affect passcode verification. If your passcode stops working, use the Reset option below to remove the lock without entering the passcode.
            </div>
          )}
          <button
            onClick={() => setShowReset((v) => !v)}
            className="mt-2 text-xs text-text-muted underline decoration-dotted hover:text-text-secondary"
          >
            Forgot passcode? Reset app lock.
          </button>
          {showReset && (
            <div className="mt-2 rounded-md border border-warn/30 bg-warn/5 px-3 py-3">
              <div className="mb-2 text-xs text-text-secondary">
                Resetting removes the app lock entirely. Your vault data is <span className="font-semibold">not</span> affected. Type <code className="font-mono text-warn">RESET</code> to confirm.
              </div>
              <div className="flex items-center gap-2">
                <input
                  value={resetConfirm}
                  onChange={(e) => setResetConfirm(e.target.value)}
                  placeholder="Type RESET"
                  className="w-32 rounded border border-warn/40 bg-background px-2 py-1 text-xs focus:outline-none"
                />
                <button
                  onClick={resetPasscode}
                  disabled={busy || resetConfirm !== "RESET"}
                  className="rounded border border-warn/40 bg-warn/10 px-3 py-1 text-xs text-warn hover:bg-warn/20 disabled:opacity-50"
                >
                  {busy ? "Resetting…" : "Reset lock"}
                </button>
              </div>
            </div>
          )}
        </>
      )}
      {note && <div className="mt-2 text-xs text-text-secondary">{note}</div>}
    </div>
  );
}

export function GatewayMark({ icon, mono }: { icon?: { path: string; hex: string }; mono?: typeof Mail }) {
  const Mono = mono;
  return (
    <span
      className="flex h-9 w-9 shrink-0 items-center justify-center rounded-lg border border-border-subtle"
      style={icon ? { background: `#${icon.hex}1f`, color: `#${icon.hex}` } : undefined}
    >
      {icon ? (
        <svg width={18} height={18} viewBox="0 0 24 24" fill={`#${icon.hex}`} aria-hidden>
          <path d={icon.path} />
        </svg>
      ) : Mono ? (
        <Mono className="h-[18px] w-[18px] text-text-muted" />
      ) : null}
    </span>
  );
}

export function AlignmentCard({ vaultPath }: { vaultPath: string }) {
  const [rep, setRep] = useState<AlignmentReport | null>(null);
  const [loading, setLoading] = useState(false);
  async function refresh() {
    setLoading(true);
    try { setRep(await invoke<AlignmentReport>("engine_alignment", { vault: vaultPath })); }
    catch { /* alignment optional */ }
    setLoading(false);
  }
  useEffect(() => { void refresh(); /* eslint-disable-next-line react-hooks/exhaustive-deps */ }, [vaultPath]);
  if (!rep || rep.pillars.length === 0) return null;
  const tint = (s: number) => (s >= 70 ? "#2fb87a" : s >= 40 ? "#e8913a" : "#e06c75");
  const overallTint = tint(rep.overall);
  const verdict = rep.overall >= 70 ? "On track" : rep.overall >= 40 ? "Drifting" : "Off course";
  return (
    <div className="mb-5 rounded-xl border border-border bg-surface p-5 shadow-sm">
      {/* IDEAL-1: a circular gauge for the overall score reads far more premium
          than a bare number; pillars below are a clean labelled bar list. */}
      <div className="flex items-center gap-4">
        <div className="relative h-16 w-16 shrink-0">
          <svg viewBox="0 0 36 36" className="h-16 w-16 -rotate-90">
            <circle cx="18" cy="18" r="15.9155" fill="none" stroke="var(--color-surface-warm, #eee)" strokeWidth="3.2" />
            <circle cx="18" cy="18" r="15.9155" fill="none" stroke={overallTint} strokeWidth="3.2" strokeLinecap="round"
              pathLength={100} strokeDasharray={`${rep.overall} 100`} className="transition-all duration-500" />
          </svg>
          <div className="absolute inset-0 flex flex-col items-center justify-center">
            <span className="text-lg font-bold leading-none" style={{ color: overallTint }}>{rep.overall}</span>
            <span className="text-[12px] text-text-muted">/100</span>
          </div>
        </div>
        <div className="min-w-0 flex-1">
          <div className="flex items-center gap-2">
            <span className="text-base font-semibold">Alignment</span>
            <span className="rounded-full px-2 py-0.5 text-[12px] font-bold tracking-wider" style={{ backgroundColor: `${overallTint}1f`, color: overallTint }}>{verdict}</span>
          </div>
          <p className="mt-0.5 text-xs text-text-secondary">How close your life is tracking to your Ideal State · {rep.method === "model" ? "model-scored" : "signal-based"}</p>
        </div>
        <button onClick={refresh} disabled={loading} title="Refresh" aria-label="Refresh alignment" className="flex h-8 w-8 shrink-0 items-center justify-center self-start rounded-md text-text-muted transition-colors hover:bg-surface-warm hover:text-accent disabled:opacity-50">
          {loading ? <Loader2 className="h-4 w-4 animate-spin" /> : <RefreshCw className="h-4 w-4" />}
        </button>
      </div>
      <div className="mt-4 space-y-2.5">
        {rep.pillars.map((p) => (
          <div key={p.pillar} className="flex items-center gap-3">
            <span className="w-28 shrink-0 truncate text-xs font-medium text-text-secondary">{p.pillar}</span>
            <div className="h-2 flex-1 overflow-hidden rounded-full bg-surface-warm">
              <div className="h-full rounded-full transition-all duration-500" style={{ width: `${p.score}%`, backgroundColor: tint(p.score) }} />
            </div>
            <span className="w-9 shrink-0 text-right text-xs font-semibold" style={{ color: tint(p.score) }}>{p.score}</span>
          </div>
        ))}
      </div>
      {rep.actions.length > 0 && (
        <div className="mt-4">
          <div className="mb-2 text-[13px] font-semibold text-text-secondary">Top actions to close the gap</div>
          {/* B2-9: each action is a clickable card that opens the relevant domain.
              "Strengthen <domain>: <detail>" -> bold domain + quiet detail + arrow. */}
          <div className="flex flex-col gap-1.5">
            {rep.actions.map((raw, i) => {
              // The engine writes "N open loop(s)"; say it properly.
              const a = raw.replace(/\b(\d+) open loop\(s\)/g, (_m, n: string) => `${n} open ${n === "1" ? "loop" : "loops"}`);
              const m = a.match(/^\s*strengthen\s+([^:]+):\s*(.*)$/i);
              const domain = m ? m[1].trim() : null;
              const detail = m ? m[2].trim() : a;
              return (
                <button
                  key={i}
                  onClick={() => { if (domain) window.dispatchEvent(new CustomEvent("prevail:open-domain", { detail: domain.toLowerCase() })); }}
                  disabled={!domain}
                  title={domain ? `Open ${titleCase(domain)} to act on this` : a}
                  className="group flex items-center gap-2.5 rounded-lg border border-border-subtle bg-background px-3 py-2 text-left transition-colors enabled:hover:border-accent-border enabled:hover:bg-surface-warm disabled:cursor-default"
                >
                  <span className="flex h-5 w-5 shrink-0 items-center justify-center rounded-full bg-accent-soft text-[12px] font-semibold text-accent">{i + 1}</span>
                  <span className="min-w-0 flex-1">
                    {domain
                      ? <><span className="text-xs font-semibold text-text-primary">Strengthen {titleCase(domain)}</span><span className="ml-1 text-[12px] text-text-muted">{detail}</span></>
                      : <span className="text-xs text-text-secondary">{a}</span>}
                  </span>
                  {domain && <ArrowRight className="h-3.5 w-3.5 shrink-0 text-text-muted transition-colors group-hover:text-accent" />}
                </button>
              );
            })}
          </div>
        </div>
      )}
    </div>
  );
}

export function PreambleCard({
  option,
  on,
  onSelect,
}: {
  option: PreambleOption;
  on: boolean;
  onSelect: () => void;
}) {
  const [open, setOpen] = useState(on);
  useEffect(() => { if (!on) setOpen(false); }, [on]);
  return (
    <div
      className={`rounded-lg border transition-colors ${
        on ? "border-accent-border bg-accent-soft" : "border-border bg-surface"
      }`}
    >
      {/* Picking one IS the interaction, so the row does it. Eighteen rows each
          carrying their own "set default" button was eighteen buttons to say
          what a click on the row says; the chevron alone opens the preamble. */}
      <div className="flex items-start gap-2 p-3">
        <button
          onClick={onSelect}
          aria-pressed={on}
          title={on ? `${option.label} is the default` : `Use ${option.label} by default`}
          className="flex min-w-0 flex-1 items-start gap-2 text-left"
        >
          <span className="mt-0.5 flex h-4 w-4 shrink-0 items-center justify-center">
            {on
              ? <Check className="h-4 w-4 text-accent" strokeWidth={3} />
              : <span className="h-2 w-2 rounded-full ring-1 ring-border" />}
          </span>
          <div className="min-w-0 flex-1">
            <div className="flex flex-wrap items-baseline gap-x-2">
              <span className={`font-mono text-sm font-semibold ${on ? "text-accent" : "text-text-primary"}`}>
                {option.label}
              </span>
              <span className="text-xs text-text-muted">{option.blurb}</span>
            </div>
          </div>
        </button>
        <button
          onClick={() => setOpen((v) => !v)}
          aria-expanded={open}
          aria-label={open ? `Hide ${option.label}'s preamble` : `Show ${option.label}'s preamble`}
          className="shrink-0 rounded p-1 text-text-muted transition-colors hover:text-accent"
        >
          <ChevronRight className={`h-4 w-4 transition-transform ${open ? "rotate-90" : ""}`} />
        </button>
      </div>
      {open && (
        <div className="border-t border-border-subtle py-2 pl-8 pr-3">
          {option.instruction ? (
            <pre className="whitespace-pre-wrap rounded border border-border-subtle bg-background px-3 py-2 font-mono text-[12px] leading-relaxed text-text-secondary">
              {option.instruction}
            </pre>
          ) : (
            <p className="text-xs italic text-text-muted">no preamble: uses the model's default response shape</p>
          )}
        </div>
      )}
    </div>
  );
}

export function WhatsAppCard() {
  const [number, setNumber] = useState(lsGet(LS.whatsappNumber));
  useEffect(() => { lsSet(LS.whatsappNumber, number); }, [number]);
  return (
    <div className="rounded-xl border border-border bg-surface p-5">
      <div className="flex items-center gap-3">
        <div className="flex h-10 w-10 items-center justify-center rounded-lg bg-[#25D366]/15">
          <svg width={20} height={20} viewBox="0 0 24 24" fill="#25D366" aria-hidden><path d={siWhatsapp.path} /></svg>
        </div>
        <div>
          <h3 className="font-semibold">
            WhatsApp <span className="ml-2 rounded bg-warn/15 px-1.5 py-0.5 text-[12px] text-warn">Soon</span>
          </h3>
          <p className="text-xs text-text-muted">Same idea as Telegram, via WhatsApp Cloud API. Setup pending Meta business approval.</p>
        </div>
      </div>
      <div className="mt-4">
        <label className="block">
          <div className="text-xs text-text-muted">Your number (E.164)</div>
          <input
            value={number}
            onChange={(e) => setNumber(e.target.value)}
            placeholder="+14155552671"
            className="mt-1 w-full rounded border border-border bg-background px-3 py-2 font-mono text-sm"
            spellCheck={false}
          />
        </label>
        <p className="mt-3 text-xs text-text-muted">
          We'll email you when WhatsApp Cloud API hookup ships. Until then, this is just stored locally for when it's ready.
        </p>
      </div>
    </div>
  );
}
