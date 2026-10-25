// App-shell pieces extracted from App.tsx: BunkerRibbon (the always-on trust
// bar) and VaultWizard (first-run vault setup).
import { Fragment, useEffect, useState, type ReactNode } from "react";
import { motion, useMotionValue, useReducedMotion, useSpring } from "framer-motion";
import { Archive, Briefcase, Cloud, Folder, FolderOpen, Ghost, Heart, Home, Laptop, Receipt, Server, Shield, ShieldCheck, TrendingUp, Users, Wallet } from "lucide-react";
import { GlyphStudioLogo } from "./GlyphStudioLogo";
import { invoke } from "./bridge";
import { PREF, getPref } from "./storage";
import { APP_VERSION } from "./constants";
import { RELEASES_URL, useUpdateAvailable } from "./updatecheck";
import { FloatingChip } from "./widgets";
import { BrandMark } from "./brandmark";

// `compact` is the phone variant: one line at 390px (tighter type, no machine
// role segment, no version chip), so the trust bar never wraps above the tab bar.
export function BunkerRibbon({ enabled, compact = false }: { enabled: boolean; compact?: boolean }) {
  const updateAvailable = useUpdateAvailable();
  // Vault Lock status, surfaced in the trust bar so the user always knows whether
  // reads/writes are confined to the vault. Defaults to ON (locked) until the
  // backend says otherwise, and refreshes when the toggle changes or on focus.
  const [vaultLocked, setVaultLocked] = useState(true);
  // Global incognito: a separate axis from network/vault posture - it governs
  // whether prompts are logged + memory is written. Reflected live so the bar
  // updates the instant the master toggle fires `prevail:incognito-changed`.
  const [incognito, setIncognito] = useState(() => getPref(PREF.incognito, "0") === "1");
  // Machine role (hub | client) for a vault shared across two Macs. Shown in the
  // trust bar so it's obvious at a glance which machine this is: the always-on
  // HUB that runs all background automation, or a CLIENT that captures prompts
  // only. Sourced from the CLI (prevail role) via a Tauri command, exactly like
  // the other bar indicators pull their state from the backend. Defaults to hub.
  const [machineRole, setMachineRole] = useState<"hub" | "client">("hub");
  // Outbound Guardrail (Privacy > Outbound Guardrail): ONE flag mirrored from
  // the engine - on means email to others only drafts and sensitive details are
  // held at the boundary. Defaults ON (the locked-down default) until the
  // backend says otherwise.
  const [guardrail, setGuardrail] = useState(true);
  useEffect(() => {
    const pull = () => { void invoke<{ enabled: boolean }>("vault_lock_status").then((s) => setVaultLocked(s?.enabled !== false)).catch(() => {}); };
    const pullGuardrail = () => {
      void Promise.all([
        invoke<{ policy?: string }>("email_policy_get").catch(() => null),
        invoke<{ mode?: string }>("egress_guard_get").catch(() => null),
      ]).then(([p, g]) => { if (p || g) setGuardrail(p?.policy !== "allow" && g?.mode !== "off"); });
    };
    const syncIncognito = () => setIncognito(getPref(PREF.incognito, "0") === "1");
    const pullRole = () => { void invoke<string>("machine_role_get").then((r) => setMachineRole(r === "client" ? "client" : "hub")).catch(() => {}); };
    pull();
    syncIncognito();
    pullRole();
    pullGuardrail();
    window.addEventListener("prevail:guardrail-changed", pullGuardrail);
    window.addEventListener("focus", pullGuardrail);
    window.addEventListener("prevail:vault-lock-changed", pull);
    window.addEventListener("prevail:incognito-changed", syncIncognito);
    window.addEventListener("prevail:role-changed", pullRole);
    window.addEventListener("focus", pull);
    window.addEventListener("focus", syncIncognito);
    window.addEventListener("focus", pullRole);
    return () => {
      window.removeEventListener("prevail:guardrail-changed", pullGuardrail);
      window.removeEventListener("focus", pullGuardrail);
      window.removeEventListener("prevail:vault-lock-changed", pull);
      window.removeEventListener("prevail:incognito-changed", syncIncognito);
      window.removeEventListener("prevail:role-changed", pullRole);
      window.removeEventListener("focus", pull);
      window.removeEventListener("focus", syncIncognito);
      window.removeEventListener("focus", pullRole);
    };
  }, []);
  // The bar carries three INDEPENDENT trust axes, each its own labelled segment
  // with a tooltip so the distinction is obvious at a glance (feedback: "the
  // difference between Cloud Connected and Vault Locked isn't clear"):
  //   1. Network  - does anything leave this machine? (Cloud vs Bunker)
  //   2. Vault    - are file reads/writes confined to your vault folder?
  //   3. Incognito- shown only when the global master is on (no logging/memory).
  // High-contrast in BOTH modes: a tinted bar (not a translucent wash that
  // disappears over warm/cream themes), dark text on cyan, light text on dark.
  const Seg = ({ Icon, label, on, tip, onClick }: { Icon: typeof Cloud; label: string; on: boolean; tip: string; onClick?: () => void }) => (
    <span
      role={onClick ? "button" : undefined}
      tabIndex={onClick ? 0 : undefined}
      onClick={onClick}
      onKeyDown={onClick ? (e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); onClick(); } } : undefined}
      className={`inline-flex select-none items-center gap-1.5 font-semibold ${compact ? "text-[9px] tracking-[0.08em]" : "text-[10px] tracking-[0.16em]"} ${onClick ? "cursor-pointer underline-offset-2 hover:underline" : "cursor-default"} ${on ? "opacity-100" : "opacity-55"}`}
      title={onClick ? `${tip} (click to change)` : tip}
    >
      <Icon className="h-3.5 w-3.5" />
      {label}
    </span>
  );
  const divider = <span className="select-none opacity-30">|</span>;
  return (
    <div
      className={`relative flex shrink-0 items-center justify-center border-t py-1 text-[11px] ${compact ? "flex-nowrap gap-x-2 overflow-hidden whitespace-nowrap px-2" : "flex-wrap gap-x-3 gap-y-0.5 px-4"} ${
        enabled
          ? "border-ai bg-ai text-[#0a2230]"
          : "border-black/30 bg-[#141416] text-white/90"
      }`}
    >
      {/* What this bar says depends on whether there is anything to say.
          Three segments permanently reading "locked, on, connected" is three
          ways of describing the ordinary state, on every screen, forever - and
          it buries the one line that matters on the day something is open.
          So: when every axis is in its protective state the bar carries ONE
          quiet segment naming that fact, with the detail on hover. The moment
          an axis is NOT protective it is named on its own, in warning weight.
          Bunker Mode and Incognito are deliberate postures rather than
          defaults, so they are always named when on. */}
      {(() => {
        const openAxes = [
          !vaultLocked && {
            Icon: FolderOpen,
            label: "Vault unlocked",
            tip: "Vault Unlocked: the assistant may reach files outside your vault folder.",
          },
          !guardrail && {
            Icon: Shield,
            label: "Guardrail off",
            tip: "Outbound Guardrail OFF: approved sends go out exactly as addressed, unscanned.",
          },
        ].filter(Boolean) as { Icon: typeof Cloud; label: string; tip: string }[];
        const openPrivacy = () => window.dispatchEvent(new CustomEvent("prevail:open-settings", { detail: "privacy" }));
        const parts: ReactNode[] = [];
        if (enabled) {
          parts.push(
            <Seg key="bunker" Icon={ShieldCheck} label="Bunker mode" on onClick={openPrivacy}
              tip="Bunker Mode: nothing leaves this device. Only local models run; cloud models and web access are blocked." />,
          );
        }
        if (incognito) {
          parts.push(
            <Seg key="incognito" Icon={Ghost} label="Incognito" on onClick={openPrivacy}
              tip="Global Incognito is ON: prompts aren't logged and nothing is written to memory, everywhere in the app." />,
          );
        }
        for (const a of openAxes) {
          parts.push(<Seg key={a.label} Icon={a.Icon} label={a.label} on={false} onClick={openPrivacy} tip={a.tip} />);
        }
        if (parts.length === 0) {
          parts.push(
            <Seg key="protected" Icon={ShieldCheck} label="Protected" on onClick={openPrivacy}
              tip="Vault Locked (files stay inside your vault) and Outbound Guardrail ON (nothing reaches another party without you). Cloud models and web access are available; switch to Bunker Mode for local-only." />,
          );
        }
        return parts.map((p, i) => (
          <Fragment key={i}>
            {i > 0 && divider}
            {p}
          </Fragment>
        ));
      })()}
      {/* 4. Machine role - which Mac this is for a shared vault. Distinct icon
          (server tower for the hub, laptop for a client) so it's obvious at a
          glance. Always shown; hub is the default single-machine state. */}
      {!compact && (<>
      {divider}
      <Seg
        Icon={machineRole === "hub" ? Server : Laptop}
        label={machineRole === "hub" ? "Hub" : "Client"}
        on
        onClick={() => window.dispatchEvent(new CustomEvent("prevail:open-settings", { detail: "daemons" }))}
        tip={machineRole === "hub"
          ? "Hub: this Mac runs all background automation for the vault (learn, loops, connector sync, schedule ticks)."
          : "Client: this Mac captures prompts only. Background automation for the shared vault runs on the hub."}
      />
      {/* Version - inside the ribbon so it inherits the high-contrast ribbon
          text color (the old standalone pill was invisible over the dark bar). */}
      {/* A newer release is a fact worth a glance, not a hunt through About.
          Green, pulsing, and it opens the release page. */}
      {updateAvailable ? (
        <a
          href={RELEASES_URL}
          target="_blank"
          rel="noreferrer"
          title={`Glyph Studio ${updateAvailable} is available. You have ${APP_VERSION}. Click to download.`}
          data-testid="update-available"
          className="absolute right-3 inline-flex items-center gap-1.5 rounded-full bg-ok px-2.5 py-0.5 font-mono text-[10px] font-bold tracking-wider text-background hover:opacity-90"
        >
          <span className="relative flex h-1.5 w-1.5">
            <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-background opacity-75" />
            <span className="relative inline-flex h-1.5 w-1.5 rounded-full bg-background" />
          </span>
          v{updateAvailable} available
        </a>
      ) : (
        <span className="pointer-events-none absolute right-3 select-none font-mono text-[10px] tracking-wider opacity-70">
          v{APP_VERSION}
        </span>
      )}
      </>)}
    </div>
  );
}

// A7: live "bridge running" chips in the app footer - so you always know a
// Telegram bridge or the WebUI is serving your vault, from anywhere in the app
// (not just buried in Settings). Polls every 4s; renders nothing when idle.

// A prominent, full-width ribbon pinned to the very bottom of the app whenever
// you're in the demo sandbox - so you always know this is sample data. The
// "Switch to Production" link takes you to the configuration page. Removed
// entirely (no ribbon) the moment you're in production.

// Per-domain preferred skills - auto-attach on entering a domain.

// Concatenates a list of chat messages into a single text payload for
// passing as context to a stateless CLI. Drops the oldest turns until
// the total stays under `maxChars`. Empty-content messages (the streaming
// placeholder for an in-flight reply) are excluded automatically.
//
// IMPORTANT: callers pass the PRIOR conversation - at send() time React's
// state update for the just-typed user turn + its placeholder has not yet
// committed, so `msgs` does NOT contain them. We must therefore keep every
// prior turn (filtering only empties). A previous version sliced off the
// last two entries on the assumption the new pair was already present, which
// silently dropped the most-recent completed exchange - so a follow-up that
// referenced it (e.g. "was he any good?") reached the model with no context,
// most visibly when switching models mid-thread. (feedback v0.4.1 B1)

// ─────────────────────────────────────────────────────────────────────
// App root - vault picker, sidebar, tabs.

export function VaultWizard({ onPick }: { onPick: () => void }) {
  // Staggered entrance for the center column.
  const container = { hidden: {}, show: { transition: { staggerChildren: 0.09, delayChildren: 0.12 } } };
  const item = {
    hidden: { opacity: 0, y: 14 },
    show: { opacity: 1, y: 0, transition: { type: "spring" as const, stiffness: 120, damping: 16 } },
  };
  const reduce = useReducedMotion();
  // Pointer parallax - shared springs the chips read from for depth.
  const px = useMotionValue(0);
  const py = useMotionValue(0);
  const sx = useSpring(px, { stiffness: 60, damping: 18 });
  const sy = useSpring(py, { stiffness: 60, damping: 18 });
  const onMove = (e: React.MouseEvent) => {
    if (reduce) return;
    px.set(e.clientX / window.innerWidth - 0.5);
    py.set(e.clientY / window.innerHeight - 0.5);
  };
  // Decorative life-domain chips (icons, never emojis) that drift + parallax.
  const chips = [
    { Icon: Wallet,    t: "Wealth",  x: "11%", y: "24%", d: 0.0, depth: 26 },
    { Icon: Heart,     t: "Health",  x: "79%", y: "18%", d: 0.6, depth: 38 },
    { Icon: Receipt,   t: "Tax",     x: "17%", y: "71%", d: 1.2, depth: 20 },
    { Icon: Briefcase, t: "Career",  x: "82%", y: "67%", d: 0.9, depth: 32 },
    { Icon: Home,      t: "Home",    x: "7%",  y: "48%", d: 1.6, depth: 44 },
    { Icon: Archive,   t: "Records", x: "87%", y: "45%", d: 0.3, depth: 16 },
  ];
  return (
    <div
      className="relative flex h-screen flex-col items-center justify-center overflow-hidden bg-background text-text-primary"
      data-tauri-drag-region
      onMouseMove={onMove}
    >
      {/* animated aurora background */}
      <div className="pointer-events-none absolute inset-0" aria-hidden>
        <motion.div
          className="absolute -left-40 -top-40 h-[42rem] w-[42rem] rounded-full blur-3xl"
          style={{ background: "radial-gradient(circle at center, color-mix(in srgb, var(--color-accent) 20%, transparent), transparent 60%)" }}
          animate={{ x: [0, 60, -20, 0], y: [0, 40, 10, 0], scale: [1, 1.1, 0.95, 1] }}
          transition={{ duration: 22, repeat: Infinity, ease: "easeInOut" }}
        />
        <motion.div
          className="absolute -right-40 top-1/4 h-[38rem] w-[38rem] rounded-full blur-3xl"
          style={{ background: "radial-gradient(circle at center, rgba(45,127,228,0.15), transparent 60%)" }}
          animate={{ x: [0, -50, 20, 0], y: [0, 30, -20, 0], scale: [1, 1.08, 1, 1] }}
          transition={{ duration: 26, repeat: Infinity, ease: "easeInOut" }}
        />
        <motion.div
          className="absolute bottom-[-12rem] left-1/3 h-[34rem] w-[34rem] rounded-full blur-3xl"
          style={{ background: "radial-gradient(circle at center, color-mix(in srgb, var(--color-accent) 13%, transparent), transparent 60%)" }}
          animate={{ x: [0, 40, -30, 0], y: [0, -30, 10, 0] }}
          transition={{ duration: 30, repeat: Infinity, ease: "easeInOut" }}
        />
      </div>

      {/* film grain */}
      <div
        className="pointer-events-none absolute inset-0 opacity-[0.04] mix-blend-overlay"
        aria-hidden
        style={{
          backgroundImage:
            "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='140' height='140'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.85' numOctaves='2'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)'/%3E%3C/svg%3E\")",
          backgroundSize: "140px 140px",
        }}
      />

      {/* drifting + parallaxing life-domain chips */}
      <div className="pointer-events-none absolute inset-0 hidden md:block" aria-hidden>
        {chips.map((c) => (
          <FloatingChip key={c.t} chip={c} sx={sx} sy={sy} reduce={!!reduce} />
        ))}
      </div>

      {/* center column */}
      <motion.div variants={container} initial="hidden" animate="show" className="relative z-10 max-w-xl px-8 text-center">
        {/* logo with orbiting rings + pulsing glow */}
        <motion.div variants={item} className="mb-7 flex justify-center">
          <div className="relative flex items-center justify-center" style={{ width: 132, height: 132 }}>
            <motion.div
              className="absolute rounded-full"
              style={{ inset: 16, boxShadow: "0 0 60px color-mix(in srgb, var(--color-accent) 40%, transparent)" }}
              animate={{ opacity: [0.45, 0.85, 0.45], scale: [0.95, 1.06, 0.95] }}
              transition={{ duration: 4, repeat: Infinity, ease: "easeInOut" }}
            />
            <motion.svg className="absolute" width={132} height={132} viewBox="0 0 132 132" fill="none"
              animate={{ rotate: 360 }} transition={{ duration: 24, repeat: Infinity, ease: "linear" }}>
              <circle cx="66" cy="66" r="62" stroke="var(--color-accent)" strokeOpacity="0.35" strokeWidth="1" strokeDasharray="3 7" />
            </motion.svg>
            <motion.svg className="absolute" width={112} height={112} viewBox="0 0 112 112" fill="none"
              animate={{ rotate: -360 }} transition={{ duration: 18, repeat: Infinity, ease: "linear" }}>
              <circle cx="56" cy="56" r="53" stroke="#2d7fe4" strokeOpacity="0.28" strokeWidth="1" strokeDasharray="2 10" />
            </motion.svg>
            <GlyphStudioLogo size={88} src="/logo-512.png" />
          </div>
        </motion.div>

        <motion.div variants={item} className="text-[11px] text-accent">◆ first launch</motion.div>

        <motion.div variants={item} className="relative mt-5 inline-block overflow-hidden px-1 py-1">
          <h1 className="font-display text-5xl font-semibold leading-[0.95] tracking-tight sm:text-6xl">
            Welcome to <BrandMark />.
          </h1>
          {!reduce && (
            <motion.span
              aria-hidden
              className="pointer-events-none absolute inset-0"
              style={{
                background: "linear-gradient(105deg, transparent 35%, rgba(255,255,255,0.55) 50%, transparent 65%)",
                mixBlendMode: "overlay",
              }}
              initial={{ x: "-130%" }}
              animate={{ x: "130%" }}
              transition={{ duration: 1.1, delay: 0.7, ease: "easeInOut" }}
            />
          )}
        </motion.div>

        <motion.p variants={item} className="mx-auto mt-5 max-w-2xl text-balance text-[15px] text-text-secondary">
          Your life in <span className="font-medium text-text-primary">Domains</span>: scored, private, <span className="font-medium text-accent">Local-first</span>.
        </motion.p>

        {/* feature pills */}
        <motion.div variants={item} className="mt-6 flex flex-wrap items-center justify-center gap-2">
          {[
            { Icon: Shield, t: "Local-first vault · cloud optional" },
            { Icon: TrendingUp, t: "Context Score" },
            { Icon: Users, t: "Multi-model council" },
          ].map(({ Icon, t }) => (
            <span key={t} className="inline-flex items-center gap-1.5 rounded-full border border-accent-border bg-accent-soft px-3 py-1 font-mono text-[11px] text-accent">
              <Icon className="h-3 w-3" />{t}
            </span>
          ))}
        </motion.div>

        {/* CTA - point to a vault. Sample data is available later from
            Settings > Workspace; we don't push it here (it read as the user's own
            data and caused confusion on a fresh install). */}
        <motion.div variants={item} className="mt-9 flex flex-wrap items-center justify-center gap-3">
          <motion.button
            onClick={onPick}
            whileHover={{ y: -2, scale: 1.02 }}
            whileTap={{ scale: 0.98 }}
            className="inline-flex items-center gap-2.5 rounded-xl bg-accent px-7 py-3.5 text-[15px] font-semibold text-background shadow-lg transition-colors hover:bg-accent-hover"
          >
            <Folder className="h-4 w-4" /> Pick your vault folder
          </motion.button>
        </motion.div>

        <motion.div variants={item} className="mt-5 text-xs text-text-muted">
          Your vault is a folder on your Mac. Want to explore first? Load sample data anytime from Settings, Workspace.
          <span className="mx-2 opacity-40">·</span>
          <span className="font-mono">v{APP_VERSION} · stays on your Mac</span>
        </motion.div>
      </motion.div>
    </div>
  );
}
