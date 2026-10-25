// Omega - the app-wide LEARNED knowledge layer (vault/omega.md). The learned
// counterpart to the Ideal State: durable, cross-cutting lessons + preferences
// Prevail distills across every domain, injected into every turn just below the
// Ideal State. This page lets the user distill, view, and hand-edit it.
// See docs/OMEGA-PLAN.md. Engine: src-tauri/src/omega.rs.
import { useCallback, useEffect, useState } from "react";
import { Eye, History, Loader2, PenLine, Sigma, Sparkles } from "lucide-react";
import { invoke } from "./bridge";
import { CollapsibleSection } from "./collapsible";
import { Markdown } from "./Markdown";
import { PREF, cheapModel, getPref, lsGet, lsSet, setPref } from "./storage";
import { REVEAL, Toggle } from "./ui";
import { BODY, META } from "./typescale";
import { SettingsHeader } from "./sectionutil";

// The distiller wraps its auto block in HTML-comment markers
// (<!-- omega:auto:start --> / <!-- omega:auto:end -->) so it knows what to
// rewrite on disk. Those markers must stay in the file, but they should never
// be shown to the user. sanitizeForDisplay strips marker-only lines and any
// inline <!-- ... --> comments before rendering. It does NOT touch what we save.
function sanitizeForDisplay(text: string): string {
  return text
    .split("\n")
    .filter((line) => !/^\s*<!--\s*omega:.*?-->\s*$/.test(line))
    .join("\n")
    .replace(/<!--[\s\S]*?-->/g, "")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

// Omega daemon - auto-distill the app-wide learned layer on a slow cadence
// (default daily) so it compounds without a manual click. Module-level timer,
// same pattern as the apps/bench/loops schedulers; the tick re-reads the pref so
// toggling needs no restart. Best-effort: a "not enough learned yet" error is
// expected early on and swallowed.
let omegaTimer: number | null = null;
export function startOmegaScheduler(vault: string) {
  if (omegaTimer !== null) window.clearInterval(omegaTimer);
  const tick = async () => {
    try {
      if (getPref(PREF.omegaAuto, "1") !== "1") return;
      const intervalMs = (Number(getPref(PREF.omegaIntervalSec, String(24 * 3600))) || 24 * 3600) * 1000;
      const last = Number(lsGet(PREF.omegaLastRun, "0")) || 0;
      if (Date.now() - last < intervalMs) return;
      lsSet(PREF.omegaLastRun, String(Date.now()));
      const provider = getPref(PREF.memoryProvider, "claude");
      const model = cheapModel();
      await invoke("omega_distill", { vault, provider, model });
      window.dispatchEvent(new Event("prevail:omega-changed"));
    } catch { /* best-effort; e.g. not enough learned across domains yet */ }
  };
  omegaTimer = window.setInterval(() => void tick(), 60 * 60 * 1000); // check hourly; tick gates on cadence
  window.setTimeout(() => void tick(), 90_000); // first check shortly after launch
}

export function OmegaSection({ vaultPath, headerless }: { vaultPath: string; headerless?: boolean }) {
  const [body, setBody] = useState<string>("");
  const [loaded, setLoaded] = useState(false);
  const [editing, setEditing] = useState(false);
  const [saving, setSaving] = useState(false);
  const [savedAt, setSavedAt] = useState<number | null>(null);
  const [distilling, setDistilling] = useState(false);
  const [note, setNote] = useState<string | null>(null);
  const [versions, setVersions] = useState<{ name: string; path: string }[]>([]);
  const [auto, setAuto] = useState(() => getPref(PREF.omegaAuto, "1") === "1");

  const loadVersions = useCallback(() =>
    invoke<{ name: string; path: string }[]>("omega_versions", { vault: vaultPath })
      .then((v) => setVersions(Array.isArray(v) ? v : []))
      .catch(() => {}), [vaultPath]);

  useEffect(() => {
    invoke<string>("read_omega", { vault: vaultPath })
      .then((s) => { setBody(s); setLoaded(true); })
      .catch(() => setLoaded(true));
    void loadVersions();
  }, [vaultPath, loadVersions]);

  async function save() {
    setSaving(true);
    try {
      await invoke("write_omega", { vault: vaultPath, body });
      setSavedAt(Date.now());
      setEditing(false);
      window.dispatchEvent(new Event("prevail:omega-changed"));
      void loadVersions();
    } finally { setSaving(false); }
  }

  async function distill() {
    setDistilling(true);
    setNote(null);
    try {
      const provider = getPref(PREF.memoryProvider, "claude");
      const model = cheapModel();
      const merged = await invoke<string>("omega_distill", { vault: vaultPath, provider, model });
      setBody(merged);
      setSavedAt(Date.now());
      window.dispatchEvent(new Event("prevail:omega-changed"));
      void loadVersions();
      setNote("Distilled what's durable across your domains into Omega.");
    } catch (e) {
      setNote(String(e));
    } finally { setDistilling(false); }
  }

  const empty = body.trim() === "";
  const icon = "flex h-8 w-8 items-center justify-center rounded-md text-text-muted hover:bg-surface-warm hover:text-accent disabled:opacity-40";
  const link = "inline-flex items-center gap-1 text-[13px] font-medium text-accent hover:underline disabled:opacity-50";

  return (
    <>
      {!headerless && (
        <SettingsHeader
          title="Omega"
          icon={Sigma}
          subtitle="What Glyph Studio has learned across your domains."
        />
      )}

      {/* One line on how Omega sits beside the constitution, then tiny actions. */}
      <div className="mb-4 flex flex-wrap items-center gap-x-3 gap-y-2">
        <p className={`${META} min-w-0 flex-1 basis-64`} title="Journals, intents and each domain's memory compound into Omega.">
          {editing ? "Editing. The auto block is rewritten on each distill; write above it." : "What Glyph Studio learned from how you work. Your constitution wins any conflict; both ride every turn."}
        </p>
        <span className="flex shrink-0 items-center gap-1">
          <label className="mr-1 inline-flex items-center gap-1.5 text-[12px] text-text-muted" title="Auto-distill Omega across your domains on a slow cadence (default daily)">
            <Toggle on={auto} onChange={(v) => { setAuto(v); setPref(PREF.omegaAuto, v ? "1" : "0"); }} label="Auto-distill Omega" />
            Auto
          </label>
          {savedAt && !editing && <span className="text-[12px] text-ok">Saved</span>}
          <button onClick={distill} disabled={distilling} title="Distill now" aria-label="Distill now" className={icon}>
            {distilling ? <Loader2 className="h-4 w-4 animate-spin" /> : <Sparkles className="h-4 w-4" />}
          </button>
          {loaded && !empty && (
            <button onClick={() => setEditing((e) => !e)} title={editing ? "View" : "Edit"} aria-label={editing ? "View" : "Edit"} className={icon}>
              {editing ? <Eye className="h-4 w-4" /> : <PenLine className="h-4 w-4" />}
            </button>
          )}
        </span>
      </div>

      {note && <p className={`${META} mb-3`}>{note}</p>}

      {editing ? (
        <div>
          <textarea
            value={body}
            onChange={(e) => setBody(e.target.value)}
            placeholder={"## What you've learned about how you work\n\n- Prefer terse, decision-first answers"}
            rows={20}
            className="w-full resize-y rounded-lg border border-border bg-background p-3 text-[14px] leading-normal text-text-primary placeholder:text-text-muted focus:border-accent-border focus:outline-none"
          />
          <div className="mt-2 flex items-center justify-between gap-2">
            <span className={META}>{body.length.toLocaleString()} characters</span>
            <button onClick={save} disabled={saving || !loaded}
              className="inline-flex h-8 items-center gap-1.5 rounded-md bg-accent px-3 text-[13px] font-medium text-on-accent hover:bg-accent-hover disabled:opacity-50">
              {saving ? "Saving" : "Save"}
            </button>
          </div>
        </div>
      ) : !loaded ? null : empty ? (
        <div>
          <p className={META}>Nothing learned yet. It fills in as Glyph Studio learns across your domains.</p>
          <div className="mt-2 flex items-center gap-4">
            <button onClick={distill} disabled={distilling} className={link}>
              {distilling ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <Sparkles className="h-3.5 w-3.5" />}
              {distilling ? "Distilling" : "Distill now"}
            </button>
            <button onClick={() => setEditing(true)} className="inline-flex items-center gap-1 text-[13px] text-text-muted hover:text-text-primary">
              <PenLine className="h-3.5 w-3.5" /> Write it myself
            </button>
          </div>
        </div>
      ) : (
        <div>
          <div className={`${BODY} max-w-3xl text-text-secondary`}>
            <Markdown source={sanitizeForDisplay(body)} compact />
          </div>
          {versions.length > 0 && (
            <CollapsibleSection
              icon={History}
              title="History"
              subtitle="Every distill and edit is kept; nothing is lost."
              summary={`${versions.length} version${versions.length === 1 ? "" : "s"}`}
              className="mt-6"
            >
              <div className="flex flex-col">
                {versions.map((v) => (
                  <div key={v.path} className="group flex items-center gap-2 py-1">
                    <span className="flex-1 text-[13px] text-text-secondary">{v.name.replace("_", " · ")}</span>
                    <button
                      onClick={async () => {
                        try {
                          const old = await invoke<string>("read_text_file", { path: v.path });
                          if (window.confirm("Restore this version? The current text is kept first.")) {
                            setBody(old);
                            await invoke("write_omega", { vault: vaultPath, body: old });
                            setSavedAt(Date.now());
                            window.dispatchEvent(new Event("prevail:omega-changed"));
                            void loadVersions();
                          }
                        } catch (e) { console.error("restore omega", e); }
                      }}
                      className={`${link} ${REVEAL}`}
                    >
                      Restore
                    </button>
                  </div>
                ))}
              </div>
            </CollapsibleSection>
          )}
        </div>
      )}
    </>
  );
}
