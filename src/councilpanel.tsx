// The multi-model Council panel, extracted from App.tsx: convene a panel of
// (CLI, model) slots over a question, stream each panelist, then synthesize a
// chair verdict. Renders the shared DomainStatusBar + DomainContextView.
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { GlyphStudioLogo } from "./GlyphStudioLogo";
import { ArrowRight, BookOpen, Check, ChevronRight, Crown, Folder, Ghost, Layers, MessageSquare, Plus, Scale, Sparkles, ThumbsDown, ThumbsUp } from "lucide-react";
import { invoke, listen } from "./bridge";
import { savePastedImages } from "./paste";
import { titleCase } from "./format";
import { startProcess, endProcess } from "./processes";
import { isLocalCli, splitThinking, stripAnsi, vendorAccent, isUserDomain } from "./helpers";
import { buildCouncilQuickActions, buildIdealStatePreamble, buildSkillsPreamble, buildSynthesisPrompt, curatedFor, loadPreferredSkills, maybeStripSycophancy, modelsFor, savePreferredSkills } from "./helpers2";
import { LS, PREF, getDomainToggle, getPref, incognitoActive, isBunkerOn, lsGet, lsSet, setPref } from "./storage";
import { ThinkingDisclosure } from "./ui";
import { ContextMeter, estimateTokens, contextWindowFor } from "./contextmeter";
import { Markdown } from "./Markdown";
import { domainIcon } from "./icons";
import { ThinkingDots, useFrameworkLens } from "./hooks";
import { USE_COUNCIL_EVENT, takePendingCouncil, useCouncils } from "./council";
import { extractCliError } from "./textutil";
import { ProviderMark } from "./marks";
import { BrandMark } from "./brandmark";
import { DomainStatusBar } from "./chatviews";
import { ContextButton, ContextCanvas, DomainContextView } from "./domainpanels";
import { AppRowLogo } from "./panels3";
import { ActApprovalCard } from "./actcard";
import { extractActIds } from "./waiting";
import type { CliInfo, Domain, DomainContextBundle, EngineApp, ModelPick, PanelistReply, PanelistSlot, SkillEntry, ThreadMeta, ThreadTurn } from "./types";
import type { UnlistenFn } from "./bridge";
import { DETAIL_TITLE } from "./typescale";

export function CouncilPanel({
  domain,
  domainPath,
  threadDomain,
  vaultPath: _vaultPath,
  clis,
  fwLens,
  activeThreadPath,
  onActiveThreadChange,
  onOpenInFinder,
  onSwitchToChat,
  onThreadsChanged,
  seedPrompt,
  seedAutoConvene,
  onSeedConsumed,
  active = true,
  phone = false,
}: {
  domain: string | null;
  domainPath: string | null;
  // See ChatPanel: thread storage scope (app space when set), distinct from
  // the grounding `domain`.
  threadDomain?: string | null;
  vaultPath: string;
  clis: CliInfo[];
  fwLens: ReturnType<typeof useFrameworkLens>;
  activeThreadPath: string | null;
  onActiveThreadChange: (path: string | null) => void;
  onOpenInFinder: () => void;
  onSwitchToChat: () => void;
  onThreadsChanged?: () => void;
  seedPrompt?: string | null;
  seedAutoConvene?: boolean;
  onSeedConsumed?: () => void;
  /** Whether the council tab is the visible one. When false the panel stays
      mounted (so a convened run keeps streaming) but ignores shared-thread
      changes driven by chat, so it doesn't clobber its own run/verdict. */
  active?: boolean;
  // Rendered inside the phone shell: the domain identity lives in the shell's
  // own big header (so the in-panel strip is dropped), the side context rail
  // has no room, and the composer placeholder is short.
  phone?: boolean;
}) {
  // Thread storage scope (app space when set), else the grounding domain.
  const tDomain = threadDomain !== undefined ? threadDomain : domain;
  // All possible (cli, model) panelist slots across ALL providers -
  // even ones not installed are listed (greyed out) so the user knows
  // what's possible. Same provider can appear multiple times with
  // different models (e.g. Opus 4.7 AND Sonnet 4.6 both on panel).
  // The council this conversation convenes: one asked for by "Use in chat",
  // else the Default. Picking another swaps the panel and chair.
  const { councils, defaultId: defaultCouncilId } = useCouncils();
  const [councilId, setCouncilId] = useState<string>(() => takePendingCouncil() ?? "");
  const activeCouncil = councils.find((c) => c.id === councilId) ?? councils.find((c) => c.id === defaultCouncilId) ?? councils[0];
  const seedCouncil = () => activeCouncil ?? { seats: [] as string[], chair: "" };
  const allSlots = useMemo<PanelistSlot[]>(() => {
    const out: PanelistSlot[] = [];
    for (const c of clis) {
      const found = modelsFor(c.id);
      const models = found.length ? found : [{ id: "", label: "default" } as ModelPick];
      for (const m of models) {
        out.push({
          key: `${c.id}::${m.id}`,
          cli: c.id,
          cliLabel: c.label,
          model: m.id,
          modelLabel: m.label,
          blurb: m.blurb,
        });
      }
    }
    return out;
  }, [clis]);

  // Selected panelists default to first model of each AVAILABLE CLI.
  const [selectedSlots, setSelectedSlots] = useState<Set<string>>(() => new Set());
  // Per-slot verification status - "verified" once a one-shot ping
  // succeeds with this exact (cli, model). Persisted in localStorage
  // so repeated app launches don't keep re-pinging.
  type VerifyStatus = "unknown" | "verifying" | "ok" | "failed";
  const VERIFY_KEY = "prevail.council.verifySlots";
  const [verifyStatus, setVerifyStatus] = useState<Record<string, VerifyStatus>>(() => {
    try {
      const raw = lsGet(VERIFY_KEY);
      if (!raw) return {};
      const obj = JSON.parse(raw) as Record<string, "ok" | "failed">;
      // Only restore "ok" results; failures get re-tried next session.
      const out: Record<string, VerifyStatus> = {};
      for (const k of Object.keys(obj)) if (obj[k] === "ok") out[k] = "ok";
      return out;
    } catch { return {}; }
  });
  const [verifyError, setVerifyError] = useState<Record<string, string>>({});
  function persistVerify(next: Record<string, VerifyStatus>) {
    const trimmed: Record<string, "ok"> = {};
    for (const k of Object.keys(next)) if (next[k] === "ok") trimmed[k] = "ok";
    try { lsSet(VERIFY_KEY, JSON.stringify(trimmed)); } catch {}
  }
  async function verifySlot(slot: PanelistSlot) {
    setVerifyStatus((s) => ({ ...s, [slot.key]: "verifying" }));
    try {
      await invoke<string>("verify_cli_model", {
        args: { cli: slot.cli, model: slot.model || null },
      });
      setVerifyStatus((s) => {
        const next = { ...s, [slot.key]: "ok" as VerifyStatus };
        persistVerify(next);
        return next;
      });
      setVerifyError((e) => { const { [slot.key]: _, ...rest } = e; return rest; });
    } catch (e) {
      const msg = String(e).slice(0, 200);
      setVerifyStatus((s) => ({ ...s, [slot.key]: "failed" }));
      setVerifyError((er) => ({ ...er, [slot.key]: msg }));
    }
  }
  // @ts-expect-error queued for v0.2.42 "verify all" button
  async function verifyAllSelected() {
    for (const s of panelistSlotsAll()) {
      if (verifyStatus[s.key] === "ok") continue;
      await verifySlot(s);
    }
  }
  function panelistSlotsAll() {
    return allSlots.filter((s) => selectedSlots.has(s.key));
  }
  useEffect(() => {
    setSelectedSlots((cur) => {
      if (cur.size > 0) return cur;
      // Seed from the configured default council panel (Settings → Council),
      // which stores exact slot keys (`${cli}::${model}`) - so a panel can hold
      // several models from the same provider. Only keep slots that still exist
      // and whose provider is available. If nothing's configured, default to one
      // slot per available CLI.
      const configured = seedCouncil().seats;
      const def = new Set<string>();
      for (const key of configured) {
        const slot = allSlots.find((s) => s.key === key);
        const cli = slot && clis.find((c) => c.id === slot.cli);
        if (slot && cli?.available) def.add(key);
      }
      if (def.size === 0) {
        const seen = new Set<string>();
        for (const s of allSlots) {
          const cli = clis.find((c) => c.id === s.cli);
          if (!cli?.available || seen.has(s.cli)) continue;
          seen.add(s.cli);
          def.add(s.key);
        }
      }
      return def;
    });
  }, [allSlots, clis]);
  const toggleSlot = (key: string) => {
    setSelectedSlots((cur) => {
      const next = new Set(cur);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      return next;
    });
  };
  const panelistSlots = useMemo(
    // Under Bunker, drop already-selected CLOUD panelists entirely, not just
    // from the picker, so they never convene and leak the prompt off-device (O60).
    () => allSlots.filter((s) => selectedSlots.has(s.key) && (!isBunkerOn() || isLocalCli(s.cli))),
    [allSlots, selectedSlots],
  );
  // Auto-verify any panelist slot that hasn't been verified yet (or
  // failed last time). Triggers when slots are selected/changed.
  // Persisted "ok" results in localStorage skip the re-check.
  useEffect(() => {
    for (const s of panelistSlots) {
      const cur = verifyStatus[s.key] ?? "unknown";
      if (cur === "unknown") {
        // Stagger so we don't hammer all CLIs simultaneously.
        const delay = Math.random() * 500;
        setTimeout(() => { verifySlot(s); }, delay);
      }
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [panelistSlots]);

  // Chair is a single (cli, model) pair - defaults to first selected
  // panelist's CLI with its first model, or whatever's saved.
  const [chairSlot, setChairSlot] = useState<string>("");
  const applyCouncil = (id: string) => {
    const c = councils.find((x) => x.id === id);
    if (!c) return;
    setCouncilId(c.id);
    setSelectedSlots(new Set(c.seats.filter((k) => allSlots.some((s) => s.key === k))));
    setChairSlot(allSlots.some((s) => s.key === c.chair) ? c.chair : "");
  };
  useEffect(() => {
    const on = (e: Event) => { const id = (e as CustomEvent<{ id: string }>).detail?.id; takePendingCouncil(); if (id) applyCouncil(id); };
    window.addEventListener(USE_COUNCIL_EVENT, on);
    return () => window.removeEventListener(USE_COUNCIL_EVENT, on);
  });
  useEffect(() => {
    if (chairSlot) return;
    // Prefer the configured chair SLOT (a specific model); fall back to the
    // legacy chair-by-CLI, then the first panelist.
    const savedSlot = seedCouncil().chair;
    if (savedSlot && allSlots.some((s) => s.key === savedSlot)) {
      setChairSlot(savedSlot);
      return;
    }
    const savedCli = lsGet(LS.defaultChairCli);
    if (savedCli) {
      const match = allSlots.find((s) => s.cli === savedCli);
      if (match) {
        setChairSlot(match.key);
        return;
      }
    }
    if (panelistSlots.length > 0) setChairSlot(panelistSlots[0].key);
    else if (allSlots.length > 0) setChairSlot(allSlots[0].key);
  }, [allSlots, panelistSlots, chairSlot]);

  // The chat never writes the council settings: a chair picked here is for
  // this conversation only. Councils are edited in Settings > Council.

  const chairSlotObj = useMemo(
    () => allSlots.find((s) => s.key === chairSlot) ?? null,
    [allSlots, chairSlot],
  );

  // Context drawer + primed extras (state.md, decisions, dragged-in
  // domains). Same machinery as Chat - gets prepended to the convened
  // prompt so panelists and the chair both see it.
  const [contextOpen, setContextOpen] = useState(false);
  const [primedContext, setPrimedContext] = useState<{ label: string; body: string }[]>([]);
  function injectContext(body: string, label: string) {
    setPrimedContext((cur) => {
      if (cur.some((c) => c.label === label)) return cur;
      return [...cur, { label, body }];
    });
  }
  // Resolve a dragged domain into a primed-context chip. Shared by the panel
  // drop zone AND the composer textarea so a domain dropped directly onto the
  // input still attaches (the textarea would otherwise eat the native drop).
  // Default = light (state.md); hold Shift for the full context bundle.
  // Same light/full/folder modes as Chat: plain = state summary, ⇧ = full
  // context bundle, ⌥ = the entire folder as a readable file map.
  async function attachCouncilDomain(name: string, mode: "light" | "full" | "folder" = "light") {
    if (!name || !_vaultPath) return;
    try {
      if (mode === "folder") {
        const t = await invoke<{ root: string; files: string[] }>("domain_tree", { vault: _vaultPath, domain: name });
        const body = [
          `Domain folder: ${t.root}`,
          "Read any file in this folder directly (paths below, relative to the folder) when it is relevant. Scan broadly; state alone may not have everything.",
          "",
          "Files:",
          ...t.files.map((f) => `- ${f}`),
        ].join("\n");
        injectContext(body, `extra (entire folder): ${titleCase(name)}`);
        return;
      }
      const c = await invoke<DomainContextBundle>("domain_context", { vault: _vaultPath, domain: name });
      if (mode === "full") {
        const parts = [
          c.state && `## state.md\n${c.state}`,
          c.decisions && `## decisions\n${c.decisions}`,
          c.journal && `## journal\n${c.journal}`,
        ].filter(Boolean);
        injectContext(parts.length ? parts.join("\n\n") : `(no context files in ${name})`, `extra (full): ${titleCase(name)}`);
      } else {
        injectContext(c.state || `(no state.md in ${name})`, `extra: ${titleCase(name)}/state.md`);
      }
    } catch (err) { console.error("attach council domain", err); }
  }
  // Skills attached to the next convene - same model as Chat.
  const [attachedSkills, setAttachedSkills] = useState<string[]>(() => loadPreferredSkills(domain));
  // Images pasted into the council composer - saved to the vault, attached to
  // the next convene as file paths every panelist can read. Cleared on convene.
  const [pastedFiles, setPastedFiles] = useState<string[]>([]);
  const [preferredSkills, setPreferredSkills] = useState<string[]>(() => loadPreferredSkills(domain));
  useEffect(() => {
    const pref = loadPreferredSkills(domain);
    setPreferredSkills(pref);
    setAttachedSkills(pref);
  }, [domain]);
  const togglePreferredSkill = useCallback((name: string) => {
    setPreferredSkills((cur) => {
      const next = cur.includes(name) ? cur.filter((n) => n !== name) : [...cur, name];
      savePreferredSkills(domain, next);
      return next;
    });
    setAttachedSkills((cur) => (cur.includes(name) ? cur.filter((n) => n !== name) : [...cur, name]));
  }, [domain]);
  const preferredSkillsSet = useMemo(() => new Set(preferredSkills), [preferredSkills]);
  function insertSkillSlash(name: string) {
    setAttachedSkills((cur) => (cur.includes(name) ? cur : [...cur, name]));
    setContextOpen(false);
  }
  function removeAttachedSkill(name: string) {
    setAttachedSkills((cur) => cur.filter((n) => n !== name));
  }
  // Auto-prime the domain's state.md whenever the domain changes.
  useEffect(() => {
    if (!domain || !_vaultPath) {
      setPrimedContext((cur) => cur.filter((x) => !x.label.startsWith("auto:")));
      return;
    }
    let mounted = true;
    invoke<DomainContextBundle>("domain_context", { vault: _vaultPath, domain })
      .then((c) => {
        if (!mounted) return;
        const label = `auto: ${titleCase(domain)}/state.md`;
        setPrimedContext((cur) => {
          const cleared = cur.filter((x) => !x.label.startsWith("auto:"));
          // Null-tolerant: a null body from the engine must not crash the panel.
          if (!c?.state) return cleared;
          return [...cleared, { label, body: c.state }];
        });
      })
      .catch(() => {});
    return () => { mounted = false; };
  }, [domain, _vaultPath]);
  const [prompt, setPrompt] = useState("");
  // ── `$`/`/` context mentions (parity with Chat) ─────────────────────────
  // Type `$` to attach a domain or connected app, `/` to attach a skill - the
  // same machinery Chat uses, ported here so the council composer behaves
  // identically. Caret-tracked matchers drive the popovers; caches feed them.
  const taRef = useRef<HTMLTextAreaElement>(null);
  const [caretPos, setCaretPos] = useState(0);
  const syncCaret = useCallback((el: HTMLTextAreaElement | null) => {
    if (el) setCaretPos(el.selectionStart ?? el.value.length);
  }, []);
  const [mentionDomains, setMentionDomains] = useState<Domain[]>([]);
  const [appsCache, setAppsCache] = useState<EngineApp[]>([]);
  const [allSkills, setAllSkills] = useState<SkillEntry[]>([]);
  useEffect(() => {
    if (!_vaultPath) { setMentionDomains([]); setAllSkills([]); return; }
    invoke<Domain[]>("scan_vault", { path: _vaultPath }).then((v) => setMentionDomains(Array.isArray(v) ? v.filter((d) => isUserDomain(d.name)) : [])).catch(() => setMentionDomains([]));
    // Only ENABLED skills feed /skills + auto-attach; disabled ones are hidden.
    invoke<SkillEntry[]>("scan_skills", { vault: _vaultPath }).then((s) => setAllSkills(s.filter((x) => x.enabled !== false))).catch(() => setAllSkills([]));
  }, [_vaultPath]);
  useEffect(() => {
    if (!_vaultPath) { setAppsCache([]); return; }
    const load = () => invoke<EngineApp[]>("engine_apps_list").then((v) => setAppsCache(Array.isArray(v) ? v : [])).catch(() => setAppsCache([]));
    void load();
    window.addEventListener("prevail:apps-changed", load);
    return () => window.removeEventListener("prevail:apps-changed", load);
  }, [_vaultPath]);
  // Attach a connected app as context (mirror of attachCouncilDomain - council
  // had no app-attach before). Compact identity card, same as Chat.
  const attachCouncilApp = useCallback(async (id: string) => {
    if (!id) return;
    try {
      const all = await invoke<EngineApp[]>("engine_apps_list");
      const app = all.find((a) => a.id === id);
      if (!app) return;
      const body = [
        `# App: ${app.title}${app.account?.label ? ` (${app.account.label})` : ""}`,
        `Connector: ${app.integration} · status: ${app.status}`,
        app.domains.length ? `Feeds these domains: ${app.domains.map(titleCase).join(", ")}` : "Not bound to any domain yet.",
      ].join("\n");
      injectContext(body, `app: ${app.title}`);
    } catch (err) { console.error("attach council app", err); }
  }, [_vaultPath]);
  // Expose the same window attach hooks the sidebar's manual drag calls, so
  // dragging a domain or app onto the Council attaches it as context exactly
  // like Chat. Only one of Chat/Council is mounted at a time, so whichever is
  // active owns the hooks. Refs hold the latest callbacks; the hooks register
  // ONCE on mount to avoid the teardown race that would delete them whenever a
  // callback's identity changed (see chatpanel B1). Without this, drops in
  // Council found no hook and silently did nothing.
  const attachDomainRef = useRef(attachCouncilDomain);
  const attachAppRef = useRef(attachCouncilApp);
  useEffect(() => { attachDomainRef.current = attachCouncilDomain; attachAppRef.current = attachCouncilApp; });
  // Claim the global drag-attach hook ONLY while Council is the active surface,
  // so a dropped app/domain/skill lands in Council and not in the hidden chat
  // panel. Mirrors chatpanel: re-claim on activation, no cleanup-delete.
  useEffect(() => {
    if (!active) return;
    const w = window as unknown as {
      __prevailAttach?: (n: string, mode?: "light" | "full" | "folder") => void;
      __prevailAttachApp?: (id: string) => void;
    };
    w.__prevailAttach = (n, mode) => void attachDomainRef.current(n, mode ?? "light");
    w.__prevailAttachApp = (id) => void attachAppRef.current(id);
  }, [active]);
  type DollarItem = { kind: "domain" | "app"; id: string; label: string; sub?: string };
  const slashMatch = useMemo(() => {
    const caret = Math.min(caretPos, prompt.length);
    const m = prompt.slice(0, caret).match(/(^|\s)\/([a-zA-Z0-9_-]*)$/);
    if (!m) return null;
    return { token: m[2], start: caret - m[2].length - 1, end: caret };
  }, [prompt, caretPos]);
  const slashCandidates = useMemo(() => {
    if (!slashMatch) return [];
    const q = slashMatch.token.toLowerCase();
    const matched = allSkills.filter((s) => s.name.toLowerCase().includes(q));
    const rank = (s: SkillEntry) => (domain && s.domain === domain ? 0 : 1);
    return [...matched].sort((a, b) => rank(a) - rank(b) || a.name.localeCompare(b.name)).slice(0, 8);
  }, [slashMatch, allSkills, domain]);
  const [slashIdx, setSlashIdx] = useState(0);
  useEffect(() => { setSlashIdx(0); }, [slashMatch?.token]);
  const dollarMatch = useMemo(() => {
    const caret = Math.min(caretPos, prompt.length);
    const m = prompt.slice(0, caret).match(/(^|\s)\$([a-zA-Z0-9_-]*)$/);
    if (!m) return null;
    return { token: m[2], start: caret - m[2].length - 1, end: caret };
  }, [prompt, caretPos]);
  const dollarCandidates = useMemo<DollarItem[]>(() => {
    if (!dollarMatch) return [];
    const q = dollarMatch.token.toLowerCase();
    const doms: DollarItem[] = mentionDomains
      .map((d) => ({ kind: "domain" as const, id: d.name, label: titleCase(d.name) }))
      .filter((d) => d.id.toLowerCase().includes(q) || d.label.toLowerCase().includes(q));
    const apps: DollarItem[] = appsCache
      .map((a) => ({ kind: "app" as const, id: a.id, label: a.title, sub: a.integration }))
      .filter((a) => a.id.toLowerCase().includes(q) || a.label.toLowerCase().includes(q));
    // Apps first so they're never starved out by the long domain list.
    return [...apps, ...doms].slice(0, 8);
  }, [dollarMatch, mentionDomains, appsCache]);
  const [dollarIdx, setDollarIdx] = useState(0);
  useEffect(() => { setDollarIdx(0); }, [dollarMatch?.token]);
  function applySlashCompletion(name: string) {
    if (!slashMatch) return;
    const head = prompt.slice(0, slashMatch.start).replace(/\s$/, "");
    const tail = prompt.slice(slashMatch.end);
    setPrompt(`${head}${head && tail && !tail.startsWith(" ") ? " " : ""}${tail}`);
    setCaretPos(head.length);
    insertSkillSlash(name);
    requestAnimationFrame(() => { const ta = taRef.current; if (ta) { ta.focus(); ta.setSelectionRange(head.length, head.length); } });
  }
  function applyDollarCompletion(item: DollarItem | undefined) {
    if (!dollarMatch || !item) return;
    const head = prompt.slice(0, dollarMatch.start).replace(/\s$/, "");
    const tail = prompt.slice(dollarMatch.end);
    setPrompt(`${head}${head && tail && !tail.startsWith(" ") ? " " : ""}${tail}`);
    setCaretPos(head.length);
    if (item.kind === "domain") void attachCouncilDomain(item.id, "light");
    else void attachCouncilApp(item.id);
    requestAnimationFrame(() => { const ta = taRef.current; if (ta) { ta.focus(); ta.setSelectionRange(head.length, head.length); } });
  }
  // Chip icon by label prefix (parity with Chat): domain icon / app logo / skill.
  function ctxChipIcon(label: string) {
    if (label.startsWith("app-skill:")) return <Sparkles className="h-3 w-3" />;
    const appTitle = label.startsWith("auto-app:") ? label.slice("auto-app:".length).replace(/\s+skill\s*$/i, "").trim()
      : label.startsWith("app:") ? label.slice("app:".length).trim()
      : null;
    if (appTitle) return <AppRowLogo app={{ title: appTitle }} size={14} fallback="letter" />;
    const dom = label.match(/^(?:auto|extra(?:\s*\([^)]*\))?):\s*([^/]+)/);
    if (dom) { const I = domainIcon(dom[1].trim().toLowerCase()); return I ? <I className="h-3 w-3" /> : <Layers className="h-3 w-3" />; }
    return <BookOpen className="h-3 w-3" />;
  }
  // G3: incognito for council. Reflects effective state (global master OR the
  // council flag); the toggle flips the council-specific flag. When the global
  // master is on it stays on and the per-surface toggle can't turn it off here.
  // Incognito now lives in the shared Modes menu (DomainStatusBar surface="council"),
  // matching chat. This panel only REFLECTS the state - a glow + ghost badge on the
  // composer - and re-syncs when Modes toggles it.
  const [incognito, setIncognito] = useState(() => incognitoActive("council"));
  const globalIncognito = getPref(PREF.incognito, "0") === "1";
  useEffect(() => {
    const sync = () => setIncognito(incognitoActive("council"));
    window.addEventListener("prevail:incognito-changed", sync);
    return () => window.removeEventListener("prevail:incognito-changed", sync);
  }, []);
  // I4: a Decision/Risks card from the domain home routes here with a seeded
  // question - drop it into the composer so the user just picks panelists and
  // convenes. Consumed once so it doesn't re-fire on re-render.
  useEffect(() => {
    if (seedPrompt) {
      const q = seedPrompt;
      setPrompt(q);
      const auto = seedAutoConvene;
      onSeedConsumed?.();
      // Auto-council: the chat send routed here; convene immediately with the
      // seeded question (slight delay so panelist slots finish mounting).
      if (auto) setTimeout(() => void conveneWith(q), 150);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [seedPrompt]);
  // Snapshot of the prompt at the moment the council was convened.
  // Composer `prompt` clears after submit so the textarea is empty for
  // the next question; this preserves the question text shown above
  // the responses in the transcript.
  const [submittedPrompt, setSubmittedPrompt] = useState("");
  const [phase, setPhase] = useState<"idle" | "panelists" | "synthesizing" | "done">("idle");
  // P1: track phase in a ref so the thread-switch effect can read "is a council
  // running?" without re-running on every phase change.
  const phaseRef = useRef(phase);
  useEffect(() => { phaseRef.current = phase; }, [phase]);
  // P3: when a council starts running, scroll its live convene to the top of the
  // viewport so the user always sees the latest council (with prior turns above,
  // the live one was below the fold and needed a manual scroll).
  const liveConveneRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (phase === "panelists") {
      // let the block mount first
      const t = window.setTimeout(() => liveConveneRef.current?.scrollIntoView({ behavior: "smooth", block: "start" }), 80);
      return () => window.clearTimeout(t);
    }
  }, [phase]);
  // P2: register the running council in the global process registry so the
  // sidebar shows it as a live process while it runs (and across navigation).
  useEffect(() => {
    const id = `council:${domain ?? "general"}`;
    if (phase === "panelists" || phase === "synthesizing") {
      startProcess(id, "council", `Council · ${domain ? titleCase(domain) : "General"}`, domain);
    } else {
      endProcess(id);
    }
    return () => endProcess(id);
  }, [phase, domain]);
  const [replies, setReplies] = useState<Record<string, PanelistReply>>({});
  const [verdict, setVerdict] = useState<string>("");
  // The decision-log id for the verdict currently on screen, so the user can
  // attach a thumbs up/down (decision_feedback) to it. (feedback v0.4.1 I5)
  const [verdictDecisionId, setVerdictDecisionId] = useState<string | null>(null);
  const [verdictRating, setVerdictRating] = useState<"up" | "down" | null>(null);
  const sessionRef = useRef<string>("");
  const unlistenRefs = useRef<UnlistenFn[]>([]);

  useEffect(() => {
    let mounted = true;
    (async () => {
      const u1 = await listen<{ session: string; cli: string; stream: string; data: string }>(
        "chat:chunk",
        (e) => {
          if (!mounted) return;
          if (!e.payload.session.startsWith(sessionRef.current)) return;
          if (e.payload.session.endsWith(":chair")) {
            if (e.payload.stream !== "stdout") return;
            setVerdict((v) => v + stripAnsi(e.payload.data));
            return;
          }
          const slotMatch = e.payload.session.match(/:slot:(.+)$/);
          if (!slotMatch) return;
          const slotKey = slotMatch[1];
          // Capture stderr so a panelist that errored shows its real
          // failure reason instead of a silent empty card.
          if (e.payload.stream === "stderr") {
            const errChunk = stripAnsi(e.payload.data);
            setReplies((r) => {
              const existing = r[slotKey] ?? { cli: e.payload.cli, content: "", streaming: true, startedAt: Date.now() };
              return { ...r, [slotKey]: { ...existing, stderr: (existing.stderr ?? "") + errChunk } };
            });
            return;
          }
          if (e.payload.stream !== "stdout") return;
          const clean = maybeStripSycophancy(stripAnsi(e.payload.data));
          setReplies((r) => {
            const existing = r[slotKey] ?? { cli: e.payload.cli, content: "", streaming: true, startedAt: Date.now() };
            return { ...r, [slotKey]: { ...existing, content: existing.content + clean } };
          });
        },
      );
      const u2 = await listen<{ session: string; cli: string; code: number }>(
        "chat:done",
        (e) => {
          if (!mounted) return;
          if (!e.payload.session.startsWith(sessionRef.current)) return;
          if (e.payload.session.endsWith(":chair")) {
            setPhase("done");
            return;
          }
          const slotMatch = e.payload.session.match(/:slot:(.+)$/);
          if (!slotMatch) return;
          const slotKey = slotMatch[1];
          setReplies((r) => {
            const existing = r[slotKey];
            if (!existing) return r;
            return { ...r, [slotKey]: { ...existing, streaming: false } };
          });
        },
      );
      unlistenRefs.current = [u1, u2];
    })();
    return () => {
      mounted = false;
      unlistenRefs.current.forEach((u) => u());
      unlistenRefs.current = [];
    };
  }, []);

  const allPanelistsDone = useMemo(
    () => panelistSlots.length > 0 && panelistSlots.every((s) => replies[s.key] && !replies[s.key].streaming),
    [panelistSlots, replies],
  );
  // Panelists that have actually produced a usable answer (finished, with
  // content). Drives the quorum / "summarize now" path so one stuck or
  // slow panelist can't hold the whole council hostage.
  const respondedSlots = useMemo(
    () => panelistSlots.filter((s) => { const r = replies[s.key]; return r && !r.streaming && r.content.trim().length > 0; }),
    [panelistSlots, replies],
  );
  const respondedCount = respondedSlots.length;

  // The set of panelists the chair will actually synthesize from. Tracked so
  // that when we summarize early, the still-pending cards render as "skipped"
  // rather than spinning forever.
  const [synthesisSlots, setSynthesisSlots] = useState<PanelistSlot[] | null>(null);

  const triggerChair = useCallback(async (slotsOverride?: PanelistSlot[]) => {
    if (!chairSlotObj) return;
    const slots = (slotsOverride && slotsOverride.length > 0) ? slotsOverride : panelistSlots;
    setSynthesisSlots(slots);
    const missing = panelistSlots.filter((s) => !slots.some((x) => x.key === s.key));
    let synthesisPrompt = buildSynthesisPrompt(submittedPrompt || prompt, replies, slots);
    if (missing.length > 0) {
      synthesisPrompt += `\n\nNOTE: ${missing.length} panelist(s) did not respond in time (${missing
        .map((s) => `${s.cliLabel} · ${s.modelLabel}`)
        .join(", ")}). Synthesize a verdict from the ${slots.length} response(s) above; do not wait for the rest.`;
    }
    setPhase("synthesizing");
    try {
      await invoke("chat_send", {
        args: {
          cli: chairSlotObj.cli,
          model: chairSlotObj.model || null,
          prompt: synthesisPrompt,
          session_id: `${sessionRef.current}:chair`,
          web: isBunkerOn() ? false : getDomainToggle(domain, "web", true),
        },
      });
    } catch (e) {
      setVerdict(`(chair error: ${e})`);
      setPhase("done");
    }
  }, [chairSlotObj, submittedPrompt, prompt, replies, panelistSlots]);

  // Manually synthesize from whoever has answered so far (the flexible path).
  const synthesizeNow = useCallback(() => {
    if (respondedSlots.length === 0) return;
    void triggerChair(respondedSlots);
  }, [respondedSlots, triggerChair]);

  // Everyone finished → synthesize from all.
  useEffect(() => {
    if (phase === "panelists" && allPanelistsDone) void triggerChair();
  }, [phase, allPanelistsDone, triggerChair]);

  // Quorum fallback: if all-but-one have answered and nothing new has arrived
  // for a grace window, auto-summarize so a stuck panelist doesn't block the
  // verdict forever. The effect re-runs (resetting the timer) on every chunk,
  // so the countdown only completes once the responsive panelists go quiet.
  useEffect(() => {
    if (phase !== "panelists") return;
    const total = panelistSlots.length;
    const quorumMet = total >= 3 && respondedCount >= total - 1 && respondedCount < total;
    if (!quorumMet) return;
    const t = setTimeout(() => { synthesizeNow(); }, 180_000); // 3 min after the last response
    return () => clearTimeout(t);
  }, [phase, respondedCount, panelistSlots.length, synthesizeNow]);

  // Persist the council session as a thread once the verdict lands.
  // Mirrors ChatPanel's auto-save but fires only on phase === "done"
  // so the file represents the complete deliberation rather than
  // intermediate in-flight state.
  // Accumulated prior turns for the active council thread, so convenes
  // continue a multi-turn conversation instead of spawning a new thread.
  const [councilTurns, setCouncilTurns] = useState<ThreadTurn[]>([]);
  const councilThreadRef = useRef<string | null>(activeThreadPath);
  const councilSelfSetRef = useRef<string | null>(null);
  // Track tab visibility in a ref so the thread effect (keyed on activeThreadPath
  // only) can bail when we're hidden, without re-firing when visibility flips.
  const activeRef = useRef(active);
  useEffect(() => { activeRef.current = active; }, [active]);
  // Load (or clear) the council transcript when the active thread changes.
  useEffect(() => {
    // Hidden (chat is the visible tab): the shared activeThreadPath is being
    // driven by chat, not us. Ignore it entirely so a convened council, running
    // OR finished, keeps its replies/verdict on screen when we come back.
    if (!activeRef.current) return;
    councilThreadRef.current = activeThreadPath ?? null;
    // We just saved this convene and adopted its own path - keep the result on
    // screen (don't clear the replies/verdict the user is reading).
    if (activeThreadPath && councilSelfSetRef.current === activeThreadPath) {
      councilSelfSetRef.current = null;
      return;
    }
    // P1: do NOT wipe a RUNNING council when the thread changes. The founder
    // expects a convened council to keep going while they move around; clearing
    // it here was exactly the "switching threads stops my council" bug. Only
    // reset the live state when the council is idle/done (so a finished or
    // not-started panel reflects the newly selected thread).
    if (phaseRef.current === "panelists" || phaseRef.current === "synthesizing") return;
    // Genuine thread switch (+ New, a different thread, or cleared on domain
    // change): clear the live convene state so the panel reflects the SELECTED
    // thread, not the previous convene's question/replies/verdict.
    setReplies({});
    setVerdict("");
    setSynthesisSlots(null);
    setSubmittedPrompt("");
    setPhase("idle");
    if (!activeThreadPath) { setCouncilTurns([]); return; }
    let cancelled = false;
    invoke<{ meta: ThreadMeta; turns: ThreadTurn[] }>("load_thread", { path: activeThreadPath })
      .then((t) => { if (!cancelled) setCouncilTurns(t.turns ?? []); })
      .catch((e) => console.error("load_thread (council)", e));
    return () => { cancelled = true; };
  }, [activeThreadPath]);

  const councilSavedRef = useRef(false);
  useEffect(() => {
    if (phase !== "done") { councilSavedRef.current = false; return; }
    if (councilSavedRef.current) return;
    if (!_vaultPath || !submittedPrompt) return;
    councilSavedRef.current = true;
    // Start from whatever is already in this thread so each convene
    // appends rather than replaces.
    const prior = councilTurns;
    const fresh: ThreadTurn[] = [
      { role: "user", cli: null, model: null, content: submittedPrompt },
    ];
    for (const s of panelistSlots) {
      const r = replies[s.key];
      if (!r || !r.content.trim()) continue;
      fresh.push({
        role: "assistant",
        cli: s.cli,
        model: s.model || null,
        content: `### ${s.cliLabel} · ${s.modelLabel}\n\n${r.content.trim()}`,
      });
    }
    if (verdict.trim()) {
      fresh.push({
        role: "assistant",
        cli: chairSlotObj?.cli ?? null,
        model: chairSlotObj?.model || null,
        content: `### Council verdict\n\n${verdict.trim()}`,
      });
    }
    const allTurns = [...prior, ...fresh];
    // Self-learning: record the verdict as a durable DECISION so the domain
    // learns from it - feeds _state derivation, scoring, and the Insights
    // surface, and can carry a thumbs up/down. (feedback v0.4.1 I1/I5)
    if (verdict.trim()) {
      const decisionId = `d-${Date.now()}`;
      setVerdictDecisionId(decisionId);
      setVerdictRating(null);
      invoke("decision_append", {
        vault: _vaultPath,
        domain: domain ?? null,
        record: {
          id: decisionId,
          kind: "council",
          ts: Date.now(),
          domain: domain ?? null,
          thread: councilThreadRef.current,
          prompt: submittedPrompt,
          verdict: verdict.trim(),
          chair: chairSlotObj ? { cli: chairSlotObj.cli, model: chairSlotObj.model || null } : null,
          panelists: panelistSlots.map((s) => ({ cli: s.cli, model: s.model || null })),
        },
      })
        .then(() => window.dispatchEvent(new CustomEvent("prevail:context-changed")))
        .catch((e) => console.error("decision_append (council)", e));
    }
    // Usage: a council turn is several model calls (each responding panelist plus
    // the chair). Record ONE usage entry per call so the Usage dashboard counts
    // council activity and breaks it down by agent/model accurately - previously
    // council turns recorded nothing, so a day spent in council looked empty.
    {
      const now = Date.now();
      const day = (() => { const d = new Date(now); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`; })();
      const thread = councilThreadRef.current;
      const calls: Array<{ cli: string; model: string | null }> = [];
      for (const s of panelistSlots) {
        const r = replies[s.key];
        if (r && r.content.trim()) calls.push({ cli: s.cli, model: s.model || null });
      }
      if (verdict.trim() && chairSlotObj) calls.push({ cli: chairSlotObj.cli, model: chairSlotObj.model || null });
      let appended = false;
      for (const c of calls) {
        appended = true;
        invoke("usage_append", {
          vault: _vaultPath,
          record: { ts: now, day, domain: domain ?? null, thread, surface: "council", cli: c.cli || "unknown", model: c.model, input_tokens: null, output_tokens: null, cost_usd: null, ok: true },
        }).catch((e) => console.error("usage_append (council)", e));
      }
      if (appended) window.dispatchEvent(new CustomEvent("prevail:usage-updated"));
    }
    // Reuse the existing thread's slug when continuing; else create new.
    const cur = councilThreadRef.current;
    const slug = cur ? cur.split("/").pop()?.replace(/\.md$/, "") ?? null : null;
    // Title comes from the FIRST user turn of the conversation.
    const firstUser = (prior.find((t) => t.role === "user")?.content ?? submittedPrompt);
    const title = `Council · ${firstUser.slice(0, 50).replace(/\n/g, " ")}`;
    invoke<string>("save_thread", {
      vault: _vaultPath,
      domain: tDomain ?? null,
      slug,
      title,
      turns: allTurns,
    })
      .then((path) => {
        setCouncilTurns(allTurns);
        if (!councilThreadRef.current) {
          councilThreadRef.current = path;
          councilSelfSetRef.current = path;
          onActiveThreadChange(path);
        }
        onThreadsChanged?.();
      })
      .catch((e) => console.error("save_thread (council)", e));
  }, [phase, submittedPrompt, replies, verdict, panelistSlots, chairSlotObj, _vaultPath, domain, councilTurns, onActiveThreadChange, onThreadsChanged]);

  // Context-window meter for the composer (parity with chat). With multiple
  // panelists the binding constraint is the SMALLEST window on the panel, so the
  // gauge tracks the most-constrained model. Conversation = the running transcript;
  // attached = primed context chips; draft = the current question.
  const councilCtx = useMemo(() => {
    const conversationTokens = councilTurns.reduce((n, t) => n + estimateTokens(t.content), 0);
    const attachedTokens = primedContext.reduce((n, c) => n + estimateTokens(c.body), 0);
    const windows = panelistSlots.map((s) => contextWindowFor(s.cli, s.model));
    const windowTokens = windows.length ? Math.min(...windows) : 200_000;
    return { conversationTokens, attachedTokens, windowTokens };
  }, [councilTurns, primedContext, panelistSlots]);
  // Start a fresh council conversation (clears the carried transcript + thread).
  const resetCouncil = useCallback(() => {
    setReplies({});
    setVerdict("");
    setPhase("idle");
    setCouncilTurns([]);
    onActiveThreadChange(null);
  }, [onActiveThreadChange]);

  async function convene() {
    return conveneWith(prompt);
  }
  // After Allow / Always on an in-flow approval card: continue the council with
  // a short user turn once the current round has finished.
  const [councilFollowUp, setCouncilFollowUp] = useState<string | null>(null);
  const queueCouncilFollowUp = useCallback((text: string) => setCouncilFollowUp(text), []);
  useEffect(() => {
    if (!councilFollowUp || (phase !== "done" && phase !== "idle")) return;
    const text = councilFollowUp;
    setCouncilFollowUp(null);
    void conveneWith(text);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [councilFollowUp, phase]);
  async function conveneWith(raw: string) {
    if (!raw.trim() || panelistSlots.length === 0) return;
    sessionRef.current = `council-${Date.now()}`;
    setReplies({});
    setVerdict("");
    setSynthesisSlots(null);
    setPhase("panelists");
    const trimmed = raw.trim();
    setSubmittedPrompt(trimmed);
    // G3: incognito - a plain council with NO injected context (no ideal state,
    // no long-term memory), so the panel answers with clear perspective. Active
    // when the global master OR the council-specific flag is on. Explicit
    // attachments the user added stay (deliberate intent).
    const incognito = incognitoActive("council");
    // Ideal State (constitution) preamble - load fresh per convene so edits
    // propagate without app restart. Highest precedence; leads the prompt.
    let idealMd = "";
    if (!incognito) { try { idealMd = await invoke<string>("read_ideal_state", { vault: _vaultPath }); } catch {} }
    const userPreamble = incognito ? "" : buildIdealStatePreamble(idealMd);
    // Self-learning: prepend distilled long-term memory to the council too.
    let memoryMd = "";
    if (!incognito) { try { memoryMd = await invoke<string>("read_memory_md", { vault: _vaultPath, domain: domain ?? null }); } catch {} }
    const memoryPreamble = (!incognito && getPref(PREF.persistentMemory, "1") === "1" && memoryMd.trim())
      ? `--- Long-term memory (${domain ?? "General"}) ---\n${memoryMd.trim().slice(0, Number(getPref(PREF.memoryBudgetChars, "4000")))}\n\n`
      : "";
    const primedPreamble = primedContext.length > 0
      ? primedContext.map((c) => `--- ${c.label} ---\n${c.body.trim()}\n`).join("\n") + "\n"
      : "";
    const skillsPreamble = attachedSkills.length > 0
      ? await buildSkillsPreamble(attachedSkills, allSkills, domain ?? null)
      : "";
    // Usage intelligence: tick the ledger for skills riding this convene
    // (fire-and-forget). Same ledger the chat path writes.
    for (const name of attachedSkills) {
      const sk = allSkills.find((s) => s.name === name);
      if (sk) void invoke("engine_skill_used", { domain: sk.domain, skill: sk.name, source: "council" }).catch(() => {});
    }
    // Continuation: feed prior council turns (questions + chair verdicts)
    // so this convene builds on the conversation so far.
    const histItems = councilTurns.filter(
      (t) => t.role === "user" || t.content.startsWith("### Council verdict"),
    );
    const historyPreamble = histItems.length
      ? "--- Conversation so far ---\n" +
        histItems
          .map((t) =>
            t.role === "user"
              ? `User: ${t.content}`
              : `Council verdict: ${t.content.replace(/^### Council verdict\n\n/, "")}`,
          )
          .join("\n\n")
          // Keep the MOST RECENT history (slice the tail, not the head) so a long
          // conversation still carries the latest context to each panelist.
          .slice(-12000) +
        "\n\n--- New question (continue the conversation) ---\n"
      : "";
    const attachPreamble = pastedFiles.length > 0
      ? `Attached files (read these as context):\n${pastedFiles.map((f) => `- ${f}`).join("\n")}\n\n`
      : "";
    const enrichedPrompt = fwLens.buildPrompt(`${userPreamble}${memoryPreamble}${primedPreamble}${historyPreamble}${skillsPreamble}${attachPreamble}${trimmed}`);
    setPrompt("");
    setAttachedSkills([]);
    // Index pasted images with council context + kick captioning (fire-forget).
    if (pastedFiles.length > 0) {
      const rel = (a: string) => (a.startsWith(_vaultPath) ? a.slice(_vaultPath.length + 1).replace(/^\/+/, "") : a);
      void invoke("attachments_index_append", {
        vault: _vaultPath,
        records: pastedFiles.map((a) => ({
          file: rel(a), ts: Date.now(), domain: domain ?? null,
          session: sessionRef.current, surface: "council", message: trimmed.slice(0, 140),
        })),
      }).catch(() => {});
      void invoke("engine_attachments_caption").catch(() => {});
    }
    setPastedFiles([]);
    for (const s of panelistSlots) {
      try {
        await invoke("chat_send", {
          args: {
            cli: s.cli,
            model: s.model || null,
            prompt: enrichedPrompt,
            session_id: `${sessionRef.current}:slot:${s.key}`,
            web: isBunkerOn() ? false : getDomainToggle(domain, "web", true),
          },
        });
      } catch (e) {
        setReplies((r) => ({
          ...r,
          [s.key]: { cli: s.cli, content: `(error spawning: ${e})`, streaming: false, startedAt: Date.now() },
        }));
      }
    }
  }

  // Cascading menus for the composer toolbar - one for adding a
  // panelist (provider → model), one for picking the chair.
  const [addMenuOpen, setAddMenuOpen] = useState(false);
  const [chairMenuOpen, setChairMenuOpen] = useState(false);
  // Per-provider model search over the full catalog (OpenRouter 300+); empty
  // shows the curated defaults. Shared by the add-panelist + chair pickers.
  const [modelSearch, setModelSearch] = useState<Record<string, string>>({});
  const addMenuRef = useRef<HTMLDivElement>(null);
  const chairMenuRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!addMenuOpen && !chairMenuOpen) return;
    const onClick = (e: MouseEvent) => {
      if (addMenuRef.current && !addMenuRef.current.contains(e.target as Node)) {
        setAddMenuOpen(false);
      }
      if (chairMenuRef.current && !chairMenuRef.current.contains(e.target as Node)) {
        setChairMenuOpen(false);
      }
    };
    window.addEventListener("mousedown", onClick);
    return () => window.removeEventListener("mousedown", onClick);
  }, [addMenuOpen, chairMenuOpen]);

  const [dragOver, setDragOver] = useState(false);
  return (
    <div
      className="flex h-full"
      onDragOver={(e) => {
        const types = Array.from(e.dataTransfer.types);
        if (types.includes("application/x-prevail-domain") || types.includes("text/plain")) {
          e.preventDefault();
          e.dataTransfer.dropEffect = "copy";
          if (!dragOver) setDragOver(true);
        }
      }}
      onDragLeave={(e) => { if (e.currentTarget === e.target) setDragOver(false); }}
      onDrop={async (e) => {
        setDragOver(false);
        let name = e.dataTransfer.getData("application/x-prevail-domain");
        if (!name) {
          const t = e.dataTransfer.getData("text/plain");
          if (t.startsWith("prevail-domain:")) name = t.slice("prevail-domain:".length);
        }
        if (!name || !_vaultPath) return;
        e.preventDefault();
        // Same light/heavy behavior as Chat - default state summary, hold
        // Shift for the full context bundle, Option for the entire folder.
        await attachCouncilDomain(name, e.altKey ? "folder" : e.shiftKey ? "full" : "light");
      }}
    >
      <div className={`relative min-w-0 flex-1 flex-col ${contextOpen && _vaultPath ? "hidden" : "flex"}`}>
      {dragOver && (
        <div className="pointer-events-none absolute inset-0 z-30 flex items-center justify-center bg-accent-soft/80 backdrop-blur-sm">
          <div className="rounded-2xl border-2 border-dashed border-accent bg-surface px-8 py-6 text-center text-sm text-accent shadow-xl">
            ⊕ drop to add as context
            <div className="mt-1 text-[12px] normal-case tracking-normal text-accent/70">state summary · ⇧ full context · ⌥ entire folder</div>
          </div>
        </div>
      )}
      {/* Minimal header - same shape as Chat. Domain + Finder on left. */}
      {!phone && (
      <div className="flex shrink-0 items-center gap-3 border-b border-border-subtle px-6 py-3">
        {domain ? (
          <>
            {(() => {
              const I = domainIcon(domain);
              return I ? <I className="h-5 w-5 text-accent" /> : <span className="text-accent">◆</span>;
            })()}
            <span className="text-[15px] font-semibold">{titleCase(domain)}</span>
            {domainPath && (
              <button
                onClick={onOpenInFinder}
                title="Open in Finder"
                className="inline-flex items-center gap-1 rounded-md border border-border-subtle bg-surface px-1.5 py-0.5 text-[12px] text-text-muted hover:bg-surface-warm hover:text-accent"
              >
                <Folder className="h-3 w-3" />
                Finder
              </button>
            )}
          </>
        ) : (
          <span className="font-mono text-xs text-text-muted">Council</span>
        )}
        <div className="flex-1" />
        <span className="font-mono text-[12px] text-text-muted">
          {panelistSlots.length} on panel
        </span>
        {/* Context swaps this column for the in-flow Context view. */}
        {_vaultPath && <ContextButton onClick={() => setContextOpen(true)} />}
      </div>
      )}
      {phone && _vaultPath && (
        <div className="flex shrink-0 items-center justify-end border-b border-border-subtle px-3 py-1.5">
          <ContextButton onClick={() => setContextOpen(true)} />
        </div>
      )}

      {/* Hero / transcript area */}
      <div className="min-h-0 flex-1 overflow-y-auto">
        {/* Prior council turns - multi-turn continuation history */}
        {councilTurns.length > 0 && (
          <div className="mx-auto max-w-3xl space-y-4 px-6 pt-6">
            {councilTurns.map((t, i) =>
              t.role === "user" ? (
                <div key={i} className="rounded-2xl border border-border-subtle bg-surface px-4 py-3 text-sm text-text-primary">
                  <span className="text-accent">$ </span>
                  {t.content}
                </div>
              ) : t.content.startsWith("### Council verdict") ? (
                <div key={i} className="rounded-2xl border border-accent-border bg-accent-soft px-4 py-3">
                  <div className="mb-1.5 text-[12px] text-accent">Council verdict</div>
                  <div className="text-sm leading-relaxed text-text-secondary">
                    <Markdown source={t.content.replace(/^### Council verdict\n\n/, "")} />
                  </div>
                </div>
              ) : null,
            )}
            {phase !== "idle" && (
              <div className="pb-1 pt-1 text-center text-[12px] text-text-muted">
                continuing…
              </div>
            )}
          </div>
        )}
        {councilTurns.length === 0 && phase === "idle" && (
          <div className="flex h-full flex-col items-center justify-start px-6 py-6">
            <span className="opacity-90" aria-hidden="true"><GlyphStudioLogo size={40} animated={false} /></span>
            <h2 className={`${DETAIL_TITLE} mt-3`}>
              <BrandMark /> Council
            </h2>
            <p className="mt-1.5 max-w-md text-center text-[13px] text-text-muted">
              {panelistSlots.length === 0 ? (
                <>Add panelists below, then ask the council.</>
              ) : (
                <>
                  {panelistSlots.length} model{panelistSlots.length === 1 ? "" : "s"} on panel · chair:{" "}
                  <span className="text-accent">
                    {chairSlotObj ? `${chairSlotObj.cliLabel.toLowerCase()} · ${chairSlotObj.modelLabel}` : "-"}
                  </span>
                  {" "}· best for <span className="text-accent">Why</span> / <span className="text-accent">should-I</span> decisions, not quick lookups.
                </>
              )}
            </p>

            {/* Compact starter rows - one line each (glyph · label · the short
                question). Clicking loads the full prompt into the composer, so
                the body text doesn't need to sit here as a wall. */}
            <ul className="mt-5 flex w-full max-w-2xl flex-col gap-1.5">
              {buildCouncilQuickActions(domain).map((q) => (
                <li key={q.label}>
                  <button
                    onClick={() => setPrompt(q.prompt)}
                    title={q.prompt}
                    className="flex w-full items-center gap-2.5 rounded-lg border border-border bg-surface px-4 py-2.5 text-left transition-colors hover:border-accent-border hover:bg-surface-warm"
                  >
                    <span className="shrink-0 text-[12px] text-accent">{q.glyph} {q.label}</span>
                    <span className="min-w-0 flex-1 truncate text-sm text-text-secondary">{q.blurb}</span>
                    <ArrowRight className="h-3.5 w-3.5 shrink-0 text-text-muted" />
                  </button>
                </li>
              ))}
            </ul>
          </div>
        )}

        {phase !== "idle" && (
          <div className="px-6 py-6" ref={liveConveneRef}>
            <div className="mb-6 rounded-lg border border-border bg-surface px-4 py-3 text-sm">
              <span className="text-accent">$</span> {submittedPrompt || prompt}
            </div>

            {/* Quorum control - once at least one panelist has answered but the
                council isn't fully back, let the user synthesize from whoever
                responded instead of waiting on a stuck panelist. */}
            {phase === "panelists" && respondedCount >= 1 && !allPanelistsDone && (
              <div className="mb-4 flex items-center justify-between gap-3 rounded-xl border border-accent-border bg-accent-soft/50 px-4 py-2.5">
                <span className="text-sm text-text-secondary">
                  <span className="font-semibold text-accent">{respondedCount} of {panelistSlots.length}</span> panelists have answered.
                  {panelistSlots.length >= 3 && respondedCount >= panelistSlots.length - 1
                    ? " Auto-summarizing soon if the rest stay quiet."
                    : " Don't wait on a slow one."}
                </span>
                <button
                  onClick={synthesizeNow}
                  className="inline-flex shrink-0 items-center gap-1.5 rounded-lg bg-accent px-3 py-1.5 text-sm font-semibold text-background shadow-sm transition-colors hover:bg-accent-hover"
                >
                  <Crown className="h-3.5 w-3.5" /> Summarize now
                </button>
              </div>
            )}

            <div className="space-y-4">
              {panelistSlots.map((s) => {
                const r = replies[s.key];
                const cardAccent = vendorAccent(s.cli);
                const cardErrored = !!r && !r.streaming && !r.content;
                const cardError = cardErrored ? extractCliError(r.stderr) : null;
                // Synthesis ran without this panelist → it was skipped, not pending.
                const skipped = !!synthesisSlots && !synthesisSlots.some((x) => x.key === s.key) && (!r || (!r.content && r.streaming));
                const showThinking = getPref(PREF.showThinking, "1") === "1";
                const parts = r?.content ? splitThinking(r.content) : { thinking: "", answer: "" };
                return (
                  <details
                    key={s.key}
                    open={!skipped}
                    className="group overflow-hidden rounded-lg border border-border bg-surface"
                    style={{ borderLeftColor: cardAccent.accent, borderLeftWidth: 3 }}
                  >
                    <summary className="flex cursor-pointer list-none items-center justify-between gap-2 border-b border-border-subtle bg-surface-warm px-4 py-2 text-xs [&::-webkit-details-marker]:hidden">
                      <span className="flex items-center gap-2">
                        <ChevronRight className="h-3.5 w-3.5 text-text-muted transition-transform group-open:rotate-90" />
                        <ProviderMark vendor={s.cli} size={18} />
                        <span style={{ color: cardAccent.accent }}>{s.cliLabel.toLowerCase()}</span>
                        <span className="text-text-muted">· {s.modelLabel}</span>
                      </span>
                      <span className="text-text-muted">
                        {skipped ? <span className="text-text-muted">Skipped</span> : (
                          <>
                            {!r && "queued"}
                            {r?.streaming && <span className="pulse-soft text-accent">Streaming</span>}
                            {r && !r.streaming && !cardErrored && <span className="text-ok">✓ done</span>}
                            {cardErrored && <span className="text-warn">⚠ no output</span>}
                          </>
                        )}
                      </span>
                    </summary>
                    <div className="px-5 py-4">
                      {r?.content ? (
                        <>
                          {showThinking && parts.thinking && <ThinkingDisclosure text={parts.thinking} open={!parts.answer} />}
                          {parts.answer ? <Markdown source={parts.answer} /> : (!parts.thinking && r.streaming ? <ThinkingDots /> : null)}
                          {r.streaming && parts.answer && <span className="cursor-blink text-accent">▌</span>}
                        </>
                      ) : skipped ? (
                        <p className="text-sm text-text-muted">Didn't respond in time. Left out of the verdict.</p>
                      ) : cardErrored ? (
                        cardError ? (
                          <pre className="whitespace-pre-wrap rounded-md bg-warn/10 px-2 py-1.5 text-[12px] leading-snug text-warn">{cardError}</pre>
                        ) : (
                          <p className="text-sm text-text-secondary">{s.cliLabel} produced no output (model rejected the prompt, hit a quota, or errored).</p>
                        )
                      ) : (
                        <ThinkingDots />
                      )}
                      {/* A panelist's held connector write: answer it here. */}
                      {extractActIds(r?.content, r?.stderr).map((id) => (
                        <div key={id} className="mt-3">
                          <ActApprovalCard vaultPath={_vaultPath} actId={id} onFollowUp={queueCouncilFollowUp} />
                        </div>
                      ))}
                    </div>
                  </details>
                );
              })}
            </div>

            {(phase === "synthesizing" || phase === "done") && (() => {
              const vparts = splitThinking(verdict);
              const showThinking = getPref(PREF.showThinking, "1") === "1";
              return (
              <details open className="group mt-8 overflow-hidden rounded-lg border border-accent-border bg-accent-soft">
                <summary className="flex cursor-pointer list-none items-center gap-2 px-6 py-4 text-xs text-accent [&::-webkit-details-marker]:hidden">
                  <ChevronRight className="h-3.5 w-3.5 transition-transform group-open:rotate-90" />
                  <Crown className="h-3.5 w-3.5" />
                  <span>
                    verdict · synthesized by{" "}
                    {chairSlotObj ? `${chairSlotObj.cliLabel.toLowerCase()} · ${chairSlotObj.modelLabel}` : "-"}
                  </span>
                  {phase === "synthesizing" && <span className="pulse-soft">Streaming</span>}
                </summary>
              <div className="px-6 pb-6">
                <div>
                  {verdict ? (
                    <>
                      {showThinking && vparts.thinking && <ThinkingDisclosure text={vparts.thinking} open={!vparts.answer} />}
                      {vparts.answer ? <Markdown source={vparts.answer} /> : (!vparts.thinking ? <ThinkingDots /> : null)}
                    </>
                  ) : (
                    <ThinkingDots />
                  )}
                  {phase === "synthesizing" && vparts.answer && <span className="cursor-blink text-accent">▌</span>}
                </div>
                {/* Verdict feedback - thumbs up/down trains which model + lens +
                    framework produce verdicts the user trusts. (v0.4.1 I5) */}
                {phase === "done" && verdict && verdictDecisionId && (
                  <div className="mt-4 flex items-center gap-2 border-t border-accent-border/40 pt-3 text-xs text-text-muted">
                    <span>Was this verdict useful?</span>
                    <button
                      title="Good verdict"
                      onClick={() => {
                        const next = verdictRating === "up" ? null : "up";
                        setVerdictRating(next);
                        invoke("decision_feedback", { vault: _vaultPath, domain: domain ?? null, id: verdictDecisionId, rating: next ?? "clear", note: null }).then(() => window.dispatchEvent(new CustomEvent("prevail:context-changed"))).catch((e) => console.error("decision_feedback", e));
                      }}
                      className={`inline-flex items-center gap-1 rounded-md border px-2 py-1 transition-colors ${verdictRating === "up" ? "border-accent bg-accent-soft text-accent" : "border-border hover:bg-surface-strong"}`}
                    >
                      <ThumbsUp className="h-3.5 w-3.5" />
                    </button>
                    <button
                      title="Not useful"
                      onClick={() => {
                        const next = verdictRating === "down" ? null : "down";
                        setVerdictRating(next);
                        invoke("decision_feedback", { vault: _vaultPath, domain: domain ?? null, id: verdictDecisionId, rating: next ?? "clear", note: null }).then(() => window.dispatchEvent(new CustomEvent("prevail:context-changed"))).catch((e) => console.error("decision_feedback", e));
                      }}
                      className={`inline-flex items-center gap-1 rounded-md border px-2 py-1 transition-colors ${verdictRating === "down" ? "border-red-400 bg-red-500/10 text-red-500" : "border-border hover:bg-surface-strong"}`}
                    >
                      <ThumbsDown className="h-3.5 w-3.5" />
                    </button>
                    {verdictRating && <span className="text-text-muted">· saved</span>}
                  </div>
                )}
              </div>
              </details>
              );
            })()}
          </div>
        )}
      </div>

      {/* Codex-style composer - textarea + panelist pills + chair pill */}
      <div className="shrink-0 px-6 pb-6 pt-2">
        {/* Incognito affordance (parity with chat): a ghost badge over the top-left
            edge + an accent glow on the composer when incognito is on. Toggled from
            the Modes menu above. */}
        <div className="relative">
        {(incognito || globalIncognito) && (
          <span className="absolute -top-2 left-3 z-10 inline-flex items-center gap-1 rounded-full border border-accent-border bg-surface px-2 py-0.5 text-[12px] font-semibold text-accent shadow-sm">
            <Ghost className="h-3 w-3" /> Incognito
          </span>
        )}
        {/* Slash-command popover for skills (parity with Chat). Shown whenever a
            `/` is typed - including an empty state - so it never looks broken. */}
        {slashMatch && (
          <div className="absolute bottom-full left-0 z-40 mb-1 w-80 max-w-[calc(100vw-1.5rem)] max-w-[calc(100vw-1.5rem)] overflow-hidden rounded-lg border border-border bg-surface shadow-xl">
            <div className="border-b border-border-subtle bg-surface-warm px-3 py-1.5 text-[12px] text-text-muted">Skills · enter to insert</div>
            {slashCandidates.length === 0 ? (
              <div className="px-3 py-2 text-[12px] text-text-muted">No skills in this vault yet. Add one in a domain's <span className="font-mono">_skills/</span> folder.</div>
            ) : slashCandidates.map((s, i) => (
              <button key={s.path} onMouseDown={(e) => { e.preventDefault(); applySlashCompletion(s.name); }}
                className={`flex w-full items-start gap-2 px-3 py-1.5 text-left ${i === slashIdx ? "bg-accent-soft" : "hover:bg-surface-warm"}`}>
                <Sparkles className="mt-0.5 h-3.5 w-3.5 shrink-0 text-text-muted" />
                <div className="min-w-0">
                  <div className={`font-mono text-xs ${i === slashIdx ? "text-accent" : "text-text-primary"}`}>/{s.name}</div>
                  {s.description && <div className="line-clamp-1 text-[12px] text-text-muted">{s.description}</div>}
                </div>
              </button>
            ))}
          </div>
        )}
        {/* Context-mention popover for `$<domain|app>` (parity with Chat) */}
        {dollarMatch && dollarCandidates.length > 0 && (
          <div className="absolute bottom-full left-0 z-40 mb-1 w-80 max-w-[calc(100vw-1.5rem)] max-w-[calc(100vw-1.5rem)] overflow-hidden rounded-lg border border-border bg-surface shadow-xl">
            <div className="border-b border-border-subtle bg-surface-warm px-3 py-1.5 text-[12px] text-text-muted">Add context · enter to attach</div>
            {dollarCandidates.map((c, i) => (
              <button key={`${c.kind}:${c.id}`} onMouseDown={(e) => { e.preventDefault(); applyDollarCompletion(c); }}
                className={`flex w-full items-start gap-2 px-3 py-1.5 text-left ${i === dollarIdx ? "bg-accent-soft" : "hover:bg-surface-warm"}`}>
                {c.kind === "domain"
                  ? (() => { const I = domainIcon(c.id); return I ? <I className="mt-0.5 h-3.5 w-3.5 shrink-0 text-text-muted" /> : <Layers className="mt-0.5 h-3.5 w-3.5 shrink-0 text-text-muted" />; })()
                  : <AppRowLogo app={{ id: c.id, title: c.label }} size={18} fallback="letter" />}
                <div className="min-w-0">
                  <div className={`font-mono text-xs ${i === dollarIdx ? "text-accent" : "text-text-primary"}`}>${c.id}</div>
                  <div className="line-clamp-1 text-[12px] text-text-muted">{c.kind === "domain" ? "domain · attaches state.md" : `app · ${c.sub ?? "context card"}`}</div>
                </div>
              </button>
            ))}
          </div>
        )}
        <div className={`rounded-2xl border bg-surface p-3 shadow-sm transition-shadow ${(incognito || globalIncognito) ? "border-dashed border-accent-border" : "border-border"}`}>
          {/* One row (parity with chat): context pills on the left, the
              context-window meter on the right - so they share a line. */}
          <div className="mb-2 flex items-center justify-between gap-2 px-2">
            <div className="flex min-w-0 flex-1 flex-wrap items-center gap-1.5">
              {primedContext.map((c, i) => (
                <span
                  key={c.label}
                  className="inline-flex items-center gap-1 rounded-full border border-accent-border bg-accent-soft py-0.5 pl-2 pr-1 font-mono text-[12px] text-accent"
                  title={c.body.slice(0, 200)}
                >
                  {ctxChipIcon(c.label)}
                  {c.label}
                  <button
                    onClick={() => setPrimedContext((cur) => cur.filter((_, j) => j !== i))}
                    className="ml-0.5 flex h-3.5 w-3.5 items-center justify-center rounded-full text-text-muted hover:bg-surface-warm hover:text-err"
                    title="Remove from context"
                  >×</button>
                </span>
              ))}
            </div>
            <div className="flex shrink-0 items-center gap-2">
              <ContextMeter
                conversationTokens={councilCtx.conversationTokens}
                attachedTokens={councilCtx.attachedTokens}
                draftTokens={estimateTokens(prompt)}
                windowTokens={councilCtx.windowTokens}
                onReset={resetCouncil}
                autoCompact={getPref(PREF.autoCompact, "1") === "1"}
                onToggleAutoCompact={(v) => setPref(PREF.autoCompact, v ? "1" : "0")}
              />
            </div>
          </div>
          {/* Attached skills */}
          {attachedSkills.length > 0 && (
            <div className="mb-2 flex flex-wrap items-center gap-1.5 px-2">
              {attachedSkills.map((name) => (
                <span
                  key={name}
                  className="inline-flex items-center gap-1 rounded-md border border-accent-border bg-accent-soft py-0.5 pl-1.5 pr-1 font-mono text-[12px] text-accent"
                >
                  <Sparkles className="h-3 w-3" />
                  /{name}
                  <button
                    onClick={() => removeAttachedSkill(name)}
                    className="ml-0.5 flex h-3.5 w-3.5 items-center justify-center rounded-full text-text-muted hover:bg-surface-warm hover:text-err"
                    title={`Remove /${name}`}
                  >×</button>
                </span>
              ))}
            </div>
          )}
          {/* Pasted images attached to the next convene - visible, removable. */}
          {pastedFiles.length > 0 && (
            <div className="mb-2 flex flex-wrap items-center gap-1.5 px-2">
              {pastedFiles.map((p) => (
                <span key={p} title={p} className="inline-flex items-center gap-1 rounded-md border border-accent-border bg-accent-soft py-0.5 pl-1.5 pr-1 font-mono text-[12px] text-accent">
                  {p.split("/").pop()}
                  <button
                    onClick={() => setPastedFiles((cur) => cur.filter((x) => x !== p))}
                    className="ml-0.5 flex h-3.5 w-3.5 items-center justify-center rounded-full text-text-muted hover:bg-surface-warm hover:text-err"
                    title="Remove attachment"
                  >×</button>
                </span>
              ))}
            </div>
          )}
          <textarea
            ref={taRef}
            value={prompt}
            onPaste={(e) => {
              void savePastedImages(e, _vaultPath).then(({ paths }) => {
                if (paths.length) setPastedFiles((cur) => [...cur, ...paths]);
              });
            }}
            onChange={(e) => { setPrompt(e.target.value); setCaretPos(e.target.selectionStart ?? e.target.value.length); }}
            onSelect={(e) => syncCaret(e.currentTarget)}
            onKeyUp={(e) => syncCaret(e.currentTarget)}
            onClick={(e) => syncCaret(e.currentTarget)}
            onDragOver={(e) => {
              const types = Array.from(e.dataTransfer.types);
              if (types.includes("application/x-prevail-domain") || types.includes("text/plain")) {
                // Suppress native text-insertion so the dropped domain becomes
                // a context chip instead of inline text in the prompt.
                const t = e.dataTransfer.getData("text/plain");
                if (t && !t.startsWith("prevail-domain:") && !types.includes("application/x-prevail-domain")) return;
                e.preventDefault();
                e.dataTransfer.dropEffect = "copy";
              }
            }}
            onDrop={(e) => {
              let name = e.dataTransfer.getData("application/x-prevail-domain");
              if (!name) {
                const t = e.dataTransfer.getData("text/plain");
                if (t && t.startsWith("prevail-domain:")) name = t.slice("prevail-domain:".length);
              }
              if (!name) return;
              // Handle here and stop bubbling so the panel drop zone doesn't
              // attach it a second time.
              e.preventDefault();
              e.stopPropagation();
              void attachCouncilDomain(name, e.altKey ? "folder" : e.shiftKey ? "full" : "light");
            }}
            onKeyDown={(e) => {
              // Route nav keys to the `/` skills popover when it's open.
              if (slashMatch && slashCandidates.length > 0) {
                if (e.key === "ArrowDown") { e.preventDefault(); setSlashIdx((i) => (i + 1) % slashCandidates.length); return; }
                if (e.key === "ArrowUp") { e.preventDefault(); setSlashIdx((i) => (i - 1 + slashCandidates.length) % slashCandidates.length); return; }
                if (e.key === "Enter" || e.key === "Tab") { e.preventDefault(); applySlashCompletion(slashCandidates[slashIdx].name); return; }
                if (e.key === "Escape") { e.preventDefault(); setPrompt((cur) => cur + " "); return; }
              }
              // Route nav keys to the `$` context-mention popover when it's open.
              if (dollarMatch && dollarCandidates.length > 0) {
                if (e.key === "ArrowDown") { e.preventDefault(); setDollarIdx((i) => (i + 1) % dollarCandidates.length); return; }
                if (e.key === "ArrowUp") { e.preventDefault(); setDollarIdx((i) => (i - 1 + dollarCandidates.length) % dollarCandidates.length); return; }
                if (e.key === "Enter" || e.key === "Tab") { e.preventDefault(); applyDollarCompletion(dollarCandidates[dollarIdx]); return; }
                if (e.key === "Escape") { e.preventDefault(); setPrompt((cur) => cur + " "); return; }
              }
              const wantCmd = getPref(PREF.sendKey, "enter") === "cmd-enter";
              const cmd = e.metaKey || e.ctrlKey;
              const fires = e.key === "Enter" && !e.shiftKey && !e.altKey && (wantCmd ? cmd : !cmd);
              if (fires) {
                e.preventDefault();
                convene();
              }
            }}
            placeholder={phone ? "Ask the council" : "ask the council · enter to convene · / skills · $ context · shift+enter for newline"}
            rows={2}
            disabled={phase === "panelists" || phase === "synthesizing"}
            className="w-full resize-none bg-transparent px-2 py-1.5 text-sm text-text-primary placeholder:text-text-muted focus:outline-none disabled:opacity-50"
          />

          {/* Panelist pills row - each with a verification badge */}
          <div className="mt-2 flex flex-wrap items-center gap-1.5">
            {panelistSlots.map((s) => {
              const st = verifyStatus[s.key] ?? "unknown";
              const tip = verifyError[s.key]
                ? `Failed: ${verifyError[s.key]}\n\nClick the dot to re-verify.`
                : st === "ok"
                ? "Verified: model is ready"
                : st === "verifying"
                ? "Verifying…"
                : "Click the dot to verify this model";
              return (
                <span
                  key={s.key}
                  title={s.blurb}
                  className={`inline-flex items-center gap-1 rounded-full border py-0.5 pl-0.5 pr-1.5 ${
                    st === "failed" ? "border-err bg-err/10" : "border-border bg-background"
                  }`}
                >
                  <ProviderMark vendor={s.cli} size={16} />
                  <span className="font-mono text-[12px] text-text-primary">{s.modelLabel}</span>
                  <button
                    onClick={() => verifySlot(s)}
                    title={tip}
                    className={`ml-0.5 flex h-3.5 w-3.5 items-center justify-center rounded-full text-[10px] leading-none ${
                      st === "ok"
                        ? "bg-ok text-background"
                        : st === "failed"
                        ? "bg-err text-background"
                        : st === "verifying"
                        ? "bg-warn text-background"
                        : "border border-border-strong text-text-muted hover:border-accent-border hover:text-accent"
                    }`}
                  >
                    {st === "ok" ? "✓" : st === "failed" ? "✗" : st === "verifying" ? "…" : "?"}
                  </button>
                  <button
                    onClick={() => toggleSlot(s.key)}
                    className="ml-0.5 flex h-3.5 w-3.5 items-center justify-center rounded-full text-text-muted hover:bg-surface-warm hover:text-err"
                    title="Remove from panel"
                  >
                    ×
                  </button>
                </span>
              );
            })}

            {/* + add panelist */}
            <div className="relative" ref={addMenuRef}>
              <button
                onClick={() => setAddMenuOpen((v) => !v)}
                className="inline-flex items-center gap-1 rounded-full border border-dashed border-border bg-background px-2 py-0.5 text-[12px] text-text-muted hover:border-accent-border hover:text-accent"
              >
                <Plus className="h-3 w-3" /> add
              </button>
              {addMenuOpen && (
                <div className="absolute bottom-full left-0 z-40 mb-1 w-72 max-w-[calc(100vw-1.5rem)] overflow-hidden rounded-lg border border-border bg-surface shadow-xl">
                  <div className="border-b border-border-subtle px-3 py-1.5 text-[12px] text-text-muted">
                    Add panelist
                  </div>
                  <div className="max-h-80 overflow-y-auto">
                    {clis.filter((c) => !isBunkerOn() || isLocalCli(c.id)).map((c) => {
                      const cliModels = modelsFor(c.id);
                      if (cliModels.length === 0) return null;
                      const curated = curatedFor(c.id);
                      const searchable = cliModels.length > curated.length;
                      const q = (modelSearch[c.id] ?? "").trim().toLowerCase();
                      const shown = q
                        ? cliModels.filter((m) => `${m.id} ${m.label ?? ""}`.toLowerCase().includes(q)).slice(0, 50)
                        : (searchable ? curated : cliModels);
                      return (
                        <div key={c.id} className={c.available ? "" : "opacity-40"}>
                          <div className="flex items-center gap-2 bg-surface-warm/60 px-3 py-1">
                            <ProviderMark vendor={c.id} size={14} />
                            <span className="font-mono text-[12px] text-text-muted">
                              {c.label}
                            </span>
                            {!c.available && (
                              <span className="ml-auto text-[12px] text-text-muted">Not installed</span>
                            )}
                          </div>
                          {searchable && c.available && (
                            <input
                              value={modelSearch[c.id] ?? ""}
                              onChange={(e) => setModelSearch((s) => ({ ...s, [c.id]: e.target.value }))}
                              placeholder={`Search all ${cliModels.length} ${c.label} models…`}
                              className="mx-3 my-1 w-[calc(100%-1.5rem)] rounded-md border border-border bg-background px-2 py-1 font-mono text-[12px] focus:border-accent-border focus:outline-none"
                            />
                          )}
                          {shown.length === 0 && <div className="px-4 py-1.5 font-mono text-[12px] text-text-muted">No models match "{q}".</div>}
                          {shown.map((m) => {
                            const slotKey = `${c.id}::${m.id}`;
                            const onPanel = selectedSlots.has(slotKey);
                            return (
                              <button
                                key={m.id}
                                onClick={() => {
                                  if (!c.available) return;
                                  toggleSlot(slotKey);
                                }}
                                disabled={!c.available}
                                className={`flex w-full items-center justify-between px-4 py-1.5 text-left transition-colors ${
                                  onPanel ? "bg-accent-soft" : "hover:bg-surface-warm"
                                }`}
                              >
                                <div className="min-w-0">
                                  <div className={`font-mono text-xs ${onPanel ? "text-accent" : "text-text-primary"}`}>
                                    {m.label}
                                  </div>
                                  {m.blurb && <div className="text-[12px] text-text-muted">{m.blurb}</div>}
                                </div>
                                {onPanel && <Check className="h-3.5 w-3.5 shrink-0 text-accent" strokeWidth={3} />}
                              </button>
                            );
                          })}
                        </div>
                      );
                    })}
                  </div>
                </div>
              )}
            </div>
          </div>

          {/* Single inline toolbar: toggles · spacer · chair · chat · send */}
          <div className="mt-2 flex flex-wrap items-center gap-1.5 border-t border-border-subtle pt-2">
            <DomainStatusBar domain={domain} fwLens={fwLens} surface="council" />
            <div className="flex-1" />

            {/* Which council: the Default, or any named one (Settings > Council). */}
            {councils.length > 0 && (
              <select aria-label="Council" data-testid="council-picker" value={activeCouncil?.id ?? ""}
                onChange={(e) => applyCouncil(e.target.value)}
                className="h-7 max-w-[12rem] truncate rounded-full border border-border bg-background px-2 text-[12px] text-text-secondary focus:border-accent-border focus:outline-none">
                {councils.map((c) => <option key={c.id} value={c.id}>{c.name}{c.id === defaultCouncilId ? " (default)" : ""}</option>)}
              </select>
            )}

            {/* Chair pill */}
            <div className="relative" ref={chairMenuRef}>
              <button
                onClick={() => setChairMenuOpen((v) => !v)}
                className="flex items-center gap-1.5 rounded-full border border-border bg-background px-2 py-1"
                title="Chair (writes the verdict)"
              >
                <Crown className="h-3 w-3 text-accent" />
                {chairSlotObj && <ProviderMark vendor={chairSlotObj.cli} size={16} />}
                <span className="font-mono text-[12px] text-text-primary">
                  {chairSlotObj ? chairSlotObj.modelLabel : "no chair"}
                </span>
                <svg className="h-3 w-3 text-text-muted" viewBox="0 0 12 12" fill="none" stroke="currentColor" strokeWidth={1.5}>
                  <path d="M3 4.5L6 7.5L9 4.5" strokeLinecap="round" strokeLinejoin="round" />
                </svg>
              </button>
              {chairMenuOpen && (
                <div className="absolute bottom-full right-0 z-40 mb-1 w-72 max-w-[calc(100vw-1.5rem)] overflow-hidden rounded-lg border border-border bg-surface shadow-xl">
                  <div className="border-b border-border-subtle px-3 py-1.5 text-[12px] text-text-muted">
                    Chair
                  </div>
                  <div className="max-h-80 overflow-y-auto">
                    {clis.filter((c) => !isBunkerOn() || isLocalCli(c.id)).map((c) => {
                      const cliModels = modelsFor(c.id);
                      if (cliModels.length === 0) return null;
                      const curated = curatedFor(c.id);
                      const searchable = cliModels.length > curated.length;
                      const q = (modelSearch[`chair:${c.id}`] ?? "").trim().toLowerCase();
                      const shown = q
                        ? cliModels.filter((m) => `${m.id} ${m.label ?? ""}`.toLowerCase().includes(q)).slice(0, 50)
                        : (searchable ? curated : cliModels);
                      return (
                        <div key={c.id} className={c.available ? "" : "opacity-40"}>
                          <div className="flex items-center gap-2 bg-surface-warm/60 px-3 py-1">
                            <ProviderMark vendor={c.id} size={14} />
                            <span className="font-mono text-[12px] text-text-muted">
                              {c.label}
                            </span>
                          </div>
                          {searchable && c.available && (
                            <input
                              value={modelSearch[`chair:${c.id}`] ?? ""}
                              onChange={(e) => setModelSearch((s) => ({ ...s, [`chair:${c.id}`]: e.target.value }))}
                              placeholder={`Search all ${cliModels.length} ${c.label} models…`}
                              className="mx-3 my-1 w-[calc(100%-1.5rem)] rounded-md border border-border bg-background px-2 py-1 font-mono text-[12px] focus:border-accent-border focus:outline-none"
                            />
                          )}
                          {shown.length === 0 && <div className="px-4 py-1.5 font-mono text-[12px] text-text-muted">No models match "{q}".</div>}
                          {shown.map((m) => {
                            const slotKey = `${c.id}::${m.id}`;
                            const isChair = chairSlot === slotKey;
                            return (
                              <button
                                key={m.id}
                                onClick={() => {
                                  if (!c.available) return;
                                  setChairSlot(slotKey);
                                  setChairMenuOpen(false);
                                }}
                                disabled={!c.available}
                                className={`flex w-full items-center justify-between px-4 py-1.5 text-left transition-colors ${
                                  isChair ? "bg-accent-soft" : "hover:bg-surface-warm"
                                }`}
                              >
                                <span className={`font-mono text-xs ${isChair ? "text-accent" : "text-text-primary"}`}>
                                  {m.label}
                                </span>
                                {isChair && <Check className="h-3.5 w-3.5 text-accent" strokeWidth={3} />}
                              </button>
                            );
                          })}
                        </div>
                      );
                    })}
                  </div>
                </div>
              )}
            </div>

            <button
              onClick={onSwitchToChat}
              title="Back to single-model conversation"
              className="inline-flex items-center gap-1.5 rounded-full border border-border bg-background px-3 py-1.5 font-mono text-xs text-text-secondary hover:border-accent-border hover:bg-accent-soft hover:text-accent"
            >
              <MessageSquare className="h-3.5 w-3.5" />
              Chat
            </button>
            {(phase === "panelists" || phase === "synthesizing") ? (
              <button
                onClick={async () => {
                  try {
                    await invoke("abort_sessions", { prefix: sessionRef.current });
                  } catch (e) { console.error("abort", e); }
                  // Mark EVERY selected slot as aborted - including
                  // ones that never reached the streaming state
                  // ("queued" / "thinking" cards). Bug fix: previously
                  // we only iterated existing reply keys, which left
                  // never-started panelists hanging in the UI.
                  setReplies((r) => {
                    const next = { ...r };
                    for (const s of panelistSlots) {
                      const existing = next[s.key];
                      if (!existing) {
                        next[s.key] = {
                          cli: s.cli,
                          content: "(aborted before starting)",
                          streaming: false,
                          startedAt: Date.now(),
                        };
                      } else if (existing.streaming) {
                        next[s.key] = {
                          ...existing,
                          streaming: false,
                          content: existing.content
                            ? existing.content + "\n\n(aborted)"
                            : "(aborted)",
                        };
                      }
                    }
                    return next;
                  });
                  setPhase("done");
                  setVerdict((v) => v ? v + "\n\n(aborted)" : "(aborted by user)");
                }}
                title="Stop the council mid-run"
                className="inline-flex items-center gap-1.5 rounded-full border border-err bg-err/10 px-4 py-1.5 text-sm font-semibold text-err hover:bg-err hover:text-background"
              >
                ■ Stop
              </button>
            ) : (
              <button
                onClick={convene}
                disabled={!prompt.trim() || panelistSlots.length === 0}
                title="Convene the council (enter)"
                className="inline-flex items-center gap-1.5 rounded-full bg-accent px-4 py-1.5 text-sm font-semibold text-background shadow-sm transition-all hover:bg-accent-hover disabled:bg-surface-strong disabled:text-text-muted"
              >
                <Scale className="h-3.5 w-3.5" />
                Convene
              </button>
            )}
          </div>
        </div>
        </div>
      </div>
      </div>
      {contextOpen && _vaultPath ? (
        <DomainContextView
          domain={domain ?? ""}
          phone={phone}
          vaultPath={_vaultPath}
          domainPath={domainPath ?? ""}
          onClose={() => setContextOpen(false)}
          onInjectContext={(body, label) => injectContext(body, label)}
          onInsertSkill={(name) => { insertSkillSlash(name); setContextOpen(false); }}
          preferredSet={preferredSkillsSet}
          onTogglePreferred={togglePreferredSkill}
        />
      ) : null}
      <ContextCanvas />
    </div>
  );
}
