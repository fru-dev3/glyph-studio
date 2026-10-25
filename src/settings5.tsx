// Settings sections extracted from App.tsx: Gateways (Telegram/WhatsApp + the
// coming-soon roster), MCP (server config + the McpCard verifier), and About
// (version, update check, changelog).
import { useEffect, useState } from "react";
import { GlyphStudioLogo } from "./GlyphStudioLogo";
import { confirm as tauriConfirm, open, save } from "@tauri-apps/plugin-dialog";
import { check as checkUpdate, type Update } from "@tauri-apps/plugin-updater";
import { relaunch } from "@tauri-apps/plugin-process";
import { Check, ChevronRight, Folder, Github, Loader2, Mail, MessageSquare, MessagesSquare, Network, Radio, Send, Sparkles, Star, Webhook, Wrench, Zap } from "lucide-react";
import { siDiscord, siMatrix, siMattermost, siSignal, siTelegram } from "simple-icons";
import { invoke, listen } from "./bridge";
import { CollapsibleSection } from "./collapsible";
import { APP_VERSION, SETTINGS_ROW } from "./constants";
import { modelsFor } from "./helpers2";
import { LS, isBunkerOn, lsGet, lsSet } from "./storage";
import { Toggle } from "./ui";
import { GatewayMark, WhatsAppCard } from "./panels";
import { SettingsHeader, mcpCommandPath } from "./sectionutil";
import { compareSemver } from "./textutil";
import { useCliVerifyLive } from "./verify";
import { BrandMark } from "./brandmark";
import type { CliInfo, DiagCheck, TgBridgeStatus } from "./types";
import type { UnlistenFn } from "./bridge";
import { invokeCached } from "./query";
import { isUserDomain } from "./helpers";

export const COMING_SOON_GATEWAYS: { name: string; icon?: { path: string; hex: string }; mono?: typeof Mail }[] = [
  // Telegram, Webhook, Matrix, Mattermost, Signal, Discord, Slack, Email are all
  // native now. SMS is inbound-webhook-based: a Twilio Function forwards to the
  // Webhook's /hook (no native bridge needed).
  { name: "SMS (Twilio)", mono: MessageSquare },
];

// U2: Gateway is the single, self-contained section (owns its header) - folds in
// the former "Integrations" bridge cards (A1) without the earlier double header /
// double Telegram-card bug. Live bridges first, then coming-soon, evenly gridded.

// BP2: persistent gateway activity log (kept on disk; survives restart).
export function GatewayLogsCard({ vaultPath }: { vaultPath: string }) {
  const [lines, setLines] = useState<string[]>([]);
  const [open, setOpen] = useState(false);
  const load = () => { invoke<string[]>("gateway_log_read", { vault: vaultPath, limit: 300 }).then((l) => setLines(Array.isArray(l) ? l : [])).catch(() => setLines([])); };
  useEffect(() => { if (open) load(); /* eslint-disable-next-line react-hooks/exhaustive-deps */ }, [open, vaultPath]);
  return (
    <div className="mt-6 ">
      <button onClick={() => setOpen((v) => !v)} className="flex w-full items-center gap-2 px-4 py-3 text-left">
        <ChevronRight className={`h-3.5 w-3.5 shrink-0 text-text-muted transition-transform ${open ? "rotate-90" : ""}`} />
        <span className="text-sm font-semibold">Gateway logs</span>
        <span className="rounded-full bg-surface-warm px-2 py-0.5 text-[12px] text-text-secondary">{lines.length}</span>
        <span className="ml-auto text-[12px] text-text-muted">Kept on disk</span>
      </button>
      {open && (
        <div className="border-t border-border-subtle p-3">
          <div className="mb-2 flex items-center gap-2">
            <button onClick={load} className="rounded-md border border-border px-2.5 py-1 text-[12px] text-text-secondary hover:border-accent-border hover:text-accent">Refresh</button>
            <button onClick={() => { invoke("gateway_log_clear", { vault: vaultPath }).then(load).catch(() => {}); }} className="rounded-md border border-border px-2.5 py-1 text-[12px] text-text-muted hover:border-err hover:text-err">Clear</button>
          </div>
          {lines.length === 0
            ? <div className="px-1 py-2 text-xs text-text-muted">No gateway activity logged yet. Start a bridge (Telegram, etc.) and events appear here, kept across restarts.</div>
            : <pre className="max-h-72 overflow-auto rounded-md border border-border-subtle bg-background p-2 text-[12px] leading-relaxed text-text-secondary">{lines.join("\n")}</pre>}
        </div>
      )}
    </div>
  );
}

export function GatewaySection() {
  const [liveTg, setLiveTg] = useState(false);
  const liveWa = false;
  useEffect(() => {
    let alive = true;
    const check = async () => {
      try { const t = await invoke<{ running: boolean }>("telegram_bridge_status"); if (alive) setLiveTg(!!t.running); } catch { if (alive) setLiveTg(false); }
    };
    void check();
    const id = window.setInterval(() => void check(), 8000);
    return () => { alive = false; window.clearInterval(id); };
  }, []);
  const anyLive = liveTg || liveWa;
  return (
    <>
      <SettingsHeader title="Gateway" icon={MessagesSquare} subtitle="Reach your council from anywhere." />

      <div>
        <CollapsibleSection
          icon={Radio}
          title="Bridges"
          subtitle="Two-way relays: message your council from another app."
          summary={anyLive ? `live${liveTg ? " · Telegram" : ""}` : "Telegram, WhatsApp"}
          status={anyLive}
          defaultOpen={anyLive}
        >
          <div className="space-y-4">
            <TelegramCard />
            <WebhookCard />
            <NativeBridgeCard platform="matrix" label="Matrix" icon={siMatrix}
              urlLabel="Homeserver" urlPlaceholder="https://matrix.org"
              channelLabel="Room ID" channelPlaceholder="!abc123:matrix.org" />
            <NativeBridgeCard platform="mattermost" label="Mattermost" icon={siMattermost}
              urlLabel="Server URL" urlPlaceholder="https://chat.example.com"
              channelLabel="Channel ID" channelPlaceholder="channel id" />
            <NativeBridgeCard platform="signal" label="Signal" icon={siSignal} noToken
              urlLabel="Account" urlPlaceholder="+15551234567"
              channelLabel="Recipient" channelPlaceholder="+15559876543" />
            <DiscordCard />
            <SlackCard />
            <EmailCard />
            <WhatsAppCard />
          </div>
        </CollapsibleSection>

        <CollapsibleSection
          icon={Sparkles}
          title="More surfaces"
          subtitle="More bridges on the way."
          summary={`${COMING_SOON_GATEWAYS.length} native pending`}
        >
          <div className="mb-3 rounded-md border border-accent-border/40 bg-accent-soft/20 px-3 py-2 text-xs text-text-secondary">
            Reachable now: point any of these at the <span className="font-semibold text-accent">Webhook</span> above
            (Zapier, n8n, a Twilio Function, or a few lines of glue forward the message to <span className="font-mono">/hook</span>).
            The rows below are the native, in-app bridges still to come.
          </div>
          <div className="space-y-1">
            {COMING_SOON_GATEWAYS.map((g) => (
              <div key={g.name} className={SETTINGS_ROW}>
                <GatewayMark icon={g.icon} mono={g.mono} />
                <span className="flex-1 text-sm text-text-secondary">{g.name}</span>
                <span className="font-mono text-[12px] text-text-muted">Native pending</span>
              </div>
            ))}
          </div>
        </CollapsibleSection>
      </div>
    </>
  );
}

export function TelegramCard() {
  // Audit #7: the bot token is a secret - it lives in the Keychain, never in
  // localStorage. `token` is a transient input value only; `tokenSaved` reflects
  // whether a token exists in the Keychain. chatId is just an identifier (not a
  // secret), so it stays in localStorage.
  const [token, setToken] = useState("");
  const [tokenSaved, setTokenSaved] = useState(false);
  const [chatId, setChatId] = useState(lsGet(LS.telegramChatId));
  const [bridgeCli, setBridgeCli] = useState(lsGet("prevail.telegram.cli") || "claude");
  const [bridgeModel, setBridgeModel] = useState(lsGet("prevail.telegram.model"));
  // Only route to providers that are detected AND validated (the user asked for
  // the dropdown to list "the ones that have been validated and are actually
  // active"). cliVerifyLive is the app-wide validation map.
  const verify = useCliVerifyLive();
  const [tgClis, setTgClis] = useState<CliInfo[]>([]);
  useEffect(() => { invokeCached<CliInfo[]>("detect_clis").then((v) => setTgClis(Array.isArray(v) ? v : [])).catch(() => {}); }, []);
  const routableClis = tgClis.filter((c) => c.available && verify.get(c.id)?.status !== "failed");
  // Keep the selection valid: if the chosen CLI isn't routable, fall back.
  useEffect(() => {
    if (routableClis.length > 0 && !routableClis.some((c) => c.id === bridgeCli)) {
      setBridgeCli(routableClis[0].id);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [tgClis, verify]);
  const [status, setStatus] = useState<{ kind: "idle" | "ok" | "err"; msg: string }>({ kind: "idle", msg: "" });
  const [bridge, setBridge] = useState<TgBridgeStatus | null>(null);
  const [feed, setFeed] = useState<Array<{ dir: "in" | "out"; text: string; ts: number }>>([]);

  // On mount: migrate any legacy localStorage token into the Keychain (then wipe
  // it), and reflect whether a token is configured.
  useEffect(() => {
    (async () => {
      try {
        const legacy = lsGet(LS.telegramToken);
        if (legacy && legacy.trim()) {
          await invoke("provider_key_set", { provider: "telegram", key: legacy.trim() });
          lsSet(LS.telegramToken, ""); // wipe the plaintext secret from localStorage
        }
        const ok = await invoke<boolean>("provider_key_exists", { provider: "telegram" });
        setTokenSaved(!!ok);
      } catch { /* keychain unavailable: leave unconfigured */ }
    })();
  }, []);
  useEffect(() => { lsSet(LS.telegramChatId, chatId); }, [chatId]);
  useEffect(() => { lsSet("prevail.telegram.cli", bridgeCli); }, [bridgeCli]);
  useEffect(() => { lsSet("prevail.telegram.model", bridgeModel); }, [bridgeModel]);

  async function refreshStatus() {
    try {
      const s = await invoke<TgBridgeStatus>("telegram_bridge_status");
      setBridge(s);
    } catch { /* ignore */ }
  }
  useEffect(() => {
    void refreshStatus();
    const id = window.setInterval(() => void refreshStatus(), 3000);
    let u1: UnlistenFn | null = null;
    let u2: UnlistenFn | null = null;
    (async () => {
      u1 = await listen<{ text: string }>("tg:message_in", (e) => {
        setFeed((cur) => [...cur.slice(-19), { dir: "in", text: e.payload.text, ts: Date.now() }]);
      });
      u2 = await listen<{ text: string }>("tg:message_out", (e) => {
        setFeed((cur) => [...cur.slice(-19), { dir: "out", text: e.payload.text, ts: Date.now() }]);
      });
    })();
    return () => { window.clearInterval(id); if (u1) u1(); if (u2) u2(); };
  }, []);

  async function startBridge() {
    if (!chatId.trim() || (!token.trim() && !tokenSaved)) {
      setStatus({ kind: "err", msg: "fill in token + chat ID first" });
      return;
    }
    try {
      // If a new token was typed, persist it to the Keychain (and clear the
      // input); otherwise the bridge resolves the saved token server-side.
      if (token.trim()) {
        await invoke("provider_key_set", { provider: "telegram", key: token.trim() });
        setTokenSaved(true);
        setToken("");
      }
      // Routing table: every vault domain plus its stored/derived keywords,
      // so a "wealth" question from Telegram lands in the wealth domain with
      // a recorded thread.
      let routes: { domain: string; keywords: string[] }[] = [];
      let vault: string | null = null;
      try {
        vault = lsGet(LS.vault) || null;
        if (vault) {
          const ds = await invoke<{ name: string }[]>("scan_vault", { path: vault });
          routes = ds.filter((d) => isUserDomain(d.name)).map((d) => ({
            domain: d.name,
            keywords: (lsGet(`prevail.domain.${d.name}.routing.keywords`) || "")
              .split(",").map((s) => s.trim()).filter(Boolean),
          }));
        }
      } catch { /* routing is best-effort; bridge works without it */ }
      await invoke("telegram_bridge_start", {
        cfg: {
          token: "", // bridge reads the secret from the Keychain
          chat_id: chatId.trim(),
          cli: bridgeCli,
          model: bridgeModel || null,
          domain: null,
          vault,
          routes,
        },
      });
      await refreshStatus();
    } catch (e) {
      setStatus({ kind: "err", msg: String(e) });
    }
  }
  async function stopBridge() {
    try {
      await invoke("telegram_bridge_stop");
      await refreshStatus();
    } catch (e) {
      setStatus({ kind: "err", msg: String(e) });
    }
  }

  async function testSend() {
    if (!chatId || (!token.trim() && !tokenSaved)) {
      setStatus({ kind: "err", msg: "fill in token + chat ID first" });
      return;
    }
    // If a fresh token was typed, save it first so Test uses the same secret.
    if (token.trim()) {
      try { await invoke("provider_key_set", { provider: "telegram", key: token.trim() }); setTokenSaved(true); setToken(""); } catch { /* ignore */ }
    }
    setStatus({ kind: "idle", msg: "sending…" });
    try {
      const r = await invoke<{ ok: boolean; description?: string }>("telegram_send", {
        token: "", chatId, text: "◆ Glyph Studio · test message ✓",
      });
      if (r.ok) {
        setStatus({ kind: "ok", msg: "delivered ✓" });
      } else {
        setStatus({ kind: "err", msg: r.description ?? "send failed" });
      }
    } catch (e) {
      setStatus({ kind: "err", msg: String(e) });
    }
  }

  const ready = !!chatId.trim() && (!!token.trim() || tokenSaved);
  return (
    // TG-1: cleaner top-to-bottom flow - header carries the live status; setup
    // (credentials + routing) is one labelled block; one primary action row;
    // running stats + feed only appear when relevant; help is a quiet footer.
    <div className="border-t border-border-subtle pt-4">
      <div className="flex items-center gap-3">
        <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-lg bg-[#229ED9]/15">
          <svg width={20} height={20} viewBox="0 0 24 24" fill="#229ED9" aria-hidden><path d={siTelegram.path} /></svg>
        </div>
        <div className="min-w-0 flex-1">
          <h3 className="font-semibold">Telegram bridge</h3>
          <p className="text-xs text-text-muted">Two-way chat: messages to your bot route to the chosen model and the reply is pushed back.</p>
        </div>
        <span className={`shrink-0 self-start rounded-full px-2 py-0.5 text-[12px] ${
          bridge?.running ? "border border-accent-border bg-accent-soft text-accent" : "border border-border bg-background text-text-muted"
        }`}>
          {bridge?.running ? "● live" : "○ stopped"}
        </span>
      </div>

      <div className="mt-4 space-y-4">
        {/* Step 1 - credentials + routing, one premium setup block. */}
        <div className="rounded-lg border border-border bg-background p-4">
          <div className="space-y-3">
            <label className="block">
              <div className="flex items-center gap-2 text-[12px] text-text-muted">
                Bot token
                {tokenSaved && <span className="rounded-full bg-accent-soft px-1.5 py-0 font-mono text-[12px] tracking-wider text-accent">In keychain</span>}
              </div>
              <input type="password" value={token} onChange={(e) => setToken(e.target.value)}
                placeholder={tokenSaved ? "•••••••• (type to replace)" : "123456:ABC-XYZ…"}
                className="mt-1 w-full rounded border border-border bg-surface px-3 py-2 font-mono text-sm focus:border-accent-border focus:outline-none" spellCheck={false} />
            </label>
            <label className="block">
              <div className="text-[12px] text-text-muted">Chat ID</div>
              <input value={chatId} onChange={(e) => setChatId(e.target.value)} placeholder="-1001234567890"
                className="mt-1 w-full rounded border border-border bg-surface px-3 py-2 font-mono text-sm focus:border-accent-border focus:outline-none" spellCheck={false} />
            </label>
            <label className="block">
              <div className="text-[12px] text-text-muted">Route to model</div>
              <select value={bridgeCli} onChange={(e) => setBridgeCli(e.target.value)}
                className="mt-1 w-full rounded border border-border bg-surface px-2 py-2 text-sm focus:border-accent-border focus:outline-none">
                {routableClis.length === 0 ? (
                  <option value="">No validated provider; set one in Models</option>
                ) : (
                  routableClis.map((c) => (
                    <option key={c.id} value={c.id}>{c.label}{verify.get(c.id)?.status === "ok" ? " ✓" : ""}</option>
                  ))
                )}
              </select>
            </label>
            <label className="block">
              <div className="text-[12px] text-text-muted">Model</div>
              <select value={bridgeModel} onChange={(e) => setBridgeModel(e.target.value)}
                className="mt-1 w-full rounded border border-border bg-surface px-2 py-2 text-sm focus:border-accent-border focus:outline-none">
                <option value="">{`Provider default (${modelsFor(bridgeCli)[0]?.label ?? "default"})`}</option>
                {modelsFor(bridgeCli).map((m) => (<option key={m.id} value={m.id}>{m.label}</option>))}
              </select>
            </label>
          </div>
        </div>

        {/* Step 2 - one action row. P1 (Monday feedback): the bridge is an ON/Off
            toggle (was Start/Stop text); test is the secondary action. */}
        <div className="flex flex-wrap items-center gap-2">
          <label className={`inline-flex items-center gap-2 rounded-md border border-border bg-background px-3 py-2 text-sm ${ready ? "" : "opacity-50"}`} title={ready ? "Turn the bridge on/off" : "Fill in token + chat ID first"}>
            <Radio className={`h-3.5 w-3.5 ${bridge?.running ? "text-accent" : "text-text-muted"}`} />
            <span className="font-medium text-text-secondary">Bridge</span>
            <Toggle on={!!bridge?.running} onChange={(v) => { if (!ready) return; v ? void startBridge() : void stopBridge(); }} label="Telegram bridge on/off" />
          </label>
          <button onClick={testSend} disabled={!ready}
            className="inline-flex items-center gap-2 rounded-md border border-border bg-background px-3 py-2 text-sm text-text-secondary hover:border-accent-border hover:text-accent disabled:opacity-50">
            <Send className="h-3.5 w-3.5" /> Send test
          </button>
          {status.kind === "ok" && <span className="text-xs text-ok"><Check className="mr-1 inline h-3 w-3" />{status.msg}</span>}
          {status.kind === "err" && <span className="text-xs text-warn">{status.msg}</span>}
          {bridge?.running && (
            <span className="ml-auto font-mono text-[12px] text-text-muted">
              in {bridge.inbound_count} · out {bridge.outbound_count}{bridge.last_inbound_ts ? ` · last ${Math.round((Date.now() / 1000 - bridge.last_inbound_ts))}s ago` : ""}
            </span>
          )}
        </div>
        {bridge?.last_error && (
          <div className="rounded border border-warn/40 bg-warn/10 px-2 py-1 text-xs text-warn">{bridge.last_error}</div>
        )}

        {/* Live feed - only when there's traffic. */}
        {feed.length > 0 && (
          <ul className="max-h-40 overflow-y-auto rounded-lg border border-border-subtle bg-background px-2 py-1.5">
            {feed.map((f, i) => (
              <li key={i} className="font-mono text-[12px] leading-relaxed">
                <span className={f.dir === "in" ? "text-accent" : "text-text-muted"}>{f.dir === "in" ? "▶" : "◀"}</span>{" "}
                <span className={f.dir === "in" ? "text-text-primary" : "text-text-secondary"}>{f.text.slice(0, 200)}{f.text.length > 200 ? "…" : ""}</span>
              </li>
            ))}
          </ul>
        )}

        {/* Quiet footer: routing + setup help. */}
        <p className="text-[12px] leading-relaxed text-text-muted">
          Inbound messages route to a domain by its keywords (set per-domain under <span className="font-mono text-text-secondary">Domain → Prefs → Channels &amp; routing</span>).
          {" "}New to bots? <a href="https://core.telegram.org/bots/features#botfather" target="_blank" rel="noreferrer" className="text-accent hover:underline">Create one via @BotFather</a>, then use getUpdates to find your chat ID.
        </p>
      </div>
    </div>
  );
}

// A6 - generic inbound Webhook surface. Credential-free (a self-generated
// secret), so it's the one bridge that's fully functional out of the box: any
// system POSTs {message} and gets the council's reply. Backend: webhook_bridge.rs.
export function WebhookCard() {
  const [secretSaved, setSecretSaved] = useState(false);
  const [port, setPort] = useState<string>(() => lsGet("prevail.webhook.port") || "8765");
  const [cli, setCli] = useState(lsGet("prevail.webhook.cli") || "claude");
  const [model, setModel] = useState(lsGet("prevail.webhook.model"));
  const verify = useCliVerifyLive();
  const [clis, setClis] = useState<CliInfo[]>([]);
  const [bridge, setBridge] = useState<TgBridgeStatus | null>(null);
  const [status, setStatus] = useState<{ kind: "idle" | "ok" | "err"; msg: string }>({ kind: "idle", msg: "" });
  const routable = clis.filter((c) => c.available && verify.get(c.id)?.status !== "failed");

  useEffect(() => { invokeCached<CliInfo[]>("detect_clis").then((v) => setClis(Array.isArray(v) ? v : [])).catch(() => {}); }, []);
  useEffect(() => { invoke<boolean>("provider_key_exists", { provider: "webhook" }).then((ok) => setSecretSaved(!!ok)).catch(() => {}); }, []);
  useEffect(() => { lsSet("prevail.webhook.port", port); }, [port]);
  useEffect(() => { lsSet("prevail.webhook.cli", cli); }, [cli]);
  useEffect(() => { lsSet("prevail.webhook.model", model); }, [model]);
  useEffect(() => {
    if (routable.length > 0 && !routable.some((c) => c.id === cli)) setCli(routable[0].id);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [clis, verify]);

  async function refresh() {
    try { setBridge(await invoke<TgBridgeStatus>("webhook_bridge_status")); } catch { /* ignore */ }
  }
  useEffect(() => {
    void refresh();
    const id = window.setInterval(() => void refresh(), 3000);
    return () => window.clearInterval(id);
  }, []);

  async function generateSecret() {
    // 32 random bytes, hex - generated in the renderer only to seed the Keychain.
    const buf = new Uint8Array(32);
    crypto.getRandomValues(buf);
    const hex = Array.from(buf).map((b) => b.toString(16).padStart(2, "0")).join("");
    try {
      await invoke("provider_key_set", { provider: "webhook", key: hex });
      setSecretSaved(true);
      setStatus({ kind: "ok", msg: "secret generated + saved to Keychain ✓" });
    } catch (e) { setStatus({ kind: "err", msg: String(e) }); }
  }

  async function toggle(on: boolean) {
    try {
      if (!on) { await invoke("webhook_bridge_stop"); await refresh(); return; }
      if (!secretSaved) { setStatus({ kind: "err", msg: "generate a secret first" }); return; }
      let routes: { domain: string; keywords: string[] }[] = [];
      let vault: string | null = null;
      try {
        vault = lsGet(LS.vault) || null;
        if (vault) {
          const ds = await invoke<{ name: string }[]>("scan_vault", { path: vault });
          routes = ds.filter((d) => isUserDomain(d.name)).map((d) => ({
            domain: d.name,
            keywords: (lsGet(`prevail.domain.${d.name}.routing.keywords`) || "").split(",").map((s) => s.trim()).filter(Boolean),
          }));
        }
      } catch { /* routing best-effort */ }
      await invoke("webhook_bridge_start", {
        cfg: { port: Number(port) || 8765, secret: "", cli, model: model || null, domain: null, vault, routes },
      });
      setStatus({ kind: "idle", msg: "" });
      await refresh();
    } catch (e) { setStatus({ kind: "err", msg: String(e) }); }
  }

  const running = !!bridge?.running;
  return (
    <div className="border-t border-border-subtle pt-4">
      <div className="flex items-center justify-between gap-3">
        <div className="flex items-center gap-2.5">
          <GatewayMark mono={Webhook} />
          <div>
            <div className="text-sm font-semibold text-text-primary">Webhook</div>
            <div className="text-xs text-text-muted">Any system POSTs a message, gets the council's reply. No platform account needed.</div>
          </div>
        </div>
        <Toggle on={running} onChange={(v) => void toggle(v)} disabled={!secretSaved} label={running ? "On" : "Off"} />
      </div>

      <div className="mt-3 grid grid-cols-[auto_1fr] items-center gap-x-3 gap-y-2 text-xs">
        <span className="text-text-muted">Port</span>
        <input value={port} onChange={(e) => setPort(e.target.value.replace(/[^0-9]/g, ""))} disabled={running}
          className="w-24 rounded-md border border-border bg-background px-2 py-1 focus:border-accent-border focus:outline-none disabled:opacity-60" />
        <span className="text-text-muted">Model</span>
        <div className="flex items-center gap-2">
          <select value={cli} onChange={(e) => setCli(e.target.value)} disabled={running}
            className="rounded-md border border-border bg-background px-2 py-1 focus:border-accent-border focus:outline-none disabled:opacity-60">
            {routable.length === 0 ? <option value={cli}>{cli}</option> : routable.map((c) => <option key={c.id} value={c.id}>{c.id}</option>)}
          </select>
          <input value={model} onChange={(e) => setModel(e.target.value)} placeholder="model (optional)" disabled={running}
            className="flex-1 rounded-md border border-border bg-background px-2 py-1 focus:border-accent-border focus:outline-none disabled:opacity-60" />
        </div>
        <span className="text-text-muted">Secret</span>
        <div className="flex items-center gap-2">
          <span className={secretSaved ? "text-ok" : "text-text-muted"}>{secretSaved ? "✓ stored in Keychain" : "none yet"}</span>
          <button onClick={generateSecret} disabled={running}
            className="rounded border border-border px-2 py-0.5 text-[12px] text-text-secondary hover:border-accent-border hover:text-accent disabled:opacity-50">
            {secretSaved ? "regenerate" : "generate"}
          </button>
        </div>
      </div>

      <div className="mt-3 rounded-md border border-border-subtle bg-background px-3 py-2 text-[12px] text-text-muted">
        curl -s 127.0.0.1:{port || "8765"}/hook -H "Authorization: Bearer &lt;secret&gt;" \<br />
        &nbsp;&nbsp;-d '{`{"message":"how's my runway?","domain":"wealth"}`}'
      </div>
      {running && bridge && (
        <div className="mt-2 font-mono text-[12px] text-text-muted">in {bridge.inbound_count ?? 0} · out {bridge.outbound_count ?? 0}{bridge.last_error ? ` · err: ${bridge.last_error.slice(0, 50)}` : ""}</div>
      )}
      {status.msg && <div className={`mt-2 text-xs ${status.kind === "err" ? "text-err" : status.kind === "ok" ? "text-ok" : "text-text-muted"}`}>{status.msg}</div>}
    </div>
  );
}

// A6 - native poll bridges (Matrix, Mattermost). Two-way relays over HTTP polling
// (no WebSocket), backend: native_bridge.rs. Off by default; inert until the user
// fills in server + token + channel and toggles it on.
export function NativeBridgeCard({ platform, label, icon, mono, urlLabel, urlPlaceholder, channelLabel, channelPlaceholder, noToken }: {
  platform: "matrix" | "mattermost" | "signal"; label: string; icon?: { path: string; hex: string }; mono?: typeof Mail;
  urlLabel: string; urlPlaceholder: string; channelLabel: string; channelPlaceholder: string; noToken?: boolean;
}) {
  const provider = `native-${platform}`;
  const [baseUrl, setBaseUrl] = useState(lsGet(`prevail.native.${platform}.url`));
  const [channel, setChannel] = useState(lsGet(`prevail.native.${platform}.channel`));
  const [token, setToken] = useState("");
  const [tokenSaved, setTokenSaved] = useState(false);
  const [cli, setCli] = useState(lsGet(`prevail.native.${platform}.cli`) || "claude");
  const verify = useCliVerifyLive();
  const [clis, setClis] = useState<CliInfo[]>([]);
  const [bridge, setBridge] = useState<TgBridgeStatus | null>(null);
  const [status, setStatus] = useState<{ kind: "idle" | "ok" | "err"; msg: string }>({ kind: "idle", msg: "" });
  const routable = clis.filter((c) => c.available && verify.get(c.id)?.status !== "failed");

  useEffect(() => { invokeCached<CliInfo[]>("detect_clis").then((v) => setClis(Array.isArray(v) ? v : [])).catch(() => {}); }, []);
  useEffect(() => { invoke<boolean>("provider_key_exists", { provider }).then((ok) => setTokenSaved(!!ok)).catch(() => {}); }, [provider]);
  useEffect(() => { lsSet(`prevail.native.${platform}.url`, baseUrl); }, [baseUrl, platform]);
  useEffect(() => { lsSet(`prevail.native.${platform}.channel`, channel); }, [channel, platform]);
  useEffect(() => { lsSet(`prevail.native.${platform}.cli`, cli); }, [cli, platform]);
  useEffect(() => {
    if (routable.length > 0 && !routable.some((c) => c.id === cli)) setCli(routable[0].id);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [clis, verify]);

  async function refresh() {
    try { setBridge(await invoke<TgBridgeStatus>("native_bridge_status", { platform })); } catch { /* ignore */ }
  }
  useEffect(() => {
    void refresh();
    const id = window.setInterval(() => void refresh(), 4000);
    return () => window.clearInterval(id);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  async function toggle(on: boolean) {
    try {
      if (!on) { await invoke("native_bridge_stop", { platform }); await refresh(); return; }
      if (!baseUrl.trim() || !channel.trim() || (!noToken && !token.trim() && !tokenSaved)) {
        setStatus({ kind: "err", msg: noToken ? "fill in account and recipient first" : "fill in server, channel, and token first" });
        return;
      }
      if (!noToken && token.trim()) { await invoke("provider_key_set", { provider, key: token.trim() }); setTokenSaved(true); setToken(""); }
      let routes: { domain: string; keywords: string[] }[] = [];
      let vault: string | null = null;
      try {
        vault = lsGet(LS.vault) || null;
        if (vault) {
          const ds = await invoke<{ name: string }[]>("scan_vault", { path: vault });
          routes = ds.filter((d) => isUserDomain(d.name)).map((d) => ({ domain: d.name, keywords: (lsGet(`prevail.domain.${d.name}.routing.keywords`) || "").split(",").map((s) => s.trim()).filter(Boolean) }));
        }
      } catch { /* routing best-effort */ }
      await invoke("native_bridge_start", {
        cfg: { platform, base_url: baseUrl.trim(), token: "", channel: channel.trim(), cli, model: null, domain: null, vault, routes, poll_secs: 5 },
      });
      setStatus({ kind: "idle", msg: "" });
      await refresh();
    } catch (e) { setStatus({ kind: "err", msg: String(e) }); }
  }

  const running = !!bridge?.running;
  return (
    <div className="border-t border-border-subtle pt-4">
      <div className="flex items-center justify-between gap-3">
        <div className="flex items-center gap-2.5">
          <GatewayMark icon={icon} mono={mono} />
          <div>
            <div className="text-sm font-semibold text-text-primary">{label}</div>
            <div className="text-xs text-text-muted">Two-way relay. Message your council from {label}.</div>
          </div>
        </div>
        <Toggle on={running} onChange={(v) => void toggle(v)} disabled={!baseUrl.trim() || !channel.trim() || (!noToken && !token.trim() && !tokenSaved)} label={running ? "On" : "Off"} />
      </div>
      <div className="mt-3 grid grid-cols-[auto_1fr] items-center gap-x-3 gap-y-2 text-xs">
        <span className="text-text-muted">{urlLabel}</span>
        <input value={baseUrl} onChange={(e) => setBaseUrl(e.target.value)} placeholder={urlPlaceholder} disabled={running}
          className="rounded-md border border-border bg-background px-2 py-1 focus:border-accent-border focus:outline-none disabled:opacity-60" />
        <span className="text-text-muted">{channelLabel}</span>
        <input value={channel} onChange={(e) => setChannel(e.target.value)} placeholder={channelPlaceholder} disabled={running}
          className="rounded-md border border-border bg-background px-2 py-1 focus:border-accent-border focus:outline-none disabled:opacity-60" />
        {!noToken && <>
          <span className="text-text-muted">Token</span>
          <div className="flex items-center gap-2">
            <input type="password" value={token} onChange={(e) => setToken(e.target.value)} placeholder={tokenSaved ? "saved · replace…" : "access token"} disabled={running}
              className="flex-1 rounded-md border border-border bg-background px-2 py-1 focus:border-accent-border focus:outline-none disabled:opacity-60" />
            {tokenSaved && <span className="font-mono text-[12px] text-ok">Stored</span>}
          </div>
        </>}
        <span className="text-text-muted">Model</span>
        <select value={cli} onChange={(e) => setCli(e.target.value)} disabled={running}
          className="rounded-md border border-border bg-background px-2 py-1 focus:border-accent-border focus:outline-none disabled:opacity-60">
          {routable.length === 0 ? <option value={cli}>{cli}</option> : routable.map((c) => <option key={c.id} value={c.id}>{c.id}</option>)}
        </select>
      </div>
      {running && bridge && (
        <div className="mt-2 text-[12px] text-text-muted">in {bridge.inbound_count ?? 0} · out {bridge.outbound_count ?? 0}{bridge.last_error ? ` · err: ${bridge.last_error.slice(0, 50)}` : ""}</div>
      )}
      {status.msg && <div className={`mt-2 text-xs ${status.kind === "err" ? "text-err" : "text-text-muted"}`}>{status.msg}</div>}
    </div>
  );
}

// Shared model picker + live status footer for the WS/email bridges below.
function useBridgeCli(key: string) {
  const [cli, setCli] = useState(lsGet(key) || "claude");
  const verify = useCliVerifyLive();
  const [clis, setClis] = useState<CliInfo[]>([]);
  useEffect(() => { invokeCached<CliInfo[]>("detect_clis").then((v) => setClis(Array.isArray(v) ? v : [])).catch(() => {}); }, []);
  const routable = clis.filter((c) => c.available && verify.get(c.id)?.status !== "failed");
  useEffect(() => { lsSet(key, cli); }, [key, cli]);
  useEffect(() => { if (routable.length > 0 && !routable.some((c) => c.id === cli)) setCli(routable[0].id);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [clis, verify]);
  return { cli, setCli, routable };
}
function BridgeFooter({ bridge, status }: { bridge: TgBridgeStatus | null; status: { kind: string; msg: string } }) {
  return (<>
    {bridge?.running && <div className="mt-2 font-mono text-[12px] text-text-muted">in {bridge.inbound_count ?? 0} · out {bridge.outbound_count ?? 0}{bridge.last_error ? ` · err: ${bridge.last_error.slice(0, 50)}` : ""}</div>}
    {status.msg && <div className={`mt-2 text-xs ${status.kind === "err" ? "text-err" : "text-text-muted"}`}>{status.msg}</div>}
  </>);
}
function CliSelect({ cli, setCli, routable, disabled }: { cli: string; setCli: (v: string) => void; routable: CliInfo[]; disabled: boolean }) {
  return (
    <select value={cli} onChange={(e) => setCli(e.target.value)} disabled={disabled}
      className="rounded-md border border-border bg-background px-2 py-1 text-xs focus:border-accent-border focus:outline-none disabled:opacity-60">
      {routable.length === 0 ? <option value={cli}>{cli}</option> : routable.map((c) => <option key={c.id} value={c.id}>{c.id}</option>)}
    </select>
  );
}
const FIELD = "rounded-md border border-border bg-background px-2 py-1 text-xs focus:border-accent-border focus:outline-none disabled:opacity-60";

export function DiscordCard() {
  const [token, setToken] = useState(""); const [saved, setSaved] = useState(false);
  const [channel, setChannel] = useState(lsGet("prevail.native.discord.channel"));
  const { cli, setCli, routable } = useBridgeCli("prevail.native.discord.cli");
  const [bridge, setBridge] = useState<TgBridgeStatus | null>(null);
  const [status, setStatus] = useState<{ kind: "idle" | "ok" | "err"; msg: string }>({ kind: "idle", msg: "" });
  useEffect(() => { invoke<boolean>("provider_key_exists", { provider: "native-discord" }).then((o) => setSaved(!!o)).catch(() => {}); }, []);
  useEffect(() => { lsSet("prevail.native.discord.channel", channel); }, [channel]);
  const refresh = async () => { try { setBridge(await invoke<TgBridgeStatus>("discord_bridge_status")); } catch { /* */ } };
  useEffect(() => { void refresh(); const id = window.setInterval(() => void refresh(), 4000); return () => window.clearInterval(id); }, []);
  async function toggle(on: boolean) {
    try {
      if (!on) { await invoke("discord_bridge_stop"); await refresh(); return; }
      if (!channel.trim() || (!token.trim() && !saved)) { setStatus({ kind: "err", msg: "bot token + channel id first" }); return; }
      if (token.trim()) { await invoke("provider_key_set", { provider: "native-discord", key: token.trim() }); setSaved(true); setToken(""); }
      const vault = lsGet(LS.vault) || null;
      await invoke("discord_bridge_start", { cfg: { token: "", channel: channel.trim(), cli, model: null, domain: null, vault, routes: [] } });
      setStatus({ kind: "idle", msg: "" }); await refresh();
    } catch (e) { setStatus({ kind: "err", msg: String(e) }); }
  }
  const running = !!bridge?.running;
  return (
    <div className="border-t border-border-subtle pt-4">
      <div className="flex items-center justify-between gap-3">
        <div className="flex items-center gap-2.5"><GatewayMark icon={siDiscord} /><div>
          <div className="text-sm font-semibold text-text-primary">Discord</div>
          <div className="text-xs text-text-muted">Bot via the Discord Gateway. Message your council from a channel.</div>
        </div></div>
        <Toggle on={running} onChange={(v) => void toggle(v)} disabled={!channel.trim() || (!token.trim() && !saved)} label={running ? "On" : "Off"} />
      </div>
      <div className="mt-3 grid grid-cols-[auto_1fr] items-center gap-x-3 gap-y-2 text-xs">
        <span className="text-text-muted">Bot token</span>
        <div className="flex items-center gap-2"><input type="password" value={token} onChange={(e) => setToken(e.target.value)} placeholder={saved ? "saved · replace…" : "bot token"} disabled={running} className={`flex-1 ${FIELD}`} />{saved && <span className="font-mono text-[12px] text-ok">Stored</span>}</div>
        <span className="text-text-muted">Channel ID</span>
        <input value={channel} onChange={(e) => setChannel(e.target.value)} placeholder="123456789012345678" disabled={running} className={`font-mono ${FIELD}`} />
        <span className="text-text-muted">Model</span>
        <CliSelect cli={cli} setCli={setCli} routable={routable} disabled={running} />
      </div>
      <BridgeFooter bridge={bridge} status={status} />
    </div>
  );
}

export function SlackCard() {
  const [appTok, setAppTok] = useState(""); const [botTok, setBotTok] = useState("");
  const [appSaved, setAppSaved] = useState(false); const [botSaved, setBotSaved] = useState(false);
  const [channel, setChannel] = useState(lsGet("prevail.native.slack.channel"));
  const { cli, setCli, routable } = useBridgeCli("prevail.native.slack.cli");
  const [bridge, setBridge] = useState<TgBridgeStatus | null>(null);
  const [status, setStatus] = useState<{ kind: "idle" | "ok" | "err"; msg: string }>({ kind: "idle", msg: "" });
  useEffect(() => { invoke<boolean>("provider_key_exists", { provider: "native-slack-app" }).then((o) => setAppSaved(!!o)).catch(() => {});
    invoke<boolean>("provider_key_exists", { provider: "native-slack" }).then((o) => setBotSaved(!!o)).catch(() => {}); }, []);
  useEffect(() => { lsSet("prevail.native.slack.channel", channel); }, [channel]);
  const refresh = async () => { try { setBridge(await invoke<TgBridgeStatus>("slack_bridge_status")); } catch { /* */ } };
  useEffect(() => { void refresh(); const id = window.setInterval(() => void refresh(), 4000); return () => window.clearInterval(id); }, []);
  async function toggle(on: boolean) {
    try {
      if (!on) { await invoke("slack_bridge_stop"); await refresh(); return; }
      if (!channel.trim() || (!appTok.trim() && !appSaved) || (!botTok.trim() && !botSaved)) { setStatus({ kind: "err", msg: "app token + bot token + channel first" }); return; }
      if (appTok.trim()) { await invoke("provider_key_set", { provider: "native-slack-app", key: appTok.trim() }); setAppSaved(true); setAppTok(""); }
      if (botTok.trim()) { await invoke("provider_key_set", { provider: "native-slack", key: botTok.trim() }); setBotSaved(true); setBotTok(""); }
      const vault = lsGet(LS.vault) || null;
      await invoke("slack_bridge_start", { cfg: { app_token: "", bot_token: "", channel: channel.trim(), cli, model: null, domain: null, vault, routes: [] } });
      setStatus({ kind: "idle", msg: "" }); await refresh();
    } catch (e) { setStatus({ kind: "err", msg: String(e) }); }
  }
  const running = !!bridge?.running;
  return (
    <div className="border-t border-border-subtle pt-4">
      <div className="flex items-center justify-between gap-3">
        <div className="flex items-center gap-2.5"><GatewayMark mono={MessagesSquare} /><div>
          <div className="text-sm font-semibold text-text-primary">Slack</div>
          <div className="text-xs text-text-muted">Socket Mode (no public URL). Needs an app token + a bot token.</div>
        </div></div>
        <Toggle on={running} onChange={(v) => void toggle(v)} disabled={!channel.trim() || (!appTok.trim() && !appSaved) || (!botTok.trim() && !botSaved)} label={running ? "On" : "Off"} />
      </div>
      <div className="mt-3 grid grid-cols-[auto_1fr] items-center gap-x-3 gap-y-2 text-xs">
        <span className="text-text-muted">App token</span>
        <div className="flex items-center gap-2"><input type="password" value={appTok} onChange={(e) => setAppTok(e.target.value)} placeholder={appSaved ? "saved · replace…" : "xapp-…"} disabled={running} className={`flex-1 ${FIELD}`} />{appSaved && <span className="font-mono text-[12px] text-ok">Stored</span>}</div>
        <span className="text-text-muted">Bot token</span>
        <div className="flex items-center gap-2"><input type="password" value={botTok} onChange={(e) => setBotTok(e.target.value)} placeholder={botSaved ? "saved · replace…" : "xoxb-…"} disabled={running} className={`flex-1 ${FIELD}`} />{botSaved && <span className="font-mono text-[12px] text-ok">Stored</span>}</div>
        <span className="text-text-muted">Channel ID</span>
        <input value={channel} onChange={(e) => setChannel(e.target.value)} placeholder="C0123456789" disabled={running} className={`font-mono ${FIELD}`} />
        <span className="text-text-muted">Model</span>
        <CliSelect cli={cli} setCli={setCli} routable={routable} disabled={running} />
      </div>
      <BridgeFooter bridge={bridge} status={status} />
    </div>
  );
}

export function EmailCard() {
  const g = (k: string) => lsGet(`prevail.native.email.${k}`);
  const [imapHost, setImapHost] = useState(g("imapHost")); const [smtpHost, setSmtpHost] = useState(g("smtpHost"));
  const [username, setUsername] = useState(g("username")); const [fromAddr, setFromAddr] = useState(g("from"));
  const [password, setPassword] = useState(""); const [pwSaved, setPwSaved] = useState(false);
  const { cli, setCli, routable } = useBridgeCli("prevail.native.email.cli");
  const [bridge, setBridge] = useState<TgBridgeStatus | null>(null);
  const [status, setStatus] = useState<{ kind: "idle" | "ok" | "err"; msg: string }>({ kind: "idle", msg: "" });
  useEffect(() => { invoke<boolean>("provider_key_exists", { provider: "native-email" }).then((o) => setPwSaved(!!o)).catch(() => {}); }, []);
  useEffect(() => { lsSet("prevail.native.email.imapHost", imapHost); }, [imapHost]);
  useEffect(() => { lsSet("prevail.native.email.smtpHost", smtpHost); }, [smtpHost]);
  useEffect(() => { lsSet("prevail.native.email.username", username); }, [username]);
  useEffect(() => { lsSet("prevail.native.email.from", fromAddr); }, [fromAddr]);
  const refresh = async () => { try { setBridge(await invoke<TgBridgeStatus>("email_bridge_status")); } catch { /* */ } };
  useEffect(() => { void refresh(); const id = window.setInterval(() => void refresh(), 5000); return () => window.clearInterval(id); }, []);
  const ready = !!imapHost.trim() && !!smtpHost.trim() && !!username.trim() && !!fromAddr.trim() && (!!password.trim() || pwSaved);
  async function toggle(on: boolean) {
    try {
      if (!on) { await invoke("email_bridge_stop"); await refresh(); return; }
      if (!ready) { setStatus({ kind: "err", msg: "fill in all fields + password" }); return; }
      if (password.trim()) { await invoke("provider_key_set", { provider: "native-email", key: password.trim() }); setPwSaved(true); setPassword(""); }
      const vault = lsGet(LS.vault) || null;
      await invoke("email_bridge_start", { cfg: { imap_host: imapHost.trim(), smtp_host: smtpHost.trim(), username: username.trim(), password: "", from_addr: fromAddr.trim(), cli, model: null, domain: null, vault, routes: [], poll_secs: 20 } });
      setStatus({ kind: "idle", msg: "" }); await refresh();
    } catch (e) { setStatus({ kind: "err", msg: String(e) }); }
  }
  const running = !!bridge?.running;
  return (
    <div className="border-t border-border-subtle pt-4">
      <div className="flex items-center justify-between gap-3">
        <div className="flex items-center gap-2.5"><GatewayMark mono={Mail} /><div>
          <div className="text-sm font-semibold text-text-primary">Email</div>
          <div className="text-xs text-text-muted">IMAP poll + SMTP reply. Email your council, get a reply. (Use an app password.)</div>
        </div></div>
        <Toggle on={running} onChange={(v) => void toggle(v)} disabled={!ready} label={running ? "On" : "Off"} />
      </div>
      <div className="mt-3 grid grid-cols-[auto_1fr] items-center gap-x-3 gap-y-2 text-xs">
        <span className="text-text-muted">IMAP host</span><input value={imapHost} onChange={(e) => setImapHost(e.target.value)} placeholder="imap.gmail.com" disabled={running} className={FIELD} />
        <span className="text-text-muted">SMTP host</span><input value={smtpHost} onChange={(e) => setSmtpHost(e.target.value)} placeholder="smtp.gmail.com" disabled={running} className={FIELD} />
        <span className="text-text-muted">Username</span><input value={username} onChange={(e) => setUsername(e.target.value)} placeholder="you@gmail.com" disabled={running} className={FIELD} />
        <span className="text-text-muted">From address</span><input value={fromAddr} onChange={(e) => setFromAddr(e.target.value)} placeholder="you@gmail.com" disabled={running} className={FIELD} />
        <span className="text-text-muted">Password</span>
        <div className="flex items-center gap-2"><input type="password" value={password} onChange={(e) => setPassword(e.target.value)} placeholder={pwSaved ? "saved · replace…" : "app password"} disabled={running} className={`flex-1 ${FIELD}`} />{pwSaved && <span className="font-mono text-[12px] text-ok">Stored</span>}</div>
        <span className="text-text-muted">Model</span><CliSelect cli={cli} setCli={setCli} routable={routable} disabled={running} />
      </div>
      <BridgeFooter bridge={bridge} status={status} />
    </div>
  );
}

export function McpCard() {
  const [enabled, setEnabled] = useState(lsGet(LS.mcpEnabled) === "1");
  useEffect(() => { lsSet(LS.mcpEnabled, enabled ? "1" : ""); }, [enabled]);
  return (
    <div className="border-t border-border-subtle pt-4">
      <div className="flex items-center gap-3">
        <div className="flex h-10 w-10 items-center justify-center rounded-lg bg-ai/15 text-ai">
          <Network className="h-5 w-5" />
        </div>
        <div>
          <h3 className="font-semibold">
            MCP server <span className="ml-2 rounded bg-warn/15 px-1.5 py-0.5 text-[12px] text-warn">Preview</span>
          </h3>
          <p className="text-xs text-text-muted">Expose your vault to Claude Desktop or any MCP client over localhost.</p>
        </div>
      </div>
      <div className="mt-4 flex items-center justify-between rounded-lg border border-border bg-background p-3">
        <div>
          <div className="text-sm">MCP server</div>
          <div className="text-xs text-text-muted">
            {enabled ? "Listening on localhost:7842" : "Off"}
          </div>
        </div>
        <Toggle on={enabled} onChange={setEnabled} label="Enable MCP server" />
      </div>
      <p className="mt-3 text-xs text-text-muted">
        For full MCP coverage right now, run Glyph Engine's <code className="text-accent">mcp-server</code> command: it ships read-only by default and is parent-process verified.
      </p>
    </div>
  );
}

// BriefingsCard removed - landing back in v0.3 when wired up.

export function McpSection({ vaultPath }: { vaultPath: string }) {
  const [enginePath, setEnginePath] = useState<string>("");
  const [copied, setCopied] = useState(false);
  const [testing, setTesting] = useState(false);
  const [handshake, setHandshake] = useState<{ ok: boolean; msg: string } | null>(null);
  // "Move to Applications" state - must be top-level hooks (the block that uses
  // them renders conditionally on mcpPathUnstable, which flips after the async
  // engine-path resolves; declaring them inside that block broke rules-of-hooks).
  const [moving, setMoving] = useState(false);
  const [moveMsg, setMoveMsg] = useState<string | null>(null);
  async function runHandshake() {
    setTesting(true); setHandshake(null);
    try {
      const r = await invoke<{ ok: boolean; info?: string; error?: string }>("mcp_test_handshake", { vault: vaultPath });
      setHandshake({ ok: !!r.ok, msg: r.ok ? (r.info ?? "Handshake OK.") : (r.error ?? "Handshake failed.") });
    } catch (e) {
      setHandshake({ ok: false, msg: String(e).slice(0, 160) });
    } finally { setTesting(false); }
  }
  useEffect(() => {
    invoke<{ engine_bin?: string }>("app_diagnostics").then((d) => setEnginePath(d.engine_bin ?? "prevail")).catch(() => setEnginePath("prevail"));
  }, []);
  const { command: mcpCommand, unstable: mcpPathUnstable } = mcpCommandPath(enginePath);
  // Ready-to-paste configs per client - the resolved absolute bin path baked in,
  // so connecting is copy-paste instead of guesswork.
  const clients: { id: string; label: string; kind: "shell" | "json" | "toml"; body: string; note: string }[] = [
    {
      id: "claude-code", label: "Claude Code", kind: "shell",
      body: `claude mcp add prevail -- ${/\s/.test(mcpCommand) ? `"${mcpCommand}"` : mcpCommand} mcp --vault ${vaultPath}`,
      note: "Run this in your terminal. Restart Claude Code, then `/mcp` to confirm.",
    },
    {
      id: "claude-desktop", label: "Claude Desktop", kind: "json",
      body: JSON.stringify({ mcpServers: { prevail: { command: mcpCommand, args: ["mcp", "--vault", vaultPath] } } }, null, 2),
      note: "Add to claude_desktop_config.json (Settings → Developer → Edit Config), then restart.",
    },
    {
      id: "codex", label: "Codex", kind: "toml",
      body: `[mcp_servers.prevail]\ncommand = "${mcpCommand}"\nargs = ["mcp", "--vault", "${vaultPath}"]`,
      note: "Add to ~/.codex/config.toml, then restart Codex.",
    },
    {
      id: "gemini", label: "Gemini CLI", kind: "json",
      body: JSON.stringify({ mcpServers: { prevail: { command: mcpCommand, args: ["mcp", "--vault", vaultPath] } } }, null, 2),
      note: "Add to ~/.gemini/settings.json under mcpServers, then restart.",
    },
    // MCP-3: broaden coverage to the other common MCP hosts. All use stdio with
    // the same resolved command; only the file location + the wrapper key differ.
    {
      id: "cursor", label: "Cursor", kind: "json",
      body: JSON.stringify({ mcpServers: { prevail: { command: mcpCommand, args: ["mcp", "--vault", vaultPath] } } }, null, 2),
      note: "Add to ~/.cursor/mcp.json (global) or .cursor/mcp.json in a project, then reload Cursor.",
    },
    {
      id: "vscode", label: "VS Code", kind: "json",
      body: JSON.stringify({ servers: { prevail: { command: mcpCommand, args: ["mcp", "--vault", vaultPath] } } }, null, 2),
      note: "Add to .vscode/mcp.json (note: VS Code uses \"servers\", not \"mcpServers\"). Works with Copilot Agent mode + Continue/Cline.",
    },
    {
      id: "generic", label: "Other / stdio", kind: "json",
      body: JSON.stringify({ mcpServers: { prevail: { command: mcpCommand, args: ["mcp", "--vault", vaultPath] } } }, null, 2),
      note: "Any MCP host that speaks stdio (OpenClaw, Paperclip, Multica, Goose, Zed, …). Use this command + args in that client's MCP config. The server is read-only over stdio and parent-verified.",
    },
  ];
  const [client, setClient] = useState(clients[0].id);
  const active = clients.find((c) => c.id === client) ?? clients[0];
  return (
    <>
      <SettingsHeader title="MCP" icon={Wrench} subtitle="Drive your vault from another AI tool, with no UI." />
      <div className="mb-5">
        <div className="mb-2 text-[14px] font-semibold text-text-primary">Connected servers (Glyph Studio consumes)</div>
        <McpCard />
      </div>
      <div className="border-t border-border-subtle pt-4">
        <div className="mb-1 text-[14px] font-semibold text-text-primary">Expose Glyph Studio to your agent</div>
        <div className="mb-3 text-xs text-text-secondary">Copy the config into your tool and restart it, then test the handshake.</div>
        {mcpPathUnstable && (
          <div className="mb-3 rounded-md border border-warn/40 bg-warn/10 px-3 py-2 text-[12px] text-warn">
            <div className="mb-2 font-medium">Glyph Studio is not in your Applications folder.</div>
            <div className="mb-2">MCP requires a stable path. Move Glyph Studio to /Applications/ once and this resolves permanently.</div>
            <div className="flex flex-wrap items-center gap-2">
              <button
                onClick={async () => {
                  setMoving(true); setMoveMsg(null);
                  try {
                    const src = enginePath?.includes(".app") ? enginePath.slice(0, enginePath.lastIndexOf(".app") + 4) : enginePath || "";
                    const msg = await invoke<string>("move_to_applications", { source: src });
                    setMoveMsg(msg);
                  } catch (e) { setMoveMsg(`Failed: ${e}`); }
                  setMoving(false);
                }}
                disabled={moving || !enginePath}
                className="inline-flex items-center gap-1.5 rounded border border-warn bg-warn/20 px-2.5 py-1 text-[12px] font-semibold hover:bg-warn/30 disabled:opacity-50"
              >
                {moving ? "Moving…" : "Move to Applications automatically"}
              </button>
              <button
                onClick={() => invoke("open_in_finder", { path: "/Applications" }).catch(() => {})}
                className="inline-flex items-center gap-1.5 rounded border border-warn/40 bg-warn/10 px-2.5 py-1 text-[12px] hover:bg-warn/20"
              >
                <Folder className="h-3 w-3" /> Open Applications folder
              </button>
              {moveMsg && <span className="w-full text-[12px]">{moveMsg}</span>}
            </div>
          </div>
        )}
        <div className="mb-3 inline-flex flex-wrap gap-1 rounded-lg border border-border-subtle bg-surface-warm/60 p-1">
          {clients.map((c) => (
            <button key={c.id} onClick={() => setClient(c.id)}
              className={`rounded-md px-2.5 py-1 text-xs font-medium transition-all ${client === c.id ? "bg-surface text-accent shadow-sm ring-1 ring-black/5" : "text-text-muted hover:text-text-secondary"}`}>
              {c.label}
            </button>
          ))}
        </div>
        <pre className="overflow-auto rounded-md border border-border-subtle bg-background p-3 text-[12px] text-text-secondary whitespace-pre-wrap">{active.body}</pre>
        <div className="mt-1.5 text-[12px] text-text-muted">{active.note}</div>
        <div className="mt-3 flex flex-wrap items-center gap-2">
          <button onClick={() => { navigator.clipboard.writeText(active.body).catch(() => {}); setCopied(true); window.setTimeout(() => setCopied(false), 1500); }}
            className="rounded-md border border-border bg-background px-3 py-1.5 text-[12px] text-text-muted hover:border-accent-border hover:text-accent">
            {copied ? "Copied" : `Copy ${active.kind === "shell" ? "command" : "config"}`}
          </button>
          <button onClick={runHandshake} disabled={testing}
            className="inline-flex items-center gap-1.5 rounded-md border border-accent-border bg-accent-soft px-3 py-1.5 text-[12px] text-accent hover:bg-accent hover:text-background disabled:opacity-50">
            {testing ? <Loader2 className="h-3 w-3 animate-spin" /> : <Zap className="h-3 w-3" />}
            {testing ? "Testing…" : "Test handshake"}
          </button>
          {handshake && (
            <span className={`font-mono text-[12px] ${handshake.ok ? "text-ok" : "text-warn"}`}>
              {handshake.ok ? "✓ " : "✗ "}{handshake.msg}
            </span>
          )}
        </div>
      </div>
    </>
  );
}

// Settings > Tasks: every task across every domain in one place, so you can
// triage what is accumulating where (the cross-domain view, vs per-domain
// Insights). Grouped by status; shows due, source, and added date.

// A quiet, honest prompt to star the repo, with the real download + star
// counts so it reads as fact, not a nag. Downloads come from shields.io's
// cached total endpoint; stars from the repo. Both fail silently.
function StarOnGitHubCard() {
  const [downloads, setDownloads] = useState<string | null>(null);
  const [stars, setStars] = useState<number | null>(null);
  useEffect(() => {
    let cancelled = false;
    fetch("https://img.shields.io/github/downloads/fru-dev3/glyph-studio/total.json")
      .then((r) => (r.ok ? r.json() : null))
      .then((j) => { if (!cancelled && j && typeof j.value === "string") setDownloads(j.value); })
      .catch(() => {});
    fetch("https://api.github.com/repos/fru-dev3/glyph-studio")
      .then((r) => (r.ok ? r.json() : null))
      .then((j) => { if (!cancelled && j && typeof j.stargazers_count === "number") setStars(j.stargazers_count); })
      .catch(() => {});
    return () => { cancelled = true; };
  }, []);
  const hasStats = downloads !== null || stars !== null;
  return (
    <div className="mt-3 flex flex-wrap items-center gap-4 rounded-xl border border-border bg-surface p-4 shadow-sm">
      <span className="flex h-10 w-10 shrink-0 items-center justify-center rounded-xl bg-accent-soft text-accent">
        <Star className="h-5 w-5" />
      </span>
      <div className="min-w-0 flex-1">
        <div className="text-sm font-semibold text-text-primary">Enjoying Glyph Studio? Star it on GitHub.</div>
        <div className="mt-0.5 text-xs text-text-secondary">
          Open source, GPL-3.0. A star helps other people find it.
          {hasStats && (
            <span className="ml-1 font-mono text-text-muted">
              {downloads !== null ? `${downloads} downloads` : ""}
              {downloads !== null && stars !== null ? " · " : ""}
              {stars !== null ? `${stars} stars` : ""}
            </span>
          )}
        </div>
      </div>
      <a
        href="https://github.com/fru-dev3/glyph-studio"
        target="_blank"
        rel="noreferrer"
        className="inline-flex shrink-0 items-center gap-1.5 rounded-lg bg-text-primary px-3 py-2 text-sm font-medium text-background transition-opacity hover:opacity-90"
      >
        <Github className="h-4 w-4" /> Star on GitHub
      </a>
    </div>
  );
}

export function AboutSection({ vaultPath }: { vaultPath: string }) {
  const verify = useCliVerifyLive();
  const [checking, setChecking] = useState(false);
  const [latest, setLatest] = useState<string | null>(null);
  const [checkErr, setCheckErr] = useState<string | null>(null);
  const [checks, setChecks] = useState<DiagCheck[] | null>(null);
  const [diagRunning, setDiagRunning] = useState(false);
  const [diagCopied, setDiagCopied] = useState(false);

  // A real health check: each item verifies one thing Prevail depends on and
  // says why it matters, with a pass/warn/fail verdict you can act on.
  async function runDiagnosis() {
    setDiagRunning(true);
    const out: DiagCheck[] = [];
    let d: { desktop_version: string; os: string; arch: string; engine_version?: string; engine_bin: string; engine_bundled: boolean; app_support: string } | null = null;
    try { d = await invoke("app_diagnostics"); } catch { /* engine probe failed */ }

    // Engine sidecar.
    if (d) {
      const match = d.engine_version && d.engine_version.length > 0;
      out.push({
        label: "Engine", status: match ? "ok" : "warn",
        detail: `${d.engine_version ?? "unknown"} ${d.engine_bundled ? "(bundled)" : `(${d.engine_bin})`}`,
        why: "The engine runs every chat, council, and benchmark. Bundled = shipped with the app.",
      });
    } else {
      out.push({ label: "Engine", status: "fail", detail: "not reachable", why: "Without the engine, nothing runs. Reinstall the app." });
    }

    // Vault: reachable, writable, encryption state.
    if (vaultPath) {
      let exists = false;
      try { exists = await invoke<boolean>("vault_exists", { path: vaultPath }); } catch { /* */ }
      let enc: { encrypted: boolean; unlocked: boolean } | null = null;
      try { enc = await invoke("engine_vault_status", { vault: vaultPath }); } catch { /* */ }
      const encNote = enc?.encrypted ? (enc.unlocked ? " · encrypted, unlocked" : " · encrypted, LOCKED") : "";
      out.push({
        label: "Vault", status: exists ? (enc?.encrypted && !enc.unlocked ? "warn" : "ok") : "fail",
        detail: `${vaultPath}${encNote}`,
        why: exists ? "Your data lives here. An encrypted+locked vault can't be read until you unlock it." : "The vault path doesn't exist; pick or restore it in Settings → Workspace.",
      });
    } else {
      out.push({ label: "Vault", status: "fail", detail: "no vault selected", why: "Set up a vault in Settings → Workspace." });
    }

    // Agents: detected AND validated.
    let clis: CliInfo[] = [];
    try { clis = await invoke<CliInfo[]>("detect_clis"); } catch { /* */ }
    const detected = clis.filter((c) => c.available);
    const valid = detected.filter((c) => verify.get(c.id)?.status === "ok");
    out.push({
      label: "Agents", status: valid.length > 0 ? "ok" : detected.length > 0 ? "warn" : "fail",
      detail: detected.length === 0 ? "none detected" : detected.map((c) => `${c.label}${verify.get(c.id)?.status === "ok" ? " ✓" : verify.get(c.id)?.status === "failed" ? " ✗" : " ?"}`).join(", "),
      why: valid.length > 0 ? "These models are installed and answered a live test." : detected.length > 0 ? "Installed but not validated; open Settings → Models and re-check (often a login/token issue)." : "Install at least one CLI (claude, codex, ollama) to chat.",
    });

    // Network + Bunker.
    const online = typeof navigator !== "undefined" ? navigator.onLine : true;
    const bunker = isBunkerOn();
    out.push({
      label: "Network", status: bunker ? "info" : online ? "ok" : "warn",
      detail: bunker ? "Bunker Mode ON (local-only by design)" : online ? "online" : "offline",
      why: bunker ? "Cloud is intentionally blocked; only local models run." : online ? "Cloud models and updates are reachable." : "Offline; cloud models and update checks won't work until reconnected.",
    });

    // Update check.
    try {
      const u = await checkUpdate();
      out.push({
        label: "Updates", status: u ? "warn" : "ok",
        detail: u ? `v${u.version} available` : `on the latest (v${APP_VERSION})`,
        why: u ? "Use 'Check for updates' above, then click Install to apply it in place." : "You're running the newest release.",
      });
    } catch {
      out.push({ label: "Updates", status: "info", detail: "couldn't check", why: "Update feed unreachable (offline or first release). Not a problem." });
    }

    // Background surfaces.
    try {
      const [tg, wu] = await Promise.all([
        invoke<{ running: boolean }>("telegram_bridge_status"),
        invoke<{ running: boolean }>("webui_status"),
      ]);
      const surfaces = [tg.running ? "Telegram" : null, wu.running ? "WebUI" : null].filter(Boolean);
      out.push({
        label: "External access", status: surfaces.length > 0 ? "info" : "ok",
        detail: surfaces.length > 0 ? `LIVE: ${surfaces.join(", ")}` : "none active",
        why: surfaces.length > 0 ? "These bridges can reach the app from outside right now." : "No external surface is exposed.",
      });
    } catch { /* */ }

    setChecks(out);
    setDiagRunning(false);
  }

  function diagText(): string {
    const head = `Glyph Studio v${APP_VERSION}`;
    const lines = (checks ?? []).map((c) => `[${c.status.toUpperCase()}] ${c.label}: ${c.detail}`);
    return [head, ...lines].join("\n");
  }

  async function exportConfig() {
    // Never export credentials or personal identifiers in a shareable config (O62).
    const SENSITIVE = /(pass|token|secret|api[_-]?key|webui|telemetry|chat[_-]?id|phone)/i;
    const cfg: Record<string, string> = {};
    for (let i = 0; i < localStorage.length; i++) {
      const k = localStorage.key(i)!;
      if (!k.startsWith("prevail.")) continue;
      if (SENSITIVE.test(k)) continue;
      cfg[k] = localStorage.getItem(k) ?? "";
    }
    try {
      const path = await save({ defaultPath: "prevail-config.json", filters: [{ name: "JSON", extensions: ["json"] }] });
      if (!path) return;
      await invoke("write_text_file", { path, contents: JSON.stringify(cfg, null, 2) });
    } catch (e) { console.error("exportConfig", e); }
  }

  async function importConfig() {
    try {
      const path = await open({ multiple: false, directory: false, filters: [{ name: "JSON", extensions: ["json"] }] });
      if (!path || typeof path !== "string") return;
      const json = await invoke<string>("read_text_file", { path });
      const cfg = JSON.parse(json) as Record<string, string>;
      // An imported file must NOT silently relax safety settings or inject
      // credentials, reject security prefs + secrets (O61).
      const BLOCKED = /(pref\.bunkerMode|pref\.redactSecrets|pref\.approvalMode|pref\.allowPrivateUrls|pass|token|secret|api[_-]?key|webui)/i;
      for (const [k, v] of Object.entries(cfg)) {
        if (!k.startsWith("prevail.") || BLOCKED.test(k)) continue;
        localStorage.setItem(k, String(v));
      }
      window.location.reload();
    } catch (e) { console.error("importConfig", e); }
  }

  async function resetConfig() {
    const ok = await tauriConfirm("Reset all Glyph Studio preferences to defaults? Your vault, chats, and stored secrets are not affected.", { title: "Reset to defaults", kind: "warning" });
    if (!ok) return;
    const keys: string[] = [];
    for (let i = 0; i < localStorage.length; i++) {
      const k = localStorage.key(i)!;
      // Reset prefs + desktop settings, but keep the vault selection.
      if ((k.startsWith("prevail.pref.") || k.startsWith("prevail.desktop.") || k.startsWith("prevail.about.")) && k !== "prevail.desktop.vaultPath") keys.push(k);
    }
    keys.forEach((k) => localStorage.removeItem(k));
    window.location.reload();
  }

  async function uninstall(scope: "app" | "data") {
    const msg = scope === "app"
      ? "Remove Glyph Studio from Applications? Your config, chats, and secrets stay so you can reinstall later."
      : "Remove the app, all app data, caches, and stored secrets? Your vault folder is NOT deleted. This cannot be undone.";
    const ok = await tauriConfirm(msg, { title: "Uninstall Glyph Studio", kind: "warning" });
    if (!ok) return;
    try { await invoke("app_uninstall", { scope }); } catch (e) { console.error("uninstall", e); }
  }

  const [installing, setInstalling] = useState(false);
  // Download progress (0-100) during an in-place install, and an explicit manual
  // download URL we only set when the in-place path genuinely can't run.
  const [downloadPct, setDownloadPct] = useState<number | null>(null);
  const [manualUrl, setManualUrl] = useState<string | null>(null);
  // A found-but-not-yet-installed update. Checking only DISCOVERS it; the user
  // must click Install to actually download + replace + relaunch. (feedback:
  // "when you check for updates, don't auto start installing").
  const [pendingUpdate, setPendingUpdate] = useState<Update | null>(null);
  async function checkForUpdates() {
    setChecking(true);
    setCheckErr(null);
    setLatest(null);
    setManualUrl(null);
    setDownloadPct(null);
    setPendingUpdate(null);
    try {
      // Only CHECK here: hit the signed latest.json feed and report whether a
      // newer build exists. We deliberately do NOT install - that waits for an
      // explicit Install click (see installUpdate).
      const update = await checkUpdate();
      if (update) {
        setLatest(update.version);
        setPendingUpdate(update);
      } else {
        // No update object → already current.
        setLatest(APP_VERSION);
      }
    } catch (pluginErr) {
      // The updater feed couldn't be reached: offline, the feed isn't published
      // yet, a signature/pubkey mismatch, OR this is a `tauri dev` build (which
      // can't self-replace). Surface the REAL reason instead of silently
      // bouncing to a browser, and offer an explicit manual download as backup.
      setCheckErr(`Update check couldn't run (${String(pluginErr).slice(0, 140)}). You can download it manually below.`);
      try {
        const r = await fetch("https://api.github.com/repos/fru-dev3/glyph-studio/releases?per_page=10");
        if (r.ok) {
          const releases = await r.json() as Array<{ tag_name: string; prerelease: boolean; html_url: string }>;
          const top = releases.find((rel) => !rel.prerelease) ?? releases[0];
          if (top) { setLatest(top.tag_name); setManualUrl(top.html_url); }
        }
      } catch { /* keep the check error visible */ }
    } finally {
      setChecking(false);
    }
  }
  async function installUpdate() {
    if (!pendingUpdate) return;
    setInstalling(true);
    setCheckErr(null);
    setDownloadPct(null);
    try {
      // Download + install IN PLACE, then relaunch into the new version. No
      // browser detour. Stream progress so the user sees it happen.
      let total = 0;
      let got = 0;
      await pendingUpdate.downloadAndInstall((ev) => {
        if (ev.event === "Started") { total = ev.data.contentLength ?? 0; setDownloadPct(0); }
        else if (ev.event === "Progress") { got += ev.data.chunkLength; setDownloadPct(total > 0 ? Math.min(100, Math.round((got / total) * 100)) : null); }
        else if (ev.event === "Finished") { setDownloadPct(100); }
      });
      await relaunch();
    } catch (pluginErr) {
      // In-place replace failed (e.g. a `tauri dev` build, or a signature
      // mismatch). Offer the manual download as backup.
      setCheckErr(`In-place install couldn't run (${String(pluginErr).slice(0, 140)}). You can download it manually below.`);
      try {
        const r = await fetch("https://api.github.com/repos/fru-dev3/glyph-studio/releases?per_page=10");
        if (r.ok) {
          const releases = await r.json() as Array<{ tag_name: string; prerelease: boolean; html_url: string }>;
          const top = releases.find((rel) => !rel.prerelease) ?? releases[0];
          if (top) { setManualUrl(top.html_url); }
        }
      } catch { /* keep the install error visible */ }
    } finally {
      setInstalling(false);
    }
  }

  function Row({ label, href }: { label: string; href: string }) {
    return (
      <a
        href={href}
        target="_blank"
        rel="noreferrer"
        className="inline-flex items-center gap-1.5 rounded-lg border border-border bg-surface px-3 py-2 text-sm text-text-primary shadow-sm transition-colors hover:border-accent-border hover:text-accent"
      >
        <span>{label}</span>
        <span className="text-text-muted">›</span>
      </a>
    );
  }

  const cmp = latest ? compareSemver(latest.replace(/^v/, ""), APP_VERSION) : 0;
  const upToDate = latest && cmp <= 0;
  const newer = latest && cmp > 0;
  // A verified, downloadable update is staged and waiting for an explicit
  // Install click. (manualUrl-only "newer" means the in-place path failed, so
  // we keep the button on Check and let the manual download banner take over.)
  const readyToInstall = !!pendingUpdate && !installing;

  return (
    // ABOUT-1: full-width single column (was a narrow centered max-w-xl). The
    // header + update controls collapse into one horizontal banner so the page
    // uses the width and fits with far less vertical scroll.
    <div className="w-full">
      <div className="flex flex-wrap items-center gap-4 rounded-xl border border-border bg-surface p-4 shadow-sm">
        <span className="shrink-0 overflow-hidden rounded-2xl shadow-md"><GlyphStudioLogo size={56} animated={false} /></span>
        <div className="min-w-0 flex-1">
          <h1 className="font-display text-2xl font-extrabold tracking-tight">
            <BrandMark className="[letter-spacing:0.12em]" />
            <span className="ml-2 align-middle rounded-full bg-surface-warm px-2.5 py-1 font-mono text-xs font-normal text-text-secondary">v{APP_VERSION}</span>
          </h1>
          <p className="mt-0.5 text-xs text-text-secondary">A private AI harness for your life, grounded in your domains.</p>
        </div>
        <div className="flex shrink-0 flex-col items-end gap-1">
          <button
            onClick={readyToInstall ? installUpdate : checkForUpdates}
            disabled={checking || installing}
            className="rounded-md bg-text-primary px-3 py-1.5 text-sm font-medium text-background transition-opacity hover:opacity-90 disabled:opacity-50"
          >
            {installing
              ? (downloadPct != null ? `Installing… ${downloadPct}%` : "Installing…")
              : checking ? "Checking…" : readyToInstall ? "Install update" : "Check for updates"}
          </button>
          {latest ? (
            <span className={`font-mono text-[12px] ${upToDate ? "text-accent" : "text-warn"}`}>
              {upToDate ? `latest (${latest})` : newer ? `update ready: ${latest}` : `latest: ${latest}`}
            </span>
          ) : (
            <span className="font-mono text-[12px] text-text-muted">In-place updates</span>
          )}
        </div>
        {/* In-place download progress bar. */}
        {installing && downloadPct != null && (
          <div className="h-1 w-full overflow-hidden rounded-full bg-surface-warm">
            <div className="h-full rounded-full bg-accent transition-[width] duration-200" style={{ width: `${downloadPct}%` }} />
          </div>
        )}
        {checkErr && (
          <div className="flex w-full flex-wrap items-center gap-2 rounded-md border border-warn/40 bg-warn/10 px-3 py-1.5 text-xs text-warn">
            <span className="min-w-0 flex-1">{checkErr}</span>
            {manualUrl && (
              <a href={manualUrl} target="_blank" rel="noreferrer" className="shrink-0 rounded border border-warn/50 bg-warn/10 px-2 py-0.5 text-[12px] hover:bg-warn/20">
                Download manually ›
              </a>
            )}
          </div>
        )}
      </div>

      {/* Star prompt: honest social proof with the real download + star counts. */}
      <StarOnGitHubCard />

      {/* Links - a horizontal wrap of chips (was a tall stacked list) to use the
          full width and shave vertical height. */}
      <div className="mt-3 flex flex-wrap gap-2">
        {/* O1: replay the onboarding tour. */}
        <button onClick={() => window.dispatchEvent(new Event("prevail:open-onboarding"))}
          className="inline-flex items-center gap-1.5 rounded-lg border border-border bg-surface px-3 py-2 text-sm text-text-primary shadow-sm transition-colors hover:border-accent-border hover:text-accent">
          Take the tour <span className="text-text-muted">↻</span>
        </button>
        <Row label="Help & documentation" href="https://github.com/fru-dev3/glyph-studio#readme" />
        <Row label="Update log" href="https://github.com/fru-dev3/glyph-studio/releases" />
        <Row label="Report an issue" href="https://github.com/fru-dev3/glyph-studio/issues/new" />
        <Row label="Glyph Engine" href="https://github.com/fru-dev3/glyph-engine" />
        <Row label="Official website" href="https://glyph.fru.dev/studio" />
      </div>

      {/* Beta / liability disclaimer */}
      <div className="mt-3 border-t border-border-subtle pt-3">
        <div className="mb-1.5 text-[14px] font-semibold text-text-primary">Beta software</div>
        <p className="text-xs leading-relaxed text-text-secondary">
          Glyph Studio is a beta release. It is provided "as is",
          without warranty of any kind, express or implied, and you use it at your own risk. The authors are not liable
          for any data loss, costs, or damages arising from its use. It runs third-party AI tools and, unless Bunker
          Mode is on, may send data to cloud providers. Always review anything important yourself. Feedback and bug
          reports are very welcome, they directly shape what comes next.
        </p>
        <a
          href="https://github.com/fru-dev3/glyph-studio/issues/new"
          target="_blank"
          rel="noreferrer"
          className="mt-2.5 inline-flex items-center gap-1.5 rounded-lg border border-border bg-background px-3 py-1.5 text-sm text-text-secondary transition-colors hover:border-accent-border hover:text-accent"
        >
          <MessageSquare className="h-3.5 w-3.5" /> Share feedback
        </a>
      </div>

      {/* Config - export / import / reset */}
      <div className="mt-3 border-t border-border-subtle pt-4">
        <div className="mb-3 text-[14px] font-semibold text-text-primary">Configuration</div>
        <div className="flex flex-wrap gap-2">
          <button onClick={exportConfig}
            className="rounded-md border border-border bg-background px-3 py-1.5 text-sm text-text-secondary hover:border-accent-border hover:text-accent">Export config…</button>
          <button onClick={importConfig}
            className="rounded-md border border-border bg-background px-3 py-1.5 text-sm text-text-secondary hover:border-accent-border hover:text-accent">Import config…</button>
          <button onClick={resetConfig}
            className="rounded-md border border-warn/40 bg-warn/10 px-3 py-1.5 text-sm text-warn hover:bg-warn/20">Reset all to defaults</button>
        </div>
        <div className="mt-2 text-xs text-text-secondary">Backs up / restores all app preferences (not your vault). Reset clears every preference and reloads.</div>
      </div>

      {/* Diagnostics - a real health check, one row per thing Prevail needs. */}
      <div className="mt-3 border-t border-border-subtle pt-4">
        <div className="mb-1 flex items-center justify-between">
          <div className="font-mono text-[14px] font-semibold text-text-primary">Health check</div>
          <div className="flex gap-2">
            <button onClick={runDiagnosis} disabled={diagRunning}
              className="rounded-md border border-border bg-background px-3 py-1.5 text-sm text-text-secondary hover:border-accent-border hover:text-accent disabled:opacity-50">{diagRunning ? "Checking…" : "Run check"}</button>
            {checks && (
              <button onClick={() => { navigator.clipboard.writeText(diagText()).catch(() => {}); setDiagCopied(true); window.setTimeout(() => setDiagCopied(false), 1500); }}
                className="rounded-md border border-border bg-background px-3 py-1.5 text-sm text-text-secondary hover:border-accent-border hover:text-accent">{diagCopied ? "Copied" : "Copy report"}</button>
            )}
          </div>
        </div>
        <p className="mb-3 text-xs text-text-muted">Verifies everything Glyph Studio depends on is healthy. Copy the report when filing an issue.</p>
        {checks && (
          <div className="flex flex-col gap-1.5">
            {checks.map((c) => (
              <div key={c.label} className="flex items-start gap-2.5 rounded-lg border border-border-subtle bg-background px-3 py-2">
                <span className={`mt-0.5 shrink-0 font-mono text-sm font-bold ${
                  c.status === "ok" ? "text-ok" : c.status === "fail" ? "text-warn" : c.status === "warn" ? "text-warn" : "text-text-muted"
                }`}>{c.status === "ok" ? "✓" : c.status === "fail" ? "✗" : c.status === "warn" ? "!" : "·"}</span>
                <div className="min-w-0 flex-1">
                  <div className="flex items-baseline gap-2">
                    <span className="text-[12px] font-semibold text-text-primary">{c.label}</span>
                    <span className="min-w-0 flex-1 truncate font-mono text-[12px] text-text-secondary" title={c.detail}>{c.detail}</span>
                  </div>
                  <div className="text-[12px] leading-snug text-text-muted">{c.why}</div>
                </div>
              </div>
            ))}
          </div>
        )}
      </div>

      {/* Danger zone - uninstall (never touches the vault) */}
      <div className="mt-3 rounded-xl border border-warn/30 bg-warn/5 p-4">
        <div className="mb-1 text-[12px] text-warn">Danger zone</div>
        <div className="mb-3 text-xs text-text-secondary">Removes the app and its data. Your vault is never deleted.</div>
        <div className="flex flex-col gap-2">
          <button onClick={() => uninstall("app")}
            className="rounded-md border border-border bg-background px-3 py-2 text-left text-sm text-text-primary hover:border-warn/50">
            <div className="font-medium">Uninstall the app</div>
            <div className="text-xs text-text-secondary">Remove the app from /Applications. Keeps all config, chats, and secrets.</div>
          </button>
          <button onClick={() => uninstall("data")}
            className="rounded-md border border-warn/40 bg-warn/10 px-3 py-2 text-left text-sm text-warn hover:bg-warn/20">
            <div className="font-medium">Uninstall everything (keep vault)</div>
            <div className="text-xs">Remove the app, all app data, caches, and stored secrets. Your vault folder stays.</div>
          </button>
        </div>
      </div>

      <div className="mt-6 flex items-center justify-between gap-3 px-1 text-[12px] text-text-muted">
        <span>GPL-3.0 licensed · Open source</span>
        <span>Local-first · Vault stays on this Mac</span>
      </div>
    </div>
  );
}
