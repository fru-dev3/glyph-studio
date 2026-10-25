// MCP - register your vault as an MCP server in each AI CLI, one click.
//
// Prompt capture used to live here too; it now has its own nav item
// (Editor → Context & Memory → Prompt capture, src/promptcapturepanel.tsx) so
// this page is just the MCP server config.
//
// Heavy lifting lives in the prevail engine (`prevail mcp install …`), reached
// through async Tauri commands that never block the UI.
import { useCallback, useEffect, useState } from "react";
import { Check, Download, Loader2, Plug, Zap } from "lucide-react";
import { invoke } from "./bridge";
import { SettingsHeader } from "./sectionutil";
import { McpSection } from "./settings5";
import type { CliInfo } from "./types";

type McpClient = { client: string; present: boolean; registered: boolean; error?: string };

const MCP_CLIENT_ORDER = ["claude", "codex", "gemini", "antigravity", "cursor"];
const LABELS: Record<string, string> = {
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

export function IntegrationsPanel({ vaultPath }: { vaultPath: string; clis: CliInfo[] }) {
  const [mcpClients, setMcpClients] = useState<McpClient[]>([]);
  const [mcpBusy, setMcpBusy] = useState(false);
  const [mcpBusyClient, setMcpBusyClient] = useState("");
  const [mcpMsg, setMcpMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [mcpTab, setMcpTab] = useState<"oneclick" | "manual">("oneclick");

  const loadMcp = useCallback(async () => {
    try {
      const m = await invoke<{ clients?: McpClient[] }>("mcp_install_status");
      setMcpClients(m.clients ?? []);
    } catch {
      /* leave the MCP list at its registry defaults */
    }
  }, []);

  useEffect(() => {
    void loadMcp();
  }, [loadMcp]);

  async function installClientMcp(client: string) {
    setMcpBusyClient(client);
    setMcpMsg(null);
    try {
      const r = await invoke<{ clients?: McpClient[] }>("mcp_install", { client });
      const c = r.clients?.find((x) => x.client === client);
      const label = LABELS[client] ?? client;
      // The install result is authoritative for THIS client (the registrar just
      // wrote the config / ran `claude mcp add`). Reflect it in the row
      // immediately instead of trusting the slower, flakier status re-check.
      if (c) {
        setMcpClients((prev) =>
          prev.some((x) => x.client === client)
            ? prev.map((x) => (x.client === client ? { ...x, ...c, present: true } : x))
            : [...prev, { ...c, present: true }],
        );
      }
      setMcpMsg(
        c?.registered
          ? { ok: true, text: `${label}: registered. Restart ${label} to pick it up.` }
          : { ok: false, text: `${label}: ${(c?.error || "install failed").slice(0, 150)}` },
      );
    } catch (e) {
      setMcpMsg({ ok: false, text: String(e).slice(0, 160) });
    } finally {
      setMcpBusyClient("");
    }
  }

  async function testMcp() {
    setMcpBusy(true);
    setMcpMsg(null);
    try {
      const r = await invoke<{ ok: boolean; info?: string; error?: string }>("mcp_test_handshake", { vault: vaultPath });
      setMcpMsg({ ok: !!r.ok, text: r.ok ? (r.info ?? "Handshake OK.") : (r.error ?? "Handshake failed.") });
    } catch (e) {
      setMcpMsg({ ok: false, text: String(e).slice(0, 160) });
    } finally {
      setMcpBusy(false);
    }
  }

  return (
    <div className="w-full space-y-4">
      {/* Page header - same SettingsHeader treatment as every other page:
          left icon badge + ghosted far-right icon flourish. */}
      <SettingsHeader
        title="MCP"
        icon={Plug}
        subtitle="Let the AI tools you already use call into your vault."
      />

      {/* USE PREVAIL FROM YOUR TOOLS (MCP) - one-click OR manual, tabbed ------ */}
      <div className="border-t border-border-subtle pt-4">
        <h2 className="mb-1 text-[15px] font-semibold text-text-primary">Use Glyph Studio from your AI tools</h2>
        <div className="mb-4 text-sm text-text-secondary">
          MCP (Model Context Protocol) lets the AI CLIs you already use call into Glyph Studio - run a council across your models, read a life domain's state, or list your domains - right inside the tool. Register Glyph Studio once and it shows up as tools in Claude Code, Codex, Gemini and more. Uses a local stdio connection; nothing leaves your machine.
        </div>

        {/* Auto-council moved to Settings → Council (it governs the council, not
            the MCP integration). */}
        <div className="mb-4 inline-flex gap-1 rounded-lg border border-border-subtle bg-surface-warm/60 p-1">
          {(
            [
              ["oneclick", "One-click setup"],
              ["manual", "Manual config"],
            ] as const
          ).map(([id, label]) => (
            <button
              key={id}
              onClick={() => setMcpTab(id)}
              className={`rounded-md px-3 py-1 text-xs font-medium transition-all ${mcpTab === id ? "bg-surface text-accent shadow-sm ring-1 ring-black/5" : "text-text-muted hover:text-text-secondary"}`}
            >
              {label}
            </button>
          ))}
        </div>
        {mcpTab === "manual" ? (
          <McpSection vaultPath={vaultPath} />
        ) : (
          <>
        <div className="mb-3 text-sm text-text-secondary">
          One click writes the server into each CLI's own config - no copy-paste. Flag-less, so it follows your vault if you move it.
        </div>
        <div className="overflow-hidden rounded-md border border-border-subtle">
          {MCP_CLIENT_ORDER.map((id) => {
            const c = mcpClients.find((x) => x.client === id);
            const present = c?.present ?? false;
            const registered = c?.registered ?? false;
            const busyThis = mcpBusyClient === id;
            return (
              <div key={id} className="flex items-center justify-between gap-3 border-b border-border-subtle px-3 py-2 last:border-b-0">
                <div className="flex items-center gap-2 text-xs">
                  <span className={`inline-block h-1.5 w-1.5 rounded-full ${present ? "bg-ok" : "bg-border"}`} />
                  <span>{LABELS[id] ?? id}</span>
                  {registered && (
                    <span className="inline-flex items-center gap-1 text-[12px] text-ok">
                      <Check className="h-3 w-3" /> registered
                    </span>
                  )}
                  {!present && <span className="text-[12px] text-text-muted">Not installed</span>}
                </div>
                <button
                  onClick={() => installClientMcp(id)}
                  disabled={busyThis || mcpBusyClient !== ""}
                  className="inline-flex items-center gap-1.5 rounded-md border border-accent-border bg-accent-soft px-2.5 py-1 text-[12px] text-accent hover:bg-accent hover:text-background disabled:opacity-50"
                >
                  {busyThis ? <Loader2 className="h-3 w-3 animate-spin" /> : <Download className="h-3 w-3" />}
                  {registered ? "Re-install" : "Install"}
                </button>
              </div>
            );
          })}
        </div>
        <div className="mt-3 flex flex-wrap items-center gap-2">
          <button
            onClick={testMcp}
            disabled={mcpBusy}
            className="inline-flex items-center gap-1.5 rounded-md border border-border bg-background px-3 py-1.5 text-[12px] text-text-muted hover:border-accent-border hover:text-accent disabled:opacity-50"
          >
            {mcpBusy ? <Loader2 className="h-3 w-3 animate-spin" /> : <Zap className="h-3 w-3" />} Test handshake
          </button>
          {mcpMsg && (
            <span className={`font-mono text-[12px] ${mcpMsg.ok ? "text-ok" : "text-warn"}`}>
              {mcpMsg.ok ? "OK " : "x "}{mcpMsg.text}
            </span>
          )}
        </div>
          </>
        )}
      </div>
    </div>
  );
}
