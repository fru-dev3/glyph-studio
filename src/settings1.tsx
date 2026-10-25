// Self-contained Settings sections extracted from App.tsx: Shortcuts,
// Remote/WebUI, and Ingestion. Each renders shared panel components and
// the SettingsHeader; none close over App root state.
import { Fragment, useEffect, useState } from "react";
import { invoke, isBrowser } from "./bridge";
import { PREF, getPref, setPref } from "./storage";
import { Toggle } from "./ui";
import { SettingsRowLite } from "./panels";
import { SettingsHeader } from "./sectionutil";
import { DesktopOnly } from "./emptystate";

export function ShortcutsSection() {
  type Entry = { keys: string[]; label: string; desc: string };
  const groups: Array<{ name: string; entries: Entry[] }> = [
    {
      name: "Navigation",
      entries: [
        { keys: ["⌘", "K"], label: "Command palette", desc: "Search actions, every page, and every domain from one place." },
        { keys: ["⌘", "⇧", "K"], label: "New chat", desc: "Drops the current domain + thread, lands on the no-domain dashboard." },
        { keys: ["⌘", "P"], label: "Quick switcher", desc: "Fuzzy finder over every domain and every saved thread." },
        { keys: ["⌘", "B"], label: "Toggle sidebar", desc: "Collapses or expands the domain rail." },
        { keys: ["⌘", ","], label: "Open Settings", desc: "Jumps to the settings panel from anywhere." },
      ],
    },
    {
      name: "Composer",
      entries: [
        { keys: ["↵"], label: "Send (Enter mode)", desc: "Default. Switch to ⌘+↵ in Settings → General → Send messages with." },
        { keys: ["⇧", "↵"], label: "New line", desc: "Insert a hard newline without sending." },
        { keys: ["↑"], label: "Recall last prompt", desc: "Walk backward through this domain's prompt history." },
        { keys: ["↓"], label: "Recall next prompt", desc: "Walk forward; ↓ past the newest clears the composer." },
        { keys: ["/"], label: "Skill autocomplete", desc: "Type / and a few letters to fuzzy-match a skill in this domain." },
      ],
    },
    {
      name: "Thread rail",
      entries: [
        { keys: ["double-click"], label: "Rename", desc: "Edit the thread's title inline. ↵ to confirm." },
        { keys: ["+"], label: "New thread", desc: "Creates an empty thread file immediately: rename it before typing." },
      ],
    },
  ];

  const Key = ({ children }: { children: React.ReactNode }) => (
    <kbd className="inline-flex h-6 min-w-[1.5rem] items-center justify-center rounded border border-border bg-background px-1.5 font-mono text-[12px] font-medium text-text-primary shadow-sm">
      {children}
    </kbd>
  );

  return (
    <>
      <SettingsHeader title="Shortcuts" subtitle="Shortcuts, most of them global." />
      <div className="space-y-6">
        {groups.map((g) => (
          <section key={g.name} className="border-t border-border-subtle pt-4">
            <div className="mb-3 text-[14px] font-semibold text-text-primary">
              {g.name}
            </div>
            <ul className="flex flex-col divide-y divide-border-subtle">
              {g.entries.map((e, i) => (
                <li key={i} className="flex items-center justify-between gap-4 py-2.5">
                  <div className="min-w-0 flex-1">
                    <div className="text-sm font-semibold text-text-primary">{e.label}</div>
                    <div className="mt-0.5 text-xs text-text-secondary">{e.desc}</div>
                  </div>
                  <div className="flex shrink-0 items-center gap-1">
                    {e.keys.map((k, j) => (
                      <Fragment key={j}>
                        <Key>{k}</Key>
                        {j < e.keys.length - 1 && e.keys.length > 1 && k.length === 1 && e.keys[j+1].length === 1 && (
                          <span className="text-[12px] text-text-muted">+</span>
                        )}
                      </Fragment>
                    ))}
                  </div>
                </li>
              ))}
            </ul>
          </section>
        ))}
      </div>
    </>
  );
}






// Stable color picker for the first-letter skill avatars. Same skill
// name always lands on the same swatch so the grid feels consistent.

import { RemotePairCard } from "./remotepair";

export function RemoteSection() {
  const [running, setRunning] = useState(false);
  const [port, setPort] = useState(() => getPref(PREF.webuiPort, "8787"));
  const [user, setUser] = useState(() => getPref(PREF.webuiUser, "admin"));
  // Reachable from other devices: binds every interface instead of loopback,
  // so a phone on the same Wi-Fi (nothing installed) or on the tailnet can
  // open it. This is what makes the phone flow possible at all. Reaching it
  // from anywhere is the separate "Share over the internet" tunnel in the
  // pair card below.
  const [remote, setRemote] = useState(() => getPref(PREF.webuiRemote, "1") === "1");
  // E2: the password lives in the OS keychain, not plaintext localStorage. Load
  // it on mount, migrating any legacy localStorage value (then scrubbing it).
  const [pass, setPass] = useState("");
  const [showPass, setShowPass] = useState(false);
  const [err, setErr] = useState("");
  useEffect(() => {
    // The bridge password is a desktop-only secret: a phone that is already
    // signed in must never be able to read it (that would hand over every
    // future session) or change it. The server refuses both commands, so
    // asking from a browser only produces 403 noise - don't ask.
    if (isBrowser()) return;
    invoke<{ running: boolean }>("webui_status").then((s) => setRunning(!!s.running)).catch(() => {});
    (async () => {
      let p = "";
      try { p = await invoke<string>("webui_secret_get"); } catch { /* keychain unavailable */ }
      const legacy = getPref(PREF.webuiPass, "");
      if (!p && legacy) { p = legacy; try { await invoke("webui_secret_set", { pass: p }); } catch { /* ignore */ } }
      if (legacy) setPref(PREF.webuiPass, ""); // scrub the plaintext copy
      if (!p) { p = Math.random().toString(36).slice(2, 10) + Math.random().toString(36).slice(2, 6); try { await invoke("webui_secret_set", { pass: p }); } catch { /* ignore */ } }
      setPass(p);
    })();
  }, []);
  const savePass = (p: string) => { setPass(p); void invoke("webui_secret_set", { pass: p }).catch(() => {}); };
  async function toggle(on: boolean) {
    setErr("");
    try {
      if (on) {
        await invoke("webui_start", { port: Number(port) || 8787, user, pass, remote });
        setRunning(true);
      } else {
        await invoke("webui_stop");
        setRunning(false);
      }
    } catch (e) { setErr(String(e)); }
  }
  return (
    <>
      <SettingsHeader title="Remote (WebUI)" subtitle="Reach this app from another device." />
      <DesktopOnly feature="The WebUI server">
      <div>
        <SettingsRowLite title="Enable WebUI" desc="Run the bridge server so a browser can use Glyph Studio. This Mac must stay on."
          control={<Toggle on={running} onChange={toggle} />} />
        <SettingsRowLite title="Port" desc="Local port the WebUI listens on."
          control={<input type="number" value={port} disabled={running} onChange={(e) => { setPort(e.target.value); setPref(PREF.webuiPort, e.target.value); }} className="w-24 rounded-md border border-border bg-background px-2 py-1.5 text-right text-sm focus:border-accent-border focus:outline-none disabled:opacity-50" />} />
        <SettingsRowLite title="Reachable from other devices" desc="Your phone and laptop can open it over the same Wi-Fi with nothing to install, and over Tailscale when both sides have it. Away from home, use Share over the internet below. Off means this Mac only."
          control={<Toggle on={remote} onChange={(v) => { setRemote(v); setPref(PREF.webuiRemote, v ? "1" : "0"); }} />} />
        <SettingsRowLite title="Username" desc="Login for the WebUI."
          control={<input value={user} disabled={running} onChange={(e) => { setUser(e.target.value); setPref(PREF.webuiUser, e.target.value); }} className="w-40 rounded-md border border-border bg-background px-2 py-1.5 text-sm focus:border-accent-border focus:outline-none disabled:opacity-50" />} />
        <SettingsRowLite title="Password" desc="Keep this private: anyone with it and the URL can use your agent."
          control={
            <div className="flex items-center gap-2">
              <input type={showPass ? "text" : "password"} value={pass} disabled={running} onChange={(e) => savePass(e.target.value)} className="w-40 rounded-md border border-border bg-background px-2 py-1.5 font-mono text-sm focus:border-accent-border focus:outline-none disabled:opacity-50" />
              <button onClick={() => setShowPass((v) => !v)} className="font-mono text-[12px] text-text-muted hover:text-accent">{showPass ? "Hide" : "Show"}</button>
            </div>
          } />
      </div>
      {running && <RemotePairCard port={port} />}
      {err && <div className="mt-3 rounded-md border border-warn/40 bg-warn/10 px-3 py-2 text-xs text-warn">{err}</div>}
      </DesktopOnly>
    </>
  );
}

