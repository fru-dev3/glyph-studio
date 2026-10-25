// Profile switcher: a compact control pinned in the sidebar that shows the
// active profile and lets you switch between fully-isolated profiles (each its
// own vault). Self-contained: it reads/writes the local profile registry and
// dispatches `prevail:switch-profile` (App performs the vault swap + re-lock).
// Gated profiles require their passcode inline before switching.
import { type ReactNode, useEffect, useRef, useState } from "react";
import { Check, ChevronDown, Lock, Plus, Settings2 } from "lucide-react";
import { getActiveId, initials, offeredProfiles, setActiveId, setDefaultId, verifyPasscode, type Profile } from "./profiles";

// The sidebar header: avatar with a presence dot, the profile name, a second
// line naming the workspace (with the switcher chevron), and a `trailing` slot
// on the right (the sidebar puts its settings button there).
export function ProfileSwitcher({ collapsed, trailing }: { collapsed: boolean; trailing?: ReactNode }) {
  const [profiles, setProfiles] = useState<Profile[]>(() => offeredProfiles());
  const [activeId, setActive] = useState<string | null>(() => getActiveId());
  const [open, setOpen] = useState(false);
  const [gateId, setGateId] = useState<string | null>(null); // profile awaiting passcode
  const [code, setCode] = useState("");
  const [err, setErr] = useState<string | null>(null);
  const ref = useRef<HTMLDivElement>(null);

  const refresh = () => { setProfiles(offeredProfiles()); setActive(getActiveId()); };
  useEffect(() => {
    const f = () => refresh();
    window.addEventListener("prevail:profiles-changed", f);
    return () => window.removeEventListener("prevail:profiles-changed", f);
  }, []);
  // Close on outside click.
  useEffect(() => {
    if (!open) return;
    const onDown = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) { setOpen(false); setGateId(null); setCode(""); setErr(null); }
    };
    document.addEventListener("mousedown", onDown);
    return () => document.removeEventListener("mousedown", onDown);
  }, [open]);

  const active = profiles.find((p) => p.id === activeId) ?? null;

  const doSwitch = async (p: Profile, passcode?: string) => {
    if (p.id === activeId) { setOpen(false); return; }
    if (p.passHash) {
      const ok = await verifyPasscode(p, passcode ?? "");
      if (!ok) { setErr("Wrong passcode"); return; }
    }
    setActiveId(p.id);
    // Switching to a profile makes it the startup default, so the app opens
    // this profile's vault on the next launch instead of reverting to the
    // sample sandbox (the "profile changes every time" bug).
    setDefaultId(p.id);
    setActive(p.id);
    window.dispatchEvent(new CustomEvent("prevail:switch-profile", { detail: { vaultPath: p.vaultPath, profileId: p.id } }));
    window.dispatchEvent(new CustomEvent("prevail:profiles-changed"));
    setOpen(false); setGateId(null); setCode(""); setErr(null);
  };

  const onRowClick = (p: Profile) => {
    setErr(null);
    if (p.passHash && p.id !== activeId) { setGateId(p.id); setCode(""); }
    else void doSwitch(p);
  };

  const avatar = (p: Profile | null, size: number) =>
    p?.image ? (
      <img src={p.image} alt="" className="shrink-0 rounded-full object-cover" style={{ width: size, height: size }} />
    ) : (
      <span
        className="flex shrink-0 items-center justify-center rounded-full font-semibold text-on-accent"
        style={{ width: size, height: size, fontSize: size * 0.42, background: p?.color || "var(--color-accent)" }}
      >
        {p ? initials(p) : "P"}
      </span>
    );
  // The dot says this profile is the one open on this machine.
  const withPresence = (p: Profile | null, size: number) => (
    <span className="relative shrink-0">
      {avatar(p, size)}
      <span className="absolute -bottom-0.5 -right-0.5 h-2.5 w-2.5 rounded-full bg-ok ring-2 ring-surface-strong" />
    </span>
  );
  const name = active?.label ?? "Glyph Studio";
  const second = active?.email || "Personal workspace";

  return (
    <div ref={ref} className="relative">
      <div className={`flex items-center ${collapsed ? "flex-col gap-2 px-2 py-3" : "gap-1.5 py-3 pl-2 pr-3"}`}>
        <button
          onClick={() => active && setOpen((v) => !v)}
          disabled={!active}
          title={active ? `Profile: ${active.label}, click to switch` : "Glyph Studio"}
          aria-label="Switch profile"
          className={`flex min-w-0 items-center rounded-lg transition-colors hover:bg-surface-warm disabled:hover:bg-transparent ${collapsed ? "justify-center p-1" : "flex-1 gap-2 px-1 py-1"}`}
        >
          {withPresence(active, collapsed ? 30 : 32)}
          {!collapsed && (
            <span className="flex min-w-0 flex-1 flex-col items-start leading-tight">
              <span className="w-full truncate text-left text-[15px] font-semibold text-text-primary">{name}</span>
              <span className="flex w-full min-w-0 items-center gap-1 text-[12px] text-text-muted">
                <span className="truncate">{second}</span>
                {active && <ChevronDown className="h-3.5 w-3.5 shrink-0" />}
              </span>
            </span>
          )}
        </button>
        {trailing}
      </div>

      {open && active && (
        <div className={`absolute top-full z-50 mt-1 w-60 rounded-lg border border-border bg-surface p-1 shadow-2xl ${collapsed ? "left-2" : "left-3 right-3 w-auto"}`}>
          <div className="px-2 py-1 text-[11px] text-text-muted">Profiles</div>
          <ul className="max-h-72 overflow-y-auto">
            {profiles.map((p) => (
              <li key={p.id}>
                <button
                  onClick={() => onRowClick(p)}
                  className="flex w-full items-center gap-2.5 rounded-md px-2 py-1.5 text-left transition-colors hover:bg-surface-warm"
                >
                  {avatar(p, 24)}
                  <span className="flex min-w-0 flex-1 flex-col leading-tight">
                    <span className="truncate text-[13px] text-text-primary">{p.label}</span>
                    {p.email && <span className="truncate text-[10px] text-text-muted">{p.email}</span>}
                  </span>
                  {p.passHash && <Lock className="h-3 w-3 shrink-0 text-text-muted" />}
                  {p.id === activeId && <Check className="h-3.5 w-3.5 shrink-0 text-accent" />}
                </button>
                {gateId === p.id && (
                  <div className="px-2 pb-1.5 pt-1">
                    <input
                      autoFocus
                      type="password"
                      value={code}
                      onChange={(e) => { setCode(e.target.value); setErr(null); }}
                      onKeyDown={(e) => { if (e.key === "Enter") void doSwitch(p, code); if (e.key === "Escape") { setGateId(null); setCode(""); setErr(null); } }}
                      placeholder="Passcode"
                      className="w-full rounded-md border border-border bg-background px-2.5 py-1.5 text-sm focus:border-accent-border focus:outline-none"
                    />
                    {err && <div className="mt-1 text-[10px] text-err">{err}</div>}
                    <button
                      onClick={() => void doSwitch(p, code)}
                      className="mt-1 w-full rounded-md bg-accent px-2 py-1 text-xs font-semibold text-background hover:bg-accent-hover"
                    >
                      Unlock & switch
                    </button>
                  </div>
                )}
              </li>
            ))}
          </ul>
          <div className="my-1 h-px bg-border-subtle" />
          <button
            onClick={() => { setOpen(false); window.dispatchEvent(new CustomEvent("prevail:open-settings", { detail: "profiles" })); }}
            className="flex w-full items-center gap-2 rounded-md px-2 py-1.5 text-left text-[13px] text-text-secondary transition-colors hover:bg-surface-warm hover:text-text-primary"
          >
            <Plus className="h-3.5 w-3.5" /> Add profile
          </button>
          <button
            onClick={() => { setOpen(false); window.dispatchEvent(new CustomEvent("prevail:open-settings", { detail: "profiles" })); }}
            className="flex w-full items-center gap-2 rounded-md px-2 py-1.5 text-left text-[13px] text-text-secondary transition-colors hover:bg-surface-warm hover:text-text-primary"
          >
            <Settings2 className="h-3.5 w-3.5" /> Manage profiles
          </button>
        </div>
      )}
    </div>
  );
}
