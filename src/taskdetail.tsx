// Task detail: a task is more than a list row. Click one open and you
// get its full shape: title, domain, due, priority, status, owner, a long-form
// description, and a comment/activity thread you (and the AI) build over time.
// The one-line _tasks.md record stays canonical; the rich parts live in the
// per-domain sidecar (_task_details.json) via task_detail_* commands.
import { useCallback, useEffect, useState, type ReactNode } from "react";
import { Bot, Flag, Loader2, MessageSquarePlus, Sparkles, User, Zap } from "lucide-react";
import { DETAIL_TITLE, META, SECTION_TITLE } from "./typescale";
import { invoke } from "./bridge";
import { titleCase, relTime } from "./format";
import { VENDOR_BRAND } from "./constants";
import { HarnessPicker } from "./harnesspicker";
import type { BoardTask, CliInfo } from "./types";

const control = "w-full rounded-md border border-border bg-background px-2 py-1 text-[14px] text-text-primary focus:border-accent-border focus:outline-none";

type Detail = { description?: string; comments?: { ts: number; text: string; author?: string }[] };

// Rendered IN the Tasks detail pane (never a pop-up). `actions` are the tiny
// icon actions for the header (delete, restore, delete forever).
export function TaskDetailPanel({ task, vaultPath, onClose, onChanged, harnesses = [], delegating = false, onDelegate, actions }: {
  task: BoardTask;
  vaultPath: string;
  onClose: () => void;
  actions?: ReactNode;
  onChanged: () => void;
  // Connected agent oracles (Hermes/Pi/OpenClaw/OpenCode) + the built-in
  // Prevail agent, and the action that hands this task to one.
  harnesses?: CliInfo[];
  delegating?: boolean;
  onDelegate?: (cli: string) => void;
}) {
  const [pickerOpen, setPickerOpen] = useState(false);
  const [detail, setDetail] = useState<Detail>({});
  const [desc, setDesc] = useState("");
  const [comment, setComment] = useState("");
  const [busy, setBusy] = useState(false);
  const id = task.id ?? "";

  useEffect(() => {
    if (!id) return;
    let alive = true;
    invoke<Detail>("task_detail_get", { vault: vaultPath, domain: task.domain, id })
      .then((d) => { if (alive) { setDetail(d || {}); setDesc(d?.description ?? ""); } })
      .catch(() => { if (alive) { setDetail({}); setDesc(""); } });
    return () => { alive = false; };
  }, [id, vaultPath, task.domain]);

  // Mutate one field on the underlying task line (status/owner/priority/due) via a
  // read-modify-write, then refresh the board.
  const patchTask = useCallback(async (patch: Partial<BoardTask>) => {
    if (!id) return;
    setBusy(true);
    try {
      const cur = await invoke<BoardTask[]>("tasks_read", { vault: vaultPath, domain: task.domain });
      await invoke("tasks_set", { vault: vaultPath, domain: task.domain, tasks: cur.map((x) => (x.id === id ? { ...x, ...patch } : x)) });
      onChanged();
    } catch (e) { console.error("patch task", e); }
    finally { setBusy(false); }
  }, [id, vaultPath, task.domain, onChanged]);

  const saveDesc = useCallback(async () => {
    if (!id || desc === (detail.description ?? "")) return;
    try { await invoke("task_detail_set_description", { vault: vaultPath, domain: task.domain, id, description: desc }); setDetail((d) => ({ ...d, description: desc })); }
    catch (e) { console.error("save description", e); }
  }, [id, desc, detail.description, vaultPath, task.domain]);

  const addComment = useCallback(async () => {
    const t = comment.trim();
    if (!id || !t) return;
    try {
      const d = await invoke<Detail>("task_detail_add_comment", { vault: vaultPath, domain: task.domain, id, text: t, author: "me" });
      setDetail(d || {});
      setComment("");
    } catch (e) { console.error("add comment", e); }
  }, [id, comment, vaultPath, task.domain]);

  const cyclePriority = () => patchTask({ priority: task.priority === "critical" ? null : task.priority === "high" ? "critical" : "high" });

  // Open this task's domain chat seeded with the FULL task context, so the
  // conversation continues with everything the task already carries: its
  // status/meta, description, and the discussion (comments) so far. A done task
  // is fine - we just frame it as a follow-up.
  const discuss = () => {
    const meta = [
      `Status: ${titleCase(task.status)}`,
      task.due ? `Due ${task.due}` : null,
      task.priority ? `Priority ${task.priority}` : null,
      `Owner ${task.owner === "ai" ? "AI" : "Me"}`,
    ].filter(Boolean).join(" · ");
    const cmts = detail.comments ?? [];
    const history = cmts.length
      ? "\n\nDiscussion so far:\n" + cmts.map((c) => {
          const a = c.author;
          const who = !a || a === "me" || a === "you" ? "Me" : a === "ai" ? "AI" : (VENDOR_BRAND[a]?.name ?? a);
          return `- ${who}: ${c.text}`;
        }).join("\n")
      : "";
    const seed = `Let's discuss this task from my ${titleCase(task.domain)} board.\n\nTask: "${task.text}"\n${meta}${desc ? `\n\nDescription:\n${desc}` : ""}${history}\n\nWhere should we take it from here?`;
    // Persist so the seed survives navigating from Tasks to the (then-
    // mounting) chat panel; ChatPanel reads pending seeds on mount. Without this
    // the live event can fire before the chat is listening and the composer ends
    // up blank - which is the bug this fixes.
    try { localStorage.setItem("prevail.compose.pending", seed); } catch { /* ignore */ }
    window.dispatchEvent(new CustomEvent("prevail:open-domain", { detail: task.domain }));
    window.dispatchEvent(new CustomEvent("prevail:compose-seed", { detail: seed }));
    onClose();
  };

  const comments = detail.comments ?? [];

  return (
    <section data-testid="task-detail" key={id}>
        <div className="flex items-start gap-3">
          <span title={task.owner === "ai" ? "AI" : "Me"} className={`mt-2 shrink-0 ${task.owner === "ai" ? "text-accent" : "text-text-muted"}`}>
            {task.owner === "ai" ? <Bot className="h-5 w-5" /> : <User className="h-5 w-5" />}
          </span>
          <div className="min-w-0 flex-1">
            <input
              aria-label="Task title"
              defaultValue={task.text}
              onBlur={(e) => { const v = e.target.value.trim(); if (v && v !== task.text) patchTask({ text: v }); }}
              onKeyDown={(e) => { if (e.key === "Enter") (e.target as HTMLInputElement).blur(); }}
              className={`${DETAIL_TITLE} w-full rounded-md bg-transparent outline-none focus:bg-background focus:px-1`}
            />
            <p className={`${META} mt-1`}>{titleCase(task.domain)}{task.trashed && <span className="text-warn"> · In Trash</span>}</p>
          </div>
          {actions && <div className="flex shrink-0 items-center gap-0.5">{actions}</div>}
        </div>

        <div className="mt-5 max-w-3xl">

          {/* Meta: four quiet controls, one line on a wide pane */}
          <div className="grid grid-cols-2 gap-x-6 gap-y-3 sm:grid-cols-4">
            <label className="block min-w-0">
              <span className={`${META} block`}>Status</span>
              <select value={task.status} onChange={(e) => patchTask({ status: e.target.value })} disabled={busy} className={`${control} mt-0.5`}>
                {["todo", "doing", "review", "blocked", "done", "icebox"].map((s) => <option key={s} value={s}>{titleCase(s)}</option>)}
              </select>
            </label>
            <label className="block min-w-0">
              <span className={`${META} block`}>Due</span>
              <input type="date" value={task.due ?? ""} onChange={(e) => patchTask({ due: e.target.value || null })} disabled={busy} className={`${control} mt-0.5`} />
            </label>
            <div className="min-w-0">
              <span className={`${META} block`}>Priority</span>
              <button onClick={cyclePriority} disabled={busy} title="Change priority" className={`mt-1 inline-flex items-center gap-1.5 text-[14px] hover:underline ${task.priority === "critical" ? "text-err" : task.priority === "high" ? "text-warn" : "text-text-primary"}`}>
                <Flag className="h-3.5 w-3.5" fill={task.priority ? "currentColor" : "none"} /> {titleCase(task.priority ?? "normal")}
              </button>
            </div>
            <div className="min-w-0">
              <span className={`${META} block`}>Owner</span>
              <button onClick={() => patchTask({ owner: task.owner === "ai" ? "me" : "ai" })} disabled={busy} title={task.owner === "ai" ? "Take it back" : "Hand to AI"} className="mt-1 inline-flex items-center gap-1.5 text-[14px] text-text-primary hover:underline">
                {task.owner === "ai" ? <><Bot className="h-3.5 w-3.5 text-accent" /> AI</> : <><User className="h-3.5 w-3.5" /> Me</>}
              </button>
            </div>
          </div>

          {/* Description */}
          <label className="mt-5 block">
            <span className={`${META} block`}>Description</span>
            <textarea
              value={desc}
              onChange={(e) => setDesc(e.target.value)}
              onBlur={saveDesc}
              placeholder="Add details, links, what done looks like"
              rows={4}
              className="mt-1 w-full resize-y rounded-md border border-border bg-background px-2.5 py-2 text-[14px] text-text-primary outline-none focus:border-accent-border"
            />
          </label>

          {/* Discuss with AI + Delegate to an agent oracle */}
          <div className="relative mt-2 flex flex-wrap items-center gap-x-5 gap-y-2">
            <button onClick={discuss} className="inline-flex items-center gap-1.5 text-[13px] font-medium text-accent hover:underline">
              <Sparkles className="h-3.5 w-3.5" /> Discuss with AI
            </button>
            {onDelegate && (
              <button
                onClick={() => setPickerOpen((v) => !v)}
                disabled={delegating}
                title="Hand this task to an agent (Glyph Studio, or a connected oracle like Hermes, Pi, OpenClaw). It runs the task and posts the result here."
                className="inline-flex items-center gap-1.5 text-[13px] text-text-secondary hover:text-accent disabled:opacity-60"
              >
                {delegating ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <Zap className="h-3.5 w-3.5" />} {delegating ? "Running" : "Delegate to agent"}
              </button>
            )}
            {pickerOpen && onDelegate && (
              <HarnessPicker harnesses={harnesses} onPick={(cli) => { setPickerOpen(false); onDelegate(cli); }} onClose={() => setPickerOpen(false)} />
            )}
          </div>

          {/* Comments / activity */}
          <div className="mt-7">
            <h3 className={SECTION_TITLE}>Comments{comments.length > 0 && <span className="ml-1.5 text-[13px] font-normal text-text-muted">{comments.length}</span>}</h3>
            {comments.length > 0 && (
              <ul className="mt-1">
                {comments.map((c, i) => {
                  // author is "me"/"you" (the user), "ai" (generic), or an
                  // agent id like "pi"/"hermes"/"opencode"/"Prevail" when a
                  // task was handed to an agent. Show who actually wrote it.
                  const a = c.author;
                  const isUser = !a || a === "me" || a === "you";
                  const who = isUser ? "You" : a === "ai" ? "AI" : (VENDOR_BRAND[a]?.name ?? a);
                  return (
                    <li key={i} className="border-b border-border-subtle py-2.5 last:border-b-0">
                      <p className={`${META} flex items-center gap-1.5`}>{isUser ? <User className="h-3 w-3" /> : <Bot className="h-3 w-3 text-accent" />}{who} · {relTime(c.ts)}</p>
                      <p className="mt-0.5 whitespace-pre-wrap text-[14px] text-text-secondary">{c.text}</p>
                    </li>
                  );
                })}
              </ul>
            )}
            <div className="mt-2 flex items-end gap-2">
              <textarea
                value={comment}
                onChange={(e) => setComment(e.target.value)}
                onKeyDown={(e) => { if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) addComment(); }}
                placeholder="Add a comment (⌘↵)"
                rows={2}
                className="min-w-0 flex-1 resize-y rounded-md border border-border bg-background px-2.5 py-1.5 text-[14px] text-text-primary outline-none focus:border-accent-border"
              />
              <button onClick={addComment} disabled={!comment.trim()} title="Add comment" aria-label="Add comment" className="inline-flex h-9 w-9 shrink-0 items-center justify-center rounded-md bg-accent text-on-accent hover:bg-accent-hover disabled:opacity-40">
                <MessageSquarePlus className="h-4 w-4" />
              </button>
            </div>
          </div>
        </div>
    </section>
  );
}
