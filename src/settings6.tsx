// Settings sections extracted from App.tsx: Privacy & Connectivity (Bunker Mode),
// Council defaults, Configuration (groups the memory/tasks/ideal sub-sections),
// and the Agents catalog (AgentCard + AgentsSection).
import { useCallback, useEffect, useState } from "react";
import { AlwaysAllowedCard } from "./actcard";
import { AlertTriangle, ArrowUpRight, Brain, Check, ChevronRight, Circle, CircleCheck, CircleX, Cloud, CloudOff, Copy, Cpu, FileX, Fingerprint, FolderCheck, FolderX, Globe, LineChart, Loader2, Lock, LockOpen, Mail, MailCheck, RefreshCw, Search, Send, Server, ShieldCheck, ShieldOff, Sigma, Sparkles, Star, Target, Terminal, User, Wifi, WifiOff } from "lucide-react";
import type { LucideIcon } from "lucide-react";
import { invoke } from "./bridge";
import { RUNTIME_META, VENDOR_BRAND, isHarnessRuntime } from "./constants";
import { modelsFor } from "./helpers2";
import { PREF, getPref, lsGet, lsSet, setPref } from "./storage";
import { Ghost, MessageSquare } from "lucide-react";
import { REVEAL, RowMenu, Toggle } from "./ui";
import type { RowMenuItem } from "./ui";
import { SettingsHeader, authLoginCmd } from "./sectionutil";
import { cliVerifyLive, loadVerifyMap, recheckCli, saveVerifyMap, setCliVerify, useCliVerifyLive } from "./verify";
import { ProviderMark } from "./marks";
import { SideSpine, STICKY_GROUP_HEAD } from "./sidespine";
import { useIsPhone } from "./useisphone";
import { RowAction } from "./rowaction";
import { ErrorLine } from "./errorline";
import { TelemetrySettings } from "./settings4";
import type { CliInfo, ModelVerifyStatus, UsageSummary } from "./types";

// Consistent section header shared by the three privacy controls. Big, legible
// title + a one-line plain-language explanation of what the section governs, so
// each grouping reads on its own.
function PrivacyGroupHead({ title, blurb }: { title: string; blurb: string }) {
  return (
    <div className="mb-3 flex flex-wrap items-baseline gap-x-3">
      <h3 className="text-[15px] font-semibold text-text-primary">{title}</h3>
      <p className="text-sm text-text-muted">{blurb}</p>
    </div>
  );
}

// The compact per-channel status row shared by all three privacy controls, so
// each card has the same granularity. `good` = the protective/active state
// (highlighted cyan); otherwise muted. Sits inside the card under a divider.
type StatusChip = { Icon: LucideIcon; label: string; state: string; good: boolean };
function StatusChips({ items, expected }: { items: StatusChip[]; expected: boolean }) {
  // Only a channel that DISAGREES with the headline earns a chip. With the
  // control on and everything it governs actually closed, four chips reading
  // "blocked" are four more ways of saying what the switch already says; the
  // one that matters is the channel that did not comply.
  const shown = expected ? items.filter((t) => !t.good) : [];
  if (shown.length === 0) return null;
  return (
    <div className="mt-3 flex flex-wrap gap-1.5 border-t border-border-subtle pt-3">
      {shown.map((t) => (
        <span
          key={t.label}
          className={`inline-flex items-center gap-1.5 rounded-md border px-2 py-1 text-[12px] ${t.good ? "border-ai/30 bg-ai/5 text-text-primary" : "border-border bg-surface text-text-muted"}`}
        >
          <t.Icon className={`h-3.5 w-3.5 ${t.good ? "text-ai" : "text-text-muted"}`} />
          {t.label}
          <span className="font-mono tracking-wide opacity-70">{t.state}</span>
        </span>
      ))}
    </div>
  );
}

// G3: the global incognito master. On = chat AND council run as a plain model
// with none of your context (profile, ideal state, omega, memory). Per-surface
// toggles in each composer can still go incognito just there.
function GlobalIncognitoToggle() {
  const [on, setOn] = useState(() => getPref(PREF.incognito, "0") === "1");
  // What the model sees right now, per context channel. `good` = hidden (the
  // private state), matching the cyan-when-protective convention.
  const chips: StatusChip[] = [
    { Icon: User, label: "Profile", state: on ? "Hidden" : "Used", good: on },
    { Icon: Target, label: "Ideal state", state: on ? "Hidden" : "Used", good: on },
    { Icon: Sigma, label: "Omega", state: on ? "Hidden" : "Used", good: on },
    { Icon: Brain, label: "Memory", state: on ? "Hidden" : "Used", good: on },
  ];
  return (
    <div className="py-1">
      <div className="flex items-center gap-3">
        <span className={`flex h-9 w-9 shrink-0 items-center justify-center rounded-lg ${on ? "bg-accent-soft text-accent" : "bg-surface-warm text-text-muted"}`}><Ghost className="h-4 w-4" /></span>
        <div className="min-w-0 flex-1">
          <div className="text-sm font-semibold text-text-primary">{on ? "On, every surface runs blank" : "Off, your context is used"}</div>
          <div className="mt-0.5 text-xs text-text-secondary">
            {on
              ? "Chat and council run as a plain model with no profile, ideal state, omega, or memory."
              : "Chat and council see your profile, ideals, omega and memory."}
          </div>
        </div>
        <Toggle on={on} onChange={(v) => { setOn(v); setPref(PREF.incognito, v ? "1" : "0"); }} label="Incognito everywhere" />
      </div>
      <StatusChips items={chips} expected={on} />
    </div>
  );
}

// Vault Lock - the filesystem-scope switch. A SEPARATE dimension from Bunker
// Mode (which is about local vs cloud models). On = the assistant may only
// touch files inside the vault; off = full local-machine access. Default ON.
function VaultLockToggle() {
  const [on, setOn] = useState(true);
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    invoke<{ enabled: boolean }>("vault_lock_status").then((s) => setOn(!!s.enabled)).catch(() => {});
  }, []);
  async function toggle(next: boolean) {
    setBusy(true);
    try {
      const s = await invoke<{ enabled: boolean }>("vault_lock_set", { enabled: next });
      setOn(!!s.enabled);
      // Tell the footer trust-bar to update immediately (it listens for this).
      window.dispatchEvent(new CustomEvent("prevail:vault-lock-changed"));
    } catch (e) { console.error("vault_lock_set", e); } finally { setBusy(false); }
  }
  // What the assistant can reach on disk right now. `good` = restricted to the
  // vault (the protective state), matching the cyan-when-protective convention.
  const chips: StatusChip[] = [
    { Icon: FolderCheck, label: "Vault", state: "Read/write", good: true },
    { Icon: FolderX, label: "Other folders", state: on ? "Blocked" : "Allowed", good: on },
    { Icon: FileX, label: "Outside files", state: on ? "Blocked" : "Allowed", good: on },
    { Icon: Terminal, label: "Local tools", state: on ? "Vault only" : "Whole machine", good: on },
  ];
  return (
    <div className="py-1">
      <div className="flex items-center gap-3">
        <span className={`flex h-9 w-9 shrink-0 items-center justify-center rounded-lg ${on ? "bg-accent-soft text-accent" : "bg-surface-warm text-text-muted"}`}>
          {on ? <Lock className="h-4 w-4" /> : <LockOpen className="h-4 w-4" />}
        </span>
        <div className="min-w-0 flex-1">
          <div className="text-sm font-semibold text-text-primary">{on ? "On, vault only" : "Off, whole machine"}</div>
          <div className="mt-0.5 text-xs text-text-secondary">
            {on
              ? "Only your vault. The rest of this Mac is off-limits."
              : "Full local-machine access. The assistant can scan any directory and use local tools across your computer."}
          </div>
        </div>
        <Toggle on={on} disabled={busy} onChange={toggle} label="Vault Lock" />
      </div>
      <StatusChips items={chips} expected={on} />
    </div>
  );
}

// Outbound Guardrail - ONE switch, like the other privacy controls. On (the
// default) engages BOTH engine-enforced outbound protections in one move:
//   who  - email to anyone but you is saved as a Gmail draft you send yourself
//          (emailPolicy draft-others)
//   what - outbound content to another party carrying PII, money figures,
//          health/legal/salary/strategy details or verbatim quotes is held
//          until you release that exact action (egressGuard on)
// Off disables both (approved actions run exactly as addressed). Finer modes
// (block-entirely email) stay available via the CLI: prevail email-policy /
// egress-guard. State is engine-side config, so every surface obeys it; the
// bottom ribbon mirrors it live via the prevail:guardrail-changed event.
function OutboundGuardrailToggle() {
  const [on, setOn] = useState(true);
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    Promise.all([
      invoke<{ policy?: string }>("email_policy_get").catch(() => null),
      invoke<{ mode?: string }>("egress_guard_get").catch(() => null),
    ]).then(([p, g]) => {
      if (p || g) setOn(p?.policy !== "allow" && g?.mode !== "off");
    });
  }, []);
  async function toggle(next: boolean) {
    setBusy(true);
    try {
      await invoke("email_policy_set", { policy: next ? "draft-others" : "allow" });
      await invoke("egress_guard_set", { mode: next ? "on" : "off" });
      setOn(next);
      window.dispatchEvent(new CustomEvent("prevail:guardrail-changed"));
    } catch (e) { console.error("guardrail toggle", e); } finally { setBusy(false); }
  }
  const chips: StatusChip[] = [
    { Icon: MailCheck, label: "Email to you", state: "Sends", good: true },
    { Icon: Mail, label: "Email to others", state: on ? "Draft only" : "Sends", good: on },
    { Icon: Fingerprint, label: "PII, figures, health, legal", state: on ? "Held" : "May leave", good: on },
    { Icon: Send, label: "Autonomous outreach", state: on ? "Needs your send" : "Allowed", good: on },
  ];
  return (
    <div className="py-1">
      <div className="flex items-center gap-3">
        <span className={`flex h-9 w-9 shrink-0 items-center justify-center rounded-lg ${on ? "bg-accent-soft text-accent" : "bg-surface-warm text-text-muted"}`}>
          {on ? <ShieldCheck className="h-4 w-4" /> : <ShieldOff className="h-4 w-4" />}
        </span>
        <div className="min-w-0 flex-1">
          <div className="text-sm font-semibold text-text-primary">{on ? "On, nothing reaches another party without you" : "Off, approved actions run as addressed"}</div>
          <div className="mt-0.5 text-xs text-text-secondary">
            {on
              ? "Email to anyone but you waits as a draft, and sensitive details are held until you release them."
              : "Approved sends go out as addressed, unscanned."}
          </div>
        </div>
        <Toggle on={on} disabled={busy} onChange={toggle} label="Outbound guardrail" />
      </div>
      <StatusChips items={chips} expected={on} />
    </div>
  );
}

export type PrivacyPart = "bunker" | "vault-lock" | "incognito" | "guardrail" | "always" | "telemetry";
const PRIVACY_PART_TITLE: Record<PrivacyPart, [string, string]> = {
  bunker: ["Bunker Mode", "Where your data can go."],
  "vault-lock": ["Vault Lock", "What files the assistant can touch."],
  incognito: ["Incognito", "How much of you the model sees."],
  guardrail: ["Outbound Guardrail", "Whether anything can reach another party without you."],
  always: ["Runs without asking", "Tools you approved once that now run without asking in one domain. Anything sensitive still waits for you."],
  telemetry: ["Telemetry", "Anonymous, opt-in, off by default."],
};
// part: one control on its own (the Privacy & Safety page gives each a row).
export function PrivacyConnectivitySection({ enabled, onChange, vaultPath, part }: { enabled: boolean; onChange: (on: boolean) => void; vaultPath?: string; part?: PrivacyPart }) {
  const show = (p: PrivacyPart) => !part || part === p;
  type BunkerStatus = { enabled: boolean; network_blocked: boolean; web_blocked: boolean; cloud_blocked: boolean; local_available: boolean };
  const [status, setStatus] = useState<BunkerStatus | null>(null);
  const [confirmOff, setConfirmOff] = useState(false);
  const [busy, setBusy] = useState(false);
  const refresh = useCallback(() => {
    invoke<BunkerStatus>("bunker_status").then(setStatus).catch(() => {});
  }, []);
  useEffect(() => { refresh(); }, [refresh]);

  async function setBunker(on: boolean) {
    setBusy(true);
    try {
      const s = await invoke<BunkerStatus>("bunker_set", { enabled: on });
      setStatus(s);
      onChange(!!s.enabled);
    } catch (e) {
      console.error("bunker_set", e);
    } finally {
      setBusy(false);
      setConfirmOff(false);
    }
  }

  // Turning OFF requires confirmation; turning ON is immediate.
  function onToggle(next: boolean) {
    if (!next) { setConfirmOff(true); return; }
    void setBunker(true);
  }

  // What's blocked vs open right now, as visual tiles. "good" = the
  // privacy-protective state (blocked / available). Each maps an icon to its
  // on/off variant so the page reads at a glance.
  const tiles = [
    {
      good: !!status?.network_blocked,
      Icon: status?.network_blocked ? WifiOff : Wifi,
      label: "Network",
      state: status?.network_blocked ? "Blocked" : "Allowed",
    },
    {
      good: !!status?.web_blocked,
      Icon: status?.web_blocked ? Search : Globe,
      label: "Web search",
      state: status?.web_blocked ? "Blocked" : "Allowed",
    },
    {
      good: !!status?.cloud_blocked,
      Icon: status?.cloud_blocked ? CloudOff : Cloud,
      label: "Cloud AI",
      state: status?.cloud_blocked ? "Blocked" : "Allowed",
    },
    {
      good: !!status?.local_available,
      Icon: Cpu,
      label: "Local models",
      state: status?.local_available ? "Available" : "Not detected",
    },
  ];

  return (
    <>
      <SettingsHeader
        title={part ? PRIVACY_PART_TITLE[part][0] : "Privacy"}
        subtitle={part ? PRIVACY_PART_TITLE[part][1] : "Four independent controls. Any combination works."}
      />

      {/* ── SECTION 1 - BUNKER MODE: where your data can go ─────────────────── */}
      {show("bunker") && <section>
        {!part && <PrivacyGroupHead
          title="Bunker Mode"
          blurb="Where your data can go."
        />}

        {/* Control card - SAME shape/weight as Vault Lock and Incognito so no one
            section dominates. The per-channel live status lives inside the card
            as compact chips, not a separate hero grid. */}
        <div className="py-1">
          <div className="flex items-center gap-3">
            <span className={`flex h-9 w-9 shrink-0 items-center justify-center rounded-lg ${enabled ? "bg-accent-soft text-accent" : "bg-surface-warm text-text-muted"}`}>
              {enabled ? <ShieldCheck className="h-4 w-4" /> : <ShieldOff className="h-4 w-4" />}
            </span>
            <div className="min-w-0 flex-1">
              <div className="text-sm font-semibold text-text-primary">{enabled ? "On, fully local" : "Off, cloud connected"}</div>
              <div className="mt-0.5 text-xs text-text-secondary">
                {enabled
                  ? "Everything stays on this device. Nothing leaves your machine."
                  : "Cloud AI, web search and network access are available."}
              </div>
            </div>
            <Toggle on={enabled} disabled={busy} onChange={onToggle} label="Bunker Mode" />
          </div>

          {/* Compact live status - what's blocked vs open right now. */}
          <StatusChips items={tiles} expected={enabled} />
          {!status?.local_available && enabled && (
            <a href="https://ollama.com/download" target="_blank" rel="noreferrer"
              className="mt-2 inline-flex items-center gap-1.5 text-xs text-accent hover:underline">
              <Cpu className="h-3.5 w-3.5" /> No local model detected. Install Ollama to run on-device.
            </a>
          )}
        </div>
      </section>}

      {/* Leave-Bunker-Mode confirmation */}
      {confirmOff && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4 backdrop-blur-sm" onClick={() => setConfirmOff(false)}>
          <div className="w-full max-w-md overflow-hidden rounded-2xl border border-border bg-surface shadow-2xl" onClick={(e) => e.stopPropagation()}>
            <div className="flex items-center gap-3 border-b border-black/20 bg-[#141416] px-5 py-4">
              <div className="flex h-11 w-11 shrink-0 items-center justify-center rounded-2xl bg-white/10">
                <ShieldOff className="h-5 w-5 text-white" />
              </div>
              <div className="min-w-0">
                <h3 className="font-display text-[15px] font-semibold text-white">Leave Bunker Mode?</h3>
                <p className="text-xs text-white/60">This opens your machine to the network.</p>
              </div>
            </div>
            <div className="px-5 py-4">
              <p className="text-sm text-text-secondary">Turning this off enables:</p>
              <div className="mt-3 grid grid-cols-1 gap-2">
                {([
                  [Cloud, "Cloud AI providers"],
                  [Globe, "Internet access"],
                  [Search, "Web search"],
                  [Server, "External services"],
                ] as const).map(([Icon, label]) => (
                  <div key={label} className="flex items-center gap-2.5 rounded-lg border border-border-subtle bg-background px-3 py-2 text-sm text-text-secondary">
                    <Icon className="h-4 w-4 shrink-0 text-text-muted" />
                    {label}
                  </div>
                ))}
              </div>
              <p className="mt-3 text-xs text-text-muted">Your data may be transmitted to third-party services depending on which features you use.</p>
            </div>
            <div className="flex justify-end gap-2 border-t border-border-subtle bg-surface-warm/40 px-5 py-3">
              <button onClick={() => setConfirmOff(false)} className="rounded-lg border border-border bg-surface px-4 py-2 text-sm font-medium hover:bg-surface-strong">Cancel</button>
              <button onClick={() => void setBunker(false)} disabled={busy} className="inline-flex items-center gap-1.5 rounded-lg bg-[#141416] px-4 py-2 text-sm font-semibold text-white shadow-sm hover:opacity-90 disabled:opacity-50">
                <ShieldOff className="h-4 w-4" /> Leave Bunker Mode
              </button>
            </div>
          </div>
        </div>
      )}

      {/* ── SECTION 2 - VAULT LOCK: what files the assistant can touch ──────── */}
      {show("vault-lock") && <section className={part ? "" : "mt-6 border-t border-border-subtle pt-6"}>
        {!part && <PrivacyGroupHead
          title="Vault Lock"
          blurb="What files the assistant can touch."
        />}
        <VaultLockToggle />
      </section>}

      {/* ── SECTION 3 - INCOGNITO: how much of you the model sees ───────────── */}
      {show("incognito") && <section className={part ? "" : "mt-6 border-t border-border-subtle pt-6"}>
        {!part && <PrivacyGroupHead
          title="Incognito"
          blurb="How much of you the model sees."
        />}
        <GlobalIncognitoToggle />
      </section>}

      {/* ── SECTION 4 - OUTBOUND GUARDRAIL: nothing reaches another party ───── */}
      {show("guardrail") && <section className={part ? "" : "mt-6 border-t border-border-subtle pt-6"}>
        {!part && <PrivacyGroupHead
          title="Outbound Guardrail"
          blurb="Whether anything can reach another party without you."
        />}
        <OutboundGuardrailToggle />
      </section>}

      {/* ── SECTION 5 - ALWAYS ALLOWED: the approvals you chose not to repeat ── */}
      {vaultPath && show("always") && (
        <section className={part ? "" : "mt-6 border-t border-border-subtle pt-6"}>
          {!part && <PrivacyGroupHead
            title="Runs without asking"
            blurb="Tools that run without asking in one domain. Anything sensitive still waits for you."
          />}
          <AlwaysAllowedCard vaultPath={vaultPath} />
        </section>
      )}

      {/* Telemetry lives under Privacy (moved from Safety). Anonymous, opt-in,
          default-OFF. Brings its own border-t / heading. */}
      {show("telemetry") && <TelemetrySettings />}
    </>
  );
}

// ─── General preferences storage ──────────────────────────────────────
// Read/write small boolean + string prefs to localStorage with sensible
// defaults. Exported helpers used at call sites (textarea, chat chunk
// handlers, etc.) to read live.

// Local, cloud and harness runtimes, grouped the same way on the Models page
// and the Council page.
const LOCAL_RUNTIME_IDS = new Set(["ollama", "omlx", "mlx", "lmstudio", "lm-studio", "localai", "llamacpp"]);
function groupRuntimes(list: CliInfo[]): { key: string; label: string; list: CliInfo[] }[] {
  const sortReady = (a: CliInfo, b: CliInfo) => Number(b.available) - Number(a.available) || a.label.localeCompare(b.label);
  const AGGREGATOR_IDS = new Set(["openrouter", "bedrock"]);
  const isLocal = (id: string) => LOCAL_RUNTIME_IDS.has(id.toLowerCase());
  const cliRuntimes = list.filter((c) => !isHarnessRuntime(c.id) && !AGGREGATOR_IDS.has(c.id)).sort(sortReady);
  return [
    { key: "cloud", label: "Cloud models", list: cliRuntimes.filter((c) => !isLocal(c.id)) },
    { key: "local", label: "Local models", list: cliRuntimes.filter((c) => isLocal(c.id)) },
    { key: "harness", label: "Harnesses", list: list.filter((c) => isHarnessRuntime(c.id)).sort(sortReady) },
  ].filter((g) => g.list.length > 0);
}

// FrameworkPickerCard was deleted with v0.2.92 - the chip-row UI
// it provided lived only in Settings → Defaults as a duplicate of
// the dedicated Settings → Frameworks page. The full two-column
// FrameworksSection is now the single source of truth.

// ─────────────────────────────────────────────────────────────────────
// Integration cards (Telegram / WhatsApp / MCP / Briefings) are now
// rendered directly inside Settings → Integrations. Old ToolsPanel
// wrapper removed.

// Economy / Balanced / Quality bias plus cascade escalation for the "Auto"
// router, in ONE compact row that sits above the model list of any runtime
// that offers Auto. Both persist globally (prevail.route.bias, default
// "balanced"; prevail.route.cascade, default off) and are forwarded to the
// engine only on auto turns. Cascade answers an ambiguous prompt with a cheaper
// model first and escalates only when a confidence check fails, so it can cost
// two calls: slower, usually cheaper. Obvious easy/hard prompts never cascade.
export const ROUTE_BIAS_KEY = "prevail.route.bias";
export const ROUTE_CASCADE_KEY = "prevail.route.cascade";
type RouteBiasValue = "economy" | "balanced" | "quality";
const ROUTE_BIAS_OPTIONS: { id: RouteBiasValue; label: string; blurb: string }[] = [
  { id: "economy", label: "Economy", blurb: "Cheaper and faster" },
  { id: "balanced", label: "Balanced", blurb: "Cost against quality" },
  { id: "quality", label: "Quality", blurb: "Strongest model every time" },
];
function readRouteBias(): RouteBiasValue {
  const v = lsGet(ROUTE_BIAS_KEY, "balanced");
  return v === "economy" || v === "quality" ? v : "balanced";
}
function readRouteCascade(): boolean { return lsGet(ROUTE_CASCADE_KEY, "0") === "1"; }

function RoutingRow() {
  const [bias, setBias] = useState<RouteBiasValue>(readRouteBias);
  const [cascade, setCascade] = useState<boolean>(readRouteCascade);
  // Stay in sync if another runtime's detail (or another window) changed it.
  useEffect(() => {
    const hb = () => setBias(readRouteBias());
    const hc = () => setCascade(readRouteCascade());
    window.addEventListener("prevail:route-bias-changed", hb);
    window.addEventListener("prevail:route-cascade-changed", hc);
    return () => {
      window.removeEventListener("prevail:route-bias-changed", hb);
      window.removeEventListener("prevail:route-cascade-changed", hc);
    };
  }, []);
  const pickBias = (v: RouteBiasValue) => {
    setBias(v);
    lsSet(ROUTE_BIAS_KEY, v);
    window.dispatchEvent(new Event("prevail:route-bias-changed"));
  };
  const setCascadeOn = (v: boolean) => {
    setCascade(v);
    lsSet(ROUTE_CASCADE_KEY, v ? "1" : "0");
    window.dispatchEvent(new Event("prevail:route-cascade-changed"));
  };
  return (
    <section data-testid="auto-routing" className="border-t border-border-subtle px-5 py-4">
      <h4 className="flex items-center gap-1.5 text-[15px] font-semibold text-text-primary"><Sparkles className="h-4 w-4 text-accent" /> Auto routing</h4>
      <p className="mt-0.5 text-[13px] text-text-muted">When a chat uses Auto, Glyph Studio picks a model for each prompt. Lean it toward cost or quality.</p>
    <div className="mt-3 flex flex-wrap items-center gap-x-3 gap-y-2">
      <div className="inline-flex rounded-md border border-border bg-background p-0.5" role="radiogroup" aria-label="Auto routing bias">
        {ROUTE_BIAS_OPTIONS.map((o) => (
          <button
            key={o.id}
            role="radio"
            aria-checked={bias === o.id}
            onClick={() => pickBias(o.id)}
            title={o.blurb}
            className={`rounded px-2.5 py-1 text-xs transition-colors ${bias === o.id ? "bg-accent text-background shadow-sm" : "text-text-secondary hover:bg-surface-warm hover:text-text-primary"}`}
          >
            {o.label}
          </button>
        ))}
      </div>
      <span className="text-xs text-text-muted">{ROUTE_BIAS_OPTIONS.find((o) => o.id === bias)?.blurb}</span>
      <label
        className="ml-auto inline-flex cursor-pointer items-center gap-2 text-xs text-text-secondary"
        title="Answer ambiguous prompts with a cheaper model first and escalate only if it is not confident. Can cost two calls, so it is slower but often cheaper."
      >
        <Toggle on={cascade} onChange={setCascadeOn} label="Cascade escalation" />
        Try a cheaper model first
      </label>
    </div>
    </section>
  );
}

// A model matches the page search by its name, id or one-line blurb.
function modelMatches(m: { id: string; label: string; blurb?: string }, q: string): boolean {
  return m.label.toLowerCase().includes(q) || m.id.toLowerCase().includes(q) || (m.blurb ?? "").toLowerCase().includes(q);
}

// A quiet status pill: colored dot (or spinner) + a two-word sentence-case
// label. Used for the runtime's health and for a failed model row.
type ChipTone = "ok" | "warn" | "err" | "muted";
function StatusChip({ tone, label, spin, title }: { tone: ChipTone; label: string; spin?: boolean; title?: string }) {
  // Status is a small dot and a word, never a filled pill.
  const cls = tone === "err" ? "text-err" : tone === "warn" ? "text-warn" : "text-text-muted";
  const dot = tone === "ok" ? "bg-ok" : tone === "warn" ? "bg-warn" : tone === "err" ? "bg-err" : "bg-text-muted";
  return (
    <span title={title} className={`inline-flex shrink-0 items-center gap-1.5 text-[12px] ${cls}`}>
      {spin ? <Loader2 className="h-3 w-3 animate-spin" /> : <span className={`h-1.5 w-1.5 rounded-full ${dot}`} />}
      {label}
    </span>
  );
}

const btnSecondary = "inline-flex items-center gap-1.5 text-[13px] font-medium text-text-secondary transition-colors hover:text-accent disabled:opacity-40";
const btnPrimary = "inline-flex items-center gap-1.5 rounded-lg bg-accent px-4 py-2 text-sm font-semibold text-background transition-colors hover:bg-accent-hover";

export function AgentCard({
  cli,
  onStartChat,
  isDefault,
  onMakeDefault,
  cost,
  chattable = true,
  forceOpen = false,
  query = "",
}: {
  /** The page search: only the models that match are listed. */
  query?: string;
  cli: CliInfo;
  onStartChat?: (cliId: string, modelId?: string) => void;
  isDefault?: boolean;
  onMakeDefault?: () => void;
  /** Cumulative spend on this runtime (USD), from the usage ledger. */
  cost?: number;
  /** Whether this runtime can power the chat composer. Harnesses are false , 
      they're catalog-only and never offered "Start chat". */
  chattable?: boolean;
  /** Render always-expanded with no collapse chevron - used as the detail pane
      in the Runtimes master-detail, where the row IS the only thing shown. */
  forceOpen?: boolean;
}) {
  const brand = VENDOR_BRAND[cli.id] ?? VENDOR_BRAND.other;
  const liveVerify = useCliVerifyLive();
  // Re-render when live discovery fills in new models.
  const [, setModelsNonce] = useState(0);
  useEffect(() => {
    const h = () => setModelsNonce((n) => n + 1);
    window.addEventListener("prevail:models-refreshed", h);
    return () => window.removeEventListener("prevail:models-refreshed", h);
  }, []);
  const allModels = modelsFor(cli.id);
  const q = query.trim().toLowerCase();
  const runtimeHit = !q || cli.label.toLowerCase().includes(q) || cli.id.includes(q);
  const models = runtimeHit ? allModels : allModels.filter((m) => modelMatches(m, q));
  // "auto" is a router sentinel, not a real model: it can't be verified and must
  // not count against the "N of M verified" tally or trigger a verify call.
  const verifiable = models.filter((m) => m.id !== "auto");
  const [open, setOpen] = useState(false);
  const isOpen = forceOpen || open;
  // The provider's default model (what a new chat uses). Set right here in
  // Models, so there's no separate Defaults page.
  const modelKey = `prevail.model.${cli.id}`;
  const [defaultModel, setDefaultModel] = useState(() => lsGet(modelKey) || models[0]?.id || "");
  useEffect(() => { if (defaultModel) lsSet(modelKey, defaultModel); }, [modelKey, defaultModel]);
  const setAsDefault = (modelId: string) => { setDefaultModel(modelId); onMakeDefault?.(); };
  const [status, setStatus] = useState<Record<string, ModelVerifyStatus>>(() => {
    const map = loadVerifyMap();
    const out: Record<string, ModelVerifyStatus> = {};
    for (const m of models) {
      const key = `${cli.id}:${m.id}`;
      if (map[key] === "ok") out[m.id] = "ok";
    }
    return out;
  });
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [cmdCopied, setCmdCopied] = useState(false);
  const [idCopied, setIdCopied] = useState("");

  async function verifyModel(modelId: string) {
    if (modelId === "auto") return; // sentinel, nothing to verify
    setStatus((s) => ({ ...s, [modelId]: "verifying" }));
    try {
      await invoke<string>("verify_cli_model", {
        args: { cli: cli.id, model: modelId || null },
      });
      setStatus((s) => {
        const next = { ...s, [modelId]: "ok" as ModelVerifyStatus };
        const map = loadVerifyMap();
        map[`${cli.id}:${modelId}`] = "ok";
        saveVerifyMap(map);
        return next;
      });
      setErrors((e) => { const { [modelId]: _, ...rest } = e; return rest; });
      setCliVerify(cli.id, { status: "ok" }); // any working model = usable provider
    } catch (e) {
      setStatus((s) => ({ ...s, [modelId]: "failed" }));
      setErrors((er) => ({ ...er, [modelId]: String(e).slice(0, 200) }));
      // Only demote the provider when nothing of it has verified ok.
      if (cliVerifyLive.get(cli.id)?.status !== "ok") {
        setCliVerify(cli.id, { status: "failed", error: String(e).slice(0, 200) });
      }
    }
  }

  function verifyAll() {
    for (const m of verifiable) {
      if (status[m.id] === "ok" || status[m.id] === "verifying") continue;
      void verifyModel(m.id);
    }
  }

  // Auto-run verification when the card is opened the first time
  // and there are unverified models in the list.
  useEffect(() => {
    if (!isOpen) return;
    const unverified = verifiable.some((m) => status[m.id] !== "ok");
    if (unverified) verifyAll();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isOpen]);

  const copyText = (text: string, done: () => void) => {
    navigator.clipboard.writeText(text).then(done).catch(() => {});
  };

  const cliErr = liveVerify.get(cli.id);
  const meta = RUNTIME_META[cli.id];
  const verifiedCount = verifiable.filter((m) => status[m.id] === "ok").length;

  // Runtime health, one chip. Sentence case, two words at most.
  const health = (() => {
    if (!cli.available) {
      return cli.error
        ? { tone: "err" as ChipTone, label: "Won't run", title: cli.error }
        : { tone: "muted" as ChipTone, label: "Not installed" };
    }
    const v = cliVerifyLive.get(cli.id);
    if (v?.status === "ok") return { tone: "ok" as ChipTone, label: "Ready" };
    if (v?.status === "failed") {
      const login = authLoginCmd(cli.id, v.error ?? "");
      return { tone: "err" as ChipTone, label: login !== null ? "Not signed in" : "Not working", title: v.error ?? undefined };
    }
    if (v?.status === "verifying") return { tone: "warn" as ChipTone, label: "Checking", spin: true };
    return { tone: "muted" as ChipTone, label: "Detected" };
  })();

  // The one-line fact strip under the name: vendor, version, spend, verified.
  const metaParts: string[] = [...(isDefault ? ["Default"] : []), brand.name];
  if (cli.available && cli.version) metaParts.push(`Version ${cli.version}`);
  if (typeof cost === "number" && cost > 0) metaParts.push(`$${cost < 1 ? cost.toFixed(2) : cost < 100 ? cost.toFixed(1) : Math.round(cost)} spent`);
  if (cli.available && verifiable.length > 0) metaParts.push(`${verifiedCount} of ${verifiable.length} models verified`);

  // Runtime-level secondary actions, behind one menu in the header.
  const runtimeMenu: RowMenuItem[] = [];
  if (cli.available && verifiable.length > 0) runtimeMenu.push({ icon: RefreshCw, label: "Verify all models", onClick: verifyAll });
  if (cli.available) runtimeMenu.push({ icon: RefreshCw, label: "Re-check runtime", onClick: () => recheckCli(cli.id) });
  if (meta?.install) runtimeMenu.push({ icon: ArrowUpRight, label: "Open setup guide", onClick: () => { window.open(meta.install, "_blank", "noreferrer"); } });

  return (
    <div className={forceOpen ? "" : `rounded-lg border bg-surface transition-colors ${open ? "border-accent-border" : "border-border-subtle"}`}>
      {/* Header: mark, big name, health chip, fact strip, ONE primary action. */}
      <div className="flex items-center gap-4 px-5 py-4">
        <ProviderMark vendor={cli.id} size={44} />
        <button
          onClick={() => !forceOpen && cli.available && setOpen((v) => !v)}
          disabled={forceOpen || !cli.available || models.length === 0}
          className="min-w-0 flex-1 text-left disabled:cursor-default"
        >
          <span className="flex items-center gap-2">
            {!forceOpen && cli.available && models.length > 0 && (
              <ChevronRight className={`h-3.5 w-3.5 shrink-0 text-text-muted transition-transform ${open ? "rotate-90" : ""}`} />
            )}
            <span className="truncate text-[15px] font-semibold text-text-primary">{cli.label}</span>
            <StatusChip tone={health.tone} label={health.label} spin={health.spin} title={health.title} />
          </span>
          <span data-testid="runtime-meta" className="mt-0.5 block truncate text-xs text-text-muted">{metaParts.join("  ·  ")}</span>
        </button>
        {cli.available && chattable ? (
          <button onClick={() => onStartChat?.(cli.id)} className={btnPrimary}>
            Start chat
          </button>
        ) : cli.available && !chattable ? (
          // Harness, installed: catalog-only (not a homepage chat runtime).
          <span className="text-xs text-text-muted" title="Harness: set up here; not a chat runtime">Ready to use</span>
        ) : (
          <a
            href={meta?.install ?? "#"}
            target="_blank"
            rel="noreferrer"
            title={meta?.blurb ? `${meta.blurb} (opens setup docs)` : "Open setup docs"}
            className="inline-flex items-center gap-1.5 rounded-lg border border-border bg-background px-4 py-2 text-sm font-medium text-text-secondary transition-colors hover:border-accent-border hover:text-accent"
          >
            Set up <ArrowUpRight className="h-3.5 w-3.5" />
          </a>
        )}
        {runtimeMenu.length > 0 && <RowMenu items={runtimeMenu} label="Runtime actions" />}
      </div>

      {/* Why it's not working, on the card face: usually an auth/token problem,
          so lead with the fix (the login command) rather than the stack. */}
      {cli.available && cliErr?.status === "failed" && cliErr.error && (
        <div className="flex items-center gap-2.5 border-t border-border-subtle bg-warn/5 px-5 py-2.5">
          <div className="min-w-0 flex-1 text-xs text-text-secondary">
            {(() => {
              const loginCmd = authLoginCmd(cli.id, cliErr.error ?? "");
              return loginCmd ? (
                <span className="flex items-center gap-2.5"><AlertTriangle className="h-3.5 w-3.5 shrink-0 text-warn" /><span>Not signed in. Run <code className="rounded bg-surface-warm px-1.5 py-0.5 font-mono text-[12px] text-accent">{loginCmd}</code> in a terminal, then re-check.</span></span>
              ) : (
                <ErrorLine error={cliErr.error ?? ""} />
              );
            })()}
          </div>
          <button onClick={() => recheckCli(cli.id)} className={btnSecondary}>Re-check</button>
        </div>
      )}

      {/* Auto routing, its own section, only for runtimes that offer "Auto". */}
      {isOpen && cli.available && models.some((m) => m.id === "auto") && <RoutingRow />}

      {isOpen && cli.available && models.length > 0 && (
        <div className="border-t border-border-subtle px-5 py-4">
          <div className="mb-3 flex items-baseline gap-2">
            <h4 className="text-[15px] font-semibold text-text-primary">Models</h4>
            <span className="text-[12px] text-text-muted">{models.length}</span>
            {verifiable.length > 0 && (
              <button onClick={verifyAll} className="ml-auto text-xs text-text-secondary hover:text-accent">
                Verify all
              </button>
            )}
          </div>
          <div className="divide-y divide-border-subtle">
            {models.map((m) => {
              const s = status[m.id];
              const err = errors[m.id];
              const isAuto = m.id === "auto";
              const isDef = defaultModel === m.id;
              const failed = s === "failed";
              const loginCmd = failed && err ? authLoginCmd(cli.id, err) : null;
              const idTip = m.resolved && m.resolved !== m.id ? `${m.id} (resolves to ${m.resolved})` : m.id;
              const glyph = isAuto
                ? <Sparkles className="h-4 w-4 text-accent" />
                : s === "ok" ? <CircleCheck className="h-4 w-4 text-ok" />
                : s === "verifying" ? <Loader2 className="h-4 w-4 animate-spin text-text-muted" />
                : failed ? <CircleX className="h-4 w-4 text-err" />
                : <Circle className="h-4 w-4 text-text-muted/40" />;
              const glyphTip = isAuto ? "Router: picks a model per prompt" : s === "ok" ? "Verified" : s === "verifying" ? "Checking" : failed ? "Failed" : "Not checked yet";
              const menu: RowMenuItem[] = [];
              if (!isDef) menu.push({ icon: Star, label: "Use as default", hint: "New chats start here", onClick: () => setAsDefault(m.id) });
              if (!isAuto) menu.push({ icon: RefreshCw, label: s === "ok" || failed ? "Test again" : "Test now", disabled: s === "verifying", onClick: () => { void verifyModel(m.id); } });
              menu.push({
                icon: LineChart,
                label: "Benchmark runs",
                hint: "Scores, domains, history",
                onClick: () => {
                  // Jump to the Arena with this model's runs expanded (key matches
                  // the leaderboard aggregation).
                  lsSet("prevail.bench.expandModel", `${cli.id}::${m.label}`);
                  window.dispatchEvent(new CustomEvent("prevail:settings-section", { detail: "benchmark" }));
                },
              });
              menu.push({ kind: "separator" });
              menu.push({ icon: Copy, label: idCopied === m.id ? "Copied" : "Copy model id", hint: idTip, onClick: () => copyText(m.id, () => { setIdCopied(m.id); window.setTimeout(() => setIdCopied(""), 1500); }) });
              return (
                <div key={m.id} className="group flex items-center gap-3 py-2.5">
                  <span className="flex w-5 shrink-0 justify-center" title={glyphTip}>{glyph}</span>
                  <div className="min-w-0 flex-1">
                    <div className="flex items-center gap-2">
                      {/* A failed model is muted by color, not opacity: opacity would
                          also fade the row's popover menu. */}
                      <span className={`truncate text-sm font-medium ${failed ? "text-text-muted" : "text-text-primary"}`} title={`Model id: ${idTip}`}>{m.label}</span>
                      {isDef && <span className="shrink-0 text-[12px] font-medium text-accent">Default</span>}
                      {failed && (
                        <StatusChip
                          tone="err"
                          label={loginCmd !== null ? "Not signed in" : "Failed"}
                          title={loginCmd ? `Run ${loginCmd} in a terminal, then test again. ${err}` : err}
                        />
                      )}
                    </div>
                    {m.blurb && <div className={`truncate text-xs ${failed ? "text-text-muted/60" : "text-text-muted"}`}>{m.blurb}</div>}
                    {failed && err && !loginCmd && <ErrorLine error={err} tone="err" className="mt-1" />}
                  </div>
                  {!failed && <span data-testid="model-status" className="shrink-0 text-[12px] text-text-muted">{isAuto ? "Router" : s === "ok" ? "Verified" : s === "verifying" ? "Checking" : "Not checked"}</span>}
                  {chattable && (
                    <span className={REVEAL}><RowAction icon={MessageSquare} label={`Chat with ${m.label}`} doneLabel="Opening chat" onClick={() => onStartChat?.(cli.id, m.id)} testId="model-chat" /></span>
                  )}
                  <RowMenu items={menu} reveal label={`More actions for ${m.label}`} />
                </div>
              );
            })}
          </div>
        </div>
      )}

      {/* Installed but no model list (harnesses): the body was previously blank,
          which read as "broken." Explain what it is and that it's ready. */}
      {isOpen && cli.available && models.length === 0 && (
        <div className="space-y-2 border-t border-border-subtle px-5 py-4">
          <div className="text-sm text-text-secondary">
            {meta?.blurb || `${cli.label} is a harness runtime.`}
          </div>
          <p className="text-xs leading-relaxed text-text-muted">
            This is a <span className="font-semibold text-text-secondary">Harness</span>: it wraps the{" "}
            <code className="text-accent">{meta?.protocol ?? "base"}</code> protocol and runs through your installed base CLI. It's installed and validated, so it's ready to use wherever harnesses are offered (it isn't a homepage chat runtime).
          </p>
          <div className="flex flex-wrap items-center gap-2 pt-0.5">
            <span className="text-xs text-text-muted">{cli.version ? `Version ${cli.version} · ` : ""}{cli.bin}</span>
            {meta?.install && (
              <a href={meta.install} target="_blank" rel="noreferrer" className={btnSecondary}>
                Docs <ArrowUpRight className="h-3 w-3" />
              </a>
            )}
          </div>
        </div>
      )}

      {/* Not installed: a real setup body (not just a tiny link), so the detail
          pane always says something actionable. */}
      {isOpen && !cli.available && (
        <div className="space-y-3 border-t border-border-subtle px-5 py-4">
          <div className="text-sm text-text-secondary">
            {cli.error
              ? `${cli.label} is installed but won't run: its launcher is on disk but failed to start.`
              : meta?.blurb || `${cli.label} isn't installed on this Mac yet.`}
          </div>
          {/* Broken install: show the actual failure so the user knows what to
              fix (the most common cause is a wrapper pointing at a removed env). */}
          {cli.error && <ErrorLine error={cli.error} tone="err" className="rounded-md border border-err/30 bg-err/5 px-2.5 py-2" />}
          <div className="space-y-2.5 rounded-lg border border-border-subtle bg-background p-3">
            <div className="text-sm font-semibold text-text-primary">{cli.error ? `Reinstall ${cli.label}` : `Set up ${cli.label}`}</div>
            <p className="text-xs leading-relaxed text-text-secondary">
              {cli.error
                ? `Reinstall ${cli.label} to repair the launcher. It runs on your own subscription, no key to paste here. Glyph Studio auto-detects it; hit Re-check once it's fixed.`
                : `Install ${cli.label} from its setup guide. It runs on your own subscription, no key to paste here. Glyph Studio auto-detects it; hit Re-check once it's installed.`}
            </p>
            {meta?.cmd && (
              <div className="flex items-center gap-2 rounded-md border border-border-subtle bg-surface-warm/60 px-2 py-1.5">
                <code className="min-w-0 flex-1 truncate font-mono text-[12px] text-text-primary" title={meta.cmd}>{meta.cmd}</code>
                <button
                  onClick={() => { void invoke("open_in_terminal", { command: meta.cmd }).catch((e) => console.error("open_in_terminal", e)); }}
                  title="Open Terminal and run this install command (you'll see it run and can confirm any prompts)"
                  className="inline-flex shrink-0 items-center gap-1 rounded-md border border-accent-border bg-accent-soft px-2.5 py-1 text-xs text-accent hover:bg-accent hover:text-background"
                >
                  <Terminal className="h-3 w-3" /> Install
                </button>
                <button
                  onClick={() => copyText(meta.cmd!, () => { setCmdCopied(true); window.setTimeout(() => setCmdCopied(false), 1500); })}
                  className={btnSecondary}
                >
                  {cmdCopied ? <><Check className="h-3 w-3" /> Copied</> : "Copy"}
                </button>
              </div>
            )}
            <div className="flex flex-wrap items-center gap-2">
              {meta?.install && (
                <a href={meta.install} target="_blank" rel="noreferrer" className={btnPrimary}>
                  Open setup guide <ArrowUpRight className="h-3.5 w-3.5" />
                </a>
              )}
              <button onClick={() => recheckCli(cli.id)} className={btnSecondary}>Re-check</button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}


// Pick a representative icon for a settings page from its title, so every
// header gets a matching glyph without threading an icon through 20 call sites.

// Header hierarchy, level 2: a subsection within a settings page. Sits clearly
// below the big SettingsHeader (level 1) and above the small mono group labels
// (level 3), so the eye reads page -> subsection -> group without guessing.
// Display-weight, sentence case, with a hairline rule underneath.

// Header hierarchy, level 3: a small group label inside a subsection (e.g.
// "Detected · 2"). The quietest of the three so it never competes with a
// level-2 SubsectionHeader.

// Privacy & Connectivity - the Bunker Mode control surface. The toggle + status
// card here reflect the BACKEND policy (bunker.rs), which is the real source of
// truth and enforcer; this screen never decides anything on its own.

// One row in the Runtimes master-detail list: provider mark, name, a health
// dot, version sub-line, and the default marker. Selecting it shows the runtime
// detail (an always-open AgentCard) on the right.
function RuntimeRow({ cli, active, vstatus, isDefault, onSelect, matches }: {
  // Models that matched the page search, named under the runtime.
  matches?: string[];
  cli: CliInfo;
  active: boolean;
  vstatus?: string;
  isDefault?: boolean;
  onSelect: () => void;
}) {
  // Broken = on disk but won't run (detect_clis returned an error). Distinct
  // from genuinely not-installed, so the row never disagrees with the detail
  // panel's BROKEN / "won't run" status.
  const broken = !cli.available && !!cli.error;
  // One lucide glyph per state, colored, no badge background: the row stays
  // quiet and the color alone says ready / checking / failed / absent.
  const state: { Icon: LucideIcon; cls: string; tip: string } = !cli.available
    ? broken
      ? { Icon: CircleX, cls: "text-err", tip: "Installed but won't run" }
      : { Icon: Circle, cls: "text-text-muted/40", tip: "Not installed" }
    : vstatus === "ok"
      ? { Icon: CircleCheck, cls: "text-ok", tip: "Ready" }
      : vstatus === "failed"
        ? { Icon: CircleX, cls: "text-warn", tip: "Not working" }
        : vstatus === "verifying"
          ? { Icon: Loader2, cls: "animate-spin text-text-muted", tip: "Checking" }
          : { Icon: Circle, cls: "text-text-muted/60", tip: "Not checked yet" };
  // Status in words first, then the version.
  const sub = matches?.length ? `Matches ${matches.slice(0, 3).join(", ")}${matches.length > 3 ? ` +${matches.length - 3}` : ""}`
    : cli.available && cli.version ? `${state.tip} · ${cli.version.slice(0, 18)}` : state.tip;
  return (
    <button
      onClick={onSelect}
      className={`flex w-full items-center gap-2.5 rounded-lg px-2.5 py-2 text-left transition-colors ${active ? "bg-surface-warm" : "hover:bg-surface-warm/50"}`}
    >
      <ProviderMark vendor={cli.id} size={28} />
      <span className="min-w-0 flex-1">
        <span className={`block truncate text-sm ${active ? "font-semibold text-text-primary" : "text-text-secondary"}`}>{cli.label}</span>
        <span data-testid="runtime-status" className="block truncate text-[12px] text-text-muted">{sub}</span>
      </span>
      {isDefault && <span className="shrink-0 text-[12px] font-medium text-accent">Default</span>}
      <span className="flex shrink-0" title={state.tip} aria-label={state.tip}><state.Icon className={`h-4 w-4 ${state.cls}`} /></span>
    </button>
  );
}

export function AgentsSection({
  clis,
  onStartChatWith,
  embedded,
  defaultChatCli,
  onMakeDefault,
  vaultPath,
}: {
  clis: CliInfo[];
  onStartChatWith?: (cliId: string, modelId?: string) => void;
  embedded?: boolean;
  defaultChatCli?: string;
  onMakeDefault?: (cliId: string) => void;
  vaultPath?: string;
}) {
  // Runtimes shown as SEPARATE collapsible groups: hosted vendor CLIs (Cloud
  // models: Claude Code, Codex, Gemini, Antigravity, ...), on-device runtimes
  // (Local models: Ollama, LM Studio, MLX, LocalAI, llama.cpp), and harnesses
  // that wrap a base protocol (Pi, OpenCode, Hermes, OpenClaw, Paperclip,
  // Motorcar). Within each, installed runtimes sort first; not-installed show a
  // "Set up" link. All groups open by default so every supported runtime is
  // visible to set up.
  // Aggregators (OpenRouter, Bedrock) are HTTP gateways with their own
  // section, so groupRuntimes leaves them out.
  // Per-runtime spend (cumulative), from the local usage ledger. Shown in the
  // detail; "-" when nothing has been spent / no vault.
  const [costByCli, setCostByCli] = useState<Record<string, number>>({});
  useEffect(() => {
    if (!vaultPath) return;
    let alive = true;
    invoke<UsageSummary>("usage_summary", { vault: vaultPath })
      .then((s) => {
        if (!alive) return;
        const m: Record<string, number> = {};
        for (const b of s.by_cli || []) m[b.key] = b.cost_usd;
        setCostByCli(m);
      })
      .catch(() => {});
    return () => { alive = false; };
  }, [vaultPath]);

  // Master-detail: pick a runtime on the left, see its full detail (an
  // always-open AgentCard) on the right - the canonical app layout.
  // Search across runtimes and their models: a runtime stays when its name
  // matches or any of its models does.
  const [query, setQuery] = useState("");
  const q = query.trim().toLowerCase();
  const modelHits = (c: CliInfo) => (q ? modelsFor(c.id).filter((m) => modelMatches(m, q)).map((m) => m.label) : []);
  const runtimeHit = (c: CliInfo) => !q || c.label.toLowerCase().includes(q) || c.id.includes(q);
  const groups = groupRuntimes(clis)
    .map((g) => ({ ...g, list: g.list.filter((c) => runtimeHit(c) || modelHits(c).length > 0) }))
    .filter((g) => g.list.length > 0);
  const all = groups.flatMap((g) => g.list);
  const verify = useCliVerifyLive();
  const [selectedId, setSelectedId] = useState("");
  const phone = useIsPhone();
  const pickable = (id: string | undefined) => (id && all.some((c) => c.id === id) ? id : "");
  const selectedEff = pickable(selectedId) || pickable(defaultChatCli) || all.find((c) => c.available)?.id || all[0]?.id || "";
  const selected = all.find((c) => c.id === selectedEff) ?? null;
  // Collapsible sub-groups (Cloud / Local / Harnesses), matching the Arena rail's
  // expandable provider groups. Collapsed keys persisted so the rail reopens the
  // same way; all groups open by default.
  const [collapsedGroups, setCollapsedGroups] = useState<Set<string>>(() => {
    try { return new Set(JSON.parse(localStorage.getItem("prevail.runtimes.groupsCollapsed") || "[]")); }
    catch { return new Set(); }
  });
  const toggleGroup = (key: string) => setCollapsedGroups((prev) => {
    const next = new Set(prev);
    if (next.has(key)) next.delete(key); else next.add(key);
    try { localStorage.setItem("prevail.runtimes.groupsCollapsed", JSON.stringify([...next])); } catch { /* ignore */ }
    return next;
  });

  const listEl = (
    <div className="space-y-3">
      {groups.map((g) => {
        const ready = g.list.filter((c) => c.available).length;
        const open = !collapsedGroups.has(g.key);
        return (
          <div key={g.key} className="space-y-1">
            <button
              onClick={() => toggleGroup(g.key)}
              aria-expanded={open}
              data-sticky-head
              className={`flex w-full items-baseline justify-between px-2.5 pb-1 pt-2 transition-colors hover:text-accent ${STICKY_GROUP_HEAD} ${phone ? "bg-background" : "spine-sticky-head"}`}
            >
              <span className="flex items-center gap-1.5 text-[15px] font-semibold text-text-primary">
                <ChevronRight className={`h-3.5 w-3.5 text-text-muted transition-transform ${open ? "rotate-90" : ""}`} strokeWidth={2.5} />
                {g.label} <span className="text-[13px] font-normal text-text-muted">{g.list.length}</span>
              </span>
              <span className="text-[12px] text-text-muted">{ready} of {g.list.length} set up</span>
            </button>
            {open && g.list.map((c) => (
              <RuntimeRow
                key={c.id}
                cli={c}
                active={c.id === selectedEff}
                vstatus={verify.get(c.id)?.status}
                isDefault={defaultChatCli === c.id}
                onSelect={() => setSelectedId(c.id)}
                matches={runtimeHit(c) ? undefined : modelHits(c)}
              />
            ))}
          </div>
        );
      })}
    </div>
  );

  const detailEl = selected ? (
    <AgentCard
      key={selected.id}
      cli={selected}
      forceOpen
      onStartChat={onStartChatWith}
      isDefault={defaultChatCli === selected.id}
      onMakeDefault={onMakeDefault ? () => onMakeDefault(selected.id) : undefined}
      cost={costByCli[selected.id]}
      chattable={!isHarnessRuntime(selected.id)}
      query={query}
    />
  ) : (
    <div className="p-8 text-center text-sm text-text-muted">{q ? "Nothing matches that search." : "Select a runtime to see its status, models, and actions."}</div>
  );

  return (
    <>
      {!embedded && (
        <SettingsHeader
          title="Runtimes"
          subtitle="The runtimes detected on this Mac."
        />
      )}
      <SideSpine storageKey="prevail.runtimes.spine" title="Runtimes" label="runtimes" testId="runtimes-list"
        toolbar={
          <label className="flex h-9 items-center gap-2 rounded-lg border border-border bg-background px-2.5 focus-within:border-accent-border">
            <Search className="h-4 w-4 shrink-0 text-text-muted" aria-hidden />
            <input value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Search runtimes and models" aria-label="Search runtimes and models"
              className="min-w-0 flex-1 bg-transparent text-[14px] text-text-primary outline-none placeholder:text-text-muted" />
          </label>
        }
        phone={phone} phoneDetail={phone && !!selectedId} onBack={() => setSelectedId("")} backLabel="All runtimes"
        detail={<div className="px-2 pb-10 pt-2">{detailEl}</div>}>
        <div className="p-2">{listEl}</div>
      </SideSpine>
    </>
  );
}
