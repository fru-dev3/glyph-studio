// Components extracted from App.tsx.
import { useEffect, useMemo, useRef, useState } from "react";
import { AlertTriangle, Check, Circle, ExternalLink, Loader2, Plus, RefreshCw, Settings as SettingsIcon, Sparkles, X } from "lucide-react";
import { GlyphStudioLogo } from "./GlyphStudioLogo";
import { invoke } from "./bridge";
import { PALETTES, SCORE_DIMENSIONS, SETTINGS_ROW, SEVERITY_LABEL, SEVERITY_ORDER, STATUS_TINT } from "./constants";
import { formatFreshness, relTime, scoreColor, titleCase } from "./format";
import { formatAuditedAt } from "./helpers";
import { ScoreBar } from "./panels";
import { Sparkline } from "./ui";
import type { ContextScore, EngineApp, MissingItem, OnboardingRecommendation } from "./types";

// Tile for a plain product name (AI suggestions only carry a name): the site's
// favicon when one resolves, else an initials monogram.
function BrandTile({ name }: { name: string }) {
  return <AppRowLogo app={{ title: name }} size={32} />;
}

// A connector's logo tile, sized for app rows/cards: the site's real favicon,
// else the app's letter/initials monogram. This is the single way vault-app
// logos render (rows, chips, mentions) so they stay consistent.
// Best-effort website host for an app, used to fetch its real favicon when no
// crisp brand icon exists. Uses the curated map where we have it, else guesses
// www.<slug>.<tld>, a wrong guess just triggers the letter fallback via onError.
function faviconHost(app: { title?: string; id?: string; website?: string }): string {
  if (app.website) { try { return new URL(app.website).hostname; } catch { /* fall through */ } }
  const slug = (app.title || app.id || "").toLowerCase().replace(/[^a-z0-9]/g, "");
  const known: Record<string, string> = {
    canva: "canva.com", notion: "notion.so", slack: "slack.com", figma: "figma.com",
    linear: "linear.app", airtable: "airtable.com", canny: "canny.io", skyscanner: "skyscanner.net",
    calendly: "calendly.com", opentable: "opentable.com", alltrails: "alltrails.com",
  };
  return known[slug] || `www.${slug}.com`;
}

export function AppRowLogo({ app, size = 32, fallback = "initials" }: {
  app: { title?: string; id?: string; website?: string };
  size?: number;
  fallback?: "initials" | "letter";
}) {
  // The site's real favicon (a base64 data: URI from the backend, cached to
  // disk, CSP-safe). Declared first so rules-of-hooks holds across the early
  // returns below.
  const [faviconUri, setFaviconUri] = useState<string | null>(null);
  const wantFavicon = !!(app.id || app.title);
  useEffect(() => {
    if (!wantFavicon) return;
    let alive = true;
    const host = faviconHost(app);
    invoke<string>("app_favicon", { host })
      .then((uri) => { if (alive && uri) setFaviconUri(uri); })
      .catch(() => {});
    return () => { alive = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [app.id, app.title]);
  const box = { height: size, width: size };
  // The real, colorful Google mark (not a flat monochrome glyph) for the Google
  // Workspace connector.
  const key = (app.id || app.title || "").toLowerCase();
  if (key === "google" || key === "google workspace") {
    const g = Math.round(size * 0.62);
    return (
      <span className="flex shrink-0 items-center justify-center rounded-lg border border-border-subtle bg-white" style={box}>
        <svg width={g} height={g} viewBox="0 0 48 48" aria-hidden>
          <path fill="#EA4335" d="M24 9.5c3.54 0 6.71 1.22 9.21 3.6l6.85-6.85C35.9 2.38 30.47 0 24 0 14.62 0 6.51 5.38 2.56 13.22l7.98 6.19C12.43 13.72 17.74 9.5 24 9.5z"/>
          <path fill="#4285F4" d="M46.98 24.55c0-1.57-.15-3.09-.38-4.55H24v9.02h12.94c-.58 2.96-2.26 5.48-4.78 7.18l7.73 6c4.51-4.18 7.09-10.36 7.09-17.65z"/>
          <path fill="#FBBC05" d="M10.53 28.59c-.48-1.45-.76-2.99-.76-4.59s.27-3.14.76-4.59l-7.98-6.19C.92 16.46 0 20.12 0 24c0 3.88.92 7.54 2.56 10.78l7.97-6.19z"/>
          <path fill="#34A853" d="M24 48c6.48 0 11.93-2.13 15.89-5.81l-7.73-6c-2.15 1.45-4.92 2.3-8.16 2.3-6.26 0-11.57-4.22-13.47-9.91l-7.98 6.19C6.51 42.62 14.62 48 24 48z"/>
        </svg>
      </span>
    );
  }
  const name = app.title || app.id || "·";
  // The backend returned the site's real favicon: show it (a data: URI,
  // CSP-safe). Falls to the letter otherwise.
  if (faviconUri) {
    return (
      <span className="flex shrink-0 items-center justify-center overflow-hidden rounded-lg border border-border-subtle bg-white" style={box}>
        <img src={faviconUri} width={Math.round(size * 0.7)} height={Math.round(size * 0.7)} alt={name} style={{ objectFit: "contain" }} />
      </span>
    );
  }
  const mono = fallback === "letter"
    ? name.charAt(0).toUpperCase()
    : name.split(/\s+/).map((w) => w[0]).join("").slice(0, 2).toUpperCase();
  return (
    <span className="flex shrink-0 items-center justify-center rounded-lg bg-surface-warm font-display font-bold text-text-secondary" style={box} aria-hidden>
      <span style={{ fontSize: Math.round(size * 0.34) }}>{mono}</span>
    </span>
  );
}

// Turn a raw engine error (e.g. "prevail exited 1: <stderr>") into something a
// human can act on. The bare "exited 1" is meaningless to the user.
function friendlyOnboardError(e: unknown, action: string): string {
  const raw = String(e ?? "").trim();
  const detail = raw.replace(/^prevail exited \d+:?\s*/i, "").trim();
  if (/no output/i.test(raw)) return `Couldn't ${action}: the engine returned nothing. Try again in a moment.`;
  if (/spawn|not found|ENOENT/i.test(raw)) return `Couldn't ${action}: the Glyph Engine isn't reachable. Restart the app and try again.`;
  return detail
    ? `Couldn't ${action}: ${detail}`
    : `Couldn't ${action} right now. Try again in a moment.`;
}

export function OnboardingModal({
  vaultPath,
  onClose,
  onApplied,
}: {
  vaultPath: string;
  onClose: () => void;
  onApplied: () => void;
}) {
  type Step = "loading" | "review" | "applying";
  const [step, setStep] = useState<Step>("loading");
  const [rec, setRec] = useState<OnboardingRecommendation | null>(null);
  const [picks, setPicks] = useState<Set<string>>(new Set());
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // Domains the vault ALREADY has - never offer to create these again.
  const [existing, setExisting] = useState<Set<string>>(new Set());
  useEffect(() => {
    invoke<{ name: string }[]>("scan_vault", { path: vaultPath })
      .then((ds) => setExisting(new Set((ds ?? []).map((d) => d.name.toLowerCase()))))
      .catch(() => setExisting(new Set()));
  }, [vaultPath]);
  // Only the proposed domains that don't already exist in the vault.
  const offered = useMemo(() => (rec?.domains ?? []).filter((d) => !existing.has(d.name.toLowerCase())), [rec, existing]);
  // Pre-select the recommended NEW domains whenever the proposal or existing set changes.
  useEffect(() => { setPicks(new Set(offered.filter((d) => d.recommended).map((d) => d.name))); }, [offered]);

  // No questionnaire. Prevail proposes a starter set automatically; the user
  // just picks what to keep. Recommendation runs once on open.
  async function requestRecommendation() {
    setBusy(true);
    setError(null);
    setStep("loading");
    try {
      const answersJson = JSON.stringify({ answers: {} });
      const value = await invoke<OnboardingRecommendation>("engine_onboard_recommend", {
        vault: vaultPath,
        answersJson,
      });
      setRec(value);
      // Picks are derived from `offered` (recommended minus existing) by an effect.
      setStep("review");
    } catch (e) {
      setError(friendlyOnboardError(e, "propose starter domains"));
    } finally {
      setBusy(false);
    }
  }

  useEffect(() => {
    requestRecommendation();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  async function applyPicks() {
    if (picks.size === 0) return;
    setBusy(true);
    setError(null);
    setStep("applying");
    try {
      const picksJson = JSON.stringify({ picks: Array.from(picks) });
      await invoke("engine_onboard_apply", { vault: vaultPath, picksJson });
      onApplied();
      onClose();
    } catch (e) {
      setError(friendlyOnboardError(e, "create the domains"));
      setStep("review");
    } finally {
      setBusy(false);
    }
  }

  function togglePick(name: string) {
    setPicks((cur) => {
      const next = new Set(cur);
      if (next.has(name)) next.delete(name);
      else next.add(name);
      return next;
    });
  }

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4 backdrop-blur-sm">
      <div className="flex max-h-[88vh] w-full max-w-2xl flex-col overflow-hidden rounded-2xl border border-border bg-surface shadow-2xl">
        {/* Header */}
        <div className="flex shrink-0 items-center justify-between border-b border-border-subtle px-6 py-4">
          <div className="flex items-center gap-2">
            <GlyphStudioLogo size={22} src="/logo-512.png" />
            <h2 className="text-[15px] font-semibold">Set up your domains</h2>
          </div>
          <button
            onClick={onClose}
            className="flex h-7 w-7 items-center justify-center rounded text-text-muted hover:bg-surface-warm hover:text-text-primary"
            title="Close"
          >
            <X className="h-4 w-4" />
          </button>
        </div>

        <div className="min-h-0 flex-1 overflow-y-auto px-6 py-5">
          {error && (
            <div className="mb-4 rounded-md border border-err/40 bg-err/10 px-3 py-2 text-sm text-err">
              {error}
            </div>
          )}

          {step === "loading" && (
            <div className="flex flex-col items-center justify-center gap-3 py-12 text-text-secondary">
              <Loader2 className="h-6 w-6 animate-spin text-accent" />
              <span className="text-sm">Proposing a starter set of domains…</span>
            </div>
          )}

          {step === "review" && rec && offered.length === 0 && (
            <div className="flex flex-col items-center justify-center gap-3 py-12 text-center">
              <Check className="h-7 w-7 text-ok" />
              <div className="text-sm font-semibold text-text-primary">This vault is already set up</div>
              <div className="max-w-sm text-xs text-text-muted">It already has {existing.size} domain{existing.size === 1 ? "" : "s"}. There's nothing to create here - close this and start working.</div>
            </div>
          )}

          {step === "review" && rec && offered.length > 0 && (
            <>
              {rec.rationale && (
                <p className="mb-4 rounded-md border border-border-subtle bg-background px-3 py-2 text-sm text-text-secondary">
                  {rec.rationale}
                </p>
              )}
              <div className="mb-2 text-[14px] font-semibold text-text-primary">
                Recommended domains · {picks.size} selected
              </div>
              <ul className="flex flex-col gap-2">
                {offered.map((d) => {
                  const on = picks.has(d.name);
                  return (
                    <li key={d.name}>
                      <button
                        onClick={() => togglePick(d.name)}
                        className={`flex w-full items-start gap-3 rounded-lg border-2 px-3 py-2.5 text-left transition-colors ${
                          on
                            ? "border-accent bg-accent-soft ring-2 ring-accent/20"
                            : "border-border-subtle bg-background hover:border-accent-border"
                        }`}
                      >
                        <span
                          className={`mt-0.5 flex h-5 w-5 shrink-0 items-center justify-center rounded border ${
                            on ? "border-accent bg-accent text-background" : "border-border bg-surface"
                          }`}
                        >
                          {on && <Check className="h-3 w-3" strokeWidth={3} />}
                        </span>
                        <span className="text-xl leading-none">{d.emoji || "◆"}</span>
                        <div className="min-w-0 flex-1">
                          <div className="flex items-center gap-2">
                            <span className="text-sm font-semibold text-text-primary">{d.label}</span>
                            <span className="font-mono text-[12px] text-text-muted">/{d.name}</span>
                            {d.recommended && (
                              <span className="rounded-full bg-accent/15 px-1.5 py-0 text-[12px] text-accent">
                                recommended
                              </span>
                            )}
                          </div>
                          {d.summary && <div className="mt-0.5 text-xs text-text-secondary">{d.summary}</div>}
                          {d.reason && <div className="mt-1 text-[12px] italic text-text-muted">{d.reason}</div>}
                        </div>
                      </button>
                    </li>
                  );
                })}
              </ul>
            </>
          )}

          {step === "applying" && (
            <div className="flex flex-col items-center justify-center gap-3 py-12 text-text-secondary">
              <Loader2 className="h-6 w-6 animate-spin text-accent" />
              <span className="text-sm">Scaffolding {picks.size} domain{picks.size === 1 ? "" : "s"}…</span>
            </div>
          )}
        </div>

        {/* Footer actions */}
        <div className="flex shrink-0 items-center justify-between gap-3 border-t border-border-subtle px-6 py-4">
          {step === "review" && offered.length === 0 ? (
            <button
              onClick={onClose}
              className="ml-auto flex items-center gap-2 rounded-md bg-accent px-4 py-2 text-sm font-semibold text-background transition-opacity hover:opacity-90"
            >
              <Check className="h-4 w-4" /> Done
            </button>
          ) : step === "review" ? (
            <>
              <button
                onClick={requestRecommendation}
                disabled={busy}
                className="flex items-center gap-2 rounded-md border border-border bg-background px-3 py-2 text-sm text-text-secondary hover:border-accent-border hover:text-accent disabled:opacity-40"
              >
                {busy ? <Loader2 className="h-4 w-4 animate-spin" /> : <Sparkles className="h-4 w-4" />}
                Re-propose
              </button>
              <button
                onClick={applyPicks}
                disabled={busy || picks.size === 0}
                className="flex items-center gap-2 rounded-md bg-accent px-4 py-2 text-sm font-semibold text-background transition-opacity hover:opacity-90 disabled:opacity-40"
              >
                {busy ? <Loader2 className="h-4 w-4 animate-spin" /> : <Check className="h-4 w-4" />}
                Create {picks.size} domain{picks.size === 1 ? "" : "s"}
              </button>
            </>
          ) : (
            <span className="font-mono text-[12px] text-text-muted">working…</span>
          )}
        </div>
      </div>
    </div>
  );
}

export function DomainAppsTab({ domain, vaultPath }: { domain: string; vaultPath: string }) {
  const [apps, setApps] = useState<EngineApp[] | null>(null);
  const [probing, setProbing] = useState<string | null>(null);
  const [probeResult, setProbeResult] = useState<Record<string, string>>({});
  const [addOpen, setAddOpen] = useState(false);
  const [addValue, setAddValue] = useState("");
  const [binding, setBinding] = useState<string | null>(null);
  // Learned app suggestions for this domain (the "you should connect X" layer).
  const [suggestions, setSuggestions] = useState<{ name: string; reason: string }[]>([]);
  const [suggesting, setSuggesting] = useState(false);
  const [addingSuggestion, setAddingSuggestion] = useState<string | null>(null);
  const loadSuggestions = () => {
    invoke<Record<string, { items?: { name: string; reason: string }[] }>>("app_suggestions_read", { vault: vaultPath })
      .then((all) => setSuggestions(all?.[domain.toLowerCase()]?.items ?? []))
      .catch(() => {});
  };
  useEffect(() => {
    invoke<EngineApp[]>("engine_apps_list", { vault: vaultPath }).then(setApps).catch(() => setApps([]));
    loadSuggestions();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [domain]);

  // Auto-suggest on open: if there are no cached suggestions for this domain,
  // learn from activity in the background so the panel is useful without the
  // user having to hit "suggest apps" first (founder ask).
  const autoSuggestedFor = useRef<string | null>(null);
  useEffect(() => {
    if (!apps) return; // wait until the app list has loaded so we know the state
    if (suggestions.length > 0) { autoSuggestedFor.current = domain; return; }
    if (autoSuggestedFor.current === domain || suggesting) return;
    autoSuggestedFor.current = domain;
    void generateSuggestions();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [apps, domain, suggestions.length]);

  async function generateSuggestions() {
    setSuggesting(true);
    try {
      const all = await invoke<Record<string, { items?: { name: string; reason: string }[] }>>("app_suggestions_generate", { vault: vaultPath, domain });
      setSuggestions(all?.[domain.toLowerCase()]?.items ?? []);
    } catch { /* surfaced by empty state */ } finally { setSuggesting(false); }
  }

  // Add a suggested app straight to THIS domain WITHOUT setting up its
  // connection. Adding to a domain and configuring the connection are two
  // separate steps: this scaffolds the app (unconfigured) and binds it here, so
  // it shows up under "apps refreshing this domain" with a "set up" action the
  // user can do later (or never). The connection itself is set up on Apps.
  async function addSuggestionToDomain(name: string) {
    setAddingSuggestion(name);
    try {
      const id = name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 48) || "app";
      try {
        await invoke("engine_app_add", { vault: vaultPath, id, title: name, integration: "manual", domains: [domain], mcpCommand: null, mcpInstall: null });
      } catch (e) {
        // Already scaffolded: just make sure it feeds this domain (below).
        if (!/already exists/i.test(String(e))) throw e;
      }
      // If the app already existed under this id without this domain, bind it.
      const list = await invoke<EngineApp[]>("engine_apps_list", { vault: vaultPath }).catch(() => apps ?? []);
      const added = list.find((a) => a.id === id);
      if (added && !added.domains.includes(domain)) {
        try { await invoke("engine_app_set_domains", { id, domains: [...added.domains, domain], vault: vaultPath }); } catch { /* leave as-is */ }
      }
      window.dispatchEvent(new CustomEvent("prevail:apps-changed"));
      const next = await invoke<EngineApp[]>("engine_apps_list", { vault: vaultPath }).catch(() => list);
      setApps(next);
      // Drop it from the suggestion list now that it's feeding the domain.
      setSuggestions((s) => s.filter((x) => x.name.toLowerCase() !== name.toLowerCase()));
    } catch { /* leave the suggestion in place to retry */ }
    finally { setAddingSuggestion(null); }
  }
  const domainApps = useMemo(() => (apps ?? []).filter((a) => a.domains.includes(domain)), [apps, domain]);
  // Apps NOT yet feeding this domain - the candidates the picker offers.
  const available = useMemo(() => (apps ?? []).filter((a) => !a.domains.includes(domain)), [apps, domain]);
  // Never re-suggest an app that already feeds this domain (match on normalized
  // name or id). Keeps the "suggested for X" list to genuinely new options.
  const visibleSuggestions = useMemo(() => {
    const norm = (s: string) => s.toLowerCase().replace(/[^a-z0-9]/g, "");
    const have = new Set(domainApps.flatMap((a) => [norm(a.title || ""), norm(a.id || "")]).filter(Boolean));
    return suggestions.filter((s) => !have.has(norm(s.name)));
  }, [suggestions, domainApps]);

  async function sync(id: string) {
    setProbing(id);
    try {
      const r = await invoke<{ ok: boolean; artifacts?: number; error?: string }>("engine_app_sync", { id, vault: vaultPath });
      setProbeResult((m) => ({ ...m, [id]: r.ok ? `synced. ${r.artifacts ?? 0} artifact(s)` : `failed: ${r.error}` }));
      invoke<EngineApp[]>("engine_apps_list", { vault: vaultPath }).then(setApps).catch(() => {});
    } catch (e) { setProbeResult((m) => ({ ...m, [id]: `error: ${e}` })); }
    setProbing(null);
  }

  // Bind an app to THIS domain - the mirror of the app-side domain editor. Same
  // engine_app_set_domains backend, just adding `domain` to the app's set.
  async function bindApp(app: EngineApp) {
    setBinding(app.id);
    try {
      const r = await invoke<{ ok: boolean; domains?: string[]; error?: string }>("engine_app_set_domains", { id: app.id, domains: [...app.domains, domain], vault: vaultPath });
      if (r.ok) {
        window.dispatchEvent(new CustomEvent("prevail:apps-changed"));
        const next = await invoke<EngineApp[]>("engine_apps_list", { vault: vaultPath }).catch(() => apps ?? []);
        setApps(next);
        setAddValue("");
      }
    } catch { /* leave open to retry */ }
    finally { setBinding(null); }
  }

  // The add-app picker, shared by the populated and empty states.
  const q = addValue.trim().toLowerCase();
  const matches = available.filter((a) => a.title.toLowerCase().includes(q) || a.id.toLowerCase().includes(q));
  const addPicker = addOpen ? (
    <div className="overflow-hidden rounded-xl border border-border-subtle bg-surface-warm/40">
      <div className="flex items-center gap-2 border-b border-border-subtle px-3 py-2">
        <Plus className="h-3.5 w-3.5 shrink-0 text-text-muted" />
        <input
          autoFocus value={addValue} onChange={(e) => setAddValue(e.target.value)}
          onKeyDown={(e) => { if (e.key === "Enter" && matches[0]) bindApp(matches[0]); if (e.key === "Escape") { setAddOpen(false); setAddValue(""); } }}
          placeholder="Filter apps to feed this domain"
          className="min-w-0 flex-1 bg-transparent text-[13px] text-text-primary outline-none placeholder:text-text-muted/60"
        />
        <button onClick={() => { setAddOpen(false); setAddValue(""); }} title="Close" className="shrink-0 rounded p-0.5 text-text-muted hover:text-text-primary"><X className="h-3.5 w-3.5" /></button>
      </div>
      <ul className="max-h-56 overflow-y-auto p-1">
        {matches.map((a) => {
          const tint = STATUS_TINT[a.status] ?? "#9aa0a6";
          return (
            <li key={a.id}>
              <button onClick={() => bindApp(a)} disabled={binding === a.id} className="flex w-full items-center gap-2.5 rounded-lg px-2.5 py-2 text-left transition-colors hover:bg-accent-soft disabled:opacity-40">
                <span className="h-2.5 w-2.5 shrink-0 rounded-full" style={{ backgroundColor: tint }} />
                <span className="text-sm font-medium text-text-primary">{a.title}</span>
                <span className="font-mono text-[12px] text-text-muted">{a.integration}</span>
                <span className="ml-auto text-[12px] text-text-muted/60">{binding === a.id ? "adding…" : ""}</span>
              </button>
            </li>
          );
        })}
        {matches.length === 0 && (
          <li className="px-2.5 py-3 text-center text-[12px] text-text-muted">
            {available.length === 0 ? "Every app already feeds this domain." : "No matching app."}
          </li>
        )}
      </ul>
    </div>
  ) : (
    <button onClick={() => setAddOpen(true)} className="flex items-center gap-1.5 rounded-lg border border-dashed border-border px-3 py-1.5 text-[12px] text-text-muted hover:border-accent-border hover:text-accent"><Plus className="h-3.5 w-3.5" /> add app</button>
  );

  // Learned/AI suggestions block. Rendered in BOTH the empty and populated
  // states - an empty domain is exactly when you most want "which apps should
  // feed this?", so it must not be hidden behind having an app already.
  const suggestBlock = (
      <div className="mt-4 rounded-lg border border-border-subtle bg-surface/60 p-3">
        <div className="mb-2 flex items-center justify-between gap-2">
          <span className="inline-flex items-center gap-1.5 text-[12px] text-text-muted">
            <Sparkles className="h-3 w-3 text-accent" /> Suggested for {titleCase(domain)}
          </span>
          <button
            onClick={generateSuggestions}
            disabled={suggesting}
            className="inline-flex items-center gap-1 rounded border border-border px-2 py-0.5 text-[12px] text-text-secondary hover:border-accent-border hover:text-accent disabled:opacity-50"
          >
            {suggesting ? <Loader2 className="h-3 w-3 animate-spin" /> : <Sparkles className="h-3 w-3" />}
            {suggesting ? "thinking" : suggestions.length ? "refresh" : "suggest apps"}
          </button>
        </div>
        {visibleSuggestions.length === 0 ? (
          <div className="px-1 py-2 text-[12px] text-text-muted">
            {suggesting ? "Learning from your activity in this domain…" : "No suggestions yet. They appear automatically as Glyph Studio learns from your activity here, or hit refresh."}
          </div>
        ) : (
          <div className="space-y-1.5">
            {visibleSuggestions.map((s) => {
              const adding = addingSuggestion === s.name;
              return (
              <div key={s.name} className="flex items-center gap-3 rounded-md px-1 py-1.5">
                <BrandTile name={s.name} />
                <div className="min-w-0 flex-1">
                  <div className="truncate text-sm font-medium text-text-primary">{s.name}</div>
                  <div className="truncate text-[12px] text-text-muted">{s.reason}</div>
                </div>
                {/* Two separate steps: add to this domain now (no setup), then
                    set up the connection later from the app's config page. */}
                <button
                  onClick={() => window.dispatchEvent(new CustomEvent("prevail:open-settings", { detail: "apps" }))}
                  title={`Set up the ${s.name} connection on Apps`}
                  className="inline-flex shrink-0 items-center gap-1 rounded border border-border px-2 py-0.5 text-[12px] text-text-secondary hover:border-accent-border hover:text-accent"
                >
                  <SettingsIcon className="h-3 w-3" /> set up
                </button>
                <button
                  onClick={() => addSuggestionToDomain(s.name)}
                  disabled={adding}
                  title={`Add ${s.name} to ${titleCase(domain)} now (you can set up the connection later)`}
                  className="inline-flex shrink-0 items-center gap-1 rounded border border-accent-border bg-accent-soft px-2 py-0.5 text-[12px] text-accent hover:bg-accent hover:text-background disabled:opacity-50"
                >
                  {adding ? <Loader2 className="h-3 w-3 animate-spin" /> : <Plus className="h-3 w-3" />} {adding ? "adding…" : "add to domain"}
                </button>
              </div>
              );
            })}
          </div>
        )}
      </div>
  );

  if (!apps) return <div className="text-sm text-text-muted">loading…</div>;
  if (domainApps.length === 0) {
    return (
      <div className="space-y-3">
        <div className="rounded-lg border border-dashed border-border bg-surface p-6 text-sm text-text-muted">
          No apps are refreshing this domain yet. Connect one of the suggestions below, add your own, or set one up from Settings → Apps.
        </div>
        {suggestBlock}
        {addPicker}
      </div>
    );
  }
  return (
    <div className="space-y-2">
      <div className="mb-3 flex items-center justify-between gap-2">
        <span className="font-mono text-[12px] text-text-muted">{domainApps.length} app{domainApps.length !== 1 ? "s" : ""} refreshing {domain}</span>
      </div>
      {domainApps.map((app) => {
        const tint = STATUS_TINT[app.status] ?? "#9aa0a6";
        const openConfig = () => window.dispatchEvent(new CustomEvent("prevail:open-app", { detail: app }));
        const syncing = probing === app.id;
        return (
          <div key={app.id} className={`${SETTINGS_ROW} relative overflow-hidden hover:border-accent-border hover:bg-surface-warm ${syncing ? "border-accent-border bg-accent-soft/20" : ""}`}>
            {/* Logo + status dot. The whole identity block links to the app's
                config page so you can authenticate / configure it. While syncing,
                the dot pulses so the row visibly reads as "working". */}
            <button onClick={openConfig} title={`Open ${app.title} configuration`} className="group flex min-w-0 flex-1 items-center gap-3 text-left">
              <span className="relative shrink-0">
                <AppRowLogo app={app} />
                <span className={`absolute -bottom-0.5 -right-0.5 h-2.5 w-2.5 rounded-full border-2 border-surface ${syncing ? "pulse-soft" : ""}`} style={{ backgroundColor: syncing ? "var(--color-accent)" : tint }} title={syncing ? "syncing…" : app.status} />
              </span>
              <div className="min-w-0 flex-1">
                <div className="flex items-center gap-2">
                  <span className="truncate text-sm font-medium text-text-primary group-hover:text-accent">{app.account?.label ? `${app.title} · ${app.account.label}` : app.title}</span>
                  <span className="shrink-0 text-[12px] text-text-muted">{app.integration}</span>
                  <ExternalLink className="h-3 w-3 shrink-0 text-text-muted/0 transition-colors group-hover:text-accent" />
                </div>
                <div className="font-mono text-[12px] text-text-muted">
                  {app.configured ? app.status : <span className="text-warn">not configured · click to set up</span>}{app.refresh?.every ? ` · every ${app.refresh.every}` : ""} · synced {relTime(app.lastSuccessTs)}
                  {probeResult[app.id] && <span className="ml-2 text-text-secondary">{probeResult[app.id]}</span>}
                  {app.lastError && !probeResult[app.id] && <span className="ml-2 text-warn">{app.lastError}</span>}
                </div>
              </div>
            </button>
            {app.configured ? (
              <button
                onClick={() => sync(app.id)}
                disabled={syncing}
                className={`inline-flex shrink-0 items-center gap-1.5 rounded border px-2.5 py-1 text-[12px] disabled:opacity-100 ${syncing ? "border-accent-border bg-accent-soft text-accent" : "border-border bg-background text-text-secondary hover:border-accent-border hover:text-accent"}`}
              >
                {syncing ? <Loader2 className="h-3 w-3 animate-spin" /> : <RefreshCw className="h-3 w-3" />}
                {syncing ? "syncing…" : "sync"}
              </button>
            ) : (
              <button
                onClick={openConfig}
                className="inline-flex shrink-0 items-center gap-1 rounded border border-accent-border bg-accent-soft px-2.5 py-1 text-[12px] text-accent hover:bg-accent hover:text-background"
              >
                <SettingsIcon className="h-3 w-3" /> set up
              </button>
            )}
            {/* Indeterminate "working" sweep along the bottom edge of the row,
                so a sync of unknown duration clearly reads as in-progress. */}
            {syncing && (
              <span className="pointer-events-none absolute inset-x-0 bottom-0 h-[2px] overflow-hidden bg-accent-soft">
                <span className="sync-sweep block h-full w-1/4 rounded-full bg-accent" />
              </span>
            )}
          </div>
        );
      })}
      {suggestBlock}
      <div className="pt-1">{addPicker}</div>
    </div>
  );
}

export function ContextScorePanel({
  score,
  loading,
  rescanning,
  error,
  onRescan,
  vaultPath,
}: {
  score: ContextScore | null;
  loading: boolean;
  rescanning: boolean;
  error: string | null;
  onRescan: () => void;
  vaultPath: string;
}) {
  // The score over time - makes the "ever-improving" nature visible: it climbs on
  // its own as apps sync, memory distills, and context is added. Refetched when
  // the score changes (a new scan appended a point).
  const [history, setHistory] = useState<number[]>([]);
  useEffect(() => {
    if (!score?.domain) { setHistory([]); return; }
    let alive = true;
    invoke<{ ts: number; score: number }[]>("engine_score_history", { vault: vaultPath, domain: score.domain })
      .then((pts) => { if (alive) setHistory(Array.isArray(pts) ? pts.map((p) => p.score) : []); })
      .catch(() => { if (alive) setHistory([]); });
    return () => { alive = false; };
  }, [vaultPath, score?.domain, score?.computed_at]);
  const delta = history.length >= 2 ? history[history.length - 1] - history[0] : null;

  // Live elapsed seconds while an audit runs, so the progress chip visibly ticks
  // (proof it is working) even though the heavy LLM work runs off the main thread
  // and the rest of the page stays interactive.
  const [auditElapsed, setAuditElapsed] = useState(0);
  useEffect(() => {
    if (!rescanning) { setAuditElapsed(0); return; }
    const t0 = Date.now();
    const iv = setInterval(() => setAuditElapsed(Math.floor((Date.now() - t0) / 1000)), 500);
    return () => clearInterval(iv);
  }, [rescanning]);
  // Clicking a readiness stat tile in the hero scrolls to (and briefly flashes)
  // its full row in the Structural readiness section below.
  const [flashDim, setFlashDim] = useState<string | null>(null);
  const scrollToDim = (key: string) => {
    const el = document.getElementById(`dim-${key}`);
    if (!el) return;
    el.scrollIntoView({ behavior: "smooth", block: "center" });
    setFlashDim(key);
    window.setTimeout(() => setFlashDim((cur) => (cur === key ? null : cur)), 1200);
  };

  if (loading && !score) {
    return <div className="text-sm text-text-muted">computing context score…</div>;
  }
  if (error && !score) {
    return (
      <div className="rounded-lg border border-dashed border-border bg-surface p-6 text-sm text-text-muted">
        couldn't compute a context score: <span className="text-text-secondary">{error}</span>
      </div>
    );
  }
  if (!score) {
    return (
      <div className="rounded-lg border border-dashed border-border bg-surface p-6 text-sm text-text-muted">
        no context score yet.
      </div>
    );
  }

  const color = scoreColor(score.score);
  // Group missing items by severity for the what's-missing section.
  const grouped: Record<string, MissingItem[]> = {};
  for (const m of score.missing) {
    (grouped[m.severity] ??= []).push(m);
  }
  const severities = Object.keys(grouped).sort(
    (a, b) => (SEVERITY_ORDER[a] ?? 99) - (SEVERITY_ORDER[b] ?? 99),
  );
  // I3: surface what's out of date as an explicit, scannable summary.
  const staleItems = score.relevance?.items.filter((it) => it.stale) ?? [];

  return (
    <div className="flex flex-col gap-6">
      {/* Big score + re-scan, with an at-a-glance readiness dashboard on the
          right so the hero is a full row of useful, clickable signal. */}
      <div className="flex flex-wrap items-center gap-5 rounded-2xl border border-border bg-surface p-5 shadow-sm">
        <div
          className="flex h-24 w-24 shrink-0 items-center justify-center rounded-full border-4"
          style={{ borderColor: color }}
        >
          <span className="font-display text-[24px] font-bold leading-none" style={{ color }}>
            {score.score}
          </span>
        </div>
        <div className="min-w-0 flex-1">
          <div className="text-[15px] font-semibold">Context Score</div>
          <div className="mt-0.5 text-xs text-text-muted">
            updated {formatFreshness(score.freshness_secs)}
            {score.audit_source ? ` · ${score.audit_source}` : " · heuristic"}
          </div>
          {/* Trend - the self-learning story: this climbs on its own as Prevail
              syncs apps, distills memory, and you add context. */}
          {history.length >= 2 ? (
            <div className="mt-2 flex items-center gap-2">
              <Sparkline values={history} width={84} height={22} />
              {delta != null && (
                <span className={`font-mono text-[12px] ${delta > 0 ? "text-ok" : delta < 0 ? "text-warn" : "text-text-muted"}`}>
                  {delta > 0 ? "↑" : delta < 0 ? "↓" : "→"} {delta > 0 ? "+" : ""}{Math.round(delta)} over {history.length} scans
                </span>
              )}
            </div>
          ) : (
            <div className="mt-2 text-[12px] text-text-muted">Climbs automatically as apps sync, memory builds, and you add context.</div>
          )}
          <div className="mt-3">
            {rescanning ? (
              // Non-blocking progress: the audit runs off-thread and as a tracked
              // background process, so the page stays usable and the user can
              // navigate away and return. The ticking timer proves it is alive.
              <div className="inline-flex items-center gap-2 rounded-md border border-accent-border bg-accent-soft px-2.5 py-1 text-[12px] text-accent">
                <Loader2 className="h-3 w-3 animate-spin" />
                Auditing… {auditElapsed}s · runs in the background, keep working
              </div>
            ) : (
              <button
                onClick={onRescan}
                className="inline-flex items-center gap-1.5 rounded-md border border-border bg-surface px-2.5 py-1 text-[12px] text-text-muted hover:border-accent-border hover:bg-accent-soft hover:text-accent"
              >
                <RefreshCw className="h-3 w-3" /> Re-scan (audit)
              </button>
            )}
          </div>
        </div>

        {/* Readiness dashboard: the six dimensions as compact, clickable stat
            tiles. Fills the otherwise-empty right side and jumps to the detail
            row below on click. Hidden on the narrowest screens. */}
        <div className="hidden shrink-0 grid-cols-3 gap-2 sm:grid" style={{ width: 312 }}>
          {SCORE_DIMENSIONS.map(({ key, label }) => {
            const dim = score.breakdown[key];
            return (
              <button
                key={key}
                onClick={() => scrollToDim(key)}
                title={dim.detail || `${label}: ${dim.score}`}
                className="group flex flex-col items-start rounded-lg border border-border-subtle bg-background px-2.5 py-1.5 text-left transition-colors hover:border-accent-border hover:bg-surface-warm"
              >
                <span className="font-mono text-[12px] text-text-muted">{label}</span>
                <span className="font-mono text-base font-semibold leading-tight" style={{ color: scoreColor(dim.score) }}>{dim.score}</span>
                <span className="mt-1 block h-1 w-full overflow-hidden rounded-full bg-surface-strong">
                  <span className="block h-full rounded-full" style={{ width: `${Math.max(0, Math.min(100, dim.score))}%`, backgroundColor: scoreColor(dim.score) }} />
                </span>
              </button>
            );
          })}
        </div>
      </div>

      {/* I3: explicit "what's out of date" summary, so staleness is obvious at
          a glance rather than buried in the per-item list below. */}
      {staleItems.length > 0 && (
        <div className="flex items-start gap-2.5 rounded-2xl border border-warn/40 bg-warn/5 p-4">
          <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0 text-warn" />
          <div className="text-sm text-text-secondary">
            <span className="font-semibold text-text-primary">
              {staleItems.length} {staleItems.length === 1 ? "item is" : "items are"} out of date.
            </span>{" "}
            {staleItems.map((it) => it.label).join(", ")}. Refreshing these lifts the freshness score.
          </div>
        </div>
      )}

      {/* Domain fit - the domain-intelligent relevance checklist. Only present
          when the CLI matched a rubric for this domain. */}
      {score.relevance && (
        <div>
          <div className="mb-2 flex items-baseline justify-between">
            <span className="font-mono text-[14px] font-semibold text-text-primary">
              Domain fit
            </span>
            <span className="font-mono text-[12px] text-text-muted">{score.relevance.detail}</span>
          </div>
          <div className="flex flex-col gap-1.5 rounded-2xl border border-border bg-surface p-3">
            {score.relevance.items.map((it) => {
              const tone = it.present && !it.stale ? "ok" : it.stale ? "warn" : it.severity === "critical" ? "danger" : "muted";
              const dotColor =
                tone === "ok" ? "var(--color-ok, #2e9e5b)"
                : tone === "warn" ? "var(--color-warn, #c98a2b)"
                : tone === "danger" ? "var(--color-err, #d24b4b)"
                : "var(--color-text-muted, #888)";
              return (
                <div
                  key={it.id}
                  className="flex items-start gap-2.5 rounded-lg px-2 py-1.5 hover:bg-surface-warm"
                >
                  <span className="mt-0.5 shrink-0" style={{ color: dotColor }}>
                    {it.present && !it.stale ? (
                      <Check className="h-4 w-4" />
                    ) : it.stale ? (
                      <AlertTriangle className="h-4 w-4" />
                    ) : (
                      <Circle className="h-4 w-4" />
                    )}
                  </span>
                  <div className="min-w-0 flex-1">
                    <div className="flex items-center justify-between gap-2">
                      <span
                        className={`text-sm font-medium ${it.present ? "text-text-primary" : "text-text-secondary"}`}
                      >
                        {it.label}
                      </span>
                      <span className="shrink-0 text-[12px] text-text-muted">{it.detail}</span>
                    </div>
                    {(!it.present || it.stale) && (
                      <div className="mt-0.5 text-[12px] text-text-muted">{it.recommend}</div>
                    )}
                  </div>
                </div>
              );
            })}
          </div>
        </div>
      )}

      {/* Six dimensions */}
      <div>
        <div className="mb-2 text-[14px] font-semibold text-text-primary">
          Structural readiness
        </div>
        <div className="flex flex-col gap-3 rounded-2xl border border-border bg-surface p-5">
          {SCORE_DIMENSIONS.map(({ key, label }) => {
            const dim = score.breakdown[key];
            return (
              <div
                key={key}
                id={`dim-${key}`}
                className={`scroll-mt-24 rounded-md p-1 transition-shadow ${flashDim === key ? "bg-accent-soft/40 ring-2 ring-accent-border" : ""}`}
              >
                <div className="mb-1 flex items-center justify-between">
                  <span className="text-sm font-medium text-text-primary">{label}</span>
                  <span className="font-mono text-xs" style={{ color: scoreColor(dim.score) }}>
                    {dim.score}
                  </span>
                </div>
                <ScoreBar value={dim.score} max={100} color={scoreColor(dim.score)} />
                {dim.detail && (
                  <div className="mt-1 text-[12px] text-text-muted">{dim.detail}</div>
                )}
              </div>
            );
          })}
        </div>
      </div>

      {/* What's missing, grouped by severity */}
      {score.missing.length > 0 && (
        <div>
          <div className="mb-2 text-[14px] font-semibold text-text-primary">
            What's missing
          </div>
          <div className="flex flex-col gap-4 rounded-2xl border border-border bg-surface p-5">
            {severities.map((sev) => {
              const tone =
                sev === "critical" ? "danger" : sev === "warn" ? "warn" : "ok";
              const dot =
                tone === "danger"
                  ? "var(--color-err, #d24b4b)"
                  : tone === "warn"
                  ? "var(--color-warn, #c98a2b)"
                  : "var(--color-text-muted, #888)";
              return (
                <div key={sev}>
                  <div className="mb-1.5 text-xs font-semibold tracking-wide text-text-secondary">
                    {SEVERITY_LABEL[sev] ?? sev}
                  </div>
                  <ul className="flex flex-col gap-1.5">
                    {grouped[sev].map((m, i) => (
                      <li key={i} className="flex items-start gap-2 text-sm text-text-primary">
                        <span
                          className="mt-1.5 inline-block h-1.5 w-1.5 shrink-0 rounded-full"
                          style={{ background: dot }}
                        />
                        <span>
                          {m.label}
                          {m.kind && (
                            <span className="ml-1.5 rounded bg-surface-warm px-1 py-0 text-[12px] text-text-muted">
                              {m.kind}
                            </span>
                          )}
                        </span>
                      </li>
                    ))}
                  </ul>
                </div>
              );
            })}
          </div>
        </div>
      )}

      {/* Assessment + last audited */}
      {score.assessment && (
        <div>
          <div className="mb-2 text-[14px] font-semibold text-text-primary">
            Assessment
          </div>
          <div className="rounded-2xl border border-border bg-surface p-5">
            <p className="text-sm leading-relaxed text-text-primary">{score.assessment}</p>
            <div className="mt-3 text-[12px] text-text-muted">
              last audited · {formatAuditedAt(score.audited_at)}
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

export function PaletteCard({
  palette,
  active,
  onSelect,
}: {
  palette: (typeof PALETTES)[number];
  active: boolean;
  onSelect: () => void;
}) {
  return (
    <button
      onClick={onSelect}
      className={`group overflow-hidden rounded-xl border-2 text-left transition-all ${
        active
          ? "border-accent shadow-md"
          : "border-border-subtle hover:border-border"
      }`}
    >
      {/* Preview card - solid swatch of the palette */}
      <div
        className="relative h-24 px-4 py-3"
        style={{ backgroundColor: palette.swatch.bg }}
      >
        {/* mock message bubble */}
        <div
          className="absolute left-4 right-12 top-3 h-2 rounded-full opacity-90"
          style={{ backgroundColor: palette.swatch.accent }}
        />
        <div
          className="absolute left-4 right-20 top-7 h-2 rounded-full opacity-50"
          style={{ backgroundColor: palette.swatch.accent }}
        />
        {/* mock pill */}
        <div
          className="absolute bottom-3 right-4 h-5 w-12 rounded-full"
          style={{ backgroundColor: palette.swatch.surface, opacity: 0.7 }}
        />
        {/* AI dot */}
        <div
          className="absolute bottom-4 left-4 h-3 w-3 rounded-full"
          style={{ backgroundColor: palette.swatch.ai }}
        />
        {active && (
          <div className="absolute right-3 top-3 flex h-5 w-5 items-center justify-center rounded-full bg-accent text-background">
            <Check className="h-3 w-3" />
          </div>
        )}
      </div>
      {/* Label */}
      <div className="border-t border-border-subtle bg-surface px-4 py-3">
        <div className="font-medium">{palette.name}</div>
        <div className="mt-0.5 text-xs text-text-secondary">{palette.blurb}</div>
      </div>
    </button>
  );
}
