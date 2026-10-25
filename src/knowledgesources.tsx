// Settings > Connections > Knowledge sources: what Prevail reads when it
// briefs and updates the owner. One place to add them (paste a link, a folder
// or a database, or say it in a sentence; the Fields toggle shows what was
// understood), see what each check found, and choose what each is used for.
// The engine probes, reads and enforces every limit (`prevail sources`); a
// password or key goes to the Keychain from here and never anywhere else.
// Linked from Playbooks, a domain's context and a project's Setup
// (SourcesInUse below).
import { useMemo, useState } from "react";
import { Archive, ArrowRight, Check, ChevronDown, ChevronRight, Database, FolderOpen, Globe, Library, Loader2, Plug, Plus, RefreshCw, ShieldCheck, SlidersHorizontal, TriangleAlert, type LucideIcon } from "lucide-react";
import { invoke, isBrowser } from "./bridge";
import { invalidateQueries, useInvokeQuery } from "./query";
import { SettingsHeader } from "./sectionutil";
import { TintIcon } from "./tint";
import { BODY, META, ROW_TITLE, SECTION_TITLE } from "./typescale";
import { REVEAL, RowMenu, Toggle } from "./ui";
import { relTime } from "./format";
import { label } from "./plansmodel";
import {
  KIND_HINT, KIND_LABEL, KIND_PLACEHOLDER, guessSource, secretName, shortLocation, sourcesInUse, splitSecret, useLine,
  type AddResult, type KnowledgeKind, type KnowledgeSource,
} from "./knowledgemodel";

export const KIND_ICON: Record<KnowledgeKind, LucideIcon> = { mcp: Plug, web: Globe, folder: FolderOpen, database: Database };
const KINDS: KnowledgeKind[] = ["mcp", "web", "folder", "database"];
const A_KIND: Record<KnowledgeKind, string> = { mcp: "an MCP server", web: "a site or feed", folder: "a folder", database: "a database" };
// One public suggestion, one click to add. The engine detects that it is an MCP server.
const SUGGESTED = [{ name: "Context (fru.dev)", text: "https://context.fru.dev/mcp", blurb: "Public data on AI, data and tech: funding, releases, pricing, incidents, kept current." }];

const field = "w-full rounded-lg border border-border bg-background px-3 py-2 text-[14px] text-text-primary placeholder:text-text-muted/70 focus:border-accent-border focus:outline-none";
const iconSm = "flex h-7 w-7 shrink-0 items-center justify-center rounded-md text-text-muted transition-colors hover:bg-surface-warm hover:text-accent disabled:opacity-40";
const textLink = "inline-flex items-center gap-1.5 text-[13px] font-medium text-accent hover:underline disabled:opacity-45 disabled:no-underline";
const primary = "inline-flex h-9 shrink-0 items-center justify-center gap-1.5 rounded-lg bg-accent px-4 text-[13px] font-semibold text-on-accent hover:bg-accent-hover disabled:opacity-45";

const errText = (e: unknown) => String(e).replace(/^Error:\s*/, "");

/** Open this page from anywhere (Playbooks, a domain, a project). */
export function openKnowledgeSources(): void {
  window.dispatchEvent(new CustomEvent("prevail:settings-section", { detail: "knowledge-sources" }));
}

export function useKnowledgeSources(vaultPath: string) {
  return useInvokeQuery<KnowledgeSource[]>("engine_knowledge_sources", vaultPath ? { vault: vaultPath } : null, { staleMs: 30_000 });
}

function KindIcon({ kind }: { kind: KnowledgeKind }) {
  return <TintIcon icon={KIND_ICON[kind] ?? Globe} tint={kind} />;
}

// ── Add: chat first, fields on request ──────────────────────────────────────

function AddSource({ vaultPath, domains, existing, onAdded }: { vaultPath: string; domains: string[]; existing: KnowledgeSource[]; onAdded: () => void }) {
  const [text, setText] = useState("");
  const [fields, setFields] = useState(false);
  const [kind, setKind] = useState<KnowledgeKind | "">("");
  const [location, setLocation] = useState("");
  const [name, setName] = useState("");
  const [key, setKey] = useState("");
  const [briefings, setBriefings] = useState(true);
  const [general, setGeneral] = useState(true);
  const [picked, setPicked] = useState<string[]>([]);
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [done, setDone] = useState<AddResult | null>(null);
  const desktop = !isBrowser();
  const guess = useMemo(() => guessSource(text), [text]);
  const shownKind = (kind || guess.kind || "") as KnowledgeKind | "";

  const openFields = () => {
    // The Fields show what the text was understood as, ready to adjust.
    if (!fields) { setKind(kind || guess.kind || ""); setLocation(location || guess.location || ""); }
    setFields(!fields);
  };

  async function add(input: { text?: string; kind?: KnowledgeKind; location?: string; name?: string; scoped?: boolean }, busyKey: string) {
    setBusy(busyKey); setErr(null); setDone(null);
    try {
      // A password in a Postgres URL, or one typed in the Fields, goes to the
      // Keychain; the engine is asked to look again once it is there.
      const t = splitSecret(input.text ?? "");
      const l = splitSecret(input.location ?? "");
      const secret = key.trim() || t.secret || l.secret;
      let r = await invoke<AddResult>("engine_knowledge_add", {
        vault: vaultPath,
        text: t.text.trim() || null,
        kind: input.kind ?? null,
        location: l.text.trim() || null,
        name: input.name?.trim() || null,
        ...(input.scoped ? { briefings, general, domains: picked, projects: null } : {}),
      });
      if (secret && r?.source?.id) {
        await invoke("app_secret_set", { name: secretName(r.source.id), value: secret });
        r = await invoke<AddResult>("engine_knowledge_check", { vault: vaultPath, id: r.source.id });
      }
      setDone(r);
      setText(""); setKey("");
      invalidateQueries("engine_knowledge_sources");
      onAdded();
    } catch (e) { setErr(errText(e)); } finally { setBusy(null); }
  }

  const submit = () => {
    if (fields) void add({ text: text.trim() && !location.trim() ? text : undefined, kind: shownKind || undefined, location: location || undefined, name, scoped: true }, "form");
    else void add({ text }, "form");
  };
  const ready = fields ? !!(location.trim() || text.trim()) : !!text.trim();
  const suggestions = SUGGESTED.filter((s) => !done && !existing.some((r) => r.urls.includes(s.text) || r.location === s.text));

  return (
    <section aria-label="Add a source" data-testid="knowledge-add" className="space-y-3">
      <div className="flex items-start gap-2">
        <textarea data-testid="knowledge-text" rows={1} value={text} onChange={(e) => setText(e.target.value)}
          onKeyDown={(e) => { if (e.key === "Enter" && !e.shiftKey && ready && desktop && !busy) { e.preventDefault(); submit(); } }}
          placeholder="Paste a link, a folder or a database, or describe it" aria-label="A link, a folder or a database, or a sentence about it"
          className={`${field} min-h-[38px] max-h-40 resize-none [field-sizing:content]`} />
        <button type="button" className={primary} data-testid="knowledge-submit" disabled={!desktop || !ready || !!busy} onClick={submit}>
          {busy === "form" ? <Loader2 className="h-4 w-4 animate-spin" /> : <Plus className="h-4 w-4" />} Add
        </button>
      </div>
      <div className="flex flex-wrap items-center gap-x-4 gap-y-1">
        <p className={`${META} min-w-0 flex-1`}>
          {guess.kind ? <>Looks like {A_KIND[guess.kind]}. Glyph Studio checks it before it is used.</> : <>For example: a feed for your wealth briefings, or ~/Documents/foo-notes.</>}
        </p>
        <button type="button" className={textLink} aria-expanded={fields} data-testid="knowledge-fields-toggle" onClick={openFields}>
          <SlidersHorizontal className="h-3.5 w-3.5" /> Fields
        </button>
      </div>

      {fields && (
        <div data-testid="knowledge-fields" className="space-y-3 border-l-2 border-border-subtle pl-4">
          <div role="radiogroup" aria-label="Kind" className="flex flex-wrap gap-1.5">
            {KINDS.map((k) => (
              <button key={k} type="button" role="radio" aria-checked={shownKind === k} data-testid={`knowledge-kind-${k}`} onClick={() => setKind(k)}
                className={`inline-flex h-8 items-center gap-1.5 rounded-md px-2.5 text-[13px] ${shownKind === k ? "bg-surface-warm font-semibold text-text-primary" : "text-text-muted hover:text-text-secondary"}`}>
                <TintIcon icon={KIND_ICON[k]} tint={k} square={false} /> {KIND_LABEL[k]}
              </button>
            ))}
          </div>
          {shownKind && <p className={META}>{KIND_HINT[shownKind]}</p>}
          <input aria-label="Where it is" data-testid="knowledge-location" value={location} onChange={(e) => setLocation(e.target.value)} placeholder={KIND_PLACEHOLDER[shownKind || "web"]} className={field} />
          <input aria-label="Name" data-testid="knowledge-name" value={name} onChange={(e) => setName(e.target.value)} placeholder="Name (optional; taken from the source)" className={field} />
          {(shownKind === "mcp" || shownKind === "database") && (
            <input type="password" autoComplete="off" aria-label="Password or key" data-testid="knowledge-key" value={key} onChange={(e) => setKey(e.target.value)} placeholder="Password or key, if it needs one (kept in your Keychain)" className={field} />
          )}
          <div className="flex flex-wrap items-center gap-x-5 gap-y-2">
            <span className="inline-flex items-center gap-2 text-[13px] text-text-secondary"><Toggle on={briefings} label="Briefings read it" onChange={setBriefings} /> Briefings</span>
            <span className="inline-flex items-center gap-2 text-[13px] text-text-secondary"><Toggle on={general} label="The chief of staff uses it" onChange={setGeneral} /> Chief of staff</span>
          </div>
          {domains.length > 0 && (
            <div className="flex flex-wrap gap-1.5" aria-label="Domains">
              {domains.map((d) => {
                const on = picked.includes(d);
                return (
                  <button key={d} type="button" aria-pressed={on} onClick={() => setPicked(on ? picked.filter((x) => x !== d) : [...picked, d])}
                    className={`h-7 rounded-md px-2 text-[12px] ${on ? "bg-accent-soft font-semibold text-accent" : "bg-surface-warm text-text-muted hover:text-text-secondary"}`}>{label(d)}</button>
                );
              })}
            </div>
          )}
        </div>
      )}

      {err && <p data-testid="knowledge-error" className="flex items-start gap-2 text-[13px] text-err"><TriangleAlert className="mt-0.5 h-4 w-4 shrink-0" /><span className="min-w-0 break-words">{err}</span></p>}
      {done && (
        <div data-testid="knowledge-result" className="flex items-start gap-3">
          <KindIcon kind={done.source.kind} />
          <div className="min-w-0 flex-1">
            <p className={`${ROW_TITLE} truncate`}>{done.source.name} {done.adopted ? "checked again" : "added"}</p>
            <p className={`text-[12px] ${done.probe.ok ? "text-text-muted" : "text-err"}`} data-testid="knowledge-found">
              {[done.detected ? `Found ${done.detected}` : KIND_LABEL[done.source.kind], done.found, `used for ${useLine(done.source).toLowerCase()}`].filter(Boolean).join(" · ")}
            </p>
          </div>
          {done.probe.ok ? <Check className="mt-0.5 h-4 w-4 shrink-0 text-ok" aria-label="Ready" /> : <TriangleAlert className="mt-0.5 h-4 w-4 shrink-0 text-err" aria-label="Not readable yet" />}
        </div>
      )}

      {suggestions.map((s) => (
        <div key={s.text} data-testid="knowledge-suggested" className="group flex items-center gap-3 py-1">
          <KindIcon kind="mcp" />
          <div className="min-w-0 flex-1">
            <p className={`${ROW_TITLE} truncate`}>{s.name}</p>
            <p className={`${META} line-clamp-1`} title={s.blurb}>Suggested · {s.blurb}</p>
          </div>
          <button type="button" className={textLink} disabled={!desktop || !!busy} onClick={() => void add({ text: s.text, name: s.name }, s.text)}>
            {busy === s.text ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <Plus className="h-3.5 w-3.5" />} Add
          </button>
        </div>
      ))}
    </section>
  );
}

// ── One source: a quiet row, more on a click ────────────────────────────────

function SourceRow({ s, vaultPath, domains, onChanged }: { s: KnowledgeSource; vaultPath: string; domains: string[]; onChanged: () => void }) {
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const desktop = !isBrowser();
  const run = async (k: string, f: () => Promise<unknown>) => {
    setBusy(k); setErr(null);
    try { await f(); invalidateQueries("engine_knowledge_sources"); onChanged(); } catch (e) { setErr(errText(e)); } finally { setBusy(null); }
  };
  const check = () => run("check", () => invoke("engine_knowledge_check", { vault: vaultPath, id: s.id }));
  const use = (patch: { briefings?: boolean; general?: boolean; domains?: string[] }) => run("use", () => invoke("engine_knowledge_use", { vault: vaultPath, id: s.id, briefings: patch.briefings ?? null, general: patch.general ?? null, domains: patch.domains ?? null, projects: null }));
  const archive = () => run("archive", () => invoke("engine_knowledge_remove", { vault: vaultPath, id: s.id }));
  const away = s.status === "untrusted_here";
  const meta = away
    ? ["Added on another Mac", "not read here until you trust it"]
    : [KIND_LABEL[s.kind], useLine(s), s.status === "error" ? `Could not read it${s.detail ? `: ${s.detail}` : ""}` : s.found ?? "", s.last_checked ? `checked ${relTime(s.last_checked)}` : ""];
  return (
    <li data-testid="knowledge-row" data-id={s.id} data-status={s.status} className="group border-b border-border-subtle py-2.5 last:border-b-0">
      <div className="flex items-start gap-3">
        <KindIcon kind={s.kind} />
        <button type="button" className="min-w-0 flex-1 text-left" aria-expanded={open} data-testid="knowledge-open" onClick={() => setOpen(!open)}>
          <p className={`${ROW_TITLE} line-clamp-2 break-words`} title={s.location}>{s.name}</p>
          <p className={`mt-0.5 line-clamp-1 text-[12px] ${s.status === "error" ? "text-err" : "text-text-muted"}`} title={meta.filter(Boolean).join(" · ")}>{meta.filter(Boolean).join(" · ")}</p>
        </button>
        <span className={`flex shrink-0 items-center gap-0.5 ${away ? "" : REVEAL}`}>
          {away ? (
            <button type="button" className={textLink} disabled={!desktop || !!busy} data-testid="knowledge-trust" onClick={() => void check()}>
              {busy === "check" ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <ShieldCheck className="h-3.5 w-3.5" />} Trust on this Mac
            </button>
          ) : (
            <button type="button" className={iconSm} title="Check again" aria-label={`Check ${s.name} again`} data-testid="knowledge-check" disabled={!desktop || !!busy} onClick={() => void check()}>
              {busy === "check" ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <RefreshCw className="h-3.5 w-3.5" />}
            </button>
          )}
          {desktop && (
            <RowMenu label={`More for ${s.name}`} items={[
              ...(away ? [] : [
                { icon: ArrowRight, label: "Briefings read it", checked: s.scope.briefings, onClick: () => void use({ briefings: !s.scope.briefings }) },
                { icon: ArrowRight, label: "Chief of staff uses it", checked: s.scope.general, onClick: () => void use({ general: !s.scope.general }) },
                { kind: "separator" as const },
              ]),
              { icon: Archive, label: "Archive", hint: "Moves it to the archive; nothing is deleted", onClick: () => void archive() },
            ]} />
          )}
        </span>
      </div>
      {err && <p className="mt-1.5 pl-[34px] text-[13px] text-err">{err}</p>}
      {open && (
        <div data-testid="knowledge-detail" className="mt-2 space-y-2.5 pl-[34px]">
          <p className={`${BODY} break-all text-text-secondary`} title={s.location}>{shortLocation(s)}</p>
          {s.found && <p className={META}>{s.found}</p>}
          {!away && (
            <>
              <div className="flex flex-wrap items-center gap-x-5 gap-y-2">
                <span className="inline-flex items-center gap-2 text-[13px] text-text-secondary"><Toggle on={s.scope.briefings} disabled={!desktop || !!busy} label="Briefings read it" onChange={(v) => void use({ briefings: v })} /> Briefings</span>
                <span className="inline-flex items-center gap-2 text-[13px] text-text-secondary"><Toggle on={s.scope.general} disabled={!desktop || !!busy} label="The chief of staff uses it" onChange={(v) => void use({ general: v })} /> Chief of staff</span>
              </div>
              {domains.length > 0 && (
                <div className="flex flex-wrap gap-1.5" aria-label={`Domains ${s.name} serves`}>
                  {domains.map((d) => {
                    const on = s.scope.domains.includes(d);
                    return (
                      <button key={d} type="button" aria-pressed={on} disabled={!desktop || !!busy} onClick={() => void use({ domains: on ? s.scope.domains.filter((x) => x !== d) : [...s.scope.domains, d] })}
                        className={`h-7 rounded-md px-2 text-[12px] ${on ? "bg-accent-soft font-semibold text-accent" : "bg-surface-warm text-text-muted hover:text-text-secondary"}`}>{label(d)}</button>
                    );
                  })}
                </div>
              )}
              {s.scope.projects.length > 0 && <p className={META}>Projects: {s.scope.projects.map(label).join(", ")}</p>}
            </>
          )}
        </div>
      )}
    </li>
  );
}

export function KnowledgeSourcesSection({ vaultPath }: { vaultPath: string }) {
  const q = useKnowledgeSources(vaultPath);
  const doms = useInvokeQuery<{ name: string }[]>("scan_vault", vaultPath ? { path: vaultPath } : null, { staleMs: 60_000 });
  const domains = useMemo(() => (Array.isArray(doms.data) ? doms.data.map((d) => d.name).filter((d) => d !== "general" && !d.startsWith("_")) : []), [doms.data]);
  const rows = Array.isArray(q.data) ? q.data : [];
  const refresh = () => { void q.refresh(); };
  return (
    <div data-testid="knowledge-sources" className="space-y-6">
      <SettingsHeader title="Knowledge sources" icon={Library} tint="knowledge"
        subtitle="What Glyph Studio reads when it briefs and updates you: MCP servers, sites and feeds, folders, databases. Read only." />
      <AddSource vaultPath={vaultPath} domains={domains} existing={rows} onAdded={refresh} />
      <section aria-label="Your sources">
        <h3 className={`${SECTION_TITLE} mb-1`}>Your sources{rows.length ? <span className="ml-2 text-[12px] font-normal text-text-muted">{rows.length}</span> : null}</h3>
        {q.error && !rows.length ? <p className="text-[13px] text-err">Could not list them: {errText(q.error)}</p>
          : !rows.length ? <p className={META}>{q.loading ? "Reading..." : "None yet. Paste a link or a folder above."}</p>
          : <ul>{rows.map((s) => <SourceRow key={s.id} s={s} vaultPath={vaultPath} domains={domains} onChanged={refresh} />)}</ul>}
      </section>
    </div>
  );
}

/** One quiet line on a playbook, a domain or a project: the sources it reads,
 *  linking to the page where they are added and scoped. */
export function SourcesInUse({ vaultPath, domain, project, briefing = false }: { vaultPath: string; domain?: string; project?: string; briefing?: boolean }) {
  const q = useKnowledgeSources(vaultPath);
  const list = sourcesInUse(Array.isArray(q.data) ? q.data : [], { domain, project, briefing });
  const [open, setOpen] = useState(false);
  return (
    <div data-testid="sources-in-use" className="flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1">
      <TintIcon icon={Library} tint="knowledge" square={false} />
      {list.length ? (
        <button type="button" className={`${META} min-w-0 truncate hover:text-text-secondary`} aria-expanded={open} onClick={() => setOpen(!open)} title={list.map((s) => s.name).join(", ")}>
          {open ? <ChevronDown className="mr-0.5 inline h-3 w-3" /> : <ChevronRight className="mr-0.5 inline h-3 w-3" />}
          Reads {list.length === 1 ? list[0]!.name : `${list.length} knowledge sources`}
        </button>
      ) : <span className={META}>No knowledge sources{briefing ? " for briefings" : ""} here yet</span>}
      <button type="button" className={textLink} data-testid="sources-in-use-open" onClick={openKnowledgeSources}>{list.length ? "Manage" : "Add one"}</button>
      {open && list.length > 1 && (
        <ul className="basis-full space-y-0.5 pl-6">
          {list.map((s) => <li key={s.id} className={`${META} flex items-center gap-1.5`}><TintIcon icon={KIND_ICON[s.kind]} tint={s.kind} square={false} size={12} />{s.name}</li>)}
        </ul>
      )}
    </div>
  );
}
