// Trusted sources as apps: the owner's knowledge sources (an MCP address, a
// site or feed, links, a folder, a database) feed the agent read only. They
// are added and scoped on Settings > Connections > Knowledge sources
// (knowledgesources.tsx); here a source behaves like any app: Chat,
// @-mention, Activity, Check again and Archive (never a delete).
import { useState } from "react";
import { Archive, Check, Database, FileText, FolderOpen, Globe, Link2, Loader2, Plug, RefreshCw, ShieldCheck, TriangleAlert } from "lucide-react";
import { invoke, isBrowser } from "./bridge";
import { RowMenu } from "./ui";
import { toast } from "./toast";
import { relTime } from "./format";
import { AppLogo } from "./appsmirror-parts";
import { statusMeta, type MirrorApp } from "./appsmirror-model";
import { AppScopeView } from "./appchat";
import { DetailTitle, META, ROW_TITLE, SECTION_TITLE } from "./typescale";
import { SOURCE_KIND_LABEL, isWebSource, type SourceKind, type SourceProbe, type UntrustedSource } from "./appscope";

// Plain sections, no boxes: the page is one column of quiet content.
const card = "";
const primary = "inline-flex items-center justify-center gap-1.5 rounded-lg bg-accent px-4 py-2 text-[13px] font-semibold text-on-accent hover:bg-accent-hover disabled:opacity-45";
const secondary = "inline-flex items-center gap-1.5 text-[13px] font-medium text-accent hover:underline disabled:opacity-45 disabled:no-underline";

export const KIND_ICON: Record<string, typeof Plug> = { "mcp-remote": Plug, web: Globe, links: Link2, folder: FolderOpen, database: Database };

// Look at a source again through the knowledge sources engine, which knows
// every kind (and trusts on this Mac one that synced in from another).
async function checkSource(vaultPath: string, id: string): Promise<{ probe: SourceProbe }> {
  return invoke<{ probe: SourceProbe }>("engine_knowledge_check", { vault: vaultPath, id });
}

// What the engine found when it looked at the source, in plain words.
export function ProbeView({ probe, kind }: { probe: SourceProbe; kind: string }) {
  if (!probe.ok) {
    return (
      <p data-testid="probe-error" className="flex items-start gap-2 text-[13px] text-err">
        <TriangleAlert className="mt-0.5 h-4 w-4 shrink-0" />
        <span className="min-w-0 break-words">{probe.error ? `Could not use it yet: ${probe.error}` : "Could not use it yet."}</span>
      </p>
    );
  }
  return (
    <div data-testid="probe-ok" className="space-y-2 text-[13px] text-text-secondary">
      {kind === "mcp-remote" && (
        <>
          <p className="flex items-center gap-2 text-ok"><Check className="h-4 w-4" /> Reached {probe.server?.name || "the server"}. {probe.tools?.length ?? 0} read-only tools.</p>
          {!!probe.tools?.length && (
            <ul className="flex flex-wrap gap-1.5">
              {probe.tools.map((t) => <li key={t.name} className="rounded-md bg-surface-warm px-2 py-0.5 font-mono text-[12px] text-text-primary">{t.name}</li>)}
            </ul>
          )}
        </>
      )}
      {kind === "web" && (
        <p className="flex items-center gap-2 text-ok"><Check className="h-4 w-4" />
          Found {[probe.llms_txt ? "llms.txt" : "", probe.openapi ? "openapi.json" : ""].filter(Boolean).join(" and ") || "the site"}.
        </p>
      )}
      {(kind === "links" || kind === "web") && !!probe.urls?.length && (
        <ul className="space-y-0.5">
          {probe.urls.map((u) => (
            <li key={u.url} className="flex min-w-0 items-center gap-2">
              <span className={`h-1.5 w-1.5 shrink-0 rounded-full ${u.ok ? "bg-ok" : "bg-err"}`} aria-hidden />
              <span className="min-w-0 truncate" title={u.url}>{u.url}</span>
              {!u.ok && <span className="shrink-0 text-err">{u.status ? `answered ${u.status}` : "no answer"}</span>}
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

// A source that synced in from another Mac: trusting is per machine, so it
// waits for a click here.
export function UntrustedSourceDetail({ vaultPath, source, onTrusted }: { vaultPath: string; source: UntrustedSource; onTrusted: () => void }) {
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [probe, setProbe] = useState<SourceProbe | null>(null);
  async function trust() {
    setBusy(true); setErr(null);
    try {
      const r = await checkSource(vaultPath, source.id);
      setProbe(r.probe);
      if (r.probe?.ok) { toast.success(`${source.name} is trusted on this Mac`); onTrusted(); }
    } catch (e) { setErr(String(e).replace(/^Error:\s*/, "")); }
    finally { setBusy(false); }
  }
  return (
    <div data-testid="untrusted-source" className="space-y-4 p-4 sm:p-6">
      <div className="flex items-center gap-3">
        <AppLogo name={source.name} url={source.urls[0]} size={32} />
        <div className="min-w-0 flex-1">
          <DetailTitle className="truncate">{source.name}</DetailTitle>
          <p className={`${META} truncate`}>Trusted source · {SOURCE_KIND_LABEL[source.integration] ?? source.integration}</p>
        </div>
      </div>
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center">
        <ShieldCheck className="hidden h-5 w-5 shrink-0 text-warn sm:block" />
        <div className="min-w-0 flex-1">
          <p className={ROW_TITLE}>Not trusted on this Mac yet</p>
          <p className={META}>It came over with your vault. Each Mac decides for itself what it trusts, so chats here leave it out until you trust it.</p>
        </div>
        <button type="button" className={primary} disabled={busy || isBrowser()} onClick={() => void trust()} data-testid="trust-here">
          {busy ? <Loader2 className="h-4 w-4 animate-spin" /> : <ShieldCheck className="h-4 w-4" />} Trust on this Mac
        </button>
      </div>
      <ul className={`${META} space-y-1`}>{source.urls.map((u) => <li key={u} className="truncate" title={u}>{u}</li>)}</ul>
      {err && <p className="text-[13px] text-err">{err}</p>}
      {probe && <ProbeView probe={probe} kind={source.integration} />}
    </div>
  );
}

export function TrustedSourceDetail({ vaultPath, app, onChanged }: { vaultPath: string; app: MirrorApp; onChanged: () => void }) {
  const [busy, setBusy] = useState<null | "check" | "archive">(null);
  const [probe, setProbe] = useState<SourceProbe | null>(null);
  const [archived, setArchived] = useState<{ from: string; to: string } | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const kind = (app.integration ?? "mcp-remote") as SourceKind;
  const status = statusMeta(app.status);
  const urls = app.urls ?? (app.url ? [app.url] : []);
  const desktop = !isBrowser();

  async function check() {
    setBusy("check"); setErr(null);
    try { const r = await checkSource(vaultPath, app.id); setProbe(r.probe); onChanged(); }
    catch (e) { setErr(String(e).replace(/^Error:\s*/, "")); }
    finally { setBusy(null); }
  }
  async function archive() {
    setBusy("archive"); setErr(null);
    try {
      const r = await invoke<{ ok?: boolean; archived?: { from: string; to: string } }>("engine_apps_remove_source", { vault: vaultPath, id: app.id });
      if (r?.archived) setArchived(r.archived);
      toast.success(`${app.name} archived`);
      onChanged();
    } catch (e) { setErr(String(e).replace(/^Error:\s*/, "")); }
    finally { setBusy(null); }
  }

  if (archived) {
    return (
      <div data-testid="source-archived" className="space-y-2 p-4 sm:p-6">
        <DetailTitle>{app.name}</DetailTitle>
        <p className="flex items-center gap-2 text-[14px] text-text-secondary"><Archive className="h-4 w-4 text-text-muted" /> Archived. Nothing was deleted.</p>
        <p className={META} title={archived.to}>Its folder moved to the archive in your vault.</p>
      </div>
    );
  }

  const tools = kind === "mcp-remote" ? (
    <section className={card} aria-label="Tools">
      <h4 className={SECTION_TITLE}>Tools{app.tools?.length ? <span className="ml-2 text-[12px] font-normal text-text-muted">{app.tools.length}</span> : null}</h4>
      {!app.tools?.length ? <p className={`${META} mt-2`}>No tools listed yet. Check it again from Connection.</p> : (
        <ul className="mt-2 divide-y divide-border-subtle">
          {app.tools.map((t) => (
            <li key={t.name} className="flex min-w-0 items-center gap-3 py-2">
              <span className="min-w-0 flex-1 truncate font-mono text-[13px] text-text-primary">{t.name}</span>
              <span data-testid="tool-badge" className={`shrink-0 text-[12px] ${t.kind === "read" ? "text-text-muted" : "text-err"}`}>{t.kind === "read" ? "Read" : "Blocked"}</span>
            </li>
          ))}
        </ul>
      )}
      <p className={`${META} mt-3`}>A trusted source is read only. Its read tools run without asking and are logged in Activity.</p>
    </section>
  ) : undefined;

  const connection = (
    <div className="space-y-6">
      <section aria-label="Source">
        <div className="flex flex-wrap items-center justify-between gap-2">
          <h4 className={SECTION_TITLE}>{SOURCE_KIND_LABEL[kind] ?? kind}</h4>
          <button type="button" className={secondary} disabled={!desktop || busy !== null} onClick={() => void check()}>
            {busy === "check" ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <RefreshCw className="h-3.5 w-3.5" />} Check again
          </button>
        </div>
        <ul className="mt-2 space-y-1">{urls.map((u) => <li key={u} className="truncate text-[13px] text-text-secondary" title={u}>{u}</li>)}</ul>
        {app.tools_checked_at && <p className={`${META} mt-1`}>Checked {relTime(app.tools_checked_at)}</p>}
        {probe && <div className="mt-3"><ProbeView probe={probe} kind={kind} /></div>}
        {err && <p className="mt-3 text-[13px] text-err">{err}</p>}
      </section>
      {app.source && (app.source.llms || app.source.endpoints?.length) ? (
        <section className={card} aria-label="What it documents">
          <h4 className={`${SECTION_TITLE} flex items-center gap-2`}><FileText className="h-4 w-4 text-text-muted" /> {app.source.title || "What it documents"}</h4>
          {app.source.llms && <p className="mt-2 line-clamp-6 whitespace-pre-wrap text-[13px] text-text-secondary">{app.source.llms}</p>}
          {!!app.source.endpoints?.length && (
            <ul className="mt-2 space-y-0.5">{app.source.endpoints.slice(0, 20).map((e) => <li key={e.path} className="truncate text-[13px] text-text-secondary"><span className="font-mono text-text-primary">GET {e.path}</span>{e.summary ? ` · ${e.summary}` : ""}</li>)}</ul>
          )}
        </section>
      ) : null}
      <p className={META}>Read only, on this Mac. Glyph Studio never stores a password or database key for a source; the address must work without one.</p>
    </div>
  );

  return (
    <AppScopeView
      vaultPath={vaultPath}
      app={{ id: app.id, name: app.name, url: urls[0], runtime: "claude" }}
      subtitle={<>Trusted source · {SOURCE_KIND_LABEL[kind] ?? kind} · <span className={status.tone === "ok" ? "text-ok" : "text-err"}>{app.status === "connected" ? "Ready" : "Not reachable"}</span></>}
      actions={desktop ? <RowMenu label="More source actions" items={[
        { icon: RefreshCw, label: "Check again", onClick: () => void check() },
        { icon: Archive, label: "Archive source", hint: "Moves its folder to the archive", onClick: () => void archive() },
      ]} /> : undefined}
      notice={app.status !== "connected" ? (
        <div className="flex flex-wrap items-center gap-x-4 gap-y-1">
          <p className="min-w-0 break-words text-[13px] text-err">Could not use it yet{app.status_detail ? `: ${app.status_detail}` : "."}</p>
          <button type="button" className={secondary} disabled={!desktop || busy !== null} onClick={() => void check()}>
            {busy === "check" ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <RefreshCw className="h-3.5 w-3.5" />} Retry
          </button>
        </div>
      ) : null}
      activityNote={isWebSource(app) ? "Fetches from this site aren't logged yet." : undefined}
      tools={tools}
      connection={connection}
    />
  );
}
