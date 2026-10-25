// Settings sections extracted from App.tsx: Providers (API-key activation +
// OpenRouter catalog) and Models (the per-provider model catalog), plus the
// refreshDiscoveredModels helper they share (imported from helpers2).
import { useEffect, useMemo, useState } from "react";
import { AlertTriangle, Check, Layers, Loader2, Zap } from "lucide-react";
import { invoke } from "./bridge";
import { CollapsibleSection } from "./collapsible";
import { DISCOVERED_MODELS } from "./constants";
import { refreshDiscoveredModels } from "./helpers2";
import { LS, lsGet, lsSet } from "./storage";
import { track } from "./telemetry";

// T18: map a provider id to the telemetry enum vocabulary (anything off-list →
// "other"), so the event records THAT a provider was configured without leaking
// a novel vendor name. Inert until keys exist; default-OFF.
const TELEMETRY_PROVIDERS = new Set(["openrouter", "anthropic", "openai", "google", "ollama", "lmstudio", "bedrock"]);
const telemetryProvider = (id: string): string => (TELEMETRY_PROVIDERS.has(id) ? id : "other");
// Active category tab on the Models page, persisted so it reopens in place.
const LS_MODELS_TAB = "prevail.settings.models.tab.v1";
import { SettingsHeader } from "./sectionutil";
import { SpineTabs } from "./sidespine";
import { toast } from "./toast";
import { autoVerifyClis, setCliVerify } from "./verify";
import { AgentsSection } from "./settings6";
import { OrVendorMark, orVendorOf } from "./providermarks";
import type { CliInfo } from "./types";

export function ProvidersSection({ onActivated, embedded }: { onActivated?: () => Promise<CliInfo[]>; embedded?: boolean }) {
  const [key, setKey] = useState("");
  const [configured, setConfigured] = useState(false);
  const [last4, setLast4] = useState<string | null>(null);
  const [testing, setTesting] = useState(false);
  const [saved, setSaved] = useState(false);
  // I10: after a key save we re-detect providers and confirm OpenRouter is now
  // selectable, so the user gets real activation feedback instead of silence.
  const [activated, setActivated] = useState<boolean | null>(null);
  // Live OpenRouter catalog browser (curated shown by default; search reveals all).
  const [orQuery, setOrQuery] = useState("");
  const [, setOrNonce] = useState(0);
  useEffect(() => {
    invoke<boolean>("provider_key_exists", { provider: "openrouter" }).then((ok) => setConfigured(!!ok)).catch(() => {});
    invoke<string | null>("provider_key_last4", { provider: "openrouter" }).then((v) => setLast4(v ?? null)).catch(() => {});
    const h = () => setOrNonce((n) => n + 1);
    window.addEventListener("prevail:models-refreshed", h);
    return () => window.removeEventListener("prevail:models-refreshed", h);
  }, []);
  const orLive = DISCOVERED_MODELS.openrouter ?? [];
  const orResults = orQuery.trim()
    ? orLive.filter((m) => `${m.id} ${m.label ?? ""}`.toLowerCase().includes(orQuery.trim().toLowerCase())).slice(0, 60)
    : [];
  async function save() {
    try {
      await invoke("provider_key_set", { provider: "openrouter", key: key.trim() });
      track("provider_configured", { provider: "openrouter" });
      setConfigured(!!key.trim());
      setKey("");
      setSaved(true);
      window.setTimeout(() => setSaved(false), 1500);
      // Re-detect so OpenRouter immediately shows as available in every picker,
      // and report back whether activation took.
      if (onActivated) {
        const list = await onActivated();
        const ok = list.some((c) => c.id === "openrouter" && c.available);
        setActivated(ok);
        window.setTimeout(() => setActivated(null), 6000);
      }
    } catch (e) { console.error("provider_key_set", e); toast.error(`Could not save the key: ${String(e)}`); }
  }
  async function remove() {
    try {
      await invoke("provider_key_del", { provider: "openrouter" });
      setConfigured(false);
      setActivated(null);
      if (onActivated) await onActivated();
    } catch (e) { console.error(e); toast.error(`Could not remove the key: ${String(e)}`); }
  }
  return (
    <>
      {!embedded && <SettingsHeader title="Providers" subtitle="Bring your own key, and the models it opens." />}
      <CollapsibleSection
        icon={Layers}
        title="OpenRouter"
        summary={configured ? `Recommended · configured${last4 ? ` · ····${last4}` : ""}` : "Recommended · one key, 200+ models"}
        storageKey="prevail.settings.aggregator.openrouter"
        defaultOpen
      >
      <div className="border-t border-border-subtle pt-4">
        <div className="mb-3 text-xs text-text-secondary">One API key unlocks every model. Used by the engine inside any domain. <a href="https://openrouter.ai/keys" target="_blank" rel="noreferrer" className="text-accent hover:underline">Get a key ›</a></div>
        <div className="flex items-center gap-2">
          <input type="password" value={key} placeholder={configured ? "•••••••• (replace)" : "sk-or-v1-…"} onChange={(e) => setKey(e.target.value)}
            className="flex-1 rounded-md border border-border bg-background px-3 py-1.5 text-sm focus:border-accent-border focus:outline-none" />
          <button onClick={save} disabled={!key.trim()} className="rounded-md bg-text-primary px-3 py-1.5 text-sm font-medium text-background hover:opacity-90 disabled:opacity-40">{saved ? "Saved" : "Save"}</button>
          {configured && (
            <button
              onClick={async () => {
                setTesting(true); setActivated(null);
                try {
                  await invoke<string>("verify_cli_model", { args: { cli: "openrouter", model: lsGet("prevail.model.openrouter") || null } });
                  setActivated(true);
                  setCliVerify("openrouter", { status: "ok" });
                } catch (e) {
                  setActivated(false);
                  setCliVerify("openrouter", { status: "failed", error: String(e).slice(0, 200) });
                } finally { setTesting(false); }
              }}
              disabled={testing}
              className="inline-flex items-center gap-1.5 rounded-md border border-accent-border bg-accent-soft px-3 py-1.5 text-sm text-accent hover:bg-accent hover:text-background disabled:opacity-50"
            >
              {testing ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <Zap className="h-3.5 w-3.5" />}
              {testing ? "Testing…" : "Test live"}
            </button>
          )}
          {configured && <button onClick={remove} className="rounded-md border border-warn/40 bg-warn/10 px-3 py-1.5 text-sm text-warn hover:bg-warn/20">Remove</button>}
        </div>
        {activated === true && (
          <div className="mt-3 flex items-center gap-2 rounded-md border border-accent-border bg-accent-soft px-3 py-2 text-xs text-accent">
            <Check className="h-4 w-4" />
            Live call succeeded: OpenRouter answered with this key. Selectable in Chat, Council, and Benchmark pickers.
          </div>
        )}
        {activated === false && (
          <div className="mt-3 flex items-center gap-2 rounded-md border border-warn/40 bg-warn/10 px-3 py-2 text-xs text-warn">
            <AlertTriangle className="h-4 w-4" />
            Key saved, but OpenRouter didn&apos;t come online. Double-check the key at openrouter.ai/keys.
          </div>
        )}
        {/* Pure search over the full live catalog, every model is available;
            there's no curated/highlighted subset to maintain. */}
        <div className="mt-4 border-t border-border-subtle pt-3">
          <div className="mb-2 flex items-center gap-2 text-[12px] text-text-secondary">
            <Layers className="h-3 w-3 text-accent" /> Model catalog
            {orLive.length > 0 && <span className="text-text-muted normal-case tracking-normal">· {orLive.length} live models, search to browse</span>}
          </div>
          <input
            value={orQuery}
            onChange={(e) => setOrQuery(e.target.value)}
            placeholder={orLive.length > 0 ? `Search all ${orLive.length} live models (e.g. fable, grok, qwen, kimi)…` : "Refresh in Models to load the live catalog…"}
            className="w-full rounded-md border border-border bg-background px-3 py-1.5 font-mono text-xs focus:border-accent-border focus:outline-none"
          />
          {/* The full live catalog, always browsable (icon per vendor). Search
              narrows; otherwise the first 80 are shown so it is never blank. */}
          {orLive.length > 0 && (
            <div className="mt-2 max-h-72 overflow-auto rounded-md border border-border-subtle bg-background">
              {(orQuery.trim() ? orResults : orLive.slice(0, 80)).length === 0 ? (
                <div className="px-3 py-2 text-xs text-text-muted">No models match "{orQuery}".</div>
              ) : (
                (orQuery.trim() ? orResults : orLive.slice(0, 80)).map((m) => (
                  <button
                    key={m.id}
                    onClick={() => { navigator.clipboard.writeText(m.id).catch(() => {}); }}
                    title="Click to copy the model id"
                    className="flex w-full items-center gap-2 px-3 py-1.5 text-left hover:bg-surface-warm"
                  >
                    <OrVendorMark id={m.id} size={16} />
                    <span className="min-w-0 flex-1 truncate font-mono text-[12px] text-text-primary">{m.label && m.label !== m.id ? m.label : m.id}</span>
                    <span className="shrink-0 font-mono text-[12px] text-text-muted">{orVendorOf(m.id) || "model"}</span>
                  </button>
                ))
              )}
              {!orQuery.trim() && orLive.length > 80 && (
                <div className="px-3 py-1.5 font-mono text-[12px] text-text-muted">+{orLive.length - 80} more, search to find them</div>
              )}
            </div>
          )}
        </div>
      </div>
      </CollapsibleSection>
      {/* Other aggregators are on the roadmap. Kept to a single understated line
          (not six "coming soon" cards) so the panel advertises what works today,
          not what is missing. */}
      <MoreAggregators />
    </>
  );
}

function MoreAggregators() {
  return (
    <div className="mt-3 flex items-start gap-3 rounded-lg border border-border-subtle bg-surface/40 px-4 py-2.5 text-xs text-text-muted">
      <Layers className="mt-0.5 h-4 w-4 shrink-0 text-text-muted" />
      <div className="min-w-0 flex-1">
        <span className="text-text-secondary">More aggregators are on the roadmap</span> (Bedrock, Vertex, Azure, Together, Fireworks, Groq). Most hosted models are already reachable today through OpenRouter above, or add a vendor key directly below.{" "}
        <a
          href="https://github.com/fru-dev3/glyph-studio/issues/new"
          target="_blank"
          rel="noreferrer"
          className="text-accent underline decoration-dotted underline-offset-2 hover:opacity-80"
        >
          Request a provider
        </a>
      </div>
    </div>
  );
}

// G1 - Direct Providers. Native single-vendor keys: the user pastes their key
// for any vendor and it works (the engine's DIRECT_PROVIDERS table routes to it;
// the desktop injects PREVAIL_<ID>_KEY from the Keychain). Each row is an
// independent key-entry that saves to the Keychain via provider_key_set, then
// re-detects so the provider shows up live in every model picker.
const DIRECT_PROVIDERS_UI: { id: string; label: string; hint: string }[] = [
  { id: "anthropic", label: "Anthropic", hint: "console.anthropic.com · sk-ant-…" },
  { id: "openai", label: "OpenAI", hint: "platform.openai.com · sk-…" },
  { id: "xai", label: "xAI (Grok)", hint: "console.x.ai · xai-…" },
  { id: "kimi", label: "Kimi (Moonshot)", hint: "platform.moonshot.ai · sk-…" },
  { id: "deepseek", label: "DeepSeek", hint: "platform.deepseek.com · sk-…" },
  { id: "google", label: "Google AI", hint: "aistudio.google.com · AIza…" },
];

function DirectProviderRow({ id, label, hint, onActivated }: {
  id: string; label: string; hint: string; onActivated?: () => Promise<CliInfo[]>;
}) {
  const [key, setKey] = useState("");
  const [configured, setConfigured] = useState(false);
  const [busy, setBusy] = useState(false);
  const [activated, setActivated] = useState<boolean | null>(null);
  useEffect(() => { invoke<boolean>("provider_key_exists", { provider: id }).then((ok) => setConfigured(!!ok)).catch(() => {}); }, [id]);
  async function save() {
    if (!key.trim()) return;
    setBusy(true);
    try {
      await invoke("provider_key_set", { provider: id, key: key.trim() });
      track("provider_configured", { provider: telemetryProvider(id) });
      setConfigured(true);
      setKey("");
      if (onActivated) {
        const list = await onActivated();
        setActivated(list.some((c) => c.id === id && c.available));
        window.setTimeout(() => setActivated(null), 6000);
      }
    } catch (e) { console.error("provider_key_set", e); toast.error(`Could not save the key: ${String(e)}`); }
    finally { setBusy(false); }
  }
  async function remove() {
    setBusy(true);
    try {
      await invoke("provider_key_del", { provider: id });
      setConfigured(false);
      setActivated(null);
      if (onActivated) await onActivated();
    } catch (e) { console.error(e); toast.error(`Could not remove the key: ${String(e)}`); }
    finally { setBusy(false); }
  }
  return (
    <div className="rounded-lg border border-border-subtle bg-surface px-3 py-2.5">
      <div className="flex items-center gap-2">
        <span className="flex-1 text-sm font-semibold text-text-primary">{label}</span>
        {configured
          ? <span className="inline-flex items-center gap-1 text-[12px] text-ok"><Check className="h-3 w-3" /> key set</span>
          : <span className="font-mono text-[12px] text-text-muted">No key</span>}
      </div>
      <div className="mt-2 flex items-center gap-2">
        <input
          type="password"
          value={key}
          onChange={(e) => setKey(e.target.value)}
          placeholder={configured ? "replace key…" : hint}
          className="flex-1 rounded-md border border-border bg-background px-2 py-1 text-xs focus:border-accent-border focus:outline-none"
        />
        <button onClick={save} disabled={busy || !key.trim()}
          className="rounded-md bg-accent px-2.5 py-1 text-[12px] text-background hover:opacity-90 disabled:opacity-50">
          {busy ? <Loader2 className="h-3 w-3 animate-spin" /> : "save"}
        </button>
        {configured && (
          <button onClick={remove} disabled={busy}
            className="rounded-md border border-border px-2 py-1 text-[12px] text-text-muted hover:border-err hover:text-err disabled:opacity-50">
            remove
          </button>
        )}
      </div>
      {activated === true && <div className="mt-1.5 text-[12px] text-ok">Live: {label} answered with this key. Selectable in Chat, Council, and Benchmark pickers.</div>}
      {activated === false && <div className="mt-1.5 text-[12px] text-warn">Key saved, but {label} didn&apos;t come online. Double-check it.</div>}
    </div>
  );
}

export function DirectProvidersSection({ onActivated }: { onActivated?: () => Promise<CliInfo[]> }) {
  return (
    <div className="space-y-2">
      <p className="mb-1 text-xs text-text-muted">Keys are stored in the OS Keychain, never in plaintext.</p>
      {DIRECT_PROVIDERS_UI.map((p) => (
        <DirectProviderRow key={p.id} id={p.id} label={p.label} hint={p.hint} onActivated={onActivated} />
      ))}
    </div>
  );
}

export function ModelsSection({
  clis,
  onStartChatWith,
  onActivated,
  vaultPath,
}: {
  clis: CliInfo[];
  onStartChatWith?: (cliId: string, modelId?: string) => void;
  onActivated?: () => Promise<CliInfo[]>;
  vaultPath?: string;
}) {
  const firstAvailable = useMemo(() => clis.find((c) => c.available)?.id ?? "", [clis]);
  const [defaultChatCli, setDefaultChatCli] = useState(() => lsGet(LS.defaultChatCli) || firstAvailable);
  useEffect(() => { if (defaultChatCli) lsSet(LS.defaultChatCli, defaultChatCli); }, [defaultChatCli]);
  useEffect(() => {
    if (!defaultChatCli && firstAvailable) setDefaultChatCli(firstAvailable);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [firstAvailable]);
  // Live model discovery: pull each provider's current models so newly released
  // ones appear without a code change. Runs once on launch + a manual Refresh.
  // Validate detected providers (idempotent / cached) and refresh model lists on
  // mount, so the per-runtime checkmarks populate without a separate status row.
  useEffect(() => {
    autoVerifyClis(clis);
    void refreshDiscoveredModels(["ollama", "lmstudio", "openrouter"]).catch(() => {});
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // The three ways to run a model, as tabs under the header, each with one
  // line saying what it is. The active tab is remembered.
  const TABS = [
    { id: "clis", label: "On this Mac", blurb: "Claude Code, Codex, Ollama and other apps you already have. They run on your own subscription or on this Mac." },
    { id: "api", label: "Aggregators", blurb: "One key, many models: OpenRouter, or your own AWS account through Bedrock." },
    { id: "direct", label: "Direct keys", blurb: "A key from one vendor, used straight from this Mac. Stored in the Keychain." },
  ] as const;
  type TabId = (typeof TABS)[number]["id"];
  const [tab, setTab] = useState<TabId>(() => {
    const saved = lsGet(LS_MODELS_TAB);
    return (TABS.some((t) => t.id === saved) ? saved : "clis") as TabId;
  });
  useEffect(() => { lsSet(LS_MODELS_TAB, tab); }, [tab]);
  const ready = clis.filter((c) => c.id !== "openrouter" && c.id !== "bedrock" && c.available).length;
  const tabs = (
    <div className="space-y-2">
      <SpineTabs label="Models view" value={tab} onChange={setTab}
        tabs={TABS.map((t) => ({ id: t.id, label: t.label, count: t.id === "clis" ? ready : undefined }))} />
      <p data-testid="models-tab-blurb" className="text-[13px] text-text-muted">{TABS.find((t) => t.id === tab)?.blurb}</p>
    </div>
  );
  return (
    <>
      <SettingsHeader title="Models" icon={Layers} subtitle="A model plus a way to run it." tabs={tabs} />
      {tab === "clis" ? (
        <AgentsSection
          clis={clis}
          onStartChatWith={onStartChatWith}
          defaultChatCli={defaultChatCli}
          onMakeDefault={setDefaultChatCli}
          vaultPath={vaultPath}
          embedded
        />
      ) : (
        <div className="min-h-0 flex-1 overflow-y-auto" data-testid="models-scroll">
          <div className="w-full px-8 py-6">
            {tab === "api" && <ProvidersSection onActivated={onActivated} embedded />}
            {tab === "direct" && <DirectProvidersSection onActivated={onActivated} />}
          </div>
        </div>
      )}
    </>
  );
}
