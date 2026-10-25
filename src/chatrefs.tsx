// @-references in every chat composer, and what a reply says about the apps
// it used. Typing "@" lists apps (connectors and trusted sources), people and
// things, and domains; picking one adds a chip that is sent with every turn
// (--app / --entity / --ref-domain). A reply whose tool calls went to an app
// opens with a small "Used Gmail · 3 reads" chip that leads to that app's
// Activity; engine notes about apps (routed, needs sign-in, unavailable) are
// drawn in the flow of the reply.
import { useEffect, useLayoutEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { AlertTriangle, ExternalLink, KeyRound, Layers, Route, X } from "lucide-react";
import { kindOfId, KINDS } from "./ia";
import { useInvokeQuery } from "./query";
import { SpecialistAvatar } from "./specialistavatar";
import { titleCase } from "./format";
import { lsGet, LS } from "./storage";
import { isUserDomain } from "./helpers";
import { domainIcon } from "./icons";
import { loadEntities, useEntityStore } from "./entitystore";
import { AppLogo, openExternal } from "./appsmirror-parts";
import type { MirrorApp, MirrorList } from "./appsmirror-model";
import { appUseLabel, appUses, openApp, runtimeName, type ChatRef, type RefKind } from "./appscope";
import type { AppNotice, ChatMessage } from "./types";

export const AT_RE = /(^|\s)@([\p{L}\p{N}_.\-/]*)$/u;
export function atMatchAt(input: string, caret: number): { token: string; start: number; end: number } | null {
  const before = input.slice(0, Math.min(caret, input.length));
  const m = before.match(AT_RE);
  if (!m) return null;
  return { token: m[2], start: before.length - m[2].length - 1, end: before.length };
}

// The apps a chat can reference: runtime connectors plus trusted sources.
export function useChatApps(vaultPath: string | null): { id: string; name: string; url?: string; runtime?: string; trusted?: boolean }[] {
  const mirror = useInvokeQuery<MirrorList>("apps_mirror_list", vaultPath ? { vault: vaultPath } : null, { staleMs: Infinity });
  return useMemo(() => (mirror.data?.apps ?? []).filter((a) => a.status !== "untrusted_here").map((a) => ({ id: a.id, name: a.name, url: a.url ?? a.urls?.[0], runtime: a.runtime, trusted: !!a.trusted })), [mirror.data]);
}

export type RefCandidate = ChatRef & { sub?: string; url?: string; entityKind?: string };

export function useRefCandidates(vaultPath: string | null, token: string | null, only: RefKind | null): RefCandidate[] {
  const apps = useChatApps(token !== null ? vaultPath : null);
  const ents = useEntityStore();
  const doms = useInvokeQuery<{ name: string }[]>("scan_vault", token !== null && vaultPath ? { path: vaultPath } : null, { staleMs: 60_000 });
  const specs = useInvokeQuery<{ id: string; name: string; on: boolean; returns: string }[]>("engine_specialists", token !== null && vaultPath ? { vault: vaultPath } : null, { staleMs: 5 * 60_000 });
  const missions = useInvokeQuery<{ slug: string; name: string; status: string; outcome: string }[]>("engine_missions_list", token !== null && vaultPath ? { vault: vaultPath, status: "all" } : null, { staleMs: 60_000 });
  useEffect(() => { if (token !== null && vaultPath) void loadEntities(vaultPath); }, [token !== null, vaultPath]); // eslint-disable-line react-hooks/exhaustive-deps
  return useMemo(() => {
    if (token === null) return [];
    const q = token.toLowerCase();
    const hit = (...xs: (string | undefined)[]) => !q || xs.some((x) => x && x.toLowerCase().includes(q));
    const a: RefCandidate[] = apps.filter((x) => hit(x.name, x.id)).slice(0, 5)
      .map((x) => ({ kind: "app", id: x.id, label: x.name, url: x.url, sub: x.trusted ? "Trusted source" : x.runtime ? `App via ${runtimeName(x.runtime)}` : "App" }));
    // People, places, products, things and events, each under its kind (ia.ts), a few of each.
    const order = (k: string) => { const i = ENTITY_ORDER.indexOf(k); return i < 0 ? 99 : i; };
    const perKind = new Map<string, number>();
    const e: RefCandidate[] = (ents.list?.entities ?? []).filter((x) => x.kind !== "project" && hit(x.name, ...x.aliases))
      .sort((x, y) => order(x.kind) - order(y.kind) || Number(y.saved) - Number(x.saved) || y.mention_count - x.mention_count)
      .filter((x) => { const n = perKind.get(x.kind) ?? 0; perKind.set(x.kind, n + 1); return n < (q ? 4 : 3); })
      .map((x) => ({ kind: "entity", id: x.id, label: x.name, entityKind: x.kind, sub: ENTITY_KIND[x.kind] ?? "Entity" }));
    const d: RefCandidate[] = (Array.isArray(doms.data) ? doms.data : []).map((x) => x.name).filter(isUserDomain).filter((x) => hit(x, titleCase(x))).slice(0, 5)
      .map((x) => ({ kind: "domain", id: x, label: titleCase(x), sub: "Domain" }));
    // Specialists: picking one hands the message to it ("@Researcher ...").
    const s: RefCandidate[] = (Array.isArray(specs.data) ? specs.data : []).filter((x) => x.on && hit(x.name, x.id)).slice(0, 6)
      .map((x) => ({ kind: "specialist", id: x.id, label: x.name, sub: `Specialist, returns ${x.returns}` }));
    // Missions: the active ones; an @ mission brings a short brief of it.
    const m: RefCandidate[] = (Array.isArray(missions.data) ? missions.data : []).filter((x) => x.status === "active" && hit(x.name, x.slug)).slice(0, 4)
      .map((x) => ({ kind: "mission", id: x.slug, label: x.name, sub: x.outcome ? `Project: ${x.outcome}` : "Project" }));
    if (only === "app") return a;
    if (only === "entity") return e;
    if (only === "specialist") return s;
    if (only === "mission") return m;
    // Activities first (events, then projects), then the entities with apps among the products.
    const ev = e.filter((x) => x.entityKind === "event");
    const rest = e.filter((x) => x.entityKind !== "event");
    const products = rest.findIndex((x) => order(x.entityKind ?? "") > order("org"));
    const withApps = products < 0 ? [...rest, ...a] : [...rest.slice(0, products), ...a, ...rest.slice(products)];
    return [...s, ...ev, ...m, ...withApps, ...d];
  }, [token, only, apps, ents.list, doms.data, specs.data, missions.data]);
}

const ENTITY_KIND: Record<string, string> = { person: "Person", place: "Place", org: "Product", thing: "Thing", event: "Event" };
const ENTITY_ORDER = ["person", "place", "org", "thing", "event"];

function RefIcon({ r, size = 16 }: { r: RefCandidate | ChatRef; size?: number }) {
  if (r.kind === "app") return <AppLogo name={r.label} url={(r as RefCandidate).url} size={size} />;
  if (r.kind === "domain") { const D = domainIcon(r.id) ?? Layers; return <D className="shrink-0 opacity-80" style={{ width: size - 2, height: size - 2 }} />; }
  if (r.kind === "mission") { const P = KINDS.find((k) => k.id === "projects")!.icon; return <P className="shrink-0 opacity-80" style={{ width: size - 2, height: size - 2 }} />; }
  if (r.kind === "specialist") return <SpecialistAvatar id={r.id} size={size + 2} />;
  const k = (r as RefCandidate).entityKind ?? r.id.split("/")[0];
  if (k === "person") {
    const ini = r.label.split(/\s+/).filter(Boolean).slice(0, 2).map((w) => w[0]!.toUpperCase()).join("") || "?";
    return <span aria-hidden className="flex shrink-0 items-center justify-center rounded-full bg-accent/15 font-semibold leading-none text-accent" style={{ width: size, height: size, fontSize: Math.max(8, Math.round(size * 0.45)) }}>{ini}</span>;
  }
  const I = kindOfId(k)?.icon ?? Layers;
  return <I className="shrink-0 opacity-80" style={{ width: size - 2, height: size - 2 }} />;
}

// The @ list speaks the two groups: each kind under its own name.
const GROUP: Record<RefKind, string> = { specialist: "Specialists", mission: "Projects", app: "Products", entity: "Entities", domain: "Domains" };
const groupOf = (r: RefCandidate) => (r.kind === "entity" ? kindOfId(r.entityKind ?? r.id)?.label ?? GROUP.entity : GROUP[r.kind]);

// The suggestion list, anchored above the composer (inside its relative box).
export function RefSuggest({ items, index, onPick, empty }: { items: RefCandidate[]; index: number; onPick: (r: RefCandidate) => void; empty: string }) {
  return (
    <div data-testid="ref-suggest" role="listbox" aria-label="Reference" className="absolute bottom-full left-3 z-40 mb-1 max-h-80 w-80 max-w-[calc(100%-1.5rem)] overflow-y-auto rounded-lg border border-border bg-surface shadow-xl">
      {items.length === 0 ? <div className="px-3 py-2.5 text-[13px] text-text-muted">{empty}</div> : items.map((r, i) => (
        <div key={`${r.kind}:${r.id}`}>
          {(i === 0 || groupOf(items[i - 1]) !== groupOf(r)) && <div className="border-t border-border-subtle bg-surface-warm px-3 py-1 text-[12px] font-medium text-text-muted first:border-t-0">{groupOf(r)}</div>}
          <button type="button" role="option" aria-selected={i === index} data-testid={`ref-option-${r.kind}-${r.id}`}
            onMouseDown={(e) => { e.preventDefault(); onPick(r); }}
            className={`flex w-full items-center gap-2.5 px-3 py-1.5 text-left ${i === index ? "bg-accent-soft" : "hover:bg-surface-warm"}`}>
            <RefIcon r={r} size={18} />
            <span className="min-w-0 flex-1">
              <span className={`block truncate text-[14px] ${i === index ? "text-accent" : "text-text-primary"}`}>{r.label}</span>
              {r.sub && <span className="block truncate text-[12px] text-text-muted">{r.sub}</span>}
            </span>
          </button>
        </div>
      ))}
    </div>
  );
}

// Everything attached to the next send, in ONE chip row above the text:
// context files, @apps, @people and things, @domains and attached files.
// The row never wraps; chips that do not fit fold into a "+N" chip that
// opens the row in place.
export type AttachItem = {
  key: string;
  label: string;
  /** Hover text: the full path or label, and its kind. */
  title: string;
  icon: ReactNode;
  /** Attached for you (auto context): a quieter chip. */
  quiet?: boolean;
  testId?: string;
  onRemove: () => void;
};

/** "extra: Business/state.md" -> "Business state"; "app: Foo" -> "Foo". */
export function shortContextLabel(label: string): string {
  const m = label.match(/^([a-z-]+)(?:\s*\(([^)]*)\))?:\s*(.*)$/i);
  if (!m) return label;
  const qual = m[2] === "entire folder" ? " folder" : m[2] === "full" ? ", full" : "";
  const rest = m[3].replace(/\/state\.md$/i, " state").replace(/\.md$/i, "").replace(/\//g, " ");
  return `${rest}${qual}`.trim() || label;
}

export function refItem(r: ChatRef, onRemove: () => void): AttachItem {
  const kind = r.kind === "app" ? "App" : r.kind === "domain" ? "Domain" : r.kind === "mission" ? "Project" : r.kind === "specialist" ? "Specialist" : kindOfId(r.id)?.singular ?? "Entity";
  return {
    key: `ref:${r.kind}:${r.id}`, label: `@${r.label}`, testId: `ref-chip-${r.kind}`,
    title: r.kind === "specialist" ? `Hands this message to the ${r.label}` : `${kind}: ${r.label}. ${r.kind === "app" ? "Used" : "Comes along"} on every turn`,
    icon: <RefIcon r={r} size={14} />, onRemove,
  };
}

const GAP = 6;
const MORE_W = 40;

export function AttachRow({ items }: { items: AttachItem[] }) {
  const [open, setOpen] = useState(false);
  const [fit, setFit] = useState(items.length);
  const wrap = useRef<HTMLDivElement>(null);
  const probe = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    const measure = () => {
      const w = wrap.current?.clientWidth ?? 0;
      const kids = Array.from(probe.current?.children ?? []) as HTMLElement[];
      if (!w) { setFit(kids.length); return; }
      let used = 0;
      let n = 0;
      for (let i = 0; i < kids.length; i++) {
        const cw = kids[i].offsetWidth + (i ? GAP : 0);
        const reserve = i < kids.length - 1 ? MORE_W + GAP : 0;
        if (used + cw + reserve > w) break;
        used += cw;
        n++;
      }
      setFit(n);
    };
    measure();
    if (typeof ResizeObserver === "undefined" || !wrap.current) return;
    const ro = new ResizeObserver(measure);
    ro.observe(wrap.current);
    // The chips change width when a web font lands after the first measure.
    if (probe.current) ro.observe(probe.current);
    return () => ro.disconnect();
  }, [items]);
  useEffect(() => { if (items.length <= fit) setOpen(false); }, [items.length, fit]);
  if (!items.length) return null;
  const shown = open ? items : items.slice(0, fit);
  const hidden = items.length - shown.length;
  // `probe`: the measuring copy, with no test ids and nothing to focus.
  const chip = (it: AttachItem, probe = false) => (
    <span key={it.key} data-testid={probe ? undefined : it.testId ?? "attach-chip"} title={probe ? undefined : it.title}
      className="inline-flex max-w-[14rem] shrink-0 items-center gap-1 rounded-full border border-accent-border bg-accent-soft py-0.5 pl-1.5 pr-1 text-[12px] font-medium text-accent">
      {it.icon}
      <span className="truncate">{it.label}</span>
      {probe ? <span className="h-3.5 w-3.5 shrink-0" /> : (
        <button type="button" onClick={it.onRemove} aria-label={`Remove ${it.label}`} title={`Remove ${it.label}`}
          className="flex h-3.5 w-3.5 shrink-0 items-center justify-center rounded-full hover:bg-surface-warm hover:text-err"><X className="h-3 w-3" /></button>
      )}
    </span>
  );
  return (
    <div ref={wrap} data-testid="attach-row" className="relative min-w-0 flex-1">
      {/* Off-screen copy of every chip, only to measure what fits. */}
      <div ref={probe} aria-hidden className="pointer-events-none invisible absolute left-0 top-0 flex gap-1.5 whitespace-nowrap">{items.map((it) => chip(it, true))}</div>
      <div className={`flex items-center gap-1.5 ${open ? "flex-wrap" : "flex-nowrap overflow-hidden"}`}>
        {shown.map((it) => chip(it))}
        {hidden > 0 && (
          <button type="button" data-testid="attach-more" onClick={() => setOpen(true)} title={`Show ${hidden} more`}
            className="inline-flex shrink-0 items-center rounded-full border border-border px-2 py-0.5 text-[12px] text-text-secondary hover:border-accent-border hover:text-accent">+{hidden}</button>
        )}
        {open && items.length > fit && (
          <button type="button" onClick={() => setOpen(false)} className="inline-flex shrink-0 items-center rounded-full px-2 py-0.5 text-[12px] text-text-muted hover:text-accent">Less</button>
        )}
      </div>
    </div>
  );
}

function useNames(): (id: string) => { name: string; url?: string; app?: MirrorApp } {
  const vault = lsGet(LS.vault) || null;
  const apps = useChatApps(vault);
  const mirror = useInvokeQuery<MirrorList>("apps_mirror_list", vault ? { vault } : null, { staleMs: Infinity });
  return (id) => {
    const a = apps.find((x) => x.id === id);
    return { name: a?.name ?? id, url: a?.url, app: mirror.data?.apps.find((x) => x.id === id) };
  };
}

// The top of a reply: which apps it used, and what the engine said about them.
export function ReplyApps({ msg }: { msg: ChatMessage }) {
  const names = useNames();
  const vault = lsGet(LS.vault) || null;
  const mirror = useInvokeQuery<MirrorList>("apps_mirror_list", vault ? { vault } : null, { staleMs: Infinity });
  const hasApps = (msg.steps ?? []).some((s) => s.app);
  const uses = hasApps ? appUses(msg.steps, mirror.data?.apps ?? [], (msg.steps ?? []).filter((s) => s.app).map((s) => ({ id: s.app!, name: names(s.app!).name }))) : [];
  const notices = msg.appNotices ?? [];
  if (!uses.length && !notices.length) return null;
  return (
    <div className="mb-2.5 flex flex-col gap-1.5">
      {notices.map((n, i) => <Notice key={i} n={n} name={(id) => names(id).name} />)}
      {uses.length > 0 && (
        <div className="flex flex-wrap items-center gap-1.5">
          {uses.map((u) => (
            <button key={u.app} type="button" data-testid="app-use-chip" onClick={() => openApp({ id: u.app, tab: "activity", thread: u.thread })}
              title={`Open ${u.name}'s activity for this conversation`}
              className="inline-flex items-center gap-1.5 rounded-full border border-border bg-background py-0.5 pl-1 pr-2.5 text-[13px] font-medium text-text-secondary transition-colors hover:border-accent-border hover:text-accent">
              <AppLogo name={u.name} url={names(u.app).url} size={18} />
              {appUseLabel(u)}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

function Notice({ n, name }: { n: AppNotice; name: (id: string) => string }) {
  if (n.kind === "routed") {
    return (
      <p data-testid="app-routed" className="inline-flex items-center gap-1.5 text-[13px] text-text-muted">
        <Route className="h-3.5 w-3.5" /> Using {runtimeName(n.runtime)}{n.apps?.length ? ` for ${n.apps.join(", ")}` : ""}
      </p>
    );
  }
  if (n.kind === "unavailable") {
    return (
      <p data-testid="app-unavailable" className="flex items-start gap-1.5 text-[13px] text-text-secondary">
        <AlertTriangle className="mt-0.5 h-3.5 w-3.5 shrink-0 text-warn" />
        <span>{name(n.app)} is connected through {runtimeName(n.runtime_needed)}, so this reply could not use it. Ask again in a chat on {runtimeName(n.runtime_needed)}.</span>
      </p>
    );
  }
  const label = n.name || name(n.app);
  const href = n.signin_url || null;
  return (
    <div data-testid="app-needs-auth" className="flex flex-col gap-2 rounded-lg border border-warn/40 bg-warn/5 px-3 py-2.5 sm:flex-row sm:items-center">
      <KeyRound className="hidden h-4 w-4 shrink-0 text-warn sm:block" />
      <div className="min-w-0 flex-1">
        <p className="text-[14px] font-semibold text-text-primary">{label} needs sign-in</p>
        <p className="text-[13px] text-text-muted">Sign in once, then ask again. Glyph Studio uses the sign-in your runtime keeps.</p>
      </div>
      <button type="button" onClick={() => (href ? openExternal(href) : openApp({ id: n.app, tab: "connection" }))}
        className="inline-flex shrink-0 items-center justify-center gap-1.5 rounded-md border border-accent-border bg-accent-soft px-3 py-1.5 text-[13px] font-semibold text-accent hover:bg-accent/15">
        Sign in {href ? <ExternalLink className="h-3.5 w-3.5" /> : null}
      </button>
    </div>
  );
}

