// Pure settings-section helpers extracted from App.tsx: CLI login-command map,
// auth-error detection, section-header / ideal-state icon pickers, the MCP engine
// path resolver, and the skill-avatar color palette + hash picker.
import { createContext, useContext, useState, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { useIsPhone } from "./useisphone";
import { Activity, Award, Brain, Briefcase, Coins, Compass, Folder, Github, Globe, GraduationCap, Heart, Home, Layers, Lightbulb, MessagesSquare, Monitor, Plug, Scale, Settings as SettingsIcon, Shield, ShieldCheck, Sparkles, Target, Users, Wrench } from "lucide-react";
import { DETAIL_TITLE } from "./typescale";
import { TintIcon } from "./tint";

export const CLI_LOGIN_CMD: Record<string, string> = {
  claude: "claude",
  codex: "codex login",
  antigravity: "agy login",
};

// When a verify error is an auth failure (CLI installed but not signed in),
// return the login command (or "" if the CLI is unknown). Returns null when
// the error isn't auth-related, so the raw message keeps showing.

export function authLoginCmd(cliId: string, raw: string): string | null {
  const isAuth = /\b401\b|invalid authentication|failed to authenticate|unauthorized|not (?:logged|signed) in|please (?:run )?.*login/i.test(raw);
  if (!isAuth) return null;
  return CLI_LOGIN_CMD[cliId] ?? "";
}

export function settingsHeaderIcon(title: string): typeof Folder {
  const t = title.toLowerCase();
  if (/privacy/.test(t)) return ShieldCheck;
  if (/council/.test(t)) return Scale;
  if (/framework|lens/.test(t)) return Scale;
  if (/skill/.test(t)) return Sparkles;
  if (/model|agent|provider/.test(t)) return Layers;
  if (/safety/.test(t)) return Shield;
  if (/gateway/.test(t)) return MessagesSquare;
  if (/remote|webui/.test(t)) return Monitor;
  if (/mcp/.test(t)) return Wrench;
  if (/vault/.test(t)) return Folder;
  if (/memory|context/.test(t)) return Brain;
  if (/about me|user|profile/.test(t)) return Users;
  if (/appearance/.test(t)) return Sparkles;
  if (/shortcut/.test(t)) return SettingsIcon;
  if (/connector|integration|ingest/.test(t)) return Plug;
  if (/about/.test(t)) return Github;
  return SettingsIcon;
}

export function mcpCommandPath(enginePath: string): { command: string; unstable: boolean } {
  const p = (enginePath || "").trim();
  // MCP-2: a dev/source-tree build path (…/src-tauri/target/debug|release/prevail)
  // must NEVER be emitted in a copyable config - it won't exist on an installed
  // user's machine AND it leaks the developer's home path/identity. Treat those
  // (along with translocated / external-volume / temp paths) as "unstable" and
  // emit the canonical installed sidecar path instead.
  const unstable =
    p === "" ||
    p.includes("/Volumes/") ||
    p.includes("AppTranslocation") ||
    p.includes("/private/var/folders/") ||
    p.includes("/target/debug/") ||
    p.includes("/target/release/") ||
    p.includes("/src-tauri/");
  if (unstable) return { command: "/Applications/Glyph Studio.app/Contents/MacOS/prevail", unstable: true };
  return { command: p, unstable: false };
}

export function idealSectionIcon(title: string) {
  const t = title.toLowerCase();
  if (/vision|north|ideal|future|dream/.test(t)) return Compass;
  if (/value|principle|rule|constitution/.test(t)) return Scale;
  if (/wealth|money|finan|invest/.test(t)) return Coins;
  if (/health|body|fitness|energy|sleep/.test(t)) return Activity;
  if (/family|relation|people|friend|marriage/.test(t)) return Users;
  if (/work|career|business|craft|build/.test(t)) return Briefcase;
  if (/learn|grow|educat|skill|read|stud/.test(t)) return GraduationCap;
  if (/home|living|place|environment/.test(t)) return Home;
  if (/faith|spirit|soul|peace|joy/.test(t)) return Heart;
  if (/freedom|travel|world|adventure/.test(t)) return Globe;
  if (/legacy|impact|give|generos|serve/.test(t)) return Award;
  if (/secur|safe|protect|risk/.test(t)) return Shield;
  if (/mind|mental|focus|clarity|think/.test(t)) return Brain;
  if (/time|priorit|goal|target|measure/.test(t)) return Target;
  return Lightbulb;
}

// Deterministic per-skill avatar colors: hash the skill name into one of these.
export const SKILL_AVATAR_PALETTE = [
  { bg: "#ef6c4a", fg: "#ffffff" }, // orange
  { bg: "#3b82f6", fg: "#ffffff" }, // blue
  { bg: "#6366f1", fg: "#ffffff" }, // indigo
  { bg: "#8b5cf6", fg: "#ffffff" }, // violet
  { bg: "#a855f7", fg: "#ffffff" }, // purple
  { bg: "#ec4899", fg: "#ffffff" }, // pink
  { bg: "#10b981", fg: "#ffffff" }, // emerald
  { bg: "#14b8a6", fg: "#ffffff" }, // teal
  { bg: "#f59e0b", fg: "#1a1a1a" }, // amber
  { bg: "#0ea5e9", fg: "#ffffff" }, // sky
];

export function pickSkillColor(name: string): { bg: string; fg: string } {
  let h = 0;
  for (let i = 0; i < name.length; i++) {
    h = ((h << 5) - h) + name.charCodeAt(i);
    h |= 0;
  }
  return SKILL_AVATAR_PALETTE[Math.abs(h) % SKILL_AVATAR_PALETTE.length];
}

// The level-1 header at the top of every Settings page: a big icon tile + title
// + optional subtitle, with a hairline rule. Picks an icon from the title when
// one isn't supplied.
// THE page shell: every Home and Settings page renders in a ScrollPage, whose
// header row (data-shell="header") holds the page's one SettingsHeader, and
// whose content is a SideSpine (data-shell="column" and "detail"). Pages never
// draw their own header band or surfaces; e2e/page-shell.spec.ts fails a page
// that does.
// Where a page's header goes. Inside the Settings and Work panes this is a
// fixed row above the scrolling content (an element to portal into), so the
// header never scrolls away; "detail" means the section is
// the detail pane of a larger page (SettingsHub), so its header becomes the
// pane's heading; null means render in place.
export const HeaderSlot = createContext<HTMLElement | "detail" | null>(null);

// The fixed header row every page uses, laid out like Intent's: full width,
// a rule under it, outside the scroll area.
export const PAGE_HEADER_ROW = "sticky top-0 z-20 shrink-0 border-b border-border bg-background px-8 py-5 max-md:px-4 max-md:py-3";


// A scrolling page with its header held above the scroll: the page's
// SettingsHeader portals into the fixed row, the rest scrolls under it, full
// width with even padding. Every Settings and Work section renders in one.
// `flush` pages (a SideSpine screen) fill the area themselves: no padding,
// and their column and detail scroll on their own.
export function ScrollPage({ children, testId, flush = false }: { children: ReactNode; testId?: string; flush?: boolean }) {
  const [slot, setSlot] = useState<HTMLDivElement | null>(null);
  return (
    <div className="flex min-h-0 min-w-0 flex-1 flex-col bg-background" data-testid={testId} data-shell="page">
      <div ref={setSlot} data-testid="page-header" data-shell="header" className={`${PAGE_HEADER_ROW} empty:hidden`} />
      <HeaderSlot.Provider value={slot}>
        {flush ? (
          <div className="flex min-h-0 min-w-0 flex-1 flex-col overflow-hidden" data-testid="page-flush">{children}</div>
        ) : (
          <div className="min-h-0 min-w-0 flex-1 overflow-y-auto" data-testid="page-scroll">
            <div className="w-full px-8 py-6 max-md:px-4 max-md:py-4">{children}</div>
          </div>
        )}
      </HeaderSlot.Provider>
    </div>
  );
}

// `tabs`: a page's view switch (a SpineTabs), in the standard place: the
// header's last row, under the title and subtitle.
// The header icon is the page's concept in its palette color (tint.tsx):
// `tint` names the concept when the icon alone does not, `color` overrides
// it (a domain page keeps its domain's color).
export function SettingsHeader({ title, subtitle, icon, right, tabs, tint, color: tintColorOverride }: { title: string; subtitle?: ReactNode; icon?: typeof Folder; right?: ReactNode; tabs?: ReactNode; tint?: string; color?: string }) {
  const Icon = icon ?? settingsHeaderIcon(title);
  const phone = useIsPhone();
  const slot = useContext(HeaderSlot);
  if (slot === "detail") {
    return (
      <div data-pane-heading className="mb-5 flex flex-wrap items-start gap-x-5 gap-y-1.5">
        <h2 className={`${DETAIL_TITLE} min-w-0`}>{title}</h2>
        {right && <div className="ml-auto flex shrink-0 items-center">{right}</div>}
        {subtitle && (typeof subtitle === "string" ? <p className="basis-full text-[14px] leading-snug text-text-muted">{subtitle}</p> : <div className="basis-full">{subtitle}</div>)}
      </div>
    );
  }
  // On a phone the shell already puts this page's name in the header bar with
  // the back button, so rendering the big title again printed it twice, one
  // under the other. Keep the one line that adds something.
  const body = phone ? (
    subtitle || right ? (
      <div data-settings-header className="flex flex-wrap items-center gap-2">
        {subtitle && (typeof subtitle === "string" ? <p className="min-w-0 flex-1 basis-40 text-[13px] text-text-muted">{subtitle}</p> : <div className="min-w-0 flex-1 basis-40">{subtitle}</div>)}
        {right && <div className="min-w-0 max-w-full">{right}</div>}
        {tabs && <div className="min-w-0 basis-full" data-shell="tabs">{tabs}</div>}
      </div>
    ) : tabs ? <div data-settings-header className="flex flex-wrap items-center gap-2"><div className="min-w-0 basis-full" data-shell="tabs">{tabs}</div></div> : null
  ) : (
    // Same header as Intent: the icon and a big title, controls on the
    // right, one calm line under it.
    <div data-settings-header className="flex flex-wrap items-center gap-x-5 gap-y-1.5">
      <h1 className="flex min-w-0 items-center gap-2.5 font-display text-[26px] font-semibold tracking-tight text-text-primary">
        <TintIcon icon={Icon} tint={tint} color={tintColorOverride} lg />
        <span className="min-w-0 truncate">{title}</span>
      </h1>
      {right && <div className="ml-auto flex shrink-0 items-center">{right}</div>}
      {subtitle && (typeof subtitle === "string" ? <p className="basis-full text-[14px] leading-snug text-text-muted">{subtitle}</p> : <div className="min-w-0 basis-full">{subtitle}</div>)}
      {tabs && <div className="mt-2 min-w-0 basis-full" data-shell="tabs">{tabs}</div>}
    </div>
  );
  if (!body) return null;
  if (slot) return createPortal(body, slot);
  return <div className="mb-4 border-b border-border-subtle pb-4">{body}</div>;
}
