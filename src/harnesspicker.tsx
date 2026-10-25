// HarnessPicker, popover for choosing how to run a task as an agent.
// "Prevail" (the built-in agent on your default model) is always offered first
// and needs no separate login. Installed external harnesses (Hermes, Pi,
// OpenCode, OpenClaw) follow; those run their own loop and may need a one-time
// login in their own CLI before they work.
import { Sparkles } from "lucide-react";
import { VENDOR_BRAND } from "./constants";
import { ProviderMark } from "./marks";
import type { CliInfo } from "./types";

// Sentinel id for the built-in agent. The board maps this to the default
// runtime (no --cli), so it runs on whatever model Prevail already uses.
export const PREVAIL_AGENT = "prevail";

export function HarnessPicker({
  harnesses,
  onPick,
  onClose,
}: {
  harnesses: CliInfo[];
  onPick: (id: string) => void;
  onClose: () => void;
}) {
  return (
    <>
      {/* click-away catcher */}
      <div className="fixed inset-0 z-40" onClick={onClose} />
      <div className="absolute right-0 z-50 mt-1 w-64 overflow-hidden rounded-lg border border-border bg-surface shadow-xl">
        <div className="border-b border-border-subtle px-3 py-2">
          <div className="text-[12px] text-text-muted">Run with agent</div>
          <p className="mt-1 text-[12px] leading-snug text-text-muted">
            Hands this task to an agent. It runs in safe mode (it proposes, it does not take consequential actions on its own) and posts what it finds back as a comment.
          </p>
        </div>

        {/* Built-in agent: always available, uses your default model, no login. */}
        <button
          onClick={() => onPick(PREVAIL_AGENT)}
          className="flex w-full items-center gap-2 border-b border-border-subtle px-3 py-2 text-left hover:bg-surface-warm"
        >
          <span className="flex h-[18px] w-[18px] shrink-0 items-center justify-center rounded bg-accent-soft text-accent">
            <Sparkles className="h-3 w-3" />
          </span>
          <span className="min-w-0 flex-1">
            <span className="block truncate text-xs font-medium text-text-primary">Glyph Studio</span>
            <span className="block truncate text-[12px] text-text-muted">Built in, on your default model. No login needed.</span>
          </span>
        </button>

        {/* External harness agents. */}
        {harnesses.map((h) => (
          <button
            key={h.id}
            onClick={() => onPick(h.id)}
            className="flex w-full items-center gap-2 px-3 py-2 text-left text-text-secondary transition-colors hover:bg-surface-warm hover:text-text-primary"
          >
            <ProviderMark vendor={h.id} size={18} />
            <span className="min-w-0 flex-1">
              <span className="block truncate text-xs">{VENDOR_BRAND[h.id]?.name ?? h.label}</span>
              <span className="block truncate text-[12px] text-text-muted">Harness agent. May need a one-time login in its own app.</span>
            </span>
          </button>
        ))}
      </div>
    </>
  );
}
