// The app sidebar, extracted from App.tsx. Prop-driven (collapse state,
// domains, active selection, and a set of callbacks).
//
// Home mode (everything that is not the Editor) reads top to bottom:
//   profile header (switcher + settings button), search (opens the command
//   palette), Home / Inbox / the Home surfaces, WORK (tasks, Compass,
//   decisions, playbooks), ENTITIES (People, Places, Products, Things),
//   ACTIVITIES (Events, Projects), SPECIALISTS, DOMAINS (Pinned / All /
//   Archived). Apps are Products now: each product's page carries its
//   connection, and Products links to the Apps page (ux ask 6).
// Editor mode keeps the same header and swaps the list for the configuration
// nav, with a way back to Home at the top.
import { Fragment, type MouseEvent as ReactMouseEvent, type ReactNode, type RefObject, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { confirm as tauriConfirm } from "@tauri-apps/plugin-dialog";
import { useChiefOfStaff } from "./chiefofstaff";
import { dropSpecialist, inSidebar, startPillDrag } from "./dragref";
import { ChiefAvatar, SpecialistAvatar, useWorkingSpecialists } from "./specialistavatar";
import { Activity, Archive, ArrowLeft, Briefcase, CalendarRange, ChevronRight, ChevronsLeft, ChevronsRight, Folder, FolderKanban, Hourglass, House, Inbox, LayoutGrid, Loader2, MoreVertical, Pin, Plus, RotateCcw, Search, Settings as SettingsIcon, Shapes, Sparkles, UserCog, X } from "lucide-react";
import { invoke } from "./bridge";
import { useInvokeQuery } from "./query";
import { daysLeftLabel, openMission, useMissions } from "./missions";
import { openStructure, useStructureSuggestions } from "./missions";
import { prefetchSection, prefetchSettings } from "./prefetch";
import { titleCase } from "./format";
import { lsGet, lsSet } from "./storage";
import { SidebarGatewayLive, SidebarMcpLive } from "./panels";
import { ProfileSwitcher } from "./profileswitcher";
import { EDITOR_NAV, WORK_NAV, navSection, workSection } from "./navdefs";
import { TintIcon } from "./tint";
import { domainIcon } from "./icons";
import { SidebarBackupActive, SidebarBenchmarkRuns, SidebarProcesses } from "./cards";
import { useProcesses } from "./processes";
import { useBenchBatches } from "./bench";
import { BACKUP_CFG } from "./backup";
import type { Domain, TabId } from "./types";
import { useWaiting, waitingByDomain } from "./waiting";
import { domainColor, isUserDomain } from "./helpers";
import { STICKY_GROUP_HEAD, markStuck } from "./sidespine";
import { ENTITY_KIND_OF, fmtDay, kindsOf, newOfKind, openKind, todayYmd, type EventRow, type KindDef, type KindId } from "./ia";
import { loadEntities, requestEntity, useEntityStore, type EntityKindName } from "./entitystore";

const TASKS_CHANGED = ["prevail:tasks-changed"];

// Active row: a light accent tint, accent text, and a short accent bar on the
// left edge. Every selectable row in the sidebar uses it.
const ACTIVE_ROW = "bg-accent-soft font-semibold text-accent before:absolute before:left-0 before:top-1.5 before:bottom-1.5 before:w-[3px] before:rounded-full before:bg-accent";
const IDLE_ROW = "text-text-secondary hover:bg-surface-warm hover:text-text-primary";
const SECTION_LABEL = "text-[11px] font-semibold uppercase tracking-[0.08em] text-text-muted";
// Sections sit one step in from the top rows (owner, 2026-10-03: Work,
// Entities... "not on the same line as Inbox, Insights"): a section's header
// and its rows share a left edge 12px right of Home, Inbox and Insights.
const SECTION_PAD = "pl-6 pr-3";
// Readable names for the side rows old Settings ids open (navdefs EDITOR_SUBS),
// so "Search settings" finds them too.
const SUB_LABELS: Record<string, string> = {
  phone: "Phone", gateway: "Gateway", mcp: "MCP", hooks: "Hooks", remote: "Network",
  privacy: "Bunker Mode", autonomy: "Autonomy", safety: "Safety", general: "General",
  appearance: "Appearance", shortcuts: "Shortcuts", vault: "Vault", profiles: "Profiles",
  about: "About", daemons: "Daemons", memory: "Memory", usage: "Usage", omega: "Omega",
};
const cap99 = (n: number) => (n > 99 ? "99+" : String(n));

// Which sidebar sections are open, for this run of the app only (owner,
// 2026-10-02): every section starts collapsed at launch, and what the user
// opens or closes holds while they move around. In memory, never stored.
const SESSION_OPEN = new Map<string, boolean>();
function useSessionOpen(key: string): [boolean, (v: boolean | ((cur: boolean) => boolean)) => void] {
  // The e2e ring opens some sections from the start (window.__sidebarOpen).
  const [open, setOpen] = useState<boolean>(() => SESSION_OPEN.get(key) ?? ((window as unknown as { __sidebarOpen?: string[] }).__sidebarOpen?.includes(key) ?? false));
  const set = useCallback((v: boolean | ((cur: boolean) => boolean)) => setOpen((cur) => { const next = typeof v === "function" ? v(cur) : v; SESSION_OPEN.set(key, next); return next; }), [key]);
  return [open, set];
}
/** A fresh launch (tests): every section collapsed again. */
export function resetSidebarSession() { SESSION_OPEN.clear(); }
/** Open sections for this session (tests, and a deep link that must show its row). */
export function openSidebarSections(keys: string[]) { for (const k of keys) SESSION_OPEN.set(k, true); }

function CountPill({ n, active, loud = false }: { n: number; active: boolean; loud?: boolean }) {
  if (n <= 0) return null;
  return (
    <span className={`ml-auto shrink-0 rounded-full px-1.5 text-[11px] font-semibold tabular-nums leading-[18px] ${active || loud ? "bg-accent text-on-accent" : "bg-surface-warm text-text-muted"}`}>
      {cap99(n)}
    </span>
  );
}

// One nav row. Collapsed, it is an icon button with the label as its tooltip.
// `loud`: the count is something to act on (the Inbox), so it is always in
// the accent colour rather than muted.
function NavRow({ icon: Icon, lead, tint, label, title, active, count = 0, loud = false, collapsed, onClick, onPrefetch, onMouseDown, chatTarget, testId }: {
  icon: typeof House; lead?: ReactNode; tint?: string; label: string; title?: string; active: boolean; count?: number; loud?: boolean; collapsed: boolean; onClick: () => void; onPrefetch?: () => void;
  onMouseDown?: (e: ReactMouseEvent) => void; chatTarget?: boolean; testId?: string;
}) {
  return (
    <button
      onClick={onClick}
      onMouseDown={onMouseDown}
      data-chat-target={chatTarget ? "" : undefined}
      onPointerEnter={onPrefetch}
      onFocus={onPrefetch}
      title={collapsed ? (count > 0 ? `${label} (${count})` : label) : title}
      aria-current={active ? "page" : undefined}
      data-testid={testId}
      className={`relative flex w-full items-center rounded-lg text-left text-[14px] transition-colors ${
        collapsed ? "h-10 justify-center" : "h-9 gap-3 px-3"
      } ${active ? ACTIVE_ROW : IDLE_ROW}`}
    >
      {lead ?? <TintIcon icon={Icon} tint={tint} />}
      {!collapsed && <span className="min-w-0 flex-1 truncate">{label}</span>}
      {!collapsed && <CountPill n={count} active={active} loud={loud} />}
      {collapsed && count > 0 && <span className="absolute right-1.5 top-1.5 h-2 w-2 rounded-full bg-accent" />}
    </button>
  );
}

// A project row (under Activities > Projects): its name and the days left at
// the right, indented under its kind.
function MissionRow({ name, left, active, collapsed, onClick, testId }: { name: string; left: string; active: boolean; collapsed: boolean; onClick: () => void; testId?: string }) {
  return (
    <button onClick={onClick} data-chat-target="" title={collapsed ? `${name}${left ? `, ${left} left` : ""}` : undefined} aria-current={active ? "page" : undefined} data-testid={testId}
      className={`relative flex w-full items-center rounded-lg text-left text-[14px] transition-colors ${collapsed ? "h-10 justify-center" : "h-8 gap-2.5 pl-9 pr-3"} ${active ? ACTIVE_ROW : IDLE_ROW}`}>
      {collapsed && <TintIcon icon={FolderKanban} tint="projects" />}
      {!collapsed && <span className="min-w-0 flex-1 truncate">{name}</span>}
      {!collapsed && left && <span className="shrink-0 text-[12px] tabular-nums text-text-muted">{left}</span>}
    </button>
  );
}

// One kind under ENTITIES or ACTIVITIES: its icon and name open its page; on
// hover a + starts a new one by talking and a chevron lists a few of them.
function KindRow({ def, count, active, open, collapsed, onOpen, onToggle, onAdd, children }: {
  def: KindDef; count?: number; active: boolean; open: boolean; collapsed: boolean; onOpen: () => void; onToggle: () => void; onAdd: () => void; children?: ReactNode;
}) {
  const Icon = def.icon;
  if (collapsed) {
    return (
      <button onClick={onOpen} title={def.label} aria-label={def.label} aria-current={active ? "page" : undefined} data-testid={`sidebar-kind-${def.id}`}
        className={`relative flex h-10 w-full items-center justify-center rounded-lg transition-colors ${active ? ACTIVE_ROW : IDLE_ROW}`}>
        <TintIcon icon={Icon} tint={def.id} />
      </button>
    );
  }
  return (
    <div>
      <div className="group/h relative flex items-center">
        <button onClick={onOpen} aria-current={active ? "page" : undefined} data-testid={`sidebar-kind-${def.id}`} data-chat-target={def.id === "projects" ? "" : undefined}
          className={`relative flex h-9 min-w-0 flex-1 items-center gap-3 rounded-lg pl-3 pr-16 text-left text-[14px] transition-colors ${active ? ACTIVE_ROW : IDLE_ROW}`}>
          <TintIcon icon={Icon} tint={def.id} />
          <span className="min-w-0 flex-1 truncate">{def.label}</span>
          {typeof count === "number" && count > 0 && <span className="shrink-0 text-[12px] tabular-nums text-text-muted group-hover/h:opacity-0">{cap99(count)}</span>}
        </button>
        <span className="absolute right-1 flex items-center">
          <button onClick={onAdd} title={`New ${def.singular.toLowerCase()}`} aria-label={`New ${def.singular.toLowerCase()}`} data-testid={`sidebar-kind-add-${def.id}`}
            className={`flex h-7 w-7 items-center justify-center rounded-md text-text-muted hover:bg-surface-warm hover:text-accent ${REVEAL}`}>
            <Plus className="h-3.5 w-3.5" strokeWidth={2.2} />
          </button>
          <button onClick={onToggle} aria-expanded={open} title={open ? `Hide ${def.label.toLowerCase()}` : `Show ${def.label.toLowerCase()}`} aria-label={open ? `Hide ${def.label.toLowerCase()}` : `Show ${def.label.toLowerCase()}`} data-testid={`sidebar-kind-toggle-${def.id}`}
            className={`flex h-7 w-7 items-center justify-center rounded-md text-text-muted hover:bg-surface-warm hover:text-text-primary ${REVEAL}`}>
            <ChevronRight className={`h-3.5 w-3.5 transition-transform ${open ? "rotate-90" : ""}`} strokeWidth={2.2} />
          </button>
        </span>
      </div>
      {open && <div className="mt-0.5 space-y-0.5" data-testid={`sidebar-kind-items-${def.id}`}>{children}</div>}
    </div>
  );
}

// An object under its kind: indented, quiet, the name and one short note.
function ObjectRow({ name, note, onClick, testId }: { name: string; note?: string; onClick: () => void; testId?: string }) {
  return (
    <button onClick={onClick} data-testid={testId} title={note ? `${name}, ${note}` : name}
      className={`relative flex h-8 w-full items-center gap-2.5 rounded-lg pl-9 pr-3 text-left text-[14px] transition-colors ${IDLE_ROW}`}>
      <span className="min-w-0 flex-1 truncate">{name}</span>
      {note && <span className="shrink-0 text-[12px] tabular-nums text-text-muted">{note}</span>}
    </button>
  );
}

function Divider() {
  return <div className="mx-3 my-2 h-px bg-border-subtle" />;
}

// Section headers pin to the top of the scrolling list (the sidebar's own
// surface behind them), each pushed up by the next section's.
const SIDEBAR_STICKY = `${STICKY_GROUP_HEAD} bg-surface-strong`;

// One header for every section (Work, Entities, Activities, Specialists, Apps, Domains):
// the label and count in the same muted ink, the row is the toggle, and the
// + and the chevron stay hidden until the row is hovered or focused
// (progressive reveal); on touch they are always there.
const REVEAL = "opacity-0 transition-opacity group-hover/h:opacity-100 group-has-[:focus-visible]/h:opacity-100 [@media(pointer:coarse)]:opacity-100";
function SectionHeader({ label, icon, tint, count, open, onToggle, onAdd, addTitle, tour, dot }: {
  label: string; icon: typeof House; tint: string; count?: number; open: boolean; onToggle: () => void; onAdd?: () => void; addTitle?: string; tour?: string;
  // A small count dot after the label (a pending suggestion), with its own click.
  dot?: { count: number; title: string; onClick: () => void };
}) {
  return (
    // Aligned with its own rows (mx-3 + pl-6 = SECTION_PAD + a row's px-3),
    // one step in from the top rows,
    // the icon in the same 22px column, the + and chevron where a row's are.
    <div data-tour={tour} data-sticky-head data-testid={`sidebar-head-${label.toLowerCase()}`} className={`group/h mx-3 flex h-8 items-center gap-0.5 pb-0.5 pl-6 pr-1 pt-0.5 ${SIDEBAR_STICKY}`}>
      <button onClick={onToggle} aria-expanded={open} title={open ? `Hide ${label}` : `Show ${label}`}
        className={`flex h-7 min-w-0 flex-1 items-center gap-3 rounded-md pl-0 text-left transition-colors hover:text-text-secondary focus-visible:text-text-secondary ${SECTION_LABEL}`}>
        <span className="flex w-[22px] shrink-0 justify-center" data-testid="sidebar-head-icon"><TintIcon icon={icon} tint={tint} square={false} size={14} /></span>
        <span className="truncate">{label}</span>
        {typeof count === "number" && <span className="font-medium tabular-nums text-text-muted/70" data-testid="sidebar-head-count">{count}</span>}
      </button>
      {dot && (
        <button onClick={dot.onClick} title={dot.title} aria-label={dot.title} data-testid={`sidebar-dot-${label.toLowerCase()}`}
          className="mr-0.5 flex h-4 min-w-4 shrink-0 items-center justify-center rounded-full bg-accent px-1 text-[10px] font-semibold tabular-nums leading-none text-white hover:bg-accent-hover">
          {dot.count}
        </button>
      )}
      {onAdd && (
        <button onClick={onAdd} title={addTitle} aria-label={addTitle} data-testid={`sidebar-add-${label.toLowerCase()}`}
          className={`flex h-6 w-6 shrink-0 items-center justify-center rounded-md text-text-muted hover:bg-surface-warm hover:text-accent ${REVEAL}`}>
          <Plus className="h-3.5 w-3.5" strokeWidth={2.2} />
        </button>
      )}
      <button onClick={onToggle} tabIndex={-1} aria-hidden data-testid={`sidebar-toggle-${label.toLowerCase()}`}
        className={`flex h-6 w-6 shrink-0 items-center justify-center rounded-md text-text-muted hover:bg-surface-warm hover:text-text-primary ${REVEAL}`}>
        <ChevronRight className={`h-3.5 w-3.5 transition-transform ${open ? "rotate-90" : ""}`} strokeWidth={2.2} />
      </button>
    </div>
  );
}

export function Sidebar({
  collapsed,
  setCollapsed,
  vaultPath,
  domains,
  vaultError,
  selectedDomain,
  setSelectedDomain,
  openInFinder,
  tab,
  setTab,
  onDomainCreated,
  runningDomains,
  finishedDomains,
  domainStats,
  railWidth,
  onOpenOnboarding,
  onDomainsChanged,
}: {
  collapsed: boolean;
  setCollapsed: (v: boolean | ((cur: boolean) => boolean)) => void;
  vaultPath: string;
  domains: Domain[];
  vaultError: string | null;
  selectedDomain: string | null;
  setSelectedDomain: (n: string) => void;
  openInFinder: (p: string | null) => void;
  tab: TabId;
  setTab: (t: TabId) => void;
  onDomainCreated: (d: Domain) => void;
  runningDomains: Set<string>;
  finishedDomains: Set<string>;
  domainStats: Record<string, number>;
  railWidth: number;
  onOpenOnboarding: () => void;
  onDomainsChanged: () => void;
}) {
  const [adding, setAdding] = useState(false);
  const [newName, setNewName] = useState("");
  // Pinned domains live in localStorage as a comma-separated slug list.
  const PIN_KEY = "prevail.desktop.pinnedDomains";
  const [pinned, setPinned] = useState<Set<string>>(() => {
    try {
      const raw = lsGet(PIN_KEY);
      return new Set(raw ? raw.split(",").filter(Boolean) : []);
    } catch { return new Set(); }
  });
  // Group collapse - Pinned vs All. Persisted so collapsing survives restarts.
  const [pinnedOpen, setPinnedOpen] = useSessionOpen("pinned");
  // "All" starts collapsed so Domains opens one level deep (Pinned + the All
  // header with its count) rather than listing every domain.
  const [allOpen, setAllOpen] = useSessionOpen("all");
  const togglePin = (name: string) => {
    setPinned((cur) => {
      const next = new Set(cur);
      if (next.has(name)) next.delete(name);
      else next.add(name);
      lsSet(PIN_KEY, Array.from(next).join(","));
      return next;
    });
  };
  // Real domains only: internal / app-scope pseudo-domains ("_meta",
  // "_app-...") never show here. Pinned first.
  const sortedDomains = useMemo(() => {
    const filtered = domains.filter((d) => isUserDomain(d.name));
    return [...filtered.filter((d) => pinned.has(d.name)), ...filtered.filter((d) => !pinned.has(d.name))];
  }, [domains, pinned]);
  const pinnedCount = sortedDomains.filter((d) => pinned.has(d.name)).length;
  const [addError, setAddError] = useState<string | null>(null);

  async function createDomain() {
    setAddError(null);
    try {
      const d = await invoke<Domain>("create_domain", { vault: vaultPath, name: newName });
      onDomainCreated(d);
      setNewName("");
      setAdding(false);
    } catch (e) {
      setAddError(String(e));
    }
  }

  const [domainsOpen, setDomainsOpen] = useSessionOpen("domains");
  const [workOpen, setWorkOpen] = useSessionOpen("work");

  // Which Editor / Work section is active, kept in sync with the events the
  // content panels listen to.
  const [editorActive, setEditorActive] = useState("settings");
  // Editor nav groups fold away and the choice is remembered. A group holding
  // the active section always opens, so where you are stays visible.
  const NAV_GROUPS_LS = "prevail.editorNav.closed";
  const [closedNavGroups, setClosedNavGroups] = useState<Set<string>>(() => {
    try { return new Set(JSON.parse(localStorage.getItem(NAV_GROUPS_LS) || "[]") as string[]); }
    catch { return new Set(); }
  });
  const toggleNavGroup = (heading: string) => setClosedNavGroups((prev) => {
    const next = new Set(prev);
    if (next.has(heading)) next.delete(heading); else next.add(heading);
    try { localStorage.setItem(NAV_GROUPS_LS, JSON.stringify([...next])); } catch { /* ignore */ }
    return next;
  });
  const [workActive, setWorkActive] = useState("task-list");
  // Which mission the Missions page shows, so its sidebar row lights up.
  const [openMissionSlug, setOpenMissionSlug] = useState<string | null>(null);
  useEffect(() => {
    const onMission = (e: Event) => setOpenMissionSlug((e as CustomEvent<string | null>).detail ?? null);
    window.addEventListener("prevail:open-mission", onMission as EventListener);
    window.addEventListener("prevail:mission-shown", onMission as EventListener);
    return () => { window.removeEventListener("prevail:open-mission", onMission as EventListener); window.removeEventListener("prevail:mission-shown", onMission as EventListener); };
  }, []);
  useEffect(() => {
    const onEd = (e: Event) => { const d = (e as CustomEvent<string>).detail || "settings"; setEditorActive(navSection(d.split(":")[0])); };
    const onWk = (e: Event) => { const d = workSection((e as CustomEvent<string>).detail || ""); if (d) setWorkActive(d); };
    window.addEventListener("prevail:settings-section", onEd as EventListener);
    // Deep links elsewhere in the app dispatch open-settings, which App routes
    // to the right mode; the highlight follows.
    const onOpen = (e: Event) => {
      const d = ((e as CustomEvent<string>).detail || "").split(":")[0];
      if (!d) return;
      const w = workSection(d);
      if (w) setWorkActive(w);
      else setEditorActive(navSection(d));
    };
    window.addEventListener("prevail:open-settings", onOpen as EventListener);
    window.addEventListener("prevail:work-section", onWk as EventListener);
    return () => {
      window.removeEventListener("prevail:settings-section", onEd as EventListener);
      window.removeEventListener("prevail:open-settings", onOpen as EventListener);
      window.removeEventListener("prevail:work-section", onWk as EventListener);
    };
  }, []);
  // App owns the mode switch + section jump; the sidebar reflects the choice
  // and announces it.
  const selectEditor = (id: string) => { setEditorActive(id); window.dispatchEvent(new CustomEvent("prevail:settings-section", { detail: id })); };
  const selectWork = (id: string) => { setWorkActive(id); window.dispatchEvent(new CustomEvent("prevail:work-section", { detail: id })); };
  const goHome = () => { setSelectedDomain(""); setTab("chat"); };
  const newTask = () => {
    try { localStorage.setItem("prevail.board.openAdd", "1"); } catch { /* storage off */ }
    selectWork("task-list");
    window.dispatchEvent(new Event("prevail:board-add"));
  };

  // Counts for the Work rows, read from the same sources their screens use:
  // open tasks across every domain. Missions are read once for their own
  // section. Through the shared cache, so the pages open on the same answers
  // instead of fetching them again.
  const today = new Date().toISOString().slice(0, 10);
  const workCount = useInvokeQuery<{ open?: number }>("work_count", vaultPath ? { vault: vaultPath, today, domain: null } : null, { invalidateOn: TASKS_CHANGED });
  const missionsQ = useMissions(vaultPath || null);
  // Named chief of staff: the General row (Home) carries their name.
  const chief = useChiefOfStaff(vaultPath || null);
  const openTasks = workCount.data?.open ?? 0;
  // MISSIONS: the active ones with days left (soonest target first), paused
  // ones folded under one row. Completed and archived live on the page.
  const activeMissions = missionsQ.missions.filter((m) => m.status === "active").sort((a, b) => (a.target || "9").localeCompare(b.target || "9"));
  const pausedMissions = missionsQ.missions.filter((m) => m.status === "paused").length;
  // ENTITIES and ACTIVITIES (ia-plan.md): both collapsed for a new user; each
  // kind row opens its page, and its chevron lists a few of that kind.
  const [entitiesOpen, setEntitiesOpen] = useSessionOpen("entities");
  const [activitiesOpen, setActivitiesOpen] = useSessionOpen("activities");
  const kindKey = (k: KindId) => `kind.${k}`;
  const [kindOpen, setKindOpen] = useState<Set<KindId>>(() => new Set([...kindsOf("entities"), ...kindsOf("activities")].filter((k) => SESSION_OPEN.get(kindKey(k.id)) ?? (window as unknown as { __sidebarOpen?: string[] }).__sidebarOpen?.includes(kindKey(k.id))).map((k) => k.id)));
  const toggleKind = (k: KindId) => setKindOpen((cur) => {
    const next = new Set(cur);
    if (next.has(k)) next.delete(k); else next.add(k);
    SESSION_OPEN.set(kindKey(k), next.has(k));
    return next;
  });
  const [iaShown, setIaShown] = useState<KindId | null>(null);
  useEffect(() => {
    const on = (e: Event) => setIaShown((e as CustomEvent<KindId>).detail ?? null);
    window.addEventListener("prevail:ia-shown", on);
    return () => window.removeEventListener("prevail:ia-shown", on);
  }, []);
  const kindActive = (k: KindId) => tab === "work" && (workActive === "entities" || workActive === "activities" || workActive === "missions") && iaShown === k && !(k === "projects" && openMissionSlug);
  const entStore = useEntityStore();
  const wantEntities = entitiesOpen && (["people", "places", "things"] as KindId[]).some((k) => kindOpen.has(k));
  useEffect(() => { if (wantEntities && vaultPath) void loadEntities(vaultPath); }, [wantEntities, vaultPath]);
  const productsQ = useInvokeQuery<{ products: { id: string; name: string; relation: string; apps: unknown[] }[] } | null>("ia_products", vaultPath && entitiesOpen && kindOpen.has("products") ? { vault: vaultPath } : null, { staleMs: 5 * 60_000, invalidateOn: ["prevail:entities-changed"] });
  const eventsQ = useInvokeQuery<{ events: EventRow[] } | null>("ia_events", vaultPath ? { vault: vaultPath } : null, { staleMs: 5 * 60_000, invalidateOn: ["prevail:events-changed", "prevail:entities-changed", "prevail:missions-changed"] });
  const today0 = todayYmd();
  const upcoming = (Array.isArray(eventsQ.data?.events) ? eventsQ.data!.events : []).filter((e) => e.date && (e.end ?? e.date) >= today0);
  // Every section header shows a count (owner, 2026-10-02): entities from the
  // shared store, activities as upcoming events plus active projects.
  useEffect(() => { if (vaultPath) void loadEntities(vaultPath); }, [vaultPath]);
  const entityCount = entStore.list?.entities?.length ?? 0;
  const activityCount = upcoming.length + activeMissions.length;
  const kindCount = (k: KindId): number | undefined => (k === "projects" ? activeMissions.length : k === "events" && eventsQ.data ? upcoming.length : undefined);
  const openEntity = (kind: EntityKindName, id: string) => requestEntity({ kind, value: id.slice(id.indexOf("/") + 1) });
  const kindItems = (k: KindId): ReactNode => {
    if (k === "projects") return (
      <div data-testid="sidebar-missions" className="space-y-0.5">
        {activeMissions.map((m) => (
          <MissionRow key={m.slug} name={m.name} left={daysLeftLabel(m)} active={tab === "work" && workActive === "missions" && openMissionSlug === m.slug} collapsed={collapsed} onClick={() => { setOpenMissionSlug(m.slug); openMission(m.slug); setWorkActive("missions"); }} testId={`sidebar-mission-${m.slug}`} />
        ))}
        {pausedMissions > 0 && <ObjectRow name={`Paused (${pausedMissions})`} onClick={() => openMissions("paused")} testId="sidebar-missions-paused" />}
        <ObjectRow name={activeMissions.length ? "All projects" : "No active projects"} onClick={() => { setOpenMissionSlug(null); openMissions("all"); }} testId="sidebar-missions-all" />
      </div>
    );
    if (k === "events") {
      const list = upcoming.slice(0, 5);
      return list.length
        ? list.map((e) => <ObjectRow key={e.id} name={e.name} note={fmtDay(e.date)} testId="sidebar-event" onClick={() => (e.has_page ? openEntity("event", e.id) : openKind("events"))} />)
        : <ObjectRow name={eventsQ.data ? "Nothing coming up" : "Reading events"} onClick={() => openKind("events")} />;
    }
    if (k === "products") {
      const rows = (Array.isArray(productsQ.data?.products) ? productsQ.data!.products : []).filter((p) => p.relation !== "reference").slice(0, 6);
      return rows.length ? rows.map((p) => <ObjectRow key={p.id} name={p.name} testId="sidebar-object" onClick={() => openEntity("org", p.id)} />)
        : <ObjectRow name={productsQ.data ? "None yet" : "Reading products"} onClick={() => openKind("products")} />;
    }
    const ek = ENTITY_KIND_OF[k] as EntityKindName;
    const rows = (entStore.list?.entities ?? []).filter((e) => e.kind === ek && e.relation !== "reference")
      .sort((a, b) => Number(b.saved) - Number(a.saved) || b.conversations - a.conversations).slice(0, 6);
    return rows.length ? rows.map((e) => <ObjectRow key={e.id} name={e.name} testId="sidebar-object" onClick={() => openEntity(ek, e.id)} />)
      : <ObjectRow name={entStore.list ? "None yet" : "Reading"} onClick={() => openKind(k)} />;
  };
  const openMissions = (focus: string) => {
    try { localStorage.setItem("prevail.missions.focus", focus); } catch { /* storage off */ }
    selectWork("missions");
    window.dispatchEvent(new CustomEvent("prevail:missions-focus", { detail: focus }));
  };
  // A pending "new domain" suggestion shows as a dot on the Domains header.
  const domainSuggestions = useStructureSuggestions(vaultPath || null).suggestions.filter((x) => x.kind === "domain").length;
  const refreshCounts = useRef<() => void>(() => {});
  refreshCounts.current = () => { void workCount.refresh(); void missionsQ.refresh(); };
  useEffect(() => {
    if (!vaultPath) return;
    const id = window.setInterval(() => refreshCounts.current(), 120000);
    return () => window.clearInterval(id);
  }, [vaultPath]);
  const workCounts: Record<string, number> = { "task-list": openTasks };
  // Specialists: only the ones that are on, like Apps. A click opens the
  // Specialists page on that specialist; the section count is running jobs.
  const specsList = useInvokeQuery<{ id: string; name: string; on: boolean }[]>("engine_specialists", vaultPath ? { vault: vaultPath } : null, { staleMs: 5 * 60_000 });
  const specialists = Array.isArray(specsList.data) ? specsList.data.filter((x) => x.on) : [];
  const working = useWorkingSpecialists(vaultPath || null);
  const [specsOpen, setSpecsOpen] = useSessionOpen("specialists");
  const openSpecialist = (focus: string) => {
    try { localStorage.setItem("prevail.specialists.focus", focus); } catch { /* storage off */ }
    selectWork("specialists");
    window.dispatchEvent(new Event("prevail:specialists-focus"));
  };
  // What is waiting on you, counted per domain for the domain rows.
  const waiting = useWaiting(vaultPath);
  const waitingPerDomain = useMemo(() => waitingByDomain(waiting.items), [waiting]);

  // Archived domains - fetched from the engine, shown under Domains, each with
  // a Restore action.
  const [archived, setArchived] = useState<string[]>([]);
  const [archivedOpen, setArchivedOpen] = useSessionOpen("archived");
  const [restoring, setRestoring] = useState<string | null>(null);
  // Which domain's kebab menu is open (one at a time).
  const [menuOpen, setMenuOpen] = useState<string | null>(null);
  useEffect(() => {
    if (!menuOpen) return;
    const onDown = (e: MouseEvent) => {
      const t = e.target as HTMLElement | null;
      if (!t || !t.closest("[data-domain-menu]")) setMenuOpen(null);
    };
    document.addEventListener("mousedown", onDown);
    return () => document.removeEventListener("mousedown", onDown);
  }, [menuOpen]);
  const refreshArchived = useCallback(async () => {
    if (!vaultPath) return;
    try {
      const list = await invoke<string[]>("engine_list_archived", { vault: vaultPath });
      // A null (older engine, empty JSON body) must not crash the shell.
      setArchived(Array.isArray(list) ? list : []);
    } catch {
      setArchived([]);
    }
  }, [vaultPath]);
  useEffect(() => { void refreshArchived(); }, [refreshArchived, domains.length]);

  async function restoreDomain(name: string) {
    setRestoring(name);
    try {
      await invoke("engine_vault_restore", { vault: vaultPath, domain: name });
      await refreshArchived();
      onDomainsChanged();
    } catch (e) {
      console.error("restore domain", e);
    } finally {
      setRestoring(null);
    }
  }

  // Archive a domain from its row. Nothing is deleted: it moves to Archived
  // and can be restored any time.
  async function archiveDomain(name: string) {
    try {
      const ok = await tauriConfirm(
        `Hide "${titleCase(name)}" from the active list? Nothing is deleted. Restore it any time from the Archived section.`,
        { title: "Archive domain", kind: "warning" },
      );
      if (!ok) return;
      await invoke("engine_vault_archive", { vault: vaultPath, domain: name });
      await refreshArchived();
      onDomainsChanged();
    } catch (e) {
      console.error("archive domain", e);
    }
  }

  // Manual drag of a domain row into the chat (WKWebView's HTML5 DnD does not
  // reliably fire dragstart). On mouseup after moving, the chat panel's global
  // attach hook takes the domain as context.
  const startDomainDrag = (e: ReactMouseEvent, name: string) => startDrag(e, titleCase(name), (ev) => {
    const hook = (window as unknown as { __prevailAttach?: (n: string, mode?: "light" | "full" | "folder") => void }).__prevailAttach;
    if (hook) hook(name, ev.altKey ? "folder" : ev.shiftKey ? "full" : "light");
    else console.warn("[prevail/drag] no attach hook registered: drop fell outside chat panel");
  });
  const startDrag = (e: ReactMouseEvent, label: string, drop: (ev: MouseEvent) => void) =>
    startPillDrag(e, label, (ev) => { if (!inSidebar(ev)) drop(ev); });
  // A specialist dragged onto a chat (or onto Home, a domain or a mission row) hands the message to it.
  const startSpecialistDrag = (e: ReactMouseEvent, name: string) => startPillDrag(e, `@${name}`, (ev) => { dropSpecialist(ev, name); });
  const openDomainRow = (name: string) => { setSelectedDomain(name); if (tab === "work") setTab("chat"); };

  const editorMode = tab === "settings";
  const homeActive = !editorMode && tab !== "work" && !selectedDomain;

  // A minimal collapse toggle at the top, beside the profile (Fru, 2026-10-02).
  const collapseButton = (
    <button
      onClick={() => setCollapsed((v) => !v)}
      title={collapsed ? "Expand sidebar (⌘B)" : "Collapse sidebar (⌘B)"}
      aria-label={collapsed ? "Expand sidebar" : "Collapse sidebar"}
      data-testid="sidebar-collapse"
      className="flex h-7 w-7 shrink-0 items-center justify-center rounded-md text-text-muted/70 transition-colors hover:bg-surface-warm hover:text-text-primary"
    >
      {collapsed ? <ChevronsRight className="h-3.5 w-3.5" /> : <ChevronsLeft className="h-3.5 w-3.5" />}
    </button>
  );

  // Home mode's one way into Settings: a quiet gear in the footer.
  const settingsButton = (
    <button
      onClick={() => setTab("settings")}
      onPointerEnter={prefetchSettings}
      onFocus={prefetchSettings}
      title="Settings"
      aria-label="Settings"
      data-tour="settings"
      className="flex h-8 w-8 shrink-0 items-center justify-center rounded-md text-text-muted transition-colors hover:bg-surface-warm hover:text-text-primary"
    >
      <SettingsIcon className="h-4 w-4" />
    </button>
  );

  // Settings mode filters its own nav as you type: the page rows, plus the
  // side rows old ids still open (EDITOR_SUBS). Enter opens the first match.
  const [navQuery, setNavQuery] = useState("");
  useEffect(() => { if (!editorMode) setNavQuery(""); }, [editorMode]);
  const q = navQuery.trim().toLowerCase();
  const navGroups = q
    ? EDITOR_NAV.map((g) => ({ ...g, items: g.items.filter((i) => i.label.toLowerCase().includes(q) || g.heading.toLowerCase().includes(q)) })).filter((g) => g.items.length > 0)
    : EDITOR_NAV;
  const pageFor = (id: string) => EDITOR_NAV.flatMap((g) => g.items).find((i) => i.id === id);
  const subMatches = q
    ? Object.entries(SUB_LABELS).filter(([, l]) => l.toLowerCase().includes(q)).map(([id, label]) => ({ id, label, page: pageFor(navSection(id)) })).filter((m) => m.page)
    : [];
  const openSub = (id: string) => { setNavQuery(""); window.dispatchEvent(new CustomEvent("prevail:open-settings", { detail: id })); };
  const openFirstMatch = () => {
    const first = navGroups[0]?.items[0];
    if (first) { setNavQuery(""); selectEditor(first.id); }
    else if (subMatches[0]) openSub(subMatches[0].id);
  };
  // Esc leaves Settings, unless you are typing somewhere.
  useEffect(() => {
    if (!editorMode) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== "Escape" || e.defaultPrevented) return;
      const t = e.target as HTMLElement | null;
      if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.tagName === "SELECT" || t.isContentEditable)) return;
      goHome();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [editorMode]);

  const groupHeader = (label: string, open: boolean, onToggle: () => void, count: number, icon?: ReactNode) => (
    <li key={`${label}-header`}>
      <button
        onClick={onToggle}
        aria-expanded={open}
        className="flex h-8 w-full items-center gap-2 rounded-lg px-3 text-left text-[13px] text-text-muted transition-colors hover:bg-surface-warm hover:text-text-secondary"
      >
        <ChevronRight className={`h-3.5 w-3.5 shrink-0 transition-transform ${open ? "rotate-90" : ""}`} strokeWidth={2.2} />
        {icon}
        <span className="flex-1">{label}</span>
        <span className="tabular-nums text-[12px] text-text-muted/80">{count}</span>
      </button>
    </li>
  );

  const domainRow = (d: Domain) => {
    const active = d.name === selectedDomain && tab !== "work" && !editorMode;
    const Icon = domainIcon(d.name);
    const isPinned = pinned.has(d.name);
    const stat = domainStats[d.name] ?? 0;
    const held = waitingPerDomain[d.name.toLowerCase()] ?? 0;
    if (collapsed) {
      return (
        <li key={d.name}>
          <button
            onClick={() => openDomainRow(d.name)}
            title={titleCase(d.name)}
            className={`relative flex h-10 w-full items-center justify-center rounded-lg transition-colors ${active ? ACTIVE_ROW : IDLE_ROW}`}
          >
            {Icon ? <TintIcon icon={Icon} color={domainColor(d.name)} /> : (
              <span className="flex h-6 w-6 items-center justify-center rounded-full bg-surface-warm text-[11px] font-semibold text-text-secondary ring-1 ring-border">
                {titleCase(d.name).charAt(0)}
              </span>
            )}
            {held > 0 && <span className="absolute right-1.5 top-1.5 h-2 w-2 rounded-full bg-warn" title={`${held} waiting for you`} />}
          </button>
        </li>
      );
    }
    return (
      <li key={d.name} className="group relative flex items-center">
        <button
          onMouseDown={(e) => startDomainDrag(e, d.name)}
          onClick={() => openDomainRow(d.name)}
          data-chat-target=""
          data-testid={`sidebar-domain-${d.name}`}
          title="Click to enter · drag to chat as context (plain: state · ⇧ full · ⌥ entire folder)"
          aria-current={active ? "page" : undefined}
          className={`relative flex h-9 min-w-0 flex-1 cursor-grab items-center gap-3 rounded-lg pl-8 pr-9 text-left text-[14px] transition-colors active:cursor-grabbing ${active ? ACTIVE_ROW : IDLE_ROW}`}
        >
          {Icon ? <TintIcon icon={Icon} color={domainColor(d.name)} /> : <span className="h-[22px] w-[22px] shrink-0 rounded-md bg-surface-warm ring-1 ring-border" />}
          <span className="min-w-0 flex-1 truncate">{titleCase(d.name)}</span>
          {runningDomains.has(d.name) ? (
            <span className="pulse-soft inline-block h-1.5 w-1.5 shrink-0 rounded-full bg-warn" title="A reply is streaming in this domain" />
          ) : finishedDomains.has(d.name) ? (
            <span className="inline-block h-1.5 w-1.5 shrink-0 rounded-full bg-ok" title="Just finished: open to view" />
          ) : null}
          {held > 0 ? (
            <span data-testid="domain-waiting" title={`${held} waiting for you`}
              className="inline-flex shrink-0 items-center gap-0.5 rounded-full bg-warn/15 px-1.5 text-[11px] font-semibold tabular-nums leading-[18px] text-warn group-hover:opacity-0">
              <Hourglass className="h-3 w-3" />{cap99(held)}
            </span>
          ) : stat > 0 && <span title={`${stat} imports`} className="shrink-0 text-[12px] tabular-nums text-text-muted group-hover:opacity-0">{cap99(stat)}</span>}
        </button>
        {/* Row actions behind one kebab: pin, open in Finder, archive. */}
        <div className="absolute right-1 shrink-0" data-domain-menu>
          <button
            onClick={(e) => { e.stopPropagation(); setMenuOpen((cur) => (cur === d.name ? null : d.name)); }}
            className={`flex h-7 w-7 items-center justify-center rounded-md text-text-muted hover:bg-surface-warm hover:text-accent ${
              menuOpen === d.name ? "opacity-100" : "opacity-0 focus:opacity-100 group-hover:opacity-100"
            }`}
            title="Domain actions"
            aria-label={`${titleCase(d.name)} actions`}
          >
            <MoreVertical className="h-4 w-4" />
          </button>
          {menuOpen === d.name && (
            <div className="absolute right-0 top-8 z-50 w-40 rounded-lg border border-border bg-surface p-1 shadow-xl">
              <button
                onClick={(e) => { e.stopPropagation(); togglePin(d.name); setMenuOpen(null); }}
                className="flex w-full items-center gap-2 rounded-md px-2 py-1.5 text-left text-[13px] text-text-primary hover:bg-surface-warm"
              >
                <Pin className={`h-3.5 w-3.5 shrink-0 ${isPinned ? "fill-accent text-accent" : ""}`} /> {isPinned ? "Unpin" : "Pin to top"}
              </button>
              <button
                onClick={(e) => { e.stopPropagation(); openInFinder(d.path); setMenuOpen(null); }}
                className="flex w-full items-center gap-2 rounded-md px-2 py-1.5 text-left text-[13px] text-text-primary hover:bg-surface-warm"
              >
                <Folder className="h-3.5 w-3.5 shrink-0" /> Open in Finder
              </button>
              <div className="my-1 h-px bg-border-subtle" />
              <button
                onClick={(e) => { e.stopPropagation(); setMenuOpen(null); void archiveDomain(d.name); }}
                className="flex w-full items-center gap-2 rounded-md px-2 py-1.5 text-left text-[13px] text-warn hover:bg-warn/10"
              >
                <Archive className="h-3.5 w-3.5 shrink-0" /> Archive
              </button>
            </div>
          )}
        </div>
      </li>
    );
  };

  const pinnedDomains = sortedDomains.filter((d) => pinned.has(d.name));
  const otherDomains = sortedDomains.filter((d) => !pinned.has(d.name));

  return (
    <aside
      data-testid="app-sidebar"
      className="flex shrink-0 flex-col border-r border-border-subtle bg-surface-strong"
      style={{ width: collapsed ? 64 : railWidth }}
    >
      {editorMode ? (
        <>
          {/* Settings mode: one way out. The whole row returns Home. */}
          {/* The same quiet arrow toggle as Home mode: collapsed, it is the icon rail. */}
          <div className={collapsed ? "flex flex-col items-center gap-1 px-2 py-3" : "flex items-center gap-1 px-3 pb-2 pt-3"}>
            <button
              onClick={goHome}
              title="Back to Home (Esc)"
              aria-label="Back to Home"
              data-testid="settings-back"
              className={`flex items-center rounded-lg text-text-primary transition-colors hover:bg-surface-warm ${collapsed ? "h-10 w-full justify-center" : "h-10 min-w-0 flex-1 gap-2 px-2"}`}
            >
              <ArrowLeft className="h-4 w-4 shrink-0 text-text-muted" />
              {!collapsed && <span className="text-[15px] font-semibold">Settings</span>}
            </button>
            {collapseButton}
          </div>
          {!collapsed && (
            <div className="px-3 pb-2">
              <label className="flex h-9 w-full items-center gap-2 rounded-lg border border-border-subtle bg-background px-3 text-text-muted focus-within:border-accent-border">
                <Search className="h-4 w-4 shrink-0" />
                <input
                  value={navQuery}
                  onChange={(e) => setNavQuery(e.target.value)}
                  onKeyDown={(e) => {
                    if (e.key === "Enter") { e.preventDefault(); openFirstMatch(); }
                    else if (e.key === "Escape" && navQuery) { e.preventDefault(); setNavQuery(""); }
                  }}
                  placeholder="Search settings"
                  aria-label="Search settings"
                  className="min-w-0 flex-1 bg-transparent text-[14px] text-text-primary placeholder:text-text-muted focus:outline-none"
                />
              </label>
            </div>
          )}
        </>
      ) : (
        <>
          <ProfileSwitcher collapsed={collapsed} trailing={collapseButton} />
          {/* Search opens the command palette (it searches every screen, action
              and domain). */}
          <div className={collapsed ? "px-2 pb-2" : "px-3 pb-2"}>
            <button
              onClick={() => window.dispatchEvent(new Event("prevail:open-palette"))}
              title="Search (⌘K)"
              aria-label="Search"
              className={`flex w-full items-center rounded-lg border border-border-subtle bg-background text-text-muted transition-colors hover:border-accent-border hover:text-text-secondary ${
                collapsed ? "h-10 justify-center" : "h-9 gap-2 px-3"
              }`}
            >
              <Search className="h-4 w-4 shrink-0" />
              {!collapsed && (
                <>
                  <span className="flex-1 text-left text-[14px]">Search</span>
                  <kbd className="rounded-md border border-border-subtle bg-surface px-1.5 text-[11px] font-medium leading-[18px] text-text-muted">⌘K</kbd>
                </>
              )}
            </button>
          </div>
        </>
      )}

      <div className="min-h-0 flex-1 overflow-y-auto overflow-x-hidden pb-2" onScroll={(e) => markStuck(e.currentTarget)} data-testid="sidebar-scroll">
        {editorMode ? (
          <div className={collapsed ? "px-2" : "px-3"}>
            {navGroups.map((group) => {
              const holdsActive = group.items.some((i) => i.id === editorActive);
              // A group that is one page is just its row: no heading to fold.
              const single = group.items.length === 1;
              const open = collapsed || single || holdsActive || !!q || !closedNavGroups.has(group.heading);
              return (
                <div key={group.heading} className="mb-1.5">
                  {!collapsed && !single && (
                    <button
                      onClick={() => toggleNavGroup(group.heading)}
                      aria-expanded={open}
                      data-sticky-head
                      data-testid={`settings-group-${group.heading.toLowerCase().replace(/[^a-z]+/g, "-")}`}
                      className={`mb-0.5 mt-2 flex h-8 w-full items-center gap-3 pl-6 pr-3 transition-colors hover:text-text-secondary ${SECTION_LABEL} ${SIDEBAR_STICKY}`}
                    >
                      {group.icon && <span className="flex w-[22px] shrink-0 justify-center"><TintIcon icon={group.icon} tint={group.tint} square={false} size={14} /></span>}
                      <span className="flex-1 text-left">{group.heading}</span>
                      {!open && <span className="font-medium tabular-nums text-text-muted/70">{group.items.length}</span>}
                      <ChevronRight className={`h-3 w-3 shrink-0 transition-transform ${open ? "rotate-90" : ""}`} strokeWidth={2.5} />
                    </button>
                  )}
                  {open && (
                    <div className={`space-y-0.5 ${!collapsed && !single ? "pl-7" : ""}`}>
                      {group.items.map((it) => (
                        <NavRow key={it.id} icon={it.icon} tint={it.id} label={it.label} active={editorActive === it.id} collapsed={collapsed} onClick={() => selectEditor(it.id)} onPrefetch={() => prefetchSection("settings", it.id, vaultPath)} />
                      ))}
                    </div>
                  )}
                </div>
              );
            })}
            {subMatches.length > 0 && (
              <div data-testid="settings-sub-matches" className="space-y-0.5">
                {subMatches.map((m) => (
                  <NavRow key={m.id} icon={m.page!.icon} tint={m.page!.id} label={`${m.label} in ${m.page!.label}`} active={false} collapsed={collapsed} onClick={() => openSub(m.id)} />
                ))}
              </div>
            )}
            {q && navGroups.length === 0 && subMatches.length === 0 && (
              <p className="px-3 py-2 text-[13px] text-text-muted">No settings match.</p>
            )}
          </div>
        ) : (
          <>
            <nav aria-label="Home" className={`space-y-0.5 ${collapsed ? "px-2" : "px-3"}`}>
              <NavRow icon={House} lead={<ChiefAvatar size={22} />} chatTarget label={chief ?? "Home"} title={chief ? `${chief}, your chief of staff` : undefined} active={homeActive} collapsed={collapsed} onClick={goHome} testId="nav-home" />
              <NavRow icon={Inbox} tint="inbox" label="Inbox" count={waiting.total} loud active={tab === "work" && workActive === "inbox"} collapsed={collapsed} onClick={() => selectWork("inbox")} onPrefetch={() => prefetchSection("work", "inbox", vaultPath)} testId="nav-inbox" />
              {WORK_NAV[0].items.map((it) => (
                <NavRow key={it.id} icon={it.icon} tint={it.id} label={it.label} active={tab === "work" && workActive === it.id} collapsed={collapsed} onClick={() => selectWork(it.id)} onPrefetch={() => prefetchSection("work", it.id, vaultPath)} />
              ))}
            </nav>

            <Divider />
            <section>
            {!collapsed && <SectionHeader label="Work" icon={Briefcase} tint="work" count={openTasks} open={workOpen} onToggle={() => setWorkOpen((v) => !v)} onAdd={newTask} addTitle="New task" />}
            {(collapsed || workOpen) && (
              <nav aria-label="Work" className={`space-y-0.5 ${collapsed ? "px-2" : SECTION_PAD}`}>
                {WORK_NAV.slice(1).flatMap((g) => g.items).map((it) => (
                  <NavRow key={it.id} icon={it.icon} tint={it.id} label={it.label} count={workCounts[it.id] ?? 0} active={tab === "work" && workActive === it.id} collapsed={collapsed} onClick={() => selectWork(it.id)} onPrefetch={() => prefetchSection("work", it.id, vaultPath)} />
                ))}
              </nav>
            )}
            </section>

            {(["entities", "activities"] as const).map((g) => {
              const open = g === "entities" ? entitiesOpen : activitiesOpen;
              const setOpen = g === "entities" ? setEntitiesOpen : setActivitiesOpen;
              return (
                <Fragment key={g}>
                  <Divider />
                  <section data-testid={`sidebar-${g}`}>
                    {!collapsed && <SectionHeader label={g === "entities" ? "Entities" : "Activities"} icon={g === "entities" ? Shapes : CalendarRange} tint={g} count={g === "entities" ? entityCount : activityCount} open={open} onToggle={() => setOpen((v) => !v)} />}
                    {(collapsed || open) && (
                      <nav aria-label={g === "entities" ? "Entities" : "Activities"} className={`space-y-0.5 ${collapsed ? "px-2" : SECTION_PAD}`}>
                        {kindsOf(g).map((k) => (
                          <KindRow key={k.id} def={k} collapsed={collapsed} count={kindCount(k.id)} active={kindActive(k.id)} open={kindOpen.has(k.id)}
                            onOpen={() => { setOpenMissionSlug(null); openKind(k.id); }} onToggle={() => toggleKind(k.id)} onAdd={() => newOfKind(k.id)}>
                            {kindItems(k.id)}
                          </KindRow>
                        ))}
                      </nav>
                    )}
                  </section>
                </Fragment>
              );
            })}

            {specialists.length > 0 && (
              <>
                <Divider />
                <section>
                {!collapsed && <SectionHeader label="Specialists" icon={Sparkles} tint="specialists" count={specialists.length} open={specsOpen} onToggle={() => setSpecsOpen((v) => !v)} />}
                {(collapsed || specsOpen) && (
                  <nav aria-label="Specialists" data-testid="sidebar-specialists" className={`space-y-0.5 ${collapsed ? "px-2" : SECTION_PAD}`}>
                    {!collapsed && specialists.map((x) => (
                      <NavRow key={x.id} icon={UserCog} lead={<SpecialistAvatar id={x.id} size={22} state={working.has(x.id) ? "working" : "idle"} />} label={x.name} title={`${x.name}: click to open, drag into a chat to hand it a message`} active={false} collapsed={collapsed}
                        onClick={() => openSpecialist(`spec:${x.id}`)} onMouseDown={(e) => startSpecialistDrag(e, x.name)} testId={`sidebar-specialist-${x.id}`} />
                    ))}
                  </nav>
                )}
                </section>
              </>
            )}


            <Divider />
            <section>
            {!collapsed && (
              <SectionHeader
                label="Domains"
                icon={LayoutGrid}
                tint="domains"
                count={sortedDomains.length}
                open={domainsOpen}
                onToggle={() => setDomainsOpen((v) => !v)}
                onAdd={() => { setDomainsOpen(true); setAdding(true); }}
                addTitle="New domain"
                tour="domains"
                dot={domainSuggestions > 0 ? { count: domainSuggestions, title: `${domainSuggestions} new domain ${domainSuggestions === 1 ? "suggestion" : "suggestions"}`, onClick: openStructure } : undefined}
              />
            )}
            {vaultError && !collapsed && domainsOpen && (
              <div className="my-2 ml-6 mr-3 rounded-lg border border-warn/40 bg-warn/10 p-2 text-[13px] text-warn">{vaultError}</div>
            )}
            {sortedDomains.length === 0 && !vaultError && !collapsed && domainsOpen && (
              <div className={`${SECTION_PAD} py-2`}>
                <p className="mb-2 text-[13px] text-text-muted">No domains yet. Let Glyph Studio suggest a starter set, or add one with the + above.</p>
                <button
                  onClick={onOpenOnboarding}
                  className="flex h-9 w-full items-center justify-center gap-2 rounded-lg bg-accent px-3 text-[14px] font-semibold text-on-accent transition-opacity hover:opacity-90"
                >
                  <Sparkles className="h-4 w-4" />
                  Set up domains
                </button>
              </div>
            )}
            {collapsed ? (
              <ul className="space-y-0.5 px-2">{sortedDomains.map(domainRow)}</ul>
            ) : domainsOpen && (
              <ul data-testid="sidebar-domains-list" className={`space-y-0.5 ${SECTION_PAD}`}>
                {pinnedDomains.length > 0 && (
                  <Fragment>
                    {groupHeader("Pinned", pinnedOpen, () => setPinnedOpen((v) => !v), pinnedCount)}
                    {pinnedOpen && pinnedDomains.map(domainRow)}
                  </Fragment>
                )}
                {otherDomains.length > 0 && (
                  <Fragment>
                    {groupHeader("All", allOpen, () => setAllOpen((v) => !v), otherDomains.length)}
                    {allOpen && otherDomains.map(domainRow)}
                  </Fragment>
                )}
                {archived.length > 0 && (
                  <Fragment>
                    {groupHeader("Archived", archivedOpen, () => setArchivedOpen((v) => !v), archived.length)}
                    {archivedOpen && archived.map((name) => (
                      <li key={`archived-${name}`} className="group flex h-9 items-center gap-3 rounded-lg pl-8 pr-2 text-text-muted">
                        <Archive className="h-4 w-4 shrink-0 opacity-70" />
                        <span className="min-w-0 flex-1 truncate text-[14px]">{titleCase(name)}</span>
                        <button
                          onClick={() => restoreDomain(name)}
                          disabled={restoring === name}
                          title={`Restore ${titleCase(name)}`}
                          className="flex shrink-0 items-center gap-1 rounded-md border border-border bg-background px-2 py-0.5 text-[12px] text-text-muted opacity-0 hover:border-accent-border hover:text-accent focus:opacity-100 group-hover:opacity-100 disabled:opacity-100"
                        >
                          {restoring === name ? <Loader2 className="h-3 w-3 animate-spin" /> : <RotateCcw className="h-3 w-3" />}
                          Restore
                        </button>
                      </li>
                    ))}
                  </Fragment>
                )}
              </ul>
            )}
            {!collapsed && domainsOpen && adding && (
              <div className={`mt-2 ${SECTION_PAD}`}>
                <div className="rounded-lg border border-border bg-background p-2">
                  <input
                    autoFocus
                    value={newName}
                    onChange={(e) => setNewName(e.target.value)}
                    onKeyDown={(e) => {
                      if (e.key === "Enter") createDomain();
                      if (e.key === "Escape") { setAdding(false); setNewName(""); setAddError(null); }
                    }}
                    placeholder="e.g. travel"
                    aria-label="New domain name"
                    className="w-full bg-transparent px-1 py-0.5 text-[14px] focus:outline-none"
                  />
                  {addError && <div className="mt-1 text-[12px] text-err">{addError}</div>}
                  <div className="mt-2 flex gap-1.5">
                    <button
                      onClick={createDomain}
                      disabled={!newName.trim()}
                      className="rounded-md bg-accent px-2.5 py-1 text-[13px] font-medium text-on-accent hover:bg-accent-hover disabled:bg-surface-warm disabled:text-text-muted"
                    >
                      Create
                    </button>
                    <button
                      onClick={() => { setAdding(false); setNewName(""); setAddError(null); }}
                      className="rounded-md border border-border px-2.5 py-1 text-[13px] text-text-muted hover:bg-surface-warm"
                    >
                      Cancel
                    </button>
                  </div>
                </div>
              </div>
            )}
            </section>
          </>
        )}
      </div>

      {/* One slim footer line: Settings, and the background-work popover. */}
      <div className={`flex shrink-0 items-center border-t border-border-subtle ${collapsed ? "flex-col gap-1 py-2" : "gap-1 px-3 py-2"}`}>
        {!editorMode && settingsButton}
        {!collapsed && <div className="flex-1" />}
        <FooterProcesses collapsed={collapsed} setTab={setTab} />
      </div>
    </aside>
  );
}

// Footer "Processes" control: one small icon (with a live count badge) that
// replaces the old stack of always-visible status strips. Clicking it opens a
// modal listing everything happening in the background, so the sidebar corner
// stays minimal until the user actually wants the detail.
function FooterProcesses({ collapsed, setTab }: { collapsed: boolean; setTab: (t: TabId) => void }) {
  const [open, setOpen] = useState(false);
  const btnRef = useRef<HTMLButtonElement>(null);
  const procs = useProcesses();
  const runningBench = useBenchBatches().filter((b) => b.running);
  const count = procs.length + runningBench.length;
  return (
    <>
      <button
        ref={btnRef}
        onClick={() => setOpen((v) => !v)}
        title={count > 0
          ? `${count} background process${count === 1 ? "" : "es"} running (click for details)`
          : "Background processes: scheduled benchmarks, backups & live activity"}
        className={`relative flex ${collapsed ? "h-8 w-8" : "h-6 w-6"} shrink-0 items-center justify-center rounded-full text-text-muted transition-colors hover:bg-surface-warm hover:text-accent ${open ? "bg-surface-warm text-accent" : ""}`}
      >
        <Activity className={collapsed ? "h-4 w-4" : "h-3.5 w-3.5"} />
        {count > 0 && (
          <span className="absolute -right-1 -top-1 flex h-3.5 min-w-3.5 items-center justify-center rounded-full bg-accent px-1 font-mono text-[10px] font-bold leading-none text-background">
            {count}
          </span>
        )}
      </button>
      {open && <ProcessesPopover anchorRef={btnRef} onClose={() => setOpen(false)} setTab={setTab} />}
    </>
  );
}

// The consolidated background-activity popover. Anchored to the footer
// Activity icon (bottom-left of the sidebar) and rises upward from it, so it
// appears where the user clicked rather than centered on screen. Reuses the
// existing strip components (they self-hide when inactive) so nothing about how
// a process, benchmark, backup, or connection renders had to be reimplemented.
function ProcessesPopover(
  { anchorRef, onClose, setTab }:
  { anchorRef: RefObject<HTMLButtonElement | null>; onClose: () => void; setTab: (t: TabId) => void },
) {
  const procs = useProcesses();
  const runningBench = useBenchBatches().filter((b) => b.running);
  const backupOn = lsGet(BACKUP_CFG.enabled, "0") === "1";
  const empty = procs.length === 0 && runningBench.length === 0 && !backupOn;
  // A small live count of the actively running work (processes + benchmark
  // runs) for the header badge. Scheduled/armed items are not counted here since
  // they are waiting, not running.
  const runningCount = procs.length + runningBench.length;

  // Anchor to the trigger: fixed positioning (so sidebar overflow never clips
  // it), left-aligned to the icon, bottom sitting just above it so the card
  // grows upward from the bottom-left footer corner.
  const [pos, setPos] = useState<{ left: number; bottom: number } | null>(null);
  const [shown, setShown] = useState(false);
  useEffect(() => {
    const place = () => {
      const r = anchorRef.current?.getBoundingClientRect();
      if (!r) return;
      const left = Math.max(8, r.left);
      const bottom = Math.max(8, window.innerHeight - r.top + 8);
      setPos({ left, bottom });
    };
    place();
    // Entrance feel: mount slightly offset/faded, then settle on next frame.
    const raf = requestAnimationFrame(() => setShown(true));
    window.addEventListener("resize", place);
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); };
    window.addEventListener("keydown", onKey);
    return () => {
      cancelAnimationFrame(raf);
      window.removeEventListener("resize", place);
      window.removeEventListener("keydown", onKey);
    };
  }, [anchorRef, onClose]);

  return (
    // Transparent click-away backdrop.
    <div className="fixed inset-0 z-50" onClick={onClose}>
      <div
        role="dialog"
        aria-label="Background processes"
        onClick={(e) => e.stopPropagation()}
        style={{
          position: "fixed",
          left: pos?.left ?? 8,
          bottom: pos?.bottom ?? 8,
          width: 320,
          visibility: pos ? "visible" : "hidden",
          transformOrigin: "bottom left",
          transform: shown ? "translateY(0) scale(1)" : "translateY(6px) scale(0.98)",
          opacity: shown ? 1 : 0,
          transition: "opacity 140ms ease-out, transform 140ms ease-out",
        }}
        className="overflow-hidden rounded-2xl border border-border bg-surface shadow-2xl ring-1 ring-black/5"
      >
        <div className="flex items-center justify-between border-b border-border-subtle/70 px-4 pb-3 pt-3.5">
          <span className="flex items-center gap-2.5">
            <span className="flex h-7 w-7 items-center justify-center rounded-lg bg-accent-soft text-accent">
              <Activity className="h-4 w-4" />
            </span>
            <span className="flex flex-col leading-tight">
              <span className="text-[13px] font-semibold text-text-primary">Background work</span>
              <span className="text-[10px] text-text-muted">Live and scheduled activity</span>
            </span>
          </span>
          <span className="flex items-center gap-1.5">
            {runningCount > 0 && (
              <span className="flex items-center gap-1 rounded-full bg-accent-soft px-2 py-0.5 text-[10px] font-semibold text-accent">
                <span className="h-1.5 w-1.5 rounded-full bg-accent animate-pulse" />
                {runningCount} live
              </span>
            )}
            <button
              onClick={onClose}
              title="Close"
              className="flex h-7 w-7 items-center justify-center rounded-lg text-text-muted transition-colors hover:bg-surface-warm hover:text-text-primary"
            >
              <X className="h-4 w-4" />
            </button>
          </span>
        </div>
        <div className="max-h-[min(60vh,420px)] overflow-y-auto p-2">
          {empty ? (
            <div className="flex flex-col items-center gap-2.5 px-4 py-9 text-center">
              <span className="flex h-11 w-11 items-center justify-center rounded-full bg-surface-warm text-text-muted">
                <Activity className="h-5 w-5" />
              </span>
              <span className="text-[13px] font-medium text-text-secondary">All quiet</span>
              <span className="max-w-[220px] text-[11px] leading-relaxed text-text-muted">
                Scheduled benchmarks, automatic backups, and live activity like chats, council, and loops will show up here.
              </span>
            </div>
          ) : (
            <div className="flex flex-col gap-1.5">
              <SidebarProcesses collapsed={false} setTab={setTab} />
              <SidebarBenchmarkRuns collapsed={false} />
              <SidebarBackupActive collapsed={false} />
              <SidebarGatewayLive collapsed={false} />
              <SidebarMcpLive collapsed={false} setTab={setTab} />
            </div>
          )}
        </div>
      </div>
    </div>
  );
}


// One floating life-domain chip: parallaxes with the cursor (via shared
// springs) and gently bobs. Icons only - never emojis.
