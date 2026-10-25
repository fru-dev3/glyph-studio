// Studio's Arena tab since 0.4.10. Benchmarking moved to its own app, Glyph Arena,
// which writes the routing policy (build/_meta/arena/policy.json) that Studio's
// Auto router follows. Studio keeps the tab so old links and shortcuts still land
// somewhere useful.
import { openUrl } from "@tauri-apps/plugin-opener";
import { ArrowUpRight, Route, Swords, Trophy } from "lucide-react";
import { invoke } from "./bridge";
import { SettingsHeader } from "./sectionutil";

export const ARENA_PAGE = "https://glyph.fru.dev/arena";

/** Open Glyph Arena if it is installed, else its page. */
export async function openGlyphArena(): Promise<void> {
  let opened = false;
  try { opened = await invoke<boolean>("open_glyph_arena"); } catch { opened = false; }
  if (!opened) {
    try { await openUrl(ARENA_PAGE); } catch { window.open(ARENA_PAGE, "_blank", "noopener,noreferrer"); }
  }
}

export function ArenaHandoff() {
  const points = [
    { icon: Swords, title: "Duels on your own tasks", body: "Your past prompts, replayed on two recipes. Checkers settle what they can; you make two-second blind picks for the rest." },
    { icon: Trophy, title: "Leagues and verdicts", body: "Per domain and kind of task. When two recipes are even, the cheaper one wins. Health and money stay on local models." },
    { icon: Route, title: "Studio follows it", body: "On Auto, Studio uses Arena's route for the chat's domain and task, and the route chip says so." },
  ];
  return (
    <div data-testid="arena-handoff">
      <SettingsHeader title="Arena" icon={Swords} subtitle="Now its own app, Glyph Arena. Studio follows the routing policy it writes." />
      <div className="mx-auto w-full max-w-[640px] py-4">
        <h2 className="font-display text-[22px] font-semibold leading-tight text-text-primary">Arena is now Glyph Arena</h2>
        <p className="mt-2 text-[14px] leading-relaxed text-text-secondary">
          Benchmarking moved into its own app, so Studio can stay focused on your work. Glyph Arena tests recipes
          (a model with its prompt, vault context and tools) on your own tasks and writes the routing policy Studio uses.
        </p>
        <div className="mt-6 space-y-3">
          {points.map(({ icon: Icon, title, body }) => (
            <div key={title} className="flex gap-3 rounded-xl border border-border-subtle bg-surface p-4">
              <Icon className="mt-0.5 h-5 w-5 shrink-0 text-accent" />
              <div>
                <div className="text-[14px] font-semibold text-text-primary">{title}</div>
                <div className="text-[13.5px] leading-relaxed text-text-secondary">{body}</div>
              </div>
            </div>
          ))}
        </div>
        <div className="mt-6 flex flex-wrap items-center gap-3">
          <button
            data-testid="open-glyph-arena"
            onClick={() => void openGlyphArena()}
            className="inline-flex h-10 items-center gap-2 rounded-lg bg-accent px-4 text-[14px] font-medium text-on-accent transition-colors hover:bg-accent-hover"
          >
            Open Glyph Arena <ArrowUpRight className="h-4 w-4" />
          </button>
          <span className="text-[13px] text-text-muted">Not installed? This opens glyph.fru.dev/arena. Your past benchmark runs stay in your vault.</span>
        </div>
      </div>
    </div>
  );
}
