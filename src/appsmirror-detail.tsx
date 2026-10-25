// One connector's detail: sync it now, edit its sync recipe, and see which of
// its tools a sync may use. Recipes only ever use read tools; send and money
// tools are blocked from sync outright.
import { useEffect, useMemo, useState } from "react";
import { AlertTriangle, Check, Info, Loader2, RefreshCw, Save, Sparkles, Wrench } from "lucide-react";
import { invoke, isBrowser } from "./bridge";
import { relTime, titleCase } from "./format";
import { toast } from "./toast";
import {
  RUNTIME_LABEL, emptyDraft, statusMeta, recipeSavePayload, syncBlockedReason, syncableTools, toolBadge,
  type MirrorApp, type RecipeDraft, type Schedule, type SyncResult,
} from "./appsmirror-model";
import { PinButton, SigninHelp, TONE_TEXT } from "./appsmirror-parts";
import { AppScopeView } from "./appchat";
import { useGoogleAccounts } from "./appscope";

// Plain sections, no boxed cards; a text link for a secondary action.
const card = "";
const link = "inline-flex items-center gap-1.5 text-[13px] font-medium text-accent hover:underline disabled:opacity-45 disabled:no-underline";
const h4 = "text-[15px] font-semibold text-text-primary";
const SCHEDULES: { id: Schedule; label: string }[] = [
  { id: "daily", label: "Daily" },
  { id: "weekly", label: "Weekly" },
  { id: "manual", label: "Only when I press Sync now" },
];

export function MirrorDetail({ app, vaultPath, domains, onChanged }: {
  app: MirrorApp;
  vaultPath: string;
  domains: string[];
  onChanged: (next?: MirrorApp) => void;
}) {
  const [draft, setDraft] = useState<RecipeDraft>(() => emptyDraft(app));
  const [dirty, setDirty] = useState(false);
  const [busy, setBusy] = useState<null | "sync" | "draft" | "save" | "tools">(null);
  const [lastRun, setLastRun] = useState<SyncResult | null>(null);
  const [tools, setTools] = useState(app.tools);
  const phone = isBrowser();

  useEffect(() => { setDraft(emptyDraft(app)); setDirty(false); setLastRun(null); setTools(app.tools); }, [app.id]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => { if (!dirty) setDraft(emptyDraft(app)); setTools(app.tools); }, [app]); // eslint-disable-line react-hooks/exhaustive-deps

  const accounts = useGoogleAccounts(vaultPath, app);
  const withTools: MirrorApp = useMemo(() => ({ ...app, tools }), [app, tools]);
  const readable = syncableTools(withTools);
  const blocked = syncBlockedReason(app);
  const edit = (p: Partial<RecipeDraft>) => { setDraft((d) => ({ ...d, ...p })); setDirty(true); };
  const domainChoices = useMemo(
    () => Array.from(new Set([...domains, ...draft.domains])).sort((a, b) => a.localeCompare(b)),
    [domains, draft.domains],
  );

  async function syncNow() {
    setBusy("sync");
    try {
      const r = await invoke<SyncResult>("apps_mirror_sync", { vault: vaultPath, id: app.id });
      setLastRun(r);
      if (r.ok && !r.error) toast.success(`${app.name} synced: ${r.records} record${r.records === 1 ? "" : "s"}`);
      else toast.error(r.error || `${app.name} sync failed`);
      onChanged();
    } catch (e) { toast.error(String(e)); }
    finally { setBusy(null); }
  }
  async function draftWithAi() {
    setBusy("draft");
    try {
      const r = await invoke<{ recipe?: Partial<RecipeDraft>; error?: string }>("apps_mirror_recipe_draft", { vault: vaultPath, id: app.id });
      if (r.error || !r.recipe) { toast.error(r.error || "No draft came back"); return; }
      setDraft((d) => ({
        prompt: r.recipe?.prompt ?? d.prompt,
        domains: r.recipe?.domains?.length ? r.recipe.domains : d.domains,
        schedule: (r.recipe?.schedule as Schedule) ?? d.schedule,
        read_tools: r.recipe?.read_tools ?? d.read_tools,
      }));
      setDirty(true);
    } catch (e) { toast.error(String(e)); }
    finally { setBusy(null); }
  }
  async function save() {
    setBusy("save");
    try {
      const r = await invoke<{ ok?: boolean; app?: MirrorApp; error?: string }>("apps_mirror_recipe_save", recipeSavePayload(vaultPath, withTools, draft));
      if (r.error || r.ok === false) { toast.error(r.error || "Could not save the recipe"); return; }
      setDirty(false);
      toast.success("Recipe saved");
      onChanged(r.app);
    } catch (e) { toast.error(String(e)); }
    finally { setBusy(null); }
  }
  async function loadTools() {
    setBusy("tools");
    try {
      const r = await invoke<{ app?: MirrorApp; error?: string }>("apps_mirror_tools", { vault: vaultPath, id: app.id });
      if (r.error) toast.error(r.error);
      if (r.app?.tools) setTools(r.app.tools);
    } catch (e) { toast.error(String(e)); }
    finally { setBusy(null); }
  }

  const runtimeLabel = RUNTIME_LABEL[app.runtime] ?? app.runtime;
  const lastLine = app.last_error
    ? null
    : app.last_sync
      ? `Last sync ${relTime(app.last_sync)}${typeof app.records_last_sync === "number" ? `, ${app.records_last_sync} record${app.records_last_sync === 1 ? "" : "s"}` : ""}`
      : "Never synced";

  const status = statusMeta(app.status);
  return (
    <AppScopeView
      vaultPath={vaultPath}
      app={{ id: app.id, name: app.name, url: app.url, runtime: app.runtime }}
      subtitle={<>via {runtimeLabel} · <span className={TONE_TEXT[status.tone]}>{status.label}</span>{app.status_detail && app.status !== "connected" ? ` · ${app.status_detail}` : ""}</>}
      actions={<PinButton app={app} />}
      notice={app.status !== "connected" ? (
        <div className="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
          <p className="text-[13px] text-text-secondary">
            {app.status === "disabled" ? `${app.name} is turned off in ${runtimeLabel}.` : app.status === "error" ? `${runtimeLabel} reports a problem with ${app.name}.` : `${app.name} needs you to sign in again in ${runtimeLabel}.`}
            {" "}Glyph Studio uses the sign-in your runtime already has.
          </p>
          <SigninHelp app={app} />
        </div>
      ) : null}
      tools={
        <div className="space-y-7">
          <section className={card} aria-label="Tools">
            <div className="flex flex-wrap items-center justify-between gap-2">
              <h4 className={h4}>Tools{tools?.length ? <span className="ml-2 text-[13px] font-normal text-text-muted">{tools.length}</span> : null}</h4>
              {!phone && app.status === "connected" && (
                <button
                  type="button"
                  onClick={loadTools}
                  disabled={busy !== null}
                  className={link}
                >
                  {busy === "tools" ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <Wrench className="h-3.5 w-3.5" />} {tools?.length ? "Check again" : "Load tools"}
                </button>
              )}
            </div>
            {!tools?.length ? (
              <p className="mt-2 text-[13px] text-text-muted">{app.status === "connected" ? "Tools have not been checked yet." : "Sign in to see this connector's tools."}</p>
            ) : (
              <>
                <ul className="mt-3 divide-y divide-border-subtle">
                  {tools.map((t) => {
                    const b = toolBadge(t);
                    return (
                      <li key={t.name} className="flex min-w-0 items-center gap-3 py-2" title={b.reason}>
                        <span className="min-w-0 flex-1 truncate font-mono text-[13px] text-text-primary">{t.name}</span>
                        <span data-testid="tool-badge" className={`shrink-0 text-[12px] ${b.tone === "ok" || b.tone === "muted" ? "text-text-muted" : TONE_TEXT[b.tone]}`}>{b.label}</span>
                      </li>
                    );
                  })}
                </ul>
                <p className="mt-3 text-[12px] leading-relaxed text-text-muted">
                  Read tools can feed a sync. Write tools stay in chat only. Send and payment tools are blocked from sync; mail stays draft-only, so you are always the one who sends.
                </p>
              </>
            )}
          </section>
        </div>
      }
      connection={
        <div className="space-y-7">
          {app.last_error && (
            <div className="flex items-start gap-2 text-[13px] text-err">
              <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" /> <span className="min-w-0 break-words">{app.last_error}</span>
            </div>
          )}
          {lastRun && !lastRun.error && lastRun.ok && (
            <div className="flex items-center gap-2 text-[13px] text-ok">
              <Check className="h-4 w-4 shrink-0" /> Wrote {lastRun.records} record{lastRun.records === 1 ? "" : "s"} to {lastRun.files} file{lastRun.files === 1 ? "" : "s"}.
            </div>
          )}

          {accounts.length > 0 && (
            <section className={card} aria-label="Google accounts" data-testid="app-accounts">
              <h4 className={h4}>Accounts<span className="ml-2 text-[13px] font-normal text-text-muted">{accounts.length}</span></h4>
              <ul className="mt-2 divide-y divide-border-subtle">
                {accounts.map((a) => (
                  <li key={a.id} data-testid="app-account-row" className="flex min-w-0 items-center gap-3 py-2">
                    <span className="min-w-0 flex-1 truncate text-[13px] text-text-primary" title={a.id}>{a.label && a.label !== a.id ? `${a.label} (${a.id})` : a.id}</span>
                    {a.default && <span className="shrink-0 text-[12px] font-medium text-accent">Default</span>}
                    <span className="shrink-0 text-[12px] text-text-muted">via {a.via === "gws" ? "Google Workspace" : "Claude"}</span>
                  </li>
                ))}
              </ul>
              <p className="mt-2 text-[12px] leading-relaxed text-text-muted">Chat can read across every account. Drafts go to one account and wait for you; Glyph Studio never sends.</p>
            </section>
          )}
          <div className={`${card} flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between`}>
            <div className="min-w-0">
              <p className="text-[15px] font-medium text-text-primary">{lastLine ?? "Last sync failed"}</p>
              <p className="text-[13px] text-text-muted">{blocked ?? (phone ? "Sync runs on your Mac." : "Pull what is new now, with read tools only.")}</p>
            </div>
            <button
              type="button"
              onClick={syncNow}
              disabled={!!blocked || busy !== null || phone}
              title={blocked ?? (phone ? "Sync runs on your Mac" : "Run this recipe now")}
              className="inline-flex h-8 shrink-0 items-center justify-center gap-1.5 rounded-md bg-accent px-3 text-[13px] font-medium text-on-accent transition-colors hover:bg-accent-hover disabled:cursor-not-allowed disabled:opacity-45"
            >
              {busy === "sync" ? <Loader2 className="h-4 w-4 animate-spin" /> : <RefreshCw className="h-4 w-4" />} Sync now
            </button>
          </div>
          {!app.syncable ? (
            <div className={`${card} flex items-start gap-3`}>
              <Info className="mt-0.5 h-4 w-4 shrink-0 text-text-muted" />
              <p className="text-[13px] leading-relaxed text-text-secondary">
                Listed from {runtimeLabel} so you can see everything in one place. It cannot be synced yet: Glyph Studio runs recipes through runtimes that support unattended, read-only runs.
              </p>
            </div>
          ) : (
            <section className={card} aria-label="Sync recipe">
              <div className="flex flex-wrap items-center justify-between gap-2">
                <h4 className={h4}>Sync recipe</h4>
                <button
                  type="button"
                  onClick={draftWithAi}
                  disabled={busy !== null || phone}
                  className={link}
                >
                  {busy === "draft" ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <Sparkles className="h-3.5 w-3.5" />} Draft with AI
                </button>
              </div>
              <p className="mt-1 text-[13px] text-text-muted">What to pull from {app.name}, where it goes, and how often. Runs with read tools only.</p>

              <label className="mt-4 block text-[13px] font-semibold text-text-primary" htmlFor={`prompt-${app.id}`}>What to pull</label>
              <textarea
                id={`prompt-${app.id}`}
                rows={4}
                value={draft.prompt}
                onChange={(e) => edit({ prompt: e.target.value })}
                placeholder="e.g. Pull what is new since the last sync and list anything that needs action."
                className="mt-1.5 w-full resize-y rounded-lg border border-border bg-background px-3 py-2 text-[13px] text-text-primary placeholder:text-text-muted/70 focus:border-accent-border focus:outline-none"
              />

              <div className="mt-4 text-[13px] font-semibold text-text-primary">Feeds these domains</div>
              {domainChoices.length === 0 ? (
                <p className="mt-1 text-[13px] text-text-muted">No domains in this vault yet.</p>
              ) : (
                <div className="mt-1.5 flex flex-wrap gap-1.5" role="group" aria-label="Domains">
                  {domainChoices.map((d) => {
                    const on = draft.domains.includes(d);
                    return (
                      <button
                        key={d}
                        type="button"
                        aria-pressed={on}
                        onClick={() => edit({ domains: on ? draft.domains.filter((x) => x !== d) : [...draft.domains, d] })}
                        className={`inline-flex items-center gap-1 rounded-full border px-2.5 py-1 text-[13px] transition-colors ${
                          on ? "border-accent-border bg-accent-soft font-medium text-accent" : "border-border text-text-secondary hover:border-accent-border hover:text-text-primary"
                        }`}
                      >
                        {on && <Check className="h-3 w-3" />} {titleCase(d)}
                      </button>
                    );
                  })}
                </div>
              )}

              <label className="mt-4 block text-[13px] font-semibold text-text-primary" htmlFor={`schedule-${app.id}`}>Schedule</label>
              <select
                id={`schedule-${app.id}`}
                value={draft.schedule}
                onChange={(e) => edit({ schedule: e.target.value as Schedule })}
                className="mt-1.5 w-full rounded-lg border border-border bg-background px-3 py-2 text-[13px] text-text-primary focus:border-accent-border focus:outline-none sm:w-72"
              >
                {SCHEDULES.map((s) => <option key={s.id} value={s.id}>{s.label}</option>)}
              </select>

              <div className="mt-4 text-[13px] font-semibold text-text-primary">Read tools it may use</div>
              {readable.length === 0 ? (
                <p className="mt-1 text-[13px] text-text-muted">{(tools ?? []).length ? "This connector has no read tools a sync may use." : "Load the tool list below to choose. With none picked, the recipe may use any read tool."}</p>
              ) : (
                <div className="mt-1.5 grid gap-1">
                  {readable.map((t) => {
                    const on = draft.read_tools.includes(t.name);
                    return (
                      <label key={t.name} className="flex min-w-0 cursor-pointer items-center gap-2 rounded-md px-2 py-1.5 text-[13px] text-text-secondary hover:bg-surface-warm">
                        <input
                          type="checkbox"
                          checked={on}
                          onChange={() => edit({ read_tools: on ? draft.read_tools.filter((x) => x !== t.name) : [...draft.read_tools, t.name] })}
                          className="h-4 w-4 shrink-0 accent-[var(--color-accent)]"
                        />
                        <span className="min-w-0 truncate font-mono text-[12px]" title={t.full_name}>{t.name}</span>
                      </label>
                    );
                  })}
                </div>
              )}

              <div className="mt-5 flex items-center gap-3">
                <button
                  type="button"
                  onClick={save}
                  disabled={busy !== null || !draft.prompt.trim() || phone}
                  className="inline-flex h-8 items-center gap-1.5 rounded-md bg-accent px-3 text-[13px] font-medium text-on-accent hover:bg-accent-hover disabled:opacity-45"
                >
                  {busy === "save" ? <Loader2 className="h-4 w-4 animate-spin" /> : <Save className="h-4 w-4" />} Save recipe
                </button>
                {dirty && <span className="text-[12px] text-text-muted">Unsaved changes</span>}
                {!dirty && app.recipe?.updated_at && <span className="text-[12px] text-text-muted">Saved {relTime(app.recipe.updated_at)}</span>}
              </div>
            </section>
          )}


        </div>
      }
    />
  );
}
