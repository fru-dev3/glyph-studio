// Prompt capture - record the prompts you type in each AI CLI into the vault.
// Extracted out of the MCP/Integrations page so it lives under its own nav item
// (now opened from Intent's capture dots) rather than being conflated with
// the MCP server config. Pure relocation: the capture behaviour is unchanged.
//
// Heavy lifting lives in the prevail engine (`prevail capture …`), reached
// through async Tauri commands that never block the UI.
import { useCallback, useEffect, useState } from "react";
import { Download, FolderOpen, FolderSearch, History, Inbox, Loader2, RefreshCw, Zap } from "lucide-react";
import { invoke } from "./bridge";
import { SettingsHeader } from "./sectionutil";
import { Toggle } from "./ui";

type Harness = {
  tool: string;
  method: "push" | "sync";
  present: boolean;
  wired: boolean;
  enabled?: boolean;
  target?: string;
  source?: string;
  detail?: string;
};
type Stream = { tool: string; path: string; count: number };
export type CaptureStatus = {
  meta?: string;
  streams?: Stream[];
  agent?: { plistPresent: boolean; loaded: boolean; supported: boolean; plist: string };
  harnesses?: Harness[];
};
type SyncSource = { tool: string; found: number; written: number; skipped: number };

export const CAPTURE_LABELS: Record<string, string> = {
  claude: "Claude Code",
  codex: "Codex",
  gemini: "Gemini",
  antigravity: "Antigravity",
  opencode: "opencode",
  openclaw: "Openclaw",
  hermes: "Hermes",
  pi: "Pi",
  prevail: "Glyph Studio",
};

export function PromptCapturePanel({ vaultPath }: { vaultPath: string }) {
  const [status, setStatus] = useState<CaptureStatus | null>(null);
  const [busy, setBusy] = useState<"" | "install" | "sync">("");
  const [note, setNote] = useState<string | null>(null);
  const [togglingTool, setTogglingTool] = useState("");

  const loadCapture = useCallback(async () => {
    try {
      setStatus(await invoke<CaptureStatus>("capture_status", { vault: vaultPath }));
    } catch (e) {
      setNote(`Could not read capture status: ${String(e).slice(0, 140)}`);
    }
  }, [vaultPath]);

  useEffect(() => {
    void loadCapture();
  }, [loadCapture]);

  async function runInstall() {
    setBusy("install");
    setNote(null);
    try {
      await invoke("capture_install", { vault: vaultPath });
      setNote("Capture turned on. Claude Code and Codex now log live; other tools are read automatically from their chat history.");
      await loadCapture();
    } catch (e) {
      setNote(`Install failed: ${String(e).slice(0, 140)}`);
    } finally {
      setBusy("");
    }
  }

  async function runSync() {
    setBusy("sync");
    setNote(null);
    try {
      const r = await invoke<{ sources?: SyncSource[] }>("capture_sync", { vault: vaultPath });
      const wrote = (r.sources ?? []).reduce((n, s) => n + (s.written ?? 0), 0);
      setNote(wrote > 0 ? `Synced ${wrote} new prompt${wrote === 1 ? "" : "s"} from your CLI transcripts.` : "Already up to date - nothing new to sync.");
      await loadCapture();
    } catch (e) {
      setNote(`Sync failed: ${String(e).slice(0, 140)}`);
    } finally {
      setBusy("");
    }
  }

  async function toggleCapture(tool: string, on: boolean) {
    setTogglingTool(tool);
    setNote(null);
    try {
      await invoke("capture_set_enabled", { vault: vaultPath, tool, on });
      setNote(`${CAPTURE_LABELS[tool] ?? tool} capture turned ${on ? "on" : "off"}.`);
      await loadCapture();
    } catch (e) {
      setNote(`Could not change ${CAPTURE_LABELS[tool] ?? tool}: ${String(e).slice(0, 120)}`);
    } finally {
      setTogglingTool("");
    }
  }

  const streamCount = (tool: string) => status?.streams?.find((s) => s.tool === tool)?.count ?? 0;
  const totalCaptured = (status?.streams ?? []).reduce((n, s) => n + s.count, 0);
  const harnesses = status?.harnesses ?? [];

  async function reveal(path?: string) {
    if (!path) return;
    try {
      await invoke("open_in_finder", { path });
    } catch {
      /* best effort */
    }
  }
  const openFolder = () => reveal(status?.meta);
  const openFile = (tool: string) => reveal(status?.streams?.find((s) => s.tool === tool)?.path);

  return (
    <div className="w-full space-y-4">
      <SettingsHeader
        title="Prompts"
        icon={Inbox}
        subtitle="Every prompt you write, kept in your vault."
      />

      {/* PROMPT CAPTURE - record prompts from each CLI into the vault --------- */}
      <div>
        <div className="flex items-stretch gap-5">
          <div className="min-w-0 flex-1">
            <h2 className="mb-1 text-[15px] font-semibold text-text-primary">Prompt capture</h2>
            <div className="text-[14px] text-text-secondary">
              Every prompt you submit, saved in your vault <span title="_meta/prompts/<tool>.jsonl" className="underline decoration-dotted underline-offset-2">per tool</span> and distilled into your intents. <span className="inline-flex items-center gap-1"><Zap className="h-3 w-3 text-ai" /> = captured live as you type, <History className="h-3 w-3" /> = read from a tool's saved chats.</span>
            </div>

            <div className="mt-4 flex flex-wrap items-center gap-x-4 gap-y-2">
              <button
                onClick={runInstall}
                disabled={busy !== ""}
                className="inline-flex h-8 items-center gap-1.5 rounded-md bg-accent px-3 text-[13px] font-medium text-on-accent hover:bg-accent-hover disabled:opacity-50"
              >
                {busy === "install" ? <Loader2 className="h-3 w-3 animate-spin" /> : <Download className="h-3 w-3" />}
                {busy === "install" ? "Installing…" : "Install capture"}
              </button>
              <button
                onClick={runSync}
                disabled={busy !== ""}
                className="inline-flex items-center gap-1.5 px-1 text-[13px] text-text-muted hover:text-text-primary disabled:opacity-50"
              >
                {busy === "sync" ? <Loader2 className="h-3 w-3 animate-spin" /> : <RefreshCw className="h-3 w-3" />}
                {busy === "sync" ? "Syncing…" : "Sync now"}
              </button>
              <button
                onClick={openFolder}
                disabled={!status?.meta}
                className="inline-flex items-center gap-1.5 px-1 text-[13px] text-text-muted hover:text-text-primary disabled:opacity-50"
              >
                <FolderOpen className="h-3 w-3" /> Open folder
              </button>
              {note && <span className="text-[12px] text-text-secondary">{note}</span>}
            </div>
          </div>

          <div className="flex shrink-0 flex-col items-center justify-center border-l border-border-subtle pl-6 text-center">
            <span className="font-display text-[24px] font-bold leading-none tabular-nums text-text-primary">{totalCaptured.toLocaleString()}</span>
            <span className="mt-2 text-[12px] text-text-muted">Prompts captured</span>
          </div>
        </div>

        <div className="mt-5 overflow-x-auto">
          <table className="w-full text-left text-[13px]">
            <thead className="border-b border-border-subtle text-[12px] text-text-muted">
              <tr>
                <th className="px-3 py-2 font-medium">Harness</th>
                <th className="px-3 py-2 text-center font-medium">How</th>
                <th className="px-3 py-2 text-right font-medium">Captured</th>
                <th className="px-3 py-2 text-right font-medium">Capture</th>
              </tr>
            </thead>
            <tbody>
              {harnesses.map((h) => (
                <tr key={h.tool} className="border-t border-border-subtle">
                  <td className="px-3 py-2">
                    <span className="group inline-flex items-center gap-1.5">
                      <span className={`inline-block h-1.5 w-1.5 rounded-full ${h.present ? "bg-ok" : "bg-border"}`} />
                      {CAPTURE_LABELS[h.tool] ?? h.tool}
                      {h.source && (
                        <button
                          onClick={() => reveal(h.source)}
                          title={`Show where this is captured from:\n${h.source}`}
                          className="text-text-muted opacity-0 transition-opacity hover:text-accent group-hover:opacity-100"
                        >
                          <FolderSearch className="h-3.5 w-3.5" />
                        </button>
                      )}
                    </span>
                  </td>
                  <td className="px-3 py-2 text-center">
                    <span
                      className="inline-flex"
                      title={h.method === "push" ? "Captured live, the moment you send a prompt" : "Read from this tool's saved chat files"}
                    >
                      {h.method === "push" ? <Zap className="h-4 w-4 text-ai" /> : <History className="h-4 w-4 text-text-muted" />}
                    </span>
                  </td>
                  <td className="px-3 py-2 text-right tabular-nums text-text-secondary">
                    {streamCount(h.tool) > 0 ? (
                      <button onClick={() => openFile(h.tool)} className="underline-offset-2 hover:text-accent hover:underline" title="Open this file">
                        {streamCount(h.tool).toLocaleString()}
                      </button>
                    ) : (
                      <span className="text-text-muted">0</span>
                    )}
                  </td>
                  <td className="px-3 py-2">
                    <div className="flex justify-end">
                      <Toggle
                        on={h.enabled !== false}
                        onChange={(v) => toggleCapture(h.tool, v)}
                        disabled={togglingTool !== ""}
                        label={`Capture ${CAPTURE_LABELS[h.tool] ?? h.tool}`}
                      />
                    </div>
                  </td>
                </tr>
              ))}
              {harnesses.length === 0 && (
                <tr><td colSpan={4} className="px-3 py-3 text-center text-text-muted">Run "Install capture" to wire up your CLIs.</td></tr>
              )}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
}
