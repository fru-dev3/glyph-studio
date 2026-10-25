// Domain-scoped panels extracted from App.tsx: the in-flow Context view,
// the agent picker rail, the pref-picker column, and the domain prefs panel.
import { createContext, useCallback, useContext, useEffect, useState } from "react";
import { AppActivity } from "./appactivity";
import { AcrossYourLife, useUpdates, yoursIn } from "./linking";
import { loadEntities, requestEntity, useEntityStore } from "./entitystore";
import { KindBadge } from "./entitydetail";
import { ArrowLeft, ArrowRight, Box, Layers, Check, ChevronDown, ChevronRight, Code, Compass, Cpu, Eye, Folder, Globe, Loader2, Lock, Maximize2, MessageSquare, Pencil, Pin, RefreshCw, Share2, SlidersHorizontal, Sparkles, Terminal, X, type LucideIcon } from "lucide-react";
import { distillCfgFromPrefs } from "./daemoncfg";
import { invoke } from "./bridge";
import { invokeCached, peekInvoke } from "./query";
import { FRAMEWORKS, LENSES } from "./constants";
import { curatedFor, modelsFor } from "./helpers2";
import { formatFreshness, titleCase } from "./format";
import { isLocalCli } from "./helpers";
import { PREF, cheapModel, getPref, isBunkerOn, lsGet, lsSet } from "./storage";
import { REVEAL, Toggle } from "./ui";
import { ResizeHandle } from "./widgets";
import { SideSpine } from "./sidespine";
import { DrawerImportsSection } from "./panels";
import { Markdown } from "./Markdown";
import { domainIcon } from "./icons";
import { pickSkillColor } from "./sectionutil";
import { ProviderMark } from "./marks";
import type { CliInfo, DomainContextBundle, DomainManifest, SkillEntry } from "./types";
import { DETAIL_TITLE } from "./typescale";
import { SourcesInUse } from "./knowledgesources";

export const SECTION_LABEL =
  "text-[13px] font-semibold text-text-secondary";

// agent stays expanded. Clicking sets the chat panel's primary CLI.
// Full-canvas preferences panel for the currently-selected domain.
// Replaces the popover. Every control writes to localStorage on
// click; no save button - picks are immediate. Pickers use brand
// icons for CLIs, prose labels for everything else.

// A standalone file-viewer pane that lives on the LEFT of the chat (not an overlay
// of the Context view). Opened by dispatching `prevail:open-canvas` with
// { title, body }; the App mounts it and owns its width + resize. Same raw /
// formatted-markdown toggle as the inline preview.
export function FileCanvas({ title, source, width, onClose }: { title: string; source: string; width: number; onClose: () => void }) {
  const [raw, setRaw] = useState(false);
  return (
    <aside style={{ width }} className="flex h-full shrink-0 flex-col border-r border-border-subtle bg-background">
      <div className="flex shrink-0 items-center gap-2 border-b border-border-subtle px-4 py-3">
        <div className="min-w-0 flex-1">
          <div className="truncate text-[15px] font-semibold text-text-primary" title={title}>{title}</div>
        </div>
        <button onClick={() => setRaw((v) => !v)} title={raw ? "Show formatted" : "Show raw text"}
          className="inline-flex items-center gap-1.5 text-[12px] text-text-muted hover:text-accent">
          {raw ? <><Eye className="h-3 w-3" /> Formatted</> : <><Code className="h-3 w-3" /> Raw text</>}
        </button>
        <button onClick={onClose} title="Close" className="flex h-7 w-7 items-center justify-center rounded text-text-muted hover:bg-surface-warm hover:text-text-primary"><X className="h-4 w-4" /></button>
      </div>
      <div className="min-h-0 flex-1 overflow-y-auto px-5 py-4">
        {raw
          ? <pre className="whitespace-pre-wrap break-words text-xs leading-relaxed text-text-secondary">{source}</pre>
          : <div className="prose-sm max-w-none text-sm leading-relaxed text-text-primary"><Markdown source={source} /></div>}
      </div>
    </aside>
  );
}

// Self-contained canvas that docks beside the chat or Context view
// (rendered as its sibling in chat/council). Listens for prevail:open-canvas and
// shows the file side-by-side with Context; resizable up to half the screen.
export function ContextCanvas() {
  const [canvas, setCanvas] = useState<{ title: string; body: string } | null>(null);
  const [width, setWidth] = useState(460);
  useEffect(() => {
    const onOpen = (e: Event) => {
      const d = (e as CustomEvent<{ title?: string; body?: string }>).detail;
      if (d && d.body != null) setCanvas({ title: d.title || "File", body: String(d.body) });
    };
    const onClose = () => setCanvas(null);
    window.addEventListener("prevail:open-canvas", onOpen as EventListener);
    window.addEventListener("prevail:close-canvas", onClose);
    return () => { window.removeEventListener("prevail:open-canvas", onOpen as EventListener); window.removeEventListener("prevail:close-canvas", onClose); };
  }, []);
  if (!canvas) return null;
  return (
    <>
      {/* Handle on the canvas's left edge: drag left to widen (clamped to half). */}
      <ResizeHandle ariaLabel="Resize file canvas"
        onChange={(dx) => setWidth((w) => Math.max(300, Math.min(Math.round(window.innerWidth * 0.5), w - dx)))} />
      <FileCanvas title={canvas.title} source={canvas.body} width={width} onClose={() => setCanvas(null)} />
    </>
  );
}

// A tiny icon action for the Context detail header and list rows.
function CtxTool({ icon: Icon, label, onClick, testId }: { icon: LucideIcon; label: string; onClick: () => void; testId?: string }) {
  return (
    <button onClick={onClick} title={label} aria-label={label} data-testid={testId}
      className="flex h-7 w-7 shrink-0 items-center justify-center rounded-md text-text-muted transition-colors hover:bg-surface-warm hover:text-accent">
      <Icon className="h-3.5 w-3.5" />
    </button>
  );
}

// A context file, rendered as markdown right in the detail pane.
function FileBody({ body, empty }: { body: string; empty: string }) {
  if (!body.trim()) return <p className="text-[12px] text-text-muted">{empty}</p>;
  return <div data-testid="ctx-markdown" className="prose-sm max-w-none text-sm leading-relaxed text-text-primary"><Markdown source={body} /></div>;
}

// One row in a folder or list section. A click previews the item in the same
// pane; the tiny icons on the right are the other actions.
function CtxItem({ title, sub, onOpen, tools, testId }: { title: string; sub?: string; onOpen: () => void; tools?: React.ReactNode; testId?: string }) {
  return (
    <li className="group flex items-center gap-1 border-b border-border-subtle last:border-b-0">
      <button onClick={onOpen} data-testid={testId} className="min-w-0 flex-1 py-2 text-left hover:text-accent">
        <div className="truncate text-[14px] text-text-primary" title={title}>{title}</div>
        {sub && <div className="mt-0.5 line-clamp-2 text-[12px] text-text-muted" title={sub}>{sub}</div>}
      </button>
      {tools && <div className={`flex shrink-0 items-center ${REVEAL}`}>{tools}</div>}
    </li>
  );
}

// A tiny "rebuild" icon for the State / Memory section headers: runs the distiller
// on demand so you can build a domain's state/memory from its activity without
// waiting for the background pass. Reports when there isn't enough material yet.
function RebuildStateButton({ vaultPath, domain, field }: { vaultPath: string; domain: string; field: "state" | "memory" }) {
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState<string | null>(null);
  const run = async (e: React.MouseEvent) => {
    e.stopPropagation();
    setBusy(true); setNote(null);
    try {
      const cfg = distillCfgFromPrefs(vaultPath);
      // Build from the JOURNAL on demand (works without an intents ledger).
      const res = await invoke<{ built: boolean; reason: string }>("build_domain_state", {
        vault: vaultPath, domain: domain || null, provider: cfg.provider, model: cfg.model,
      });
      window.dispatchEvent(new CustomEvent("prevail:context-changed"));
      if (res.built) window.setTimeout(() => setNote(null), 1500);
      else setNote("No activity yet");
    } catch (err) { setNote("Could not rebuild it"); }
    finally { setBusy(false); }
  };
  return (
    <span className="flex shrink-0 items-center gap-1">
      {note && <span className="text-[12px] text-text-muted">{note}</span>}
      <button onClick={run} disabled={busy} title={`Rebuild ${field} from your activity here`}
        className="rounded p-1 text-text-muted transition-colors hover:text-accent disabled:opacity-50">
        {busy ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <RefreshCw className="h-3.5 w-3.5" />}
      </button>
    </span>
  );
}

type CtxModeValue = { mode: "list" | "detail"; selected: string; select: (k: string) => void };
const CtxMode = createContext<CtxModeValue>({ mode: "list", selected: "", select: () => {} });

// One context section. In the spine it is a row (title and count); in the
// detail pane only the picked one renders, under a big header with its real
// filename on one quiet line and its actions as tiny icons.
function CtxSection({ keyName, title, count, body, action, file }: { keyName: string; title: string; count?: number; body: React.ReactNode; action?: React.ReactNode; file?: string }) {
  const { mode, selected, select } = useContext(CtxMode);
  if (mode === "list") {
    const on = selected === keyName;
    return (
      <button
        data-testid={`ctx-row-${keyName}`}
        aria-current={on ? "true" : undefined}
        onClick={() => select(keyName)}
        className={`mx-2 flex h-9 w-[calc(100%-1rem)] items-center justify-between gap-2 rounded-lg px-2.5 text-left transition-colors ${on ? "bg-surface-warm font-semibold text-text-primary" : "text-text-secondary hover:bg-surface-warm/50"}`}
      >
        <span className="min-w-0 truncate text-[14px]">{title}</span>
        {count !== undefined && <span className="shrink-0 text-[12px] font-normal tabular-nums text-text-muted">{count}</span>}
      </button>
    );
  }
  if (selected !== keyName) return null;
  return (
    <section data-testid={`ctx-detail-${keyName}`}>
      <div className="mb-4 flex items-start gap-3">
        <div className="min-w-0 flex-1">
          {/* The file it comes from is on hover, never printed as a path. */}
          <h3 data-testid="ctx-file" title={file ? `From ${file}` : undefined} className={DETAIL_TITLE}>{title}</h3>
        </div>
        {action && <div className="flex shrink-0 items-center gap-0.5">{action}</div>}
      </div>
      <div className="max-w-3xl text-[14px]">{body}</div>
    </section>
  );
}

export function DomainContextView({
  domain,
  phone = false,
  vaultPath,
  domainPath,
  initialSection,
  onClose,
  onInjectContext,
  onInsertSkill,
  preferredSet,
  onTogglePreferred,
}: {
  domain: string;
  phone?: boolean;
  initialSection?: string;
  vaultPath: string;
  domainPath: string;
  onClose: () => void;
  onInjectContext: (text: string, label: string) => void;
  onInsertSkill: (skillName: string) => void;
  preferredSet?: Set<string>;
  onTogglePreferred?: (name: string) => void;
}) {
  const [ctx, setCtx] = useState<DomainContextBundle | null>(null);
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState<string | null>(null);
  // Which context section the detail pane shows. The global Ideal always
  // exists, so it is the safe default; a domain switch resets to it.
  const [selected, setSelected] = useState<string>(initialSection ?? "ideal");
  const [phoneDetail, setPhoneDetail] = useState(!!initialSection);
  useEffect(() => { setSelected(initialSection ?? "ideal"); setPhoneDetail(!!initialSection); }, [domain, initialSection]);
  // Linking: what conversations elsewhere noted for this domain, and your
  // entities whose home is here.
  const across = useUpdates(domain ? vaultPath : null, domain ? { domain } : null);
  const store = useEntityStore();
  useEffect(() => { if (domain) void loadEntities(vaultPath); }, [vaultPath, domain]);
  const things = domain && store.vault === vaultPath ? yoursIn(store.list?.entities ?? [], domain) : [];
  // A file or item picked inside a folder or list section, previewed in the
  // same pane with a way back to the list.
  type Preview = { title: string; body: string; label: string };
  const [preview, setPreview] = useState<Preview | null>(null);
  useEffect(() => { setPreview(null); }, [domain]);
  const select = (k: string) => { setSelected(k); setPhoneDetail(true); setPreview(null); };
  const showItem = (title: string, body: string, label = title) => setPreview({ title, body, label });
  const showFromDisk = async (title: string, cmd: "read_file" | "read_skill", path: string) => {
    try { showItem(title, await invoke<string>(cmd, { path })); }
    catch (e) { showItem(title, `Could not read ${path}: ${String(e)}`); }
  };
  // Live decision ledger (_decisions.jsonl) + distilled long-term memory.
  // These update the moment a verdict is saved - no waiting on distillation.
  type DecisionRecord = { id?: string; ts?: number; kind?: string; prompt?: string; verdict?: string; decision?: string; feedback?: { rating?: string } | string | null };
  const [decisionLog, setDecisionLog] = useState<DecisionRecord[]>([]);
  // A decision is worth showing only if it has text. Distiller-extracted entries
  // carry it in `decision`; council verdicts in `prompt`/`verdict`. Empties (the
  // "(untitled decision)" noise) are filtered out entirely.
  const decisions = decisionLog.filter((d) => (d.prompt || d.verdict || d.decision || "").trim());
  const [memory, setMemory] = useState<string>("");
  useEffect(() => {
    let mounted = true;
    setLoading(true);
    // A domain opened before paints its last context at once while it reloads.
    const cachedCtx = peekInvoke<DomainContextBundle>("domain_context", { vault: vaultPath, domain: domain || "" });
    if (cachedCtx) setCtx(cachedCtx);
    const load = () => {
      // C1 (Monday feedback): General now gets the SAME context items as domains.
      // domain_context with an empty domain reads the vault ROOT, which is exactly
      // where General's journal / session logs / skills / decisions live - so the
      // panel shows them instead of only the cross-cutting trio.
      invokeCached<DomainContextBundle>("domain_context", { vault: vaultPath, domain: domain || "" }, { force: true })
        .then((c) => { if (mounted) { setCtx(c); setErr(null); } })
        .catch((e) => { if (mounted) { setCtx(null); setErr(domain ? String(e) : null); } })
        .finally(() => { if (mounted) setLoading(false); });
      invoke<DecisionRecord[]>("decisions_read", { vault: vaultPath, domain: domain || null, limit: 15 })
        .then((d) => { if (mounted) setDecisionLog(Array.isArray(d) ? d : []); })
        .catch(() => { if (mounted) setDecisionLog([]); });
      invoke<string>("read_memory_md", { vault: vaultPath, domain: domain || null })
        .then((m) => { if (mounted) setMemory(m || ""); })
        .catch(() => { if (mounted) setMemory(""); });
      invoke<string>("read_ideal_state", { vault: vaultPath })
        .then((s) => { if (mounted) setIdealState(s || ""); })
        .catch(() => { if (mounted) setIdealState(""); });
      // This domain's OWN ideal-state.md (its target/aim) - the most important
      // local context, distinct from the global constitution above. For General
      // (no domain) the global ideal already covers the vault root, so skip.
      if (domain) {
        invoke<string>("read_domain_ideal", { vault: vaultPath, domain })
          .then((s) => { if (mounted) setDomainIdeal(s || ""); })
          .catch(() => { if (mounted) setDomainIdeal(""); });
      } else if (mounted) {
        setDomainIdeal("");
      }
      // The user's own material + the task board. Read straight off disk by
      // path (v4 first, then legacy) so absence just yields empty - no error.
      void (async () => {
        // All four reads at once (they were awaited one after another).
        const read = (path: string) => invoke<string>("read_text_file", { path }).catch(() => "");
        const [v4Tasks, legacyTasks, ...bodies] = await Promise.all([
          read(`${domainPath}/memory/tasks.md`), read(`${domainPath}/_tasks.md`),
          ...["goals.md", "config.md"].map((f) => read(`${domainPath}/source/${f}`)),
        ]);
        if (mounted) setDomainTasks(v4Tasks || legacyTasks || "");
        const src: { name: string; body: string }[] = [];
        ["goals.md", "config.md"].forEach((f, i) => { const t = bodies[i]; if (t && t.trim()) src.push({ name: `source/${f}`, body: t }); });
        if (mounted) setSourceFiles(src);
      })();
      // Imports row shows only when the domain has any.
      if (domain) {
        invoke<unknown[]>("ingestion_list_artifacts", { domain })
          .then((rows) => { if (mounted) setImportCount(Array.isArray(rows) ? rows.length : 0); })
          .catch(() => { if (mounted) setImportCount(0); });
      } else if (mounted) {
        setImportCount(0);
      }
    };
    load();
    // Refresh the instant a decision/verdict is saved anywhere in the app.
    const onChanged = () => load();
    window.addEventListener("prevail:context-changed", onChanged);
    return () => { mounted = false; window.removeEventListener("prevail:context-changed", onChanged); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [vaultPath, domain]);

  const [idealState, setIdealState] = useState<string>("");
  const [domainIdeal, setDomainIdeal] = useState<string>("");
  // The user's own source material (source/goals.md, source/config.md) and the
  // domain's task board - real on-disk context that wasn't surfaced here before.
  const [sourceFiles, setSourceFiles] = useState<{ name: string; body: string }[]>([]);
  const [domainTasks, setDomainTasks] = useState<string>("");
  const [importCount, setImportCount] = useState(0);
  // Clicking a file/section opens it in the LEFT canvas pane (owned by App), not
  // inline here - so the drawer stays a compact index and the content gets room.
  const openCanvas = (title: string, body: string) => {
    if (!body || !body.trim()) return;
    window.dispatchEvent(new CustomEvent("prevail:open-canvas", { detail: { title, body } }));
  };
  // G2: the learned user profile - what Prevail knows about you, surfaced so it's
  // visible what grounds the answers. Loaded from user.md (falls back to profile.md).
  const [profile, setProfile] = useState<string>("");
  const [editingProfile, setEditingProfile] = useState(false);
  const [profileDraft, setProfileDraft] = useState("");
  const [savingProfile, setSavingProfile] = useState(false);
  useEffect(() => {
    invoke<string>("read_user_md", { vault: vaultPath }).then((s) => setProfile(s || "")).catch(() => setProfile(""));
  }, [vaultPath]);
  const startEditProfile = () => { setProfileDraft(profile); setEditingProfile(true); };
  const saveProfile = async () => {
    setSavingProfile(true);
    try {
      await invoke("write_user_md", { vault: vaultPath, body: profileDraft });
      setProfile(profileDraft);
      setEditingProfile(false);
    } catch (e) { console.error("write_user_md", e); }
    finally { setSavingProfile(false); }
  };

  // Show the REAL on-disk filename: the v4 path on a migrated domain, else the
  // legacy flat name. Keeps the UI label matched to the filesystem exactly.
  const vf = (v4: string, legacy: string) => (ctx?.layoutV4 ? v4 : legacy);

  // Every "use in chat" goes through here so the header can confirm it.
  const [added, setAdded] = useState<string | null>(null);
  const inject = (body: string, label: string) => { onInjectContext(body, label); setAdded(label); };
  // The actions every file carries: open it in the canvas, or use it in chat.
  const fileTools = (title: string, body: string, label: string) => body.trim() ? (<>
    <CtxTool icon={Maximize2} label="Open in canvas" onClick={() => openCanvas(title, body)} />
    <CtxTool icon={ArrowRight} label="Use in chat" onClick={() => inject(body, label)} />
  </>) : null;
  const where = domain ? titleCase(domain) : "General";

  // The section tree renders twice: as the spine's list ("list") and as the
  // picked section's full body in the detail pane ("detail").
  const renderTree = (mode: "list" | "detail") => (
      <CtxMode.Provider value={{ mode, selected, select }}>
        {mode === "list" && (<>
        {/* X6 (cascading goals): make the "why" legible - every domain's context
            traces up to your life mission (the ideal-state). Shows the mission's
            headline so tasks/answers here read as serving something bigger. */}
        {(() => {
          const mission = idealState
            .split("\n")
            .map((l) => l.replace(/^#+\s*/, "").trim())
            .find((l) => l.length > 0);
          if (!mission) return null;
          return (
            <button
              onClick={() => select("ideal")}
              className="flex w-full items-start gap-2 px-4 py-2.5 text-left hover:bg-surface-warm/50"
              title="Your north star - open your ideal state"
            >
              <Compass className="mt-0.5 h-3.5 w-3.5 shrink-0 text-accent" />
              <div className="min-w-0">
                <div className="text-[12px] font-medium text-accent">
                  {domain ? `${titleCase(domain)} serves your purpose` : "Your purpose"}
                </div>
                <div className="truncate text-[12px] text-text-muted" title={mission}>{mission}</div>
              </div>
            </button>
          );
        })()}
        {loading && <div className="px-4 py-2 text-[12px] text-text-muted">Reading this domain</div>}
        {/* B2-28: calm, recoverable message instead of a raw "domain not found:
            /path" error. The Global sections (Ideal State, Profile, Memory) still
            render below; only this domain's local context failed to load. */}
        {err && (
          <div className="px-4 py-2 text-[12px] text-text-muted">
            Couldn't load this domain's local context right now.{" "}
            <button
              onClick={() => window.dispatchEvent(new CustomEvent("prevail:context-changed"))}
              className="font-medium text-accent hover:underline"
            >
              Retry
            </button>
          </div>
        )}
        {!domain && (
          <div className="px-4 py-2 text-[12px] leading-snug text-text-muted">
            Your no-domain workspace. Open a domain for its own context.
          </div>
        )}
        </>)}
        {/* C2: clarify GLOBAL vs LOCAL. Global = the constitution that applies to
            every domain. Below, "This domain" = everything scoped to {domain}. */}
        {mode === "list" && (
        <div title="Applies everywhere, shared across every domain" className="flex cursor-help items-center gap-1.5 px-4 pb-1 pt-3 text-[13px] font-semibold text-text-secondary">
          <Globe className="h-3.5 w-3.5 text-text-muted" /> Everywhere
        </div>
        )}
        <CtxSection keyName="ideal" title="Ideal" file="ideal-state.md" count={idealState.trim() ? 1 : undefined}
          action={fileTools("Ideal", idealState, "Ideal · constitution")}
          body={<FileBody body={idealState} empty="Not set. Add it in Settings, Ideals." />} />
        {/* G2: what Prevail knows about you - the profile that grounds every answer.
            Now editable (write_user_md), not just viewable. */}
        <CtxSection keyName="profile" title="User" file="user.md" count={profile.trim() ? 1 : undefined}
          action={editingProfile ? null : (<>
            <CtxTool icon={Pencil} label={profile.trim() ? "Edit profile" : "Add your profile"} onClick={startEditProfile} />
            {fileTools("User", profile, "User · who you are")}
          </>)}
          body={
          editingProfile ? (
            <div>
              <textarea
                value={profileDraft}
                onChange={(e) => setProfileDraft(e.target.value)}
                rows={8}
                placeholder="Who you are, what matters to you, how you like to work. Glyph Studio reads this as standing context for every answer."
                className="w-full resize-y rounded-md border border-border bg-background px-2.5 py-2 text-[14px] leading-normal text-text-primary focus:border-accent-border focus:outline-none"
              />
              <div className="mt-2 flex items-center gap-4">
                <button onClick={saveProfile} disabled={savingProfile} className="inline-flex h-8 items-center gap-1.5 rounded-md bg-accent px-3 text-[13px] font-medium text-on-accent hover:bg-accent-hover disabled:opacity-50">
                  {savingProfile ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : null} Save
                </button>
                <button onClick={() => setEditingProfile(false)} className="text-[13px] text-text-muted hover:text-text-primary">Cancel</button>
              </div>
            </div>
          ) : (
            <FileBody body={profile} empty="Not set yet. Add your profile so Glyph Studio grounds every answer in who you are." />
          )
        } />
        {mode === "list" && (
        <div title={domain ? `Specific to ${titleCase(domain)}` : "Specific to General (the no-domain workspace)"} className="flex cursor-help items-center gap-1.5 px-4 pb-1 pt-4 text-[13px] font-semibold text-text-secondary">
          {(() => { const I = domain ? domainIcon(domain) : MessageSquare; return I ? <I className="h-3.5 w-3.5 text-text-muted" /> : null; })()}
          {domain ? titleCase(domain) : "General"}
        </div>
        )}
        {/* This domain's own ideal-state.md - its target/aim. The single most
            important local context, so it leads the domain section. Only shown
            for a real domain; General's ideal IS the global one above. */}
        {domain && (
          <CtxSection keyName="domainideal" title="Ideal" file="ideal-state.md" count={domainIdeal.trim() ? 1 : undefined}
            action={fileTools(`${titleCase(domain)} ideal`, domainIdeal, `${titleCase(domain)} · ideal`)}
            body={<FileBody body={domainIdeal} empty="Not set. Draft it from the domain's Ideal editor." />} />
        )}
        {domain && (
          <CtxSection keyName="across" title="Across your life" file="memory/updates.jsonl" count={across.lines.length || undefined}
            body={<AcrossYourLife vaultPath={vaultPath} target={{ domain }} emptyName={titleCase(domain)} />} />
        )}
        {/* The knowledge sources this space's briefings and chats read. */}
        <CtxSection keyName="knowledge" title="Knowledge sources" body={<SourcesInUse vaultPath={vaultPath} domain={domain || "general"} />} />
        {domain && (
          <CtxSection keyName="things" title="Your things" count={things.length || undefined} body={
            things.length ? (
              <ul data-testid="your-things" className="max-w-3xl">
                {things.map((e) => (
                  <li key={e.id}>
                    <button type="button" data-testid="your-thing" onClick={() => requestEntity({ kind: e.kind, value: e.id.slice(e.id.indexOf("/") + 1) })}
                      className="flex w-full items-center gap-2.5 rounded-lg px-2 py-2 text-left hover:bg-surface-warm">
                      <KindBadge kind={e.kind} name={e.name} domain={e.domain} size={30} entity={e} />
                      <span className="min-w-0 flex-1 truncate text-[14px] font-medium text-text-primary">{e.name}</span>
                      <span className="shrink-0 text-[12px] tabular-nums text-text-muted" title={`${e.conversations} conversations`}>{e.conversations}</span>
                    </button>
                  </li>
                ))}
              </ul>
            ) : <p className="text-[12px] text-text-muted">Nothing yet. The people, places and things of your life that belong to {titleCase(domain)} show here as you talk about them.</p>
          } />
        )}
        {/* The user's own material (source/) - goals and config they wrote. Real
            grounding context, surfaced per file so the label matches the path. */}
        {sourceFiles.length > 0 && (
          <CtxSection keyName="source" title="Source" file="source/" count={sourceFiles.length} body={
            <ul>
              {sourceFiles.map((f) => (
                <CtxItem key={f.name} title={f.name} testId={`ctx-item-${f.name}`}
                  onOpen={() => showItem(f.name, f.body, `${where} · ${f.name}`)}
                  tools={<CtxTool icon={ArrowRight} label="Use in chat" onClick={() => inject(f.body, `${where} · ${f.name}`)} />} />
              ))}
            </ul>
          } />
        )}
        {/* The task board - what's open in this domain. Injectable as context so a
            chat can reason over the current workload. */}
        {domainTasks.trim() && (
          <CtxSection keyName="tasks" title="Tasks" file={vf("memory/tasks.md", "_tasks.md")}
            action={fileTools(`${where} tasks`, domainTasks, `${where} · tasks`)}
            body={<FileBody body={domainTasks} empty="No tasks yet." />} />
        )}
        <CtxSection keyName="memory" title="Memory" file={vf("memory/memory.md", "_memory.md")}
          action={<><RebuildStateButton vaultPath={vaultPath} domain={domain} field="memory" />{fileTools(`${where} memory`, memory, `${where} · memory`)}</>}
          body={<FileBody body={memory} empty="Empty until distilled. Rebuild it with the refresh icon above." />} />
        {ctx && (
          <>
            <CtxSection keyName="state" title="State" file={vf("memory/state.md", "_state.md")}
              action={<><RebuildStateButton vaultPath={vaultPath} domain={domain} field="state" />{fileTools(`${where} state`, ctx.state ?? "", `${where} · state`)}</>}
              body={<FileBody body={ctx.state ?? ""} empty="Empty until distilled. Rebuild it with the refresh icon above." />} />
            {/* Decisions = the live ledger (latest, raw) + the distiller's curated
                summary, in ONE section (was split into "Recent decisions" + "Decisions"). */}
            <CtxSection keyName="decisions" title="Decisions" file={vf("memory/decisions.jsonl", "_decisions.jsonl")} count={decisions.length || undefined} body={
              <>
              <p className="mb-2 text-[12px] text-text-muted">Council verdicts and saved decisions, latest first.</p>
              {decisions.length > 0 ? (
                <ul>
                  {decisions.slice(0, 8).map((d, i) => {
                    const fb = typeof d.feedback === "object" && d.feedback ? d.feedback.rating : (typeof d.feedback === "string" ? d.feedback : undefined);
                    const ago = d.ts ? formatFreshness(Math.max(0, Math.floor((Date.now() - d.ts) / 1000))) : "";
                    const key = d.id ?? String(i);
                    const text = (d.prompt || d.decision || "(untitled)").trim();
                    const full = (d.verdict || d.decision || d.prompt || "").trim();
                    const title = `Decision · ${text.slice(0, 48)}`;
                    return (
                      <CtxItem key={key} title={text} sub={`${d.kind ?? "decision"}${ago ? ` · ${ago}` : ""}${fb === "up" ? " · liked" : fb === "down" ? " · disliked" : ""}`}
                        onOpen={() => showItem(title, full, `decision · ${text.slice(0, 30)}`)}
                        tools={full ? <CtxTool icon={ArrowRight} label="Use in chat" onClick={() => inject(full, `decision · ${text.slice(0, 30)}`)} /> : undefined} />
                    );
                  })}
                </ul>
              ) : <p className="text-[12px] text-text-muted">Empty. Run a council or save a decision.</p>}
              </>
            } />
            {/* JOURNAL = the literal record of every prompt that came in (raw),
                distinct from the distilled sections above which are derived from
                it. Per founder's model: journal = raw prompts; intent = distilled.
                (The on-disk file is _intents.jsonl today; a forced rename to a
                journal-named file is the pending vault-layout migration.) */}
            <CtxSection keyName="activity" title="Journal" file={vf(".system/journal.jsonl", "_intents.jsonl")} count={ctx.recent_logs.length || undefined} body={
              <>
              <ul>
                {ctx.journal && (
                  <CtxItem title="Raw journal" sub="Every prompt you sent, verbatim. The distilled sections come from this."
                    onOpen={() => showItem(`${where} journal`, ctx.journal!, `${where} · journal`)}
                    tools={<CtxTool icon={ArrowRight} label="Use in chat" onClick={() => inject(ctx.journal!, `${where} · journal`)} />} />
                )}
                {ctx.recent_logs.map((l) => (
                  <CtxItem key={l.path} title={l.name} sub={l.preview || undefined} onOpen={() => void showFromDisk(l.name, "read_file", l.path)} />
                ))}
              </ul>
              {ctx.recent_logs.length === 0 && !ctx.journal && (
                <p className="text-[12px] text-text-muted">Empty. Your chats here build this record.</p>
              )}
              </>
            } />
            <CtxSection keyName="skills" title="Skills" file={vf("memory/skills/", "_skills/")} count={ctx.skills.length} body={
              ctx.skills.length === 0 ? (
                <div className="text-[12px] text-text-muted">No skills here yet. Add one from Toolkit, or ask a chat here to save one.</div>
              ) : (
                <ul>
                  {ctx.skills.map((s) => {
                    const on = s.enabled !== false;
                    return (
                    <li key={s.path} className={`group flex items-center gap-1 border-b border-border-subtle last:border-b-0 ${on ? "" : "opacity-55"}`}>
                      <button
                        onClick={() => void showFromDisk(`/${s.name}`, "read_skill", s.path)}
                        title="Preview this skill"
                        className="min-w-0 flex-1 py-2 text-left"
                      >
                        <div className="text-[14px] font-medium text-accent">/{s.name}</div>
                        {s.description && <div className="mt-0.5 line-clamp-2 text-[12px] text-text-muted">{s.description}</div>}
                      </button>
                      {on && <span className={`flex items-center ${REVEAL}`}><CtxTool icon={ArrowRight} label={`Insert /${s.name}`} onClick={() => onInsertSkill(s.name)} /></span>}
                      {/* Enable/disable: a disabled skill stays on disk but is
                          excluded from /skills + auto-attach. */}
                      <span className="flex shrink-0 items-center px-1" title={on ? "Enabled - slide left to disable" : "Disabled - slide right to enable"}>
                        <Toggle
                          on={on}
                          label={`${on ? "Disable" : "Enable"} ${s.name}`}
                          onChange={(next) => {
                            void invoke("skill_set_enabled", { vault: vaultPath, domain: s.domain, name: s.name, enabled: next })
                              .then(() => window.dispatchEvent(new Event("prevail:context-changed")))
                              .catch((e) => console.error("skill_set_enabled", e));
                          }}
                        />
                      </span>
                      {onTogglePreferred && (
                        <button
                          onClick={() => onTogglePreferred(s.name)}
                          title={preferredSet?.has(s.name) ? "Unpin" : "Pin: auto-attach"}
                          aria-label={preferredSet?.has(s.name) ? `Unpin ${s.name}` : `Pin ${s.name}`}
                          aria-pressed={!!preferredSet?.has(s.name)}
                          className={`flex h-7 w-7 shrink-0 items-center justify-center rounded-md transition-colors hover:bg-surface-warm ${preferredSet?.has(s.name) ? "text-accent" : `text-text-muted hover:text-accent ${REVEAL}`}`}
                        >
                          <Pin className={`h-3.5 w-3.5 ${preferredSet?.has(s.name) ? "fill-current" : ""}`} />
                        </button>
                      )}
                    </li>
                    );
                  })}
                </ul>
              )
            } />
            {importCount > 0 && (
              <CtxSection keyName="imports" title="Imports" file="imports/" count={importCount} body={
                <DrawerImportsSection
                  domain={domain}
                  onInject={(body, label) => inject(body, label)}
                  onPreview={(title, body) => showItem(title, body)}
                />
              } />
            )}
          </>
        )}
        {/* Every call this domain's conversations made to an app. */}
        <CtxSection keyName="apps-used" title="Apps used" file="data/apps/*/_log/access.jsonl" body={
          <AppActivity vaultPath={vaultPath} filter={{ domain: domain || "general", limit: 100 }} showApp
            empty={`No app calls from ${where} yet. When a conversation here reads from or writes to an app, it shows here.`} />
        } />
      </CtxMode.Provider>
  );

  const domainLabel = domain ? titleCase(domain) : "General";
  const DomainIcon = domain ? domainIcon(domain) : MessageSquare;
  // Where this context lives on disk: the domain's folder, or the vault root
  // for General. The last few segments show; the full path is on hover.
  const folder = domain ? domainPath : vaultPath;
  const finder = (
    <button
      data-testid="ctx-folder"
      onClick={() => { void invoke("open_in_finder", { path: folder }); }}
      title={`Open in Finder\n${folder}`}
      aria-label="Open the folder in Finder"
      className="flex h-8 w-8 shrink-0 items-center justify-center rounded-md text-text-muted transition-colors hover:bg-surface-warm hover:text-accent"
    >
      <Folder className="h-4 w-4" />
    </button>
  );
  const previewPane = preview && (
    <section data-testid="ctx-preview">
      <button onClick={() => setPreview(null)} className="mb-3 inline-flex h-8 items-center gap-1.5 text-[13px] font-medium text-accent hover:underline">
        <ArrowLeft className="h-4 w-4" /> Back
      </button>
      <div className="mb-4 flex items-start gap-3">
        <h3 className={`min-w-0 flex-1 break-words ${DETAIL_TITLE}`}>{preview.title}</h3>
        <div className="flex shrink-0 items-center gap-0.5">{fileTools(preview.title, preview.body, preview.label)}</div>
      </div>
      <div className="max-w-3xl"><FileBody body={preview.body} empty="This file is empty." /></div>
    </section>
  );

  // In-flow, never an overlay: this view takes the chat column's place. The
  // header carries the way back; the canonical SideSpine lists the sections on
  // the left and the picked one fills the detail pane (list-then-detail on a phone).
  return (
    <div data-testid="context-view" className="flex min-h-0 min-w-0 flex-1 flex-col bg-background">
      <div className={`flex shrink-0 items-center gap-3 border-b border-border-subtle ${phone ? "px-3 py-2" : "px-5 py-3"}`}>
        <button
          onClick={onClose}
          title="Back to chat"
          className="inline-flex h-9 shrink-0 items-center gap-1.5 rounded-md px-2 text-[14px] font-medium text-accent hover:bg-surface-warm"
        >
          <ArrowLeft className="h-4 w-4" /> Chat
        </button>
        {DomainIcon ? <DomainIcon className="h-5 w-5 shrink-0 text-accent" /> : null}
        <div className="min-w-0 flex-1">
          <h2 className={`min-w-0 truncate font-display font-semibold tracking-tight text-text-primary ${phone ? "text-[18px]" : "text-[22px]"}`}>
            {domainLabel} context
          </h2>
        </div>
        {added && <span role="status" className="hidden min-w-0 truncate text-[13px] text-accent sm:inline">Added to chat: {added}</span>}
        {finder}
      </div>
      <SideSpine
        storageKey="prevail.contextSpine.collapsed"
        title="Sections"
        label="context sections"
        testId="context-spine"
        phone={phone}
        phoneDetail={phoneDetail}
        onBack={() => setPhoneDetail(false)}
        backLabel="All sections"
        detail={<div className={phone ? "px-4 py-3" : "px-8 py-6"}>{previewPane || renderTree("detail")}</div>}
      >
        {renderTree("list")}
      </SideSpine>
    </div>
  );
}

// Drawer section that surfaces a domain's ingested imports without
// the user having to navigate to Settings → Ingestion. Click a row
// to load the first chunk into the chat as primed context, or
// "reveal" to open in Finder. Read-only - toggling for attachment
// happens via the chips above the composer.

// Domain actions menu - "Back up" and "Archive" for a single domain.
// Used in the domain header. Backs up via engine_vault_backup(domainOpt),
// archives via engine_vault_archive. Archive never deletes data; it just
// flips the manifest flag and hides the domain from the active sidebar.

// ─────────────────────────────────────────────────────────────────────
// Usage dashboard (P4.7 Phase 4) - reads the aggregated <vault>/usage
// summary written by usage_append at each turn close and renders totals
// plus breakdowns by CLI, model, and domain, with a per-day activity
// strip. Surfaced on the no-domain landing; renders nothing until there's
// at least one captured turn, so new vaults stay clean.



// The user's Ideal State (constitution) framed as highest-precedence law and
// prepended to chat/council prompts the desktop sends directly. Mirrors the
// engine framing (cli-bridge.ts buildConstitutionPreamble) and the Rust daemon
// helper (lib.rs ideal_state_preamble) so the constitution reads identically
// everywhere. Empty string when the Ideal State is blank.


// Fetches the engine-backed usage roll-up (whole-vault, or scoped to one domain
// when `domain` is set) and renders it. On the no-domain landing we pass
// hideWhenEmpty so a fresh vault stays clean; in the Usage tab we show a
// friendly empty state instead.


// I7: create a reusable skill from the UI - the "build skills over time" path.
// A skill is just a named, reusable prompt the model runs on demand (slash
// `/name` in chat). Seeded from the composer's "Save as skill" or written here.


// Side drawer that shows the current domain's state.md, decisions,
// journal, recent session logs, and skills. Loaded on-demand via the
// `domain_context` Rust command. Items can be "used in chat" to
// inject as prompt context.

export function PrefPickerColumn({
  glyph,
  title,
  options,
  selected,
  onSelect,
  onClear,
}: {
  glyph?: string;
  title: string;
  options: readonly { id: string; label: string; blurb: string }[];
  selected: string;
  onSelect: (id: string) => void;
  onClear: () => void;
}) {
  void glyph;
  return (
    <div>
      <div className="mb-3 flex items-center justify-between">
        <div className="text-[13px] font-semibold text-text-secondary">{title}</div>
        {selected && (
          <button
            onClick={onClear}
            className="text-[12px] text-text-muted hover:text-accent"
          >
            Use global
          </button>
        )}
      </div>
      <div className="flex max-h-72 flex-col gap-1 overflow-y-auto">
        {options.map((o) => {
          const picked = selected === o.id;
          return (
            <button
              key={o.id}
              onClick={() => onSelect(o.id)}
              className={`flex items-center gap-3 rounded-md px-3 py-2 text-left transition-colors ${
                picked ? "bg-surface-warm" : "hover:bg-surface-warm/50"
              }`}
            >
              <span className={`shrink-0 text-[14px] ${picked ? "font-semibold text-text-primary" : "text-text-primary"}`}>{o.label}</span>
              <span className="min-w-0 flex-1 truncate text-[12px] text-text-muted">{o.blurb}</span>
              {picked && (
                <Check className="h-4 w-4 shrink-0 text-accent" strokeWidth={2.5} />
              )}
            </button>
          );
        })}
      </div>
    </div>
  );
}

// Collapsible card for a Preferences section. Collapsed by default so the page
// reads as a tidy list of sections; click the header (or expand the one you want)
// to reveal its controls. `right` is an optional header-aligned action that does
// not toggle the section.
function PrefSection({ title, subtitle, icon, right, defaultOpen = false, children }: { title: string; subtitle?: string; icon?: React.ReactNode; right?: React.ReactNode; defaultOpen?: boolean; children: React.ReactNode }) {
  const [open, setOpen] = useState(defaultOpen);
  return (
    <section className="border-b border-border-subtle">
      <div className="flex items-center gap-2 py-3">
        <button onClick={() => setOpen((o) => !o)} className="flex min-w-0 flex-1 items-center gap-2.5 text-left">
          <ChevronRight className={`h-3.5 w-3.5 shrink-0 text-text-muted transition-transform ${open ? "rotate-90" : ""}`} strokeWidth={2.5} />
          {icon && <span className="flex h-4 w-4 shrink-0 items-center justify-center text-text-muted">{icon}</span>}
          <span className="shrink-0 text-[14px] font-medium text-text-primary">{title}</span>
        </button>
        {/* Right-side summary of what's inside, so the row reads at a glance
            even while collapsed (founder ask: icon left, summary right). */}
        {subtitle && <span className="min-w-0 truncate text-right text-[12px] text-text-muted">{subtitle}</span>}
        {right && <div className="shrink-0" onClick={(e) => e.stopPropagation()}>{right}</div>}
      </div>
      {open && <div className="pb-5 pl-6">{children}</div>}
    </section>
  );
}

export function DomainPrefsPanel({
  domain,
  vaultPath,
  clis,
  skills,
  preferredSkills,
  onTogglePreferredSkill,
  onChanged,
  onBack,
}: {
  domain: string;
  vaultPath: string;
  clis: CliInfo[];
  skills: SkillEntry[];
  preferredSkills: string[];
  onTogglePreferredSkill: (name: string) => void;
  onChanged: () => void;
  onBack?: () => void;
}) {
  // Read overrides directly so save buttons are unnecessary -
  // bump tick on every write so this component re-renders.
  const [tick, setTick] = useState(0);
  const force = () => { setTick((t) => t + 1); onChanged(); };
  void tick;
  // Skill list collapses by default so a long roster doesn't crowd the panel.
  const [skillsOpen, setSkillsOpen] = useState(false);
  // Which CLI's model list is expanded. Independent of selection (pickedCli): the
  // user can collapse the selected provider's models without deselecting it, and
  // can collapse everything. Initialized to the currently picked cli so the panel
  // opens as before on first render.
  const [expandedCli, setExpandedCli] = useState<string | null>(() => lsGet(`prevail.domain.${domain}.cli`) || null);
  // Per-provider model search over the full catalog (OpenRouter 300+); empty
  // shows curated defaults so the list isn't a wall.
  const [modelSearch, setModelSearch] = useState<Record<string, string>>({});

  const cliKey = `prevail.domain.${domain}.cli`;
  const modelKey = `prevail.domain.${domain}.model`;
  const fwKey = `prevail.domain.${domain}.framework`;
  const lensKey = `prevail.domain.${domain}.lens`;
  const autoStateKey = `prevail.domain.${domain}.autoState`;
  // Privacy / sandbox / routing live in top-level manifest blocks (not
  // config), but we mirror to localStorage too so the rest of the app
  // (ChatPanel reads prevail.domain.<name>.localOnly) keeps working.
  const localOnlyKey = `prevail.domain.${domain}.localOnly`;
  const sandboxKey = `prevail.domain.${domain}.sandbox`;
  const keywordsKey = `prevail.domain.${domain}.routing.keywords`;
  // M6: per-domain Ideal State (this domain's own target, layered under global).
  const [domainIdeal, setDomainIdeal] = useState<string>("");
  const [domainIdealSaved, setDomainIdealSaved] = useState(false);
  const [draftingIdeal, setDraftingIdeal] = useState(false);
  const [draftErr, setDraftErr] = useState<string | null>(null);
  useEffect(() => {
    invoke<string>("read_domain_ideal", { vault: vaultPath, domain }).then((s) => setDomainIdeal(s || "")).catch(() => setDomainIdeal(""));
  }, [vaultPath, domain]);
  const saveDomainIdeal = async () => {
    try { await invoke("write_domain_ideal", { vault: vaultPath, domain, body: domainIdeal }); setDomainIdealSaved(true); window.setTimeout(() => setDomainIdealSaved(false), 1500); } catch (e) { console.error("write domain ideal", e); }
  };
  // IDEAL-AI: draft the ideal state from the domain's real context, for review.
  const draftIdealWithAI = async () => {
    setDraftingIdeal(true); setDraftErr(null);
    try {
      const provider = getPref(PREF.memoryProvider, "claude");
      const model = cheapModel();
      const text = await invoke<string>("domain_draft_ideal", { vault: vaultPath, domain, provider, model });
      if (text?.trim()) setDomainIdeal(text.trim());
    } catch (e) { setDraftErr(String(e)); }
    finally { setDraftingIdeal(false); }
  };

  // Per-domain daemon config (_daemon.json) - taskgen + reminders toggles.
  // Default true so domains work without any config file.
  const daemonCfgPath = `${vaultPath}/${domain}/_daemon.json`;
  const [daemonTaskgen, setDaemonTaskgen] = useState(true);
  const [daemonReminders, setDaemonReminders] = useState(true);
  const [daemonSkillgen, setDaemonSkillgen] = useState(true);
  useEffect(() => {
    invoke<string>("read_text_file", { path: daemonCfgPath })
      .then((raw) => {
        try {
          const cfg = JSON.parse(raw);
          if (typeof cfg.taskgen === "boolean") setDaemonTaskgen(cfg.taskgen);
          if (typeof cfg.reminders === "boolean") setDaemonReminders(cfg.reminders);
          if (typeof cfg.skillgen === "boolean") setDaemonSkillgen(cfg.skillgen);
        } catch {}
      })
      .catch(() => {}); // file absent → defaults (true)
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [daemonCfgPath]);
  function saveDaemonCfg(patch: { taskgen?: boolean; reminders?: boolean; skillgen?: boolean }) {
    const next = { taskgen: daemonTaskgen, reminders: daemonReminders, skillgen: daemonSkillgen, ...patch };
    invoke("write_text_file", { path: daemonCfgPath, contents: JSON.stringify(next, null, 2) }).catch(() => {});
  }

  // Per-domain prefs are stored in the domain's manifest (config block)
  // when the engine supports it, and ALSO mirrored to localStorage so the
  // rest of the app (ChatPanel) - which reads localStorage - keeps working.
  // On mount we load the manifest and hydrate any localStorage keys that
  // aren't already set from it. When the manifest is unavailable we fall
  // back to localStorage-only (the previous behavior).
  const [manifestReady, setManifestReady] = useState(false);
  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const m = await invoke<DomainManifest>("engine_manifest_get", { vault: vaultPath, domain });
        if (cancelled) return;
        const cfg = m?.config;
        if (cfg) {
          // Hydrate localStorage from the manifest only where the user
          // hasn't already set a local override, so the manifest acts as
          // the durable store without clobbering an in-flight local edit.
          if (!lsGet(cliKey) && cfg.cli) lsSet(cliKey, cfg.cli);
          if (!lsGet(modelKey) && cfg.model) lsSet(modelKey, cfg.model);
          if (!lsGet(fwKey) && cfg.framework) lsSet(fwKey, cfg.framework);
          if (!lsGet(lensKey) && cfg.lens) lsSet(lensKey, cfg.lens);
          if (!lsGet(autoStateKey)) lsSet(autoStateKey, cfg.autoState === false ? "0" : "1");
          // Preferred skills come from the parent; seed them from the
          // manifest when none are pinned yet.
          if (Array.isArray(cfg.skills) && cfg.skills.length > 0 && preferredSkills.length === 0) {
            for (const s of cfg.skills) onTogglePreferredSkill(s);
          }
        }
        // Hydrate top-level privacy / sandbox / routing blocks.
        if (!lsGet(localOnlyKey)) lsSet(localOnlyKey, m?.privacy?.localOnly ? "1" : "0");
        if (!lsGet(sandboxKey)) lsSet(sandboxKey, m?.sandbox?.mode === "locked" ? "locked" : "open");
        if (!lsGet(keywordsKey) && Array.isArray(m?.routing?.keywords)) {
          // A6: the domain name is an implicit, non-editable default keyword, so
          // strip it from the editable "extras" we hydrate into the input.
          const extras = (m.routing!.keywords as string[]).filter(
            (k) => k.trim().toLowerCase() !== domain.toLowerCase(),
          );
          lsSet(keywordsKey, extras.join(", "));
        }
        // Nothing stored and nothing in the manifest: derive routing keywords
        // from the domain's own goals/soul so routing works without manual
        // setup. Frequency-ranked distinctive words, top six.
        if (!lsGet(keywordsKey)) {
          try {
            // B5 (Monday feedback): routing keywords weren't populating because
            // this only read the LEGACY path; v3 vaults keep domains under
            // domains/<d>/. Try the v3 path first, then legacy.
            // v4 (data/domains/<d>, goals and config under source/) first,
            // then v3 and the legacy flat layout.
            const bases = [`${vaultPath}/data/domains/${domain}`, `${vaultPath}/domains/${domain}`, `${vaultPath}/${domain}`];
            const texts = await Promise.all(
              [["source/goals.md", "goals.md"], ["ideal-state.md", "soul.md"], ["source/config.md", "config.md"]].map(async (names) => {
                for (const base of bases) for (const f of names) {
                  const t = await invoke<string>("read_text_file", { path: `${base}/${f}` }).catch(() => "");
                  if (t && t.trim()) return t;
                }
                return "";
              }),
            );
            const STOP = new Set("the and for with that this from your you are was have has not but they them then than when what where which while will would could should about into over under each every some most more very just also like been being our their his her its only own same can may might must a an of to in on at by it is as or be do if no so we i me my".split(" "));
            const freq = new Map<string, number>();
            for (const w of texts.join(" ").replace(/~[a-z_]+:\S+/gi, " ").toLowerCase().split(/[^a-z][^a-z]*/)) {
              if (w.length < 4 || STOP.has(w) || w === domain.toLowerCase()) continue;
              freq.set(w, (freq.get(w) ?? 0) + 1);
            }
            const top = [...freq.entries()].sort((a, b) => b[1] - a[1]).slice(0, 6).map(([w]) => w);
            if (top.length > 0) {
              lsSet(keywordsKey, top.join(", "));
              // B5: persist derived keywords to the manifest too - localStorage
              // alone is invisible to the CLI gateway router, so inbound channel
              // messages never matched. Store domain name first, then the derived
              // extras (deduped), matching the edit-path convention.
              const full = [domain.toLowerCase(), ...top].filter((k, i, a) => a.indexOf(k) === i);
              invoke("engine_manifest_set", {
                vault: vaultPath,
                domain,
                json: JSON.stringify({ routing: { keywords: full } }),
              }).catch(() => { /* manifest write unsupported - localStorage holds it */ });
            }
          } catch { /* derivation is best-effort */ }
        }
      } catch {
        // Engine/manifest unavailable - localStorage remains the source.
      } finally {
        if (!cancelled) { setManifestReady(true); force(); }
      }
    })();
    return () => { cancelled = true; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [vaultPath, domain]);

  // Merge a partial config block into the manifest. Best-effort: failures
  // are swallowed so localStorage stays the working fallback.
  const persistManifest = useCallback(
    (config: Record<string, unknown>) => {
      const json = JSON.stringify({ config });
      invoke("engine_manifest_set", { vault: vaultPath, domain, json }).catch(() => {
        /* manifest write unsupported - localStorage already holds the value */
      });
    },
    [vaultPath, domain],
  );

  // Merge an arbitrary top-level manifest patch (e.g. privacy / sandbox /
  // routing blocks). Best-effort - same fallback contract as persistManifest.
  const persistManifestTop = useCallback(
    (patch: Record<string, unknown>) => {
      const json = JSON.stringify(patch);
      invoke("engine_manifest_set", { vault: vaultPath, domain, json }).catch(() => {
        /* manifest write unsupported - localStorage already holds the value */
      });
    },
    [vaultPath, domain],
  );

  // Mirror preferred-skill changes into the manifest once loaded.
  const skillsSig = preferredSkills.join(",");
  useEffect(() => {
    if (!manifestReady) return;
    persistManifest({ skills: preferredSkills });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [skillsSig, manifestReady]);

  const pickedCli = lsGet(cliKey);
  const pickedModel = lsGet(modelKey);
  const pickedFw = lsGet(fwKey);
  const pickedLens = lsGet(lensKey);
  const autoState = lsGet(autoStateKey) !== "0";
  const localOnly = lsGet(localOnlyKey) === "1";
  const sandboxMode = lsGet(sandboxKey) === "locked" ? "locked" : "open";
  const keywordsRaw = lsGet(keywordsKey);

  // Map a localStorage pref key to its manifest config field so writes go
  // to both stores.
  const KEY_TO_CONFIG: Record<string, string> = {
    [cliKey]: "cli",
    [modelKey]: "model",
    [fwKey]: "framework",
    [lensKey]: "lens",
  };

  function setOverride(key: string, value: string) {
    lsSet(key, value);
    const field = KEY_TO_CONFIG[key];
    if (field) persistManifest({ [field]: value || null });
    force();
  }

  void onBack;
  return (
    <div className="w-full">
      {/* Header */}
      <div className="mb-6 flex items-end justify-between gap-3">
        <div>
          <h2 className={DETAIL_TITLE}>Preferences</h2>
          <p className="mt-1 text-[12px] text-text-muted">
            Domain-only overrides. Pickers apply on the next reload of this domain; global defaults still apply when these are unset.
          </p>
        </div>
        <button
          onClick={() => {
            for (const k of [cliKey, modelKey, fwKey, lensKey, autoStateKey, `prevail.domain.${domain}.skills`, localOnlyKey, sandboxKey, keywordsKey]) {
              lsSet(k, "");
            }
            // Clear the manifest config overrides too.
            persistManifest({ cli: null, model: null, framework: null, lens: null, autoState: true, skills: [] });
            persistManifestTop({ privacy: { localOnly: false }, sandbox: { mode: "open" }, routing: { keywords: [] } });
            force();
          }}
          className="shrink-0 text-[12px] text-text-muted hover:text-warn"
        >
          Reset all
        </button>
      </div>

      {/* CLI picker - select a CLI to expand its models inline (collapse & indent) */}
      <PrefSection
        title="CLI"
        icon={<Terminal className="h-4 w-4" />}
        subtitle={pickedCli ? titleCase(pickedCli) : "Global default"}
        right={pickedCli ? (
          <button
            onClick={() => { setOverride(cliKey, ""); setOverride(modelKey, ""); }}
            className="text-[12px] text-text-muted hover:text-accent"
          >
            Use global
          </button>
        ) : undefined}
      >
        <p className="mb-3 text-[12px] text-text-muted">Which runtime runs every prompt in {titleCase(domain)}. Pick a provider, then its model.</p>
        {/* List rows; the selected CLI expands to show its models indented below. */}
        <div className="flex flex-col gap-1.5">
          {clis.filter((c) => !isBunkerOn() || isLocalCli(c.id)).map((c) => {
            const picked = pickedCli === c.id;
            const disabled = !c.available;
            const models = modelsFor(c.id);
            const expanded = expandedCli === c.id;
            return (
              <div key={c.id}>
                <button
                  disabled={disabled}
                  onClick={() => { setOverride(cliKey, c.id); setExpandedCli(c.id); }}
                  title={disabled ? `${c.label} not installed` : c.label}
                  className={`group flex w-full items-center gap-2 rounded-md px-3 py-2 text-left transition-colors ${
                    picked ? "bg-surface-warm" : disabled ? "opacity-40" : "hover:bg-surface-warm/50"
                  }`}
                >
                  {/* Expand chevron on the LEFT - toggles the model list without
                      changing the selection. Hidden when there are no models. */}
                  {!disabled && models.length > 0 ? (
                    <span
                      role="button"
                      tabIndex={0}
                      aria-label={expanded ? "Collapse models" : "Expand models"}
                      title={expanded ? "Collapse models" : "Expand models"}
                      onClick={(e) => { e.stopPropagation(); setExpandedCli((v) => (v === c.id ? null : c.id)); }}
                      onKeyDown={(e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); e.stopPropagation(); setExpandedCli((v) => (v === c.id ? null : c.id)); } }}
                      className="-ml-0.5 flex h-5 w-5 shrink-0 items-center justify-center rounded text-text-muted transition-colors hover:text-accent"
                    >
                      <ChevronDown className={`h-3.5 w-3.5 transition-transform ${expanded ? "" : "-rotate-90"}`} strokeWidth={2.5} />
                    </span>
                  ) : (
                    <span className="h-5 w-5 shrink-0" />
                  )}
                  <ProviderMark vendor={c.id} size={22} />
                  <span className={`flex-1 text-[14px] ${picked ? "font-semibold text-text-primary" : "font-medium text-text-primary"}`}>
                    {c.label}
                  </span>
                  {disabled && (
                    <span className="text-[12px] text-text-muted">Not installed</span>
                  )}
                  {picked && <Check className="h-4 w-4 shrink-0 text-accent" strokeWidth={2.5} />}
                </button>
                {/* Models - indented under the expanded CLI, collapsed otherwise.
                    Expansion is independent of selection (expandedCli, not picked). */}
                {expanded && models.length > 0 && (() => {
                  const curated = curatedFor(c.id);
                  const searchable = models.length > curated.length;
                  const q = (modelSearch[c.id] ?? "").trim().toLowerCase();
                  const shown = q
                    ? models.filter((m) => `${m.id} ${m.label ?? ""}`.toLowerCase().includes(q)).slice(0, 50)
                    : (searchable ? curated : models);
                  return (
                  <div className="ml-4 mt-1 flex flex-col gap-0.5 border-l border-border-subtle pl-4">
                    <div className="flex items-center justify-between pt-0.5">
                      <span className="text-[12px] font-semibold text-text-secondary">Model</span>
                      {pickedModel && (
                        <button
                          onClick={() => setOverride(modelKey, "")}
                          className="text-[12px] text-text-muted hover:text-accent"
                        >
                          Use the runtime default
                        </button>
                      )}
                    </div>
                    {searchable && (
                      <input
                        value={modelSearch[c.id] ?? ""}
                        onChange={(e) => setModelSearch((s) => ({ ...s, [c.id]: e.target.value }))}
                        placeholder={`Search all ${models.length} ${c.label} models…`}
                        className="w-full rounded-md border border-border bg-background px-2.5 py-1 text-[12px] focus:border-accent-border focus:outline-none"
                      />
                    )}
                    {shown.length === 0 && <span className="text-[12px] text-text-muted">No models match "{q}".</span>}
                    {shown.map((m) => {
                      const mpicked = pickedModel === m.id;
                      return (
                        <button
                          key={m.id}
                          onClick={() => setOverride(modelKey, m.id)}
                          className={`flex items-center gap-3 rounded-md px-3 py-1.5 text-left transition-colors ${
                            mpicked ? "bg-surface-warm" : "hover:bg-surface-warm/50"
                          }`}
                        >
                          <span className={`shrink-0 text-[14px] ${mpicked ? "font-semibold text-text-primary" : "text-text-primary"}`}>{m.label}</span>
                          {m.blurb && <span className="min-w-0 flex-1 truncate text-[12px] text-text-muted">{m.blurb}</span>}
                          {mpicked && (
                            <Check className="ml-auto h-4 w-4 shrink-0 text-accent" strokeWidth={2.5} />
                          )}
                        </button>
                      );
                    })}
                    {!q && searchable && (
                      <span className="text-[12px] text-text-muted">+{models.length - shown.length} more · search to pick any model</span>
                    )}
                  </div>
                  );
                })()}
              </div>
            );
          })}
        </div>
      </PrefSection>

      {/* Framework + Lens - stacked full-width, one per row */}
      <PrefSection title="Framework & Lens" icon={<Compass className="h-4 w-4" />} subtitle={[pickedFw && pickedFw !== "none" ? "framework" : "", pickedLens && pickedLens !== "none" ? "lens" : ""].filter(Boolean).join(" + ") || "none set"}>
        <div className="grid grid-cols-1 gap-4">
          <PrefPickerColumn
            title="Framework"
            options={FRAMEWORKS as readonly { id: string; label: string; blurb: string }[]}
            selected={pickedFw}
            onSelect={(id) => setOverride(fwKey, id)}
            onClear={() => setOverride(fwKey, "")}
          />
          <PrefPickerColumn
            title="Lens"
            options={LENSES as readonly { id: string; label: string; blurb: string }[]}
            selected={pickedLens}
            onSelect={(id) => setOverride(lensKey, id)}
            onClear={() => setOverride(lensKey, "")}
          />
        </div>
      </PrefSection>

      {/* Skills - star-toggle list with avatars; collapsed by default, indented when open */}
      <section className="border-b border-border-subtle">
        <button
          onClick={() => setSkillsOpen((v) => !v)}
          className="flex w-full items-center gap-2.5 py-3 text-left"
        >
          <ChevronRight className={`h-3.5 w-3.5 shrink-0 text-text-muted transition-transform ${skillsOpen ? "rotate-90" : ""}`} strokeWidth={2.5} />
          <span className="flex-1 text-[14px] font-medium text-text-primary">Skills</span>
          <span className="text-[12px] text-text-muted">{preferredSkills.length} pinned of {skills.length}</span>
        </button>
        {skillsOpen && (skills.length === 0 ? (
          <p className="pb-4 pl-6 text-[12px] text-text-muted">No skills in {titleCase(domain)} yet.</p>
        ) : (
          <ul className="pb-4 pl-6">
            <li className="pb-1 text-[12px] text-text-muted">Pinned skills auto-attach to every new chat in {titleCase(domain)}.</li>
            {skills.map((s) => {
              const on = preferredSkills.includes(s.name);
              const color = pickSkillColor(s.name);
              return (
                <li key={s.path} className="group flex items-center gap-3 border-b border-border-subtle py-2 last:border-b-0">
                  <span
                    className="flex h-8 w-8 shrink-0 items-center justify-center rounded-md font-display text-sm font-bold ring-1 ring-black/5"
                    style={{ background: color.bg, color: color.fg }}
                  >
                    {(s.name || "·").charAt(0).toUpperCase()}
                  </span>
                  <div className="min-w-0 flex-1">
                    <div className="text-[14px] font-medium text-text-primary">/{s.name}</div>
                    {s.description && <div className="line-clamp-1 text-[12px] text-text-muted">{s.description}</div>}
                  </div>
                  <button
                    onClick={() => onTogglePreferredSkill(s.name)}
                    title={on ? "Pinned: auto-attaches. Click to unpin" : "Pin: auto-attach to new chats"}
                    aria-label={on ? `Unpin ${s.name}` : `Pin ${s.name}`}
                    aria-pressed={on}
                    className={`flex h-7 w-7 shrink-0 items-center justify-center rounded-md hover:bg-surface-warm ${on ? "text-accent" : `text-text-muted hover:text-accent ${REVEAL}`}`}
                  >
                    <Pin className={`h-3.5 w-3.5 ${on ? "fill-current" : ""}`} />
                  </button>
                </li>
              );
            })}
          </ul>
        ))}
      </section>

      {/* Behavior toggles */}
      <PrefSection title="Behavior" icon={<SlidersHorizontal className="h-4 w-4" />} subtitle={autoState ? "Auto-attach on" : "Manual"}>
        <div className="flex items-center justify-between gap-3 py-2">
          <div>
            <div className="text-[14px] font-medium text-text-primary">Auto-attach state.md</div>
            <div className="mt-0.5 text-[12px] text-text-muted">
              {autoState
                ? "Each new chat starts with state.md as a context chip you can remove."
                : "Manual: drag the domain in or use the Context drawer to attach state.md."}
            </div>
          </div>
          <Toggle
            on={autoState}
            onChange={(v) => { lsSet(autoStateKey, v ? "1" : "0"); persistManifest({ autoState: v }); force(); }}
            label="Auto-attach state.md"
          />
        </div>
      </PrefSection>

      {/* Privacy - local-only (Ollama) pin → manifest.privacy.localOnly */}
      <PrefSection title="Privacy" icon={<Lock className="h-4 w-4" />} subtitle={localOnly ? "Local only" : "Standard"}>
        <div className="flex items-center justify-between gap-3 py-2">
          <div>
            <div className="text-[14px] font-medium text-text-primary">Local-only (Ollama)</div>
            <div className="mt-0.5 text-[12px] text-text-muted">
              {localOnly
                ? "Every prompt in this domain is forced through a local model: nothing leaves your machine."
                : "Off: prompts use the domain's configured CLI, which may call a cloud model."}
            </div>
          </div>
          <Toggle
            on={localOnly}
            onChange={(v) => {
              lsSet(localOnlyKey, v ? "1" : "0");
              persistManifestTop({ privacy: { localOnly: v } });
              force();
            }}
            label="Local-only (Ollama)"
          />
        </div>
      </PrefSection>

      {/* Sandbox - open | locked → manifest.sandbox.mode */}
      <PrefSection title="Sandbox" icon={<Box className="h-4 w-4" />} subtitle={sandboxMode === "locked" ? "Locked: read-only" : "Open: read + write"}>
        <div className="flex items-center justify-between gap-3">
          <p className="text-[13px] text-text-secondary">
            {sandboxMode === "locked"
              ? "Locked: agents can read this domain but cannot write files or run shell side-effects."
              : "Open: agents can read and write within this domain's folder."}
          </p>
          <select
            value={sandboxMode}
            onChange={(e) => {
              const v = e.target.value === "locked" ? "locked" : "open";
              lsSet(sandboxKey, v);
              persistManifestTop({ sandbox: { mode: v } });
              force();
            }}
            className="rounded-md border border-border bg-background px-3 py-1.5 text-sm focus:border-accent-border focus:outline-none"
          >
            <option value="open">Open</option>
            <option value="locked">Locked</option>
          </select>
        </div>
      </PrefSection>

      {/* M6: per-domain Ideal State - this domain's own target, layered under the
          global Ideal State (which wins on conflict). Injected into this domain's
          turns by the engine. */}
      <PrefSection
        title="Ideal state"
        icon={<Compass className="h-4 w-4" />}
        subtitle={domainIdeal.trim() ? "set" : "not set"}
      >
        {/* One per-domain target (ideal-state.md). The SAME field the Loops page
            uses as its gap-target; grounds every chat in this domain. */}
        <p className="mb-2.5 text-[12px] text-text-muted">
          What a thriving <span className="font-medium text-text-secondary">{titleCase(domain)}</span> looks like. Grounds every {titleCase(domain)} chat (under your global Ideal State) and is the target every {titleCase(domain)} loop closes the gap to. One target, used everywhere.
        </p>
        <div className="rounded-md border border-border bg-background transition-colors focus-within:border-accent-border">
          <textarea
            value={domainIdeal}
            onChange={(e) => setDomainIdeal(e.target.value)}
            placeholder={`e.g. "${titleCase(domain)}: thriving, resilient, and on a clear upward path." Or let AI draft it from what it knows about your ${titleCase(domain)}.`}
            rows={4}
            disabled={draftingIdeal}
            className="w-full resize-y bg-transparent px-2.5 py-2 text-sm leading-relaxed text-text-primary outline-none placeholder:text-text-muted/70 disabled:opacity-60"
          />
        </div>
        <div className="mt-2.5 flex items-center gap-2">
          <button onClick={saveDomainIdeal} disabled={draftingIdeal} className="inline-flex h-8 items-center gap-1.5 rounded-md bg-accent px-3 text-[13px] font-medium text-on-accent hover:bg-accent-hover disabled:opacity-50">
            <Check className="h-3.5 w-3.5" /> Save
          </button>
          <button onClick={draftIdealWithAI} disabled={draftingIdeal}
            title={`Draft from what Glyph Studio knows about your ${titleCase(domain)} - review before saving`}
            className="inline-flex items-center gap-1.5 px-2 text-[13px] font-medium text-accent hover:underline disabled:opacity-50">
            {draftingIdeal ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <Sparkles className="h-3.5 w-3.5" />}
            {draftingIdeal ? "Drafting…" : domainIdeal.trim() ? "Redraft with AI" : "Draft with AI"}
          </button>
          {domainIdealSaved && <span className="inline-flex items-center gap-1 text-[12px] text-ok"><Check className="h-3 w-3" /> saved</span>}
        </div>
        {draftErr && <p className="mt-2 text-[12px] text-warn">{draftErr}</p>}
      </PrefSection>

      {/* Channels / routing - domain name is always matched (A6); the input
          holds extra keywords → manifest.routing.keywords = [domain, ...extras] */}
      <PrefSection
        title="Channels & routing"
        icon={<Share2 className="h-4 w-4" />}
        subtitle={(() => { const n = 1 + keywordsRaw.split(",").map((s) => s.trim()).filter(Boolean).length; return `${n} keyword${n === 1 ? "" : "s"}`; })()}
      >
        <p className="mb-3 text-[12px] text-text-muted">
          When a bridge (e.g. Telegram) receives a message, these keywords route it to {titleCase(domain)}.
          The domain name always matches; add extras below. Saved to the domain manifest.
        </p>
        <div className="mb-2 flex items-center gap-2">
          <span className="inline-flex items-center gap-1 rounded-full border border-accent-border bg-accent-soft px-2.5 py-1 font-mono text-xs text-accent" title="Always matched: the domain name is a built-in keyword">
            <Pin className="h-3 w-3" /> {domain.toLowerCase()}
          </span>
          <span className="text-[12px] text-text-muted">Always on</span>
        </div>
        <input
          defaultValue={keywordsRaw}
          key={`kw-${domain}-${manifestReady ? 1 : 0}`}
          placeholder="extra keywords: invoices, taxes, deductions…"
          onBlur={(e) => {
            const extras = e.target.value
              .split(",")
              .map((s) => s.trim())
              .filter(Boolean)
              .filter((k) => k.toLowerCase() !== domain.toLowerCase());
            lsSet(keywordsKey, extras.join(", "));
            // Persist the domain name as the first keyword so routing always
            // matches it even when the user adds none.
            const full = [domain.toLowerCase(), ...extras].filter(
              (k, i, a) => a.indexOf(k) === i,
            );
            persistManifestTop({ routing: { keywords: full } });
            force();
          }}
          className="w-full rounded-md border border-border bg-background px-3 py-2 font-mono text-sm focus:border-accent-border focus:outline-none"
          spellCheck={false}
        />
        <div className="mt-2 text-[12px] text-text-muted">
          Edits save when the field loses focus.
        </div>
      </PrefSection>

      <PrefSection title="Routines" icon={<Cpu className="h-4 w-4" />} subtitle={`${[daemonTaskgen, daemonReminders, daemonSkillgen].filter(Boolean).length}/3 on`}>
        <p className="mb-2.5 text-[12px] text-text-muted">
          Background work Glyph Studio does for {titleCase(domain)} on its own, even when the app is closed.
        </p>
        <div>
          {([
            { on: daemonTaskgen, set: setDaemonTaskgen, key: "taskgen", icon: ChevronRight, title: "Task generation", desc: "Proactively writes tasks for this domain from your goals and memory." },
            { on: daemonReminders, set: setDaemonReminders, key: "reminders", icon: Cpu, title: "Reminders", desc: "Fires a notification when tasks in this domain are due or overdue." },
            { on: daemonSkillgen, set: setDaemonSkillgen, key: "skillgen", icon: Sparkles, title: "Skill learning", desc: "Distills reusable skills from this domain's conversations as you use it." },
          ] as const).map((r) => {
            const Icon = r.icon;
            return (
              <div key={r.key} className="flex items-start gap-3 border-b border-border-subtle py-2.5 last:border-b-0">
                <Icon className="mt-0.5 h-4 w-4 shrink-0 text-text-muted" />
                <div className="min-w-0 flex-1">
                  <div className="text-[14px] font-medium text-text-primary">{r.title}</div>
                  <div className="mt-0.5 text-[12px] text-text-muted">{r.desc}</div>
                </div>
                <Toggle on={r.on} onChange={(v) => { r.set(v); saveDaemonCfg({ [r.key]: v }); }} />
              </div>
            );
          })}
        </div>
      </PrefSection>
    </div>
  );
}

// The one way into the in-flow Context view from a chat or council column.
export function ContextButton({ onClick }: { onClick: () => void }) {
  return (
    <button
      data-testid="open-context"
      onClick={onClick}
      title="Show this domain's context"
      className="inline-flex h-8 shrink-0 items-center gap-1.5 rounded-md px-2 text-[13px] text-text-muted transition-colors hover:bg-surface-warm hover:text-text-primary"
    >
      <Layers className="h-3.5 w-3.5" /> Context
    </button>
  );
}
