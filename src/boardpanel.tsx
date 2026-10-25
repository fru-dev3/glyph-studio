// Tasks: every task across your domains as one plain list. Tasks are owned by
// Me or AI; AI-owned tasks run as workflows via the Loop steward, and anything
// consequential waits in the Inbox. Reads tasks_read_all; moves via
// tasks_set_status / tasks_set_owner. Trash and Icebox sit behind More.
import { useCallback, useEffect, useMemo, useState } from "react";
import { VIRTUAL_MIN, VirtualRows } from "./virtualrows";
import { Bot, Filter, Flag, LayoutGrid, ListChecks, Loader2, Play, Plus, RotateCcw, Search, Trash2, User, Zap } from "lucide-react";
import { invoke, listen } from "./bridge";
import type { UnlistenFn } from "./bridge";
import { invokeCached, peekInvoke, useInvokeQuery } from "./query";
import { SettingsHeader } from "./sectionutil";
import { titleCase } from "./format";
import { isHarnessRuntime } from "./constants";
import { PREF, cheapModel, getPref } from "./storage";
import { WaitingChip } from "./actcard";
import { useWaiting, waitingTaskIds } from "./waiting";
import { TaskDetailPanel } from "./taskdetail";
import { SideSpine, SpineTabs } from "./sidespine";
import { useIsPhone } from "./useisphone";
import type { BoardTask, CliInfo } from "./types";
import { isUserDomain } from "./helpers";
import { RowMenu } from "./ui";

const iconBtn = "flex h-8 w-8 shrink-0 items-center justify-center rounded-md text-text-muted transition-colors hover:bg-surface-warm hover:text-accent disabled:opacity-50";

type BoardView = "open" | "waiting" | "done" | "trash" | "icebox";

const dueTone = (due?: string | null): string => {
  if (!due) return "text-text-muted/60";
  const today = new Date().toISOString().slice(0, 10);
  if (due < today) return "text-err";
  if (due === today) return "text-warn";
  return "text-text-muted";
};

// A task is OVERDUE when it has a due date strictly before today and is not done.
// Overdue work gets a loud red alert treatment everywhere it renders so it cannot
// be missed.
const isOverdue = (t: BoardTask): boolean => {
  if (!t.due || t.status === "done" || t.done) return false;
  const today = new Date().toISOString().slice(0, 10);
  return t.due < today;
};

// Turn a raw harness failure into something actionable. External harnesses
// (Hermes, Pi, OpenCode) bring their own model, so "validated" only means the
// binary is installed and responds — it does NOT mean the harness is logged in
// to a model provider. The most common runtime failure is exactly that missing
// login, so we detect it and tell the user how to fix it instead of dumping
// raw stderr. `cli` is the harness binary id (empty for the built-in Prevail
// agent, which never hits this path).
function humanizeAgentError(label: string, cli: string, raw: string): string {
  const needsLogin = /no api key|not logged in|\/login|unauthor|no provider|missing .*api.?key|set .*api.?key/i.test(raw);
  if (needsLogin && cli) {
    return [
      `${label} started but isn't signed in to a model provider yet, so it couldn't run.`,
      "",
      `${label} is a separate agent that runs on its own model, so it needs a one-time login in its own app. Open a terminal and run \`${cli}\`, then \`/login\`. Glyph Studio confirmed ${label} is installed (that's the green check), but it can't sign in on ${label}'s behalf.`,
      "",
      `Once ${label} is logged in, run this task again. Or hand it to the built-in Glyph Studio agent, which runs on your Glyph Studio model and needs no separate login.`,
      "",
      "- original message -",
      raw,
    ].join("\n");
  }
  return `${label} couldn't finish:\n\n${raw}`;
}

export function BoardPanel({ vaultPath, initialDomain, clis }: { vaultPath: string; initialDomain?: string; clis?: CliInfo[] }) {
  const [tasks, setTasks] = useState<BoardTask[]>(() => { const c = peekInvoke<BoardTask[]>("tasks_read_all", { vault: vaultPath, limit: 200 }); return Array.isArray(c) ? c : []; });
  // Installed harness agents available to run a task (Hermes/Pi/OpenCode/…).
  const harnesses = useMemo(() => (clis ?? []).filter((c) => isHarnessRuntime(c.id) && c.available), [clis]);
  // Which task's "Run with agent" picker is open, and which tasks are mid-run.
  const [agentRunning, setAgentRunning] = useState<Set<string>>(new Set());
  const [ownerFilter, setOwnerFilter] = useState<"all" | "me" | "ai">("all");
  // When opened scoped to a domain (the in-domain Work tab), pre-filter to it.
  const [domainFilter, setDomainFilter] = useState<string>(initialDomain || "all");
  const [view, setView] = useState<BoardView>("open");
  const [q, setQ] = useState("");
  const phone = useIsPhone();
  const [busy, setBusy] = useState<string | null>(null);
  // The task opened in the detail panel (full "task object" view).
  const [openId, setOpenId] = useState<string | null>(null);
  const [addText, setAddText] = useState("");
  const [addDomain, setAddDomain] = useState("");
  const [addDue, setAddDue] = useState("");
  const [addModalOpen, setAddModalOpen] = useState(false);
  // The sidebar's Work "+" opens this dialog; a flag covers a board that is
  // still mounting when the event fires.
  useEffect(() => {
    const open = () => setAddModalOpen(true);
    try { if (localStorage.getItem("prevail.board.openAdd") === "1") { localStorage.removeItem("prevail.board.openAdd"); open(); } } catch { /* storage off */ }
    window.addEventListener("prevail:board-add", open);
    return () => window.removeEventListener("prevail:board-add", open);
  }, []);
  const [running, setRunning] = useState(false);
  const domainsQ = useInvokeQuery<{ name: string }[]>("scan_vault", { path: vaultPath });
  const allDomains = useMemo(() => (Array.isArray(domainsQ.data) ? domainsQ.data.map((d) => d.name).filter(isUserDomain) : []), [domainsQ.data]);
  // Backend pagination: read a bounded first page (open/time-sensitive tasks
  // first) so a huge vault doesn't ship every task at once. "Load more tasks"
  // raises the cap. Default page is generous so normal vaults load everything.
  const TASK_PAGE = 200;
  const [taskLimit, setTaskLimit] = useState(TASK_PAGE);
  const [maybeMore, setMaybeMore] = useState(() => tasks.length >= TASK_PAGE);

  const reload = useCallback(() => {
    invokeCached<BoardTask[]>("tasks_read_all", { vault: vaultPath, limit: taskLimit }, { force: true })
      .then((t) => { const arr = Array.isArray(t) ? t : []; setTasks(arr); setMaybeMore(arr.length >= taskLimit); })
      .catch((e) => console.error("tasks_read_all", e));
  }, [vaultPath, taskLimit]);
  useEffect(() => { reload(); }, [reload]);
  useEffect(() => {
    const f = () => reload();
    window.addEventListener("prevail:tasks-changed", f);
    return () => window.removeEventListener("prevail:tasks-changed", f);
  }, [reload]);
  // A task link in a chat reply opens that task's detail panel. Tasks is often
  // mounting fresh when the link is clicked, so the id also waits in
  // localStorage for this first render.
  useEffect(() => {
    const onOpenTask = (e: Event) => {
      const id = (e as CustomEvent<string>).detail;
      if (typeof id === "string" && id) {
        try { localStorage.removeItem("prevail.board.openTask"); } catch { /* storage off */ }
        setOpenId(id);
      }
    };
    window.addEventListener("prevail:open-task", onOpenTask as EventListener);
    try {
      const pending = localStorage.getItem("prevail.board.openTask");
      if (pending) { localStorage.removeItem("prevail.board.openTask"); setOpenId(pending); }
    } catch { /* storage off */ }
    return () => window.removeEventListener("prevail:open-task", onOpenTask as EventListener);
  }, []);
  // Full domain list (so you can add a task to a domain that has none yet):
  // domainsQ above, shared with every other domain picker.

  // Filter dropdown shows only domains with tasks; the add picker offers every domain.
  const domains = useMemo(() => [...new Set(tasks.map((t) => t.domain))].sort(), [tasks]);
  const addDomains = useMemo(
    () => [...new Set([...allDomains, ...domains])].sort(),
    [allDomains, domains],
  );
  useEffect(() => { if (!addDomain && addDomains.length) setAddDomain(addDomains[0]); }, [addDomains, addDomain]);

  const shown = useMemo(
    () => tasks.filter((t) =>
      !t.trashed && // trashed tasks live in the Trash view, not the normal board
      t.status !== "icebox" && // iceboxed tasks are set aside; they live in the Icebox view
      (ownerFilter === "all" || t.owner === ownerFilter) &&
      (domainFilter === "all" || t.domain === domainFilter)),
    [tasks, ownerFilter, domainFilter],
  );
  // Set-aside tasks: not done, not trashed, just parked. Recoverable from the Icebox view.
  const iceboxed = useMemo(
    () => tasks.filter((t) =>
      t.status === "icebox" && !t.trashed &&
      (ownerFilter === "all" || t.owner === ownerFilter) &&
      (domainFilter === "all" || t.domain === domainFilter)),
    [tasks, ownerFilter, domainFilter],
  );
  // Soft-deleted tasks, newest first, honoring the same owner/domain filters.
  const trashed = useMemo(
    () => tasks.filter((t) =>
      t.trashed &&
      (ownerFilter === "all" || t.owner === ownerFilter) &&
      (domainFilter === "all" || t.domain === domainFilter))
      .sort((a, b) => (b.trashed || "").localeCompare(a.trashed || "")),
    [tasks, ownerFilter, domainFilter],
  );
  // Live read on the AI workflow (across all owners/domains, ignoring filters):
  // what AI is actively working, what's queued to it, what's waiting on you.
  const flow = useMemo(() => ({
    inFlight: tasks.filter((t) => t.owner === "ai" && t.status === "doing").length,
    queued: tasks.filter((t) => t.owner === "ai" && t.status === "todo").length,
    waiting: tasks.filter((t) => t.status === "review" || t.status === "blocked").length,
  }), [tasks]);

  // Trigger one engine pass now (advances loops + works AI-owned tasks) so handing
  // a task to AI produces visible movement instead of waiting for the daemon tick.
  const runNow = async () => {
    setRunning(true);
    try {
      const provider = getPref(PREF.memoryProvider, "claude");
      const model = cheapModel();
      await invoke("loops_run_once", { vault: vaultPath, provider, model });
      reload();
      window.dispatchEvent(new Event("prevail:tasks-changed"));
      window.dispatchEvent(new Event("prevail:loops-advanced"));
    } catch (e) { console.error("run now", e); }
    finally { setRunning(false); }
  };

  const act = async (key: string, fn: () => Promise<unknown>) => {
    setBusy(key);
    try { await fn(); reload(); window.dispatchEvent(new Event("prevail:tasks-changed")); }
    catch (e) { console.error("board action", e); }
    finally { setBusy(null); }
  };

  // Delegate a task to a harness agent: stream the run, then append the agent's
  // output as a comment and move the task to Review (the result sink). Defaults
  // to safe autonomy — the engine's broker gate guards consequential actions.
  const runWithAgent = async (t: BoardTask, cli: string) => {
    if (!t.id) return;
    const taskId = t.id;
    // "prevail" is the built-in agent: run with the default runtime (no --cli),
    // so it uses whatever model Prevail already runs on, no harness login needed.
    const effectiveCli = cli === "prevail" ? "" : cli;
    const agentLabel = cli === "prevail" ? "Glyph Studio" : cli;
    setAgentRunning((s) => new Set(s).add(taskId));
    const session = `agent-${taskId}-${Date.now()}`;
    let result = "";
    let errored = false;
    let unline: UnlistenFn | undefined;
    let undone: UnlistenFn | undefined;
    const cleanup = () => {
      try { unline?.(); } catch { /* */ }
      try { undone?.(); } catch { /* */ }
      setAgentRunning((s) => { const n = new Set(s); n.delete(taskId); return n; });
    };
    try {
      unline = await listen<{ session: string; data: { type?: string; text?: string; error?: string } }>("engine-agent:line", (e) => {
        if (e.payload.session !== session) return;
        const d = e.payload.data;
        if (d?.type === "assistant" && d.text) { result = d.text; errored = false; }
        else if (d?.type === "error" && d.error) { result = d.error; errored = true; }
      });
      undone = await listen<{ session: string }>("engine-agent:done", async (e) => {
        if (e.payload.session !== session) return;
        try {
          const text = errored ? humanizeAgentError(agentLabel, effectiveCli, result.trim()) : result.trim();
          if (text) {
            await invoke("task_detail_add_comment", { vault: vaultPath, domain: t.domain, id: taskId, text, author: agentLabel });
            // Only advance to Review on a real result. A login/setup failure
            // means the task was never actually worked, so leave its status.
            if (!errored && (t.status === "todo" || t.status === "doing")) {
              await invoke("tasks_set_status", { vault: vaultPath, domain: t.domain, id: taskId, status: "review" });
            }
          }
        } catch (err) { console.error("agent result sink", err); }
        cleanup();
        window.dispatchEvent(new Event("prevail:tasks-changed"));
      });
      await invoke("engine_agent_run", { session, vault: vaultPath, domain: t.domain, goal: t.text, taskId, cli: effectiveCli, autonomy: "safe" });
    } catch (err) {
      console.error("engine_agent_run", err);
      cleanup();
    }
  };
  // Bulk hand-off: assign every currently-shown, me-owned, open task to the agent
  // at once - so you do not have to click "hand to AI" on each one. Skips anything
  // that needs the human (blocked = awaiting a decision, or in Review), and skips
  // done tasks. Respects the active owner/domain filters via "shown".
  const [bulkMsg, setBulkMsg] = useState<string | null>(null);
  const needsHuman = (t: BoardTask) => t.status === "blocked" || t.status === "review";
  const assignAllToAgent = async () => {
    const targets = shown.filter((t) => t.id && t.owner === "me" && t.status !== "done" && !needsHuman(t));
    setBulkMsg(null);
    if (targets.length === 0) { setBulkMsg("Nothing to assign - no eligible tasks owned by you."); window.setTimeout(() => setBulkMsg(null), 4000); return; }
    setBusy("bulk-assign");
    try {
      await Promise.all(targets.map((t) =>
        invoke("tasks_set_owner", { vault: vaultPath, domain: t.domain, id: t.id, owner: "ai" })
          // Move queued todo work into Doing so the steward picks it up, mirroring toggleOwner.
          .then(() => (t.status === "todo" ? invoke("tasks_set_status", { vault: vaultPath, domain: t.domain, id: t.id, status: "doing" }) : null))));
      reload();
      window.dispatchEvent(new Event("prevail:tasks-changed"));
      setBulkMsg(`Handed ${targets.length} task${targets.length === 1 ? "" : "s"} to the agent.`);
    } catch (e) {
      console.error("assign all to agent", e);
      setBulkMsg(`Failed to assign: ${String(e)}`);
    } finally {
      setBusy(null);
      window.setTimeout(() => setBulkMsg(null), 4000);
    }
  };

  // Delete = soft-delete: tag the task ~trashed:<today> so it moves to Trash
  // (recoverable), never silently lost. Honors the "never delete user data" rule.
  const del = async (t: BoardTask) => {
    if (!t.id) return;
    const today = new Date().toISOString().slice(0, 10);
    await act(`d:${t.id}`, async () => {
      const cur = await invoke<BoardTask[]>("tasks_read", { vault: vaultPath, domain: t.domain });
      await invoke("tasks_set", { vault: vaultPath, domain: t.domain, tasks: cur.map((x) => (x.id === t.id ? { ...x, trashed: today } : x)) });
    });
  };
  // Restore a trashed task back to the board (clear the marker).
  const restore = async (t: BoardTask) => {
    if (!t.id) return;
    await act(`r:${t.id}`, async () => {
      const cur = await invoke<BoardTask[]>("tasks_read", { vault: vaultPath, domain: t.domain });
      await invoke("tasks_set", { vault: vaultPath, domain: t.domain, tasks: cur.map((x) => (x.id === t.id ? { ...x, trashed: null } : x)) });
    });
  };
  // Delete forever: actually remove the line. Only from the Trash view, with confirm.
  const purge = async (t: BoardTask) => {
    if (!t.id) return;
    if (!window.confirm(`Permanently delete "${t.text.slice(0, 60)}"? This cannot be undone.`)) return;
    await act(`p:${t.id}`, async () => {
      const cur = await invoke<BoardTask[]>("tasks_read", { vault: vaultPath, domain: t.domain });
      await invoke("tasks_set", { vault: vaultPath, domain: t.domain, tasks: cur.filter((x) => x.id !== t.id) });
    });
  };
  // Tasks the engine counts as waiting on you (blocked on your call).
  const waiting = useWaiting(vaultPath);
  const heldTaskIds = useMemo(() => waitingTaskIds(waiting.items), [waiting]);

  // Ordering: open work first (todo, doing, review), done last; then by due.
  const ORDER: Record<string, number> = { todo: 0, doing: 1, blocked: 1, review: 2, done: 3, icebox: 4 };
  const listed = useMemo(
    () => [...shown].sort((a, b) =>
      (ORDER[a.status] ?? 0) - (ORDER[b.status] ?? 0) ||
      (a.due || "9999").localeCompare(b.due || "9999")),
    [shown],
  );
  const [addErr, setAddErr] = useState<string | null>(null);
  // Brief auto-dismissing "Added" confirmation shown near the add bar.
  const [addMsg, setAddMsg] = useState<string | null>(null);
  const addTask = () => {
    const text = addText.trim();
    const domain = (addDomain || addDomains[0] || "").trim();
    setAddErr(null);
    setAddMsg(null);
    if (!text) { setAddErr("Type a task first."); return; }
    if (!domain) { setAddErr("Create a domain first (no domain to add to)."); return; }
    const withDue = addDue ? `${text} @${addDue}` : text;
    setBusy("add");
    invoke("tasks_add", { vault: vaultPath, domain, text: withDue, source: "user" })
      .then(() => {
        setAddText("");
        setAddDue("");
        reload();
        window.dispatchEvent(new Event("prevail:tasks-changed"));
        // Make the new task visible. If the active domain filter would hide it,
        // switch the filter to its domain so the user immediately sees it land.
        const hidden = domainFilter !== "all" && domainFilter !== domain;
        if (hidden) {
          setDomainFilter(domain);
          setAddMsg(`Added to ${titleCase(domain)} - switched filter so you can see it`);
        } else {
          setAddMsg(`Added to ${titleCase(domain)}`);
        }
        setAddModalOpen(false);
        // Also make sure we are on the Open tab (not Trash or Icebox).
        setView("open");
        window.setTimeout(() => setAddMsg(null), 4000);
      })
      .catch((e) => setAddErr(String(e)))
      .finally(() => setBusy(null));
  };

  // The tabs pick what the column lists. Waiting on you: blocked, in review,
  // or held by the engine for your answer.
  const waitingOnYou = (t: BoardTask) => t.status === "blocked" || t.status === "review" || (!!t.id && heldTaskIds.has(t.id));
  const tabItems: Record<BoardView, BoardTask[]> = {
    open: listed.filter((t) => t.status !== "done"),
    waiting: listed.filter(waitingOnYou),
    done: listed.filter((t) => t.status === "done"),
    trash: trashed,
    icebox: iceboxed,
  };
  const needle = q.trim().toLowerCase();
  const inTab = tabItems[view].filter((t) => !needle || t.text.toLowerCase().includes(needle) || t.domain.toLowerCase().includes(needle));
  const byDomain = useMemo(() => {
    const m = new Map<string, BoardTask[]>();
    for (const t of inTab) m.set(t.domain, [...(m.get(t.domain) ?? []), t]);
    return [...m.entries()].sort(([a2], [b2]) => a2.localeCompare(b2));
  }, [inTab]);
  const openTask = openId ? tasks.find((x) => x.id === openId) ?? null : null;
  const pick = (t: BoardTask) => { if (t.id) setOpenId(t.id); };

  const row = (t: BoardTask) => {
    const on = !!t.id && t.id === openId;
    const overdue = isOverdue(t);
    return (
      <button key={`${t.domain}:${t.id ?? t.text}`} data-testid="task-row" onClick={() => pick(t)} aria-current={on ? "true" : undefined}
        className={`flex w-full items-center gap-2 rounded-lg px-2.5 py-2 text-left transition-colors ${on ? "bg-surface-warm" : "hover:bg-surface-warm/50"}`}>
        {t.owner === "ai" ? <Bot className="h-3.5 w-3.5 shrink-0 text-accent" /> : <User className="h-3.5 w-3.5 shrink-0 text-text-muted" />}
        <span className="min-w-0 flex-1">
          <span className={`block truncate text-[14px] ${t.status === "done" || t.trashed ? "text-text-muted line-through" : on ? "font-semibold text-text-primary" : "text-text-primary"}`}>{t.text}</span>
          {(t.due || overdue) && <span className={`block text-[12px] ${overdue ? "text-err" : dueTone(t.due)}`}>{overdue ? `Overdue · ${t.due}` : t.due}</span>}
        </span>
        {waitingOnYou(t) && t.status !== "done" && <WaitingChip compact />}
        {(t.priority === "critical" || t.priority === "high") && <Flag className={`h-3.5 w-3.5 shrink-0 ${t.priority === "critical" ? "text-err" : "text-warn"}`} fill="currentColor" />}
      </button>
    );
  };

  // Priority and owner are controls in the detail; the header keeps the rest in one menu.
  const detailActions = (t: BoardTask) => t.trashed ? (<>
    <button onClick={() => void restore(t)} title="Restore" aria-label="Restore task" className={iconBtn}><RotateCcw className="h-4 w-4" /></button>
    <RowMenu items={[{ icon: Trash2, label: "Delete forever", danger: true, onClick: () => void purge(t) }]} />
  </>) : (
    <RowMenu items={[{ icon: Trash2, label: "Move to Trash", hint: "You can restore it", danger: true, onClick: () => { void del(t); setOpenId(null); } }]} />
  );

  const TABS: { id: BoardView; label: string }[] = [
    { id: "open", label: "Open" }, { id: "waiting", label: "Waiting on you" }, { id: "done", label: "Done" },
    { id: "trash", label: "Trash" }, { id: "icebox", label: "Icebox" },
  ];

  const domainHead = (d: string, n: number) => (
    <h3 className="flex items-baseline gap-2 px-2.5 pb-1 pt-1 text-[13px] font-semibold text-text-secondary">{titleCase(d)}<span className="font-normal tabular-nums text-text-muted">{n}</span></h3>
  );
  type FlatRow = { kind: "h"; d: string; n: number; first: boolean } | { kind: "t"; t: BoardTask };
  const flatRows: FlatRow[] = [];
  byDomain.forEach(([d, items], i) => {
    flatRows.push({ kind: "h", d, n: items.length, first: i === 0 });
    for (const t of items.slice(0, 200)) flatRows.push({ kind: "t", t });
  });

  return (
    <div className={`flex min-h-0 flex-col ${initialDomain ? "h-[75vh]" : "h-full"}`} data-testid="tasks-page">
      <SettingsHeader title="Tasks" icon={ListChecks} subtitle="Your tasks, yours or handed to AI."
        right={<SpineTabs label="Tasks" value={view} onChange={(v) => { setView(v); setOpenId(null); }}
          tabs={TABS.filter((t) => t.id === "open" || t.id === view || tabItems[t.id].length > 0).map((t) => ({ ...t, count: tabItems[t.id].length }))} />} />
      <SideSpine storageKey="prevail.tasks.spine" title="Tasks" label="tasks" testId="tasks-column"
        actions={<button onClick={() => { setAddErr(null); setAddModalOpen(true); }} title="New task" aria-label="New task" data-testid="task-new" className="rounded-md p-1.5 text-text-muted transition-colors hover:bg-surface-warm hover:text-accent"><Plus className="h-4 w-4" /></button>}
        toolbar={
          <div className="space-y-2">
            <label className="flex h-9 items-center gap-2 rounded-lg border border-border bg-background px-2.5 focus-within:border-accent-border">
              <Search className="h-4 w-4 shrink-0 text-text-muted" aria-hidden />
              <input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Search tasks" aria-label="Search tasks" className="min-w-0 flex-1 bg-transparent text-[14px] text-text-primary outline-none placeholder:text-text-muted" />
            </label>
            <div className="flex items-center gap-1.5">
              <div className="flex items-center overflow-hidden rounded-lg border border-border">
                {([["all", "All tasks", LayoutGrid], ["me", "Mine", User], ["ai", "AI-owned", Bot]] as const).map(([k, label, Icon], i) => (
                  <button key={k} onClick={() => setOwnerFilter(k)} aria-pressed={ownerFilter === k} title={label} aria-label={label}
                    className={`inline-flex items-center justify-center px-2.5 py-1 transition-colors ${i > 0 ? "border-l border-border" : ""} ${ownerFilter === k ? "bg-accent text-background" : "bg-background text-text-secondary hover:bg-surface-warm"}`}>
                    <Icon className="h-3.5 w-3.5" />
                  </button>
                ))}
              </div>
              <div className="flex min-w-0 flex-1 items-center gap-1 rounded-lg border border-border bg-background pl-2 text-text-muted">
                <Filter className="h-3.5 w-3.5 shrink-0" />
                <select value={domainFilter} onChange={(e) => setDomainFilter(e.target.value)} aria-label="Domain filter" className="min-w-0 flex-1 cursor-pointer appearance-none bg-transparent py-1 pr-2 text-[13px] text-text-secondary focus:outline-none">
                  <option value="all">All domains</option>
                  {domains.map((d) => <option key={d} value={d}>{titleCase(d)}</option>)}
                </select>
              </div>
            </div>
          </div>
        }
        footer={
          <div className="space-y-1.5 text-[12px] text-text-muted">
            <div className="flex items-center gap-1.5">
              {running ? <span className="inline-flex items-center gap-1.5 text-accent"><Loader2 className="h-3.5 w-3.5 animate-spin" /> AI is working</span>
                : <span className="inline-flex min-w-0 items-center gap-1.5 truncate"><Bot className="h-3.5 w-3.5 shrink-0 text-accent" /> {flow.inFlight} in flight · {flow.queued} queued</span>}
              <button onClick={runNow} disabled={running} title="Run one engine pass now: advance loops and work AI-owned tasks" aria-label="Run now" className={`${iconBtn} ml-auto h-7 w-7`}><Play className="h-3.5 w-3.5" /></button>
              <button onClick={assignAllToAgent} disabled={busy === "bulk-assign"} title="Hand every shown task you own to the agent (skips ones waiting on you)" aria-label="Assign all to the agent" className={`${iconBtn} h-7 w-7`}>
                {busy === "bulk-assign" ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <Zap className="h-3.5 w-3.5" />}
              </button>
            </div>
            {bulkMsg && <div className={bulkMsg.startsWith("Failed") ? "text-err" : "text-accent"}>{bulkMsg}</div>}
            {addMsg && !addErr && <div className="text-ok">{addMsg}</div>}
          </div>
        }
        phone={phone} phoneDetail={phone && !!openTask} onBack={() => setOpenId(null)} backLabel="All tasks"
        detail={
          <div className={phone ? "px-4 py-4" : "w-full px-8 py-6"}>
            {openTask ? (
              <TaskDetailPanel
                key={openTask.id}
                task={openTask}
                vaultPath={vaultPath}
                onClose={() => setOpenId(null)}
                onChanged={reload}
                harnesses={harnesses}
                delegating={!!openTask.id && agentRunning.has(openTask.id)}
                onDelegate={(cli) => runWithAgent(openTask, cli)}
                actions={detailActions(openTask)}
              />
            ) : inTab.length ? <p className="text-[13px] text-text-muted">Pick a task on the left.</p> : null}
          </div>
        }>
        <div className="p-2" data-testid="tasks-list">
          {addModalOpen && (
            <div className="mb-3 border-b border-border-subtle px-2.5 pb-3" data-testid="task-add" onKeyDown={(e) => { if (e.key === "Escape") setAddModalOpen(false); }}>
              <input autoFocus value={addText} onChange={(e) => { setAddText(e.target.value); if (addErr) setAddErr(null); }} onKeyDown={(e) => { if (e.key === "Enter") addTask(); }}
                placeholder="What needs doing?" aria-label="New task" className="w-full rounded-md border border-border bg-background px-2.5 py-1.5 text-[14px] text-text-primary focus:border-accent-border focus:outline-none" />
              <div className="mt-2 flex items-center gap-2">
                {addDomains.length > 0 && (
                  <select value={addDomain} onChange={(e) => setAddDomain(e.target.value)} aria-label="Domain"
                    className="min-w-0 flex-1 cursor-pointer rounded-md border border-border bg-background px-2 py-1 text-[13px] text-text-secondary focus:border-accent-border focus:outline-none">
                    {addDomains.map((d) => <option key={d} value={d}>{titleCase(d)}</option>)}
                  </select>
                )}
                <input type="date" value={addDue} onChange={(e) => setAddDue(e.target.value)} aria-label="Due date (optional)"
                  className="min-w-0 cursor-pointer rounded-md border border-border bg-background px-2 py-1 text-[13px] text-text-muted focus:border-accent-border focus:outline-none" />
              </div>
              {addErr && <p className="mt-1.5 text-[12px] text-err">{addErr}</p>}
              <div className="mt-2 flex items-center gap-4">
                <button onClick={addTask} disabled={busy === "add"} className="inline-flex items-center gap-1 text-[13px] font-medium text-accent hover:underline disabled:opacity-50">
                  {busy === "add" ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <Plus className="h-3.5 w-3.5" />} Add task
                </button>
                <button onClick={() => setAddModalOpen(false)} className="text-[13px] text-text-muted hover:text-text-primary">Cancel</button>
              </div>
            </div>
          )}
          {flatRows.length > VIRTUAL_MIN
            // A large board: one windowed list of domain headings and task rows.
            ? <VirtualRows items={flatRows} estimate={52} getKey={(r) => (r.kind === "h" ? `h:${r.d}` : r.t.id ?? r.t.text)}
                render={(r) => (r.kind === "h" ? <div className={r.first ? "" : "pt-3"}>{domainHead(r.d, r.n)}</div> : row(r.t))} />
            : byDomain.map(([d, items]) => (
            <section key={d} className="mb-3">
              {domainHead(d, items.length)}
              {items.slice(0, 200).map(row)}
            </section>
          ))}
          {inTab.length === 0 && <p className="px-2.5 py-2 text-[13px] text-text-muted">{needle ? "No tasks match." : "No tasks here."}</p>}
          {maybeMore && (
            <button onClick={() => setTaskLimit((n) => n + TASK_PAGE)} className="mx-2.5 mt-1 text-[13px] font-medium text-accent hover:underline">Load more tasks</button>
          )}
        </div>
      </SideSpine>
    </div>
  );
}
