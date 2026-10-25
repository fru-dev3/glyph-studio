// Phone: the one screen for putting Prevail on your phone. Lives at the top
// level of the Editor nav rather than buried in the network settings, because
// nobody goes looking for "mobile access" inside a WebUI server panel.
//
// It does the whole job in one place: turn the bridge on, show a QR code that
// signs the phone in WITHOUT typing a password, offer an internet address for
// when you are away from home, and say how to install it to the home screen.
// The technical knobs (port, username, password) stay in Network.
//
// The QR carries a one-shot pairing code in the URL fragment. Scanning trades
// it for a session token, which is what makes this usable: a generated
// password is miserable to type on a phone keyboard.
import { useCallback, useEffect, useRef, useState } from "react";
import { Check, Copy, Globe, Mic, Smartphone, ShieldCheck, Wifi } from "lucide-react";
import QRCode from "qrcode";
import { invoke } from "./bridge";
import { PREF, getPref, setPref } from "./storage";
import { SettingsHeader } from "./sectionutil";
import { DesktopOnly } from "./emptystate";

interface WebuiStatus {
  running: boolean;
  port: number;
  user: string;
  remote: boolean;
  remote_url: string;
  via_tailscale: boolean;
  lan_url: string;
  tailscale_url: string;
  tunnel_url: string;
  tunnel_state: "off" | "starting" | "on" | "error";
  tunnel_error: string;
  cloudflared_installed: boolean;
  pair_ready: boolean;
  devices: Device[];
  bunker_blocking: boolean;
}

export interface Device {
  id: string;
  label: string;
  ip: string;
  first_seen_ms: number;
  last_seen_ms: number;
  via: "qr" | "password" | string;
}

// "just now" / "4 min ago" / "2 h ago". Phones drop off Wi-Fi constantly, so
// the useful question is not "is it connected" but "when did I last hear from
// it", which this answers without a clock on screen.
function ago(ms: number): string {
  const s = Math.max(0, Math.round((Date.now() - ms) / 1000));
  if (s < 45) return "just now";
  if (s < 3600) return `${Math.round(s / 60)} min ago`;
  if (s < 86400) return `${Math.round(s / 3600)} h ago`;
  return `${Math.round(s / 86400)} d ago`;
}

// A phone polls while its tab is open, so silence for two minutes means the
// screen went off or the tab was closed, not that it is mid-request.
const LIVE_WINDOW_MS = 120_000;
function isLive(d: Device): boolean {
  return Date.now() - d.last_seen_ms < LIVE_WINDOW_MS;
}

const BREW_CLOUDFLARED = "brew install cloudflared";

function CopyButton({ text, label = "Copy address" }: { text: string; label?: string }) {
  const [copied, setCopied] = useState(false);
  async function copy() {
    try { await navigator.clipboard.writeText(text); setCopied(true); window.setTimeout(() => setCopied(false), 1500); } catch { /* clipboard unavailable */ }
  }
  return (
    <button onClick={copy} className="inline-flex shrink-0 items-center gap-1 rounded-md border border-border px-2 py-1 text-xs text-text-muted hover:text-accent" title={label} aria-label={label}>
      {copied ? <Check className="h-3.5 w-3.5" /> : <Copy className="h-3.5 w-3.5" />} {copied ? "Copied" : "Copy"}
    </button>
  );
}

// Poll the bridge. One hook so the Phone screen and the Network screen agree.
function useWebuiStatus(pollMs = 3000) {
  const [status, setStatus] = useState<WebuiStatus | null>(null);
  const refresh = useCallback(() => invoke<WebuiStatus>("webui_status").then(setStatus).catch(() => setStatus(null)), []);
  useEffect(() => {
    let alive = true;
    const tick = () => { if (alive) void refresh(); };
    tick();
    const id = window.setInterval(tick, pollMs);
    return () => { alive = false; window.clearInterval(id); };
  }, [refresh, pollMs]);
  return { status, setStatus, refresh };
}

// A pairing code lives about two minutes, so the QR on screen is refreshed
// while you are looking at it and nothing stays valid for long after you walk
// away.
const PAIR_REFRESH_MS = 100_000;

// Keep a live pairing code for the address currently on screen.
//
// A code is single use. When one is spent we deliberately do NOT mint another:
// we stop showing a QR and name the device that took it instead. That matters
// because the person who redeems a code is not necessarily the person holding
// the Mac - anyone who can see the screen, or a photo of it, can race for it.
// Auto-minting hid that completely: the owner saw "paired", scanned the fresh
// code, and never learned that a second device had also got in. Now a spent
// code produces a confirmation with a name, an address and a way to cut it off,
// and showing another code takes a deliberate tap.
function usePairingQr(status: WebuiStatus | null) {
  const url = status?.remote_url ?? "";
  const [pairUrl, setPairUrl] = useState("");
  // The device that spent the last code, held until dismissed - not a toast
  // that disappears before it is read.
  const [pairedDevice, setPairedDevice] = useState<Device | null>(null);
  const mintedFor = useRef("");
  const mintedAt = useRef(0);
  const wasReady = useRef(false);

  const mint = useCallback((forUrl: string) => {
    mintedFor.current = forUrl;
    mintedAt.current = Date.now();
    setPairedDevice(null);
    invoke<string>("webui_pair_code")
      .then((u) => setPairUrl(u))
      .catch(() => setPairUrl("")); // fall back to the plain address + password
  }, []);

  useEffect(() => {
    if (!status?.running || !url) {
      setPairUrl("");
      mintedFor.current = "";
      wasReady.current = false;
      return;
    }
    const first = mintedFor.current !== url;
    const consumed = wasReady.current && !status.pair_ready;
    wasReady.current = status.pair_ready;
    if (consumed) {
      // Whichever device signed in by code most recently is the one that just
      // spent it. Naming it is what turns a silent compromise into a visible
      // one.
      const byCode = (status.devices ?? []).filter((d) => d.via === "qr");
      const newest = byCode.reduce<Device | null>((best, d) => (!best || d.first_seen_ms > best.first_seen_ms ? d : best), null);
      setPairedDevice(newest);
      setPairUrl("");
      return;
    }
    // A spent code waits for a deliberate tap before another is minted, so a
    // photographed screen cannot keep producing working codes.
    if (pairedDevice) return;
    // Refresh the code while the screen is open so what is displayed always
    // works, without leaving a long-lived credential behind when it is not.
    const stale = Date.now() - mintedAt.current > PAIR_REFRESH_MS;
    if (first || stale) mint(url);
  }, [status?.running, status?.pair_ready, url, mint, status, pairedDevice]);

  // Re-check staleness on a timer too: the status poll alone would leave a
  // code expired-but-displayed if nothing else changed.
  useEffect(() => {
    if (!url || pairedDevice) return;
    const id = window.setInterval(() => {
      if (Date.now() - mintedAt.current > PAIR_REFRESH_MS) mint(url);
    }, 10_000);
    return () => window.clearInterval(id);
  }, [url, pairedDevice, mint]);

  // Stop handing out a way in once nobody is looking at the code.
  useEffect(() => () => { void invoke("webui_pair_clear").catch(() => {}); }, []);

  return {
    qrTarget: pairUrl || (pairedDevice ? "" : url),
    signsInAutomatically: !!pairUrl,
    pairedDevice,
    showNewCode: () => mint(url),
  };
}

export function RemotePairCard({ port }: { port: string }) {
  const { status, setStatus, refresh } = useWebuiStatus();
  const { qrTarget, signsInAutomatically, pairedDevice, showNewCode } = usePairingQr(status);
  const [qr, setQr] = useState("");
  const [sharing, setSharing] = useState(false);
  const [shareErr, setShareErr] = useState("");
  const [revoking, setRevoking] = useState(false);

  // "That wasn't me": end the session the code just created, right where the
  // pairing is confirmed, so cutting off a stolen scan is one tap and not a
  // hunt through a device list.
  async function revokePaired() {
    if (!pairedDevice) return;
    setRevoking(true);
    try { setStatus(await invoke<WebuiStatus>("webui_device_revoke", { id: pairedDevice.id })); }
    catch { void refresh(); }
    finally { setRevoking(false); showNewCode(); }
  }

  const url = status?.remote_url || "";
  useEffect(() => {
    if (!qrTarget) { setQr(""); return; }
    let alive = true;
    // Dark-on-light so phone cameras lock on instantly regardless of theme.
    QRCode.toDataURL(qrTarget, { margin: 1, width: 320, color: { dark: "#0a0d1f", light: "#ffffff" } })
      .then((d) => { if (alive) setQr(d); })
      .catch(() => { if (alive) setQr(""); });
    return () => { alive = false; };
  }, [qrTarget]);

  async function share() {
    setSharing(true); setShareErr("");
    try { setStatus(await invoke<WebuiStatus>("webui_tunnel_start")); }
    catch (e) { setShareErr(String(e instanceof Error ? e.message : e)); void refresh(); }
    finally { setSharing(false); }
  }
  async function stopShare() {
    setShareErr("");
    try { setStatus(await invoke<WebuiStatus>("webui_tunnel_stop")); } catch { void refresh(); }
  }

  const localUrl = `http://localhost:${port}`;
  const tunnelOn = status?.tunnel_state === "on" && !!status.tunnel_url;
  const tunnelStarting = sharing || status?.tunnel_state === "starting";
  const tunnelError = shareErr || (status?.tunnel_state === "error" ? status.tunnel_error : "");
  const primaryIsTunnel = tunnelOn && url === status?.tunnel_url;

  return (
    <div className="mt-4 overflow-hidden rounded-xl border border-border bg-surface" data-testid="remote-pair">
      {/* Header strip: state first, so a glance answers "is this on?" */}
      <div className="flex flex-wrap items-center justify-between gap-2 border-b border-border-subtle bg-surface-warm/60 px-5 py-3">
        <div className="flex items-center gap-2">
          <span className="relative flex h-2 w-2 shrink-0">
            <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-ok opacity-60" />
            <span className="relative inline-flex h-2 w-2 rounded-full bg-ok" />
          </span>
          <span className="text-sm font-semibold text-text-primary">Phone access is on</span>
        </div>
        <a href={localUrl} target="_blank" rel="noreferrer" className="font-mono text-xs text-text-muted hover:text-accent">{localUrl}</a>
      </div>

      {url ? (
        <div className="flex flex-col gap-6 px-5 py-5 sm:flex-row">
          {/* The QR is the product here, so it gets real size and a quiet frame.
              Once a code is spent there is no QR to show: a new one is a
              deliberate tap, so a screen someone photographed cannot keep
              producing working codes. */}
          <div className="shrink-0">
            {pairedDevice ? (
              <div className="flex flex-col items-center justify-center rounded-xl border border-ok/40 bg-ok/5 p-4 text-center" style={{ height: 190, width: 190 }}>
                <Check className="h-7 w-7 text-ok" />
                <div className="mt-2 text-sm font-semibold text-text-primary" data-testid="remote-paired">{pairedDevice.label}</div>
                <div className="font-mono text-[12px] text-text-muted">{pairedDevice.ip}</div>
                <div className="mt-0.5 text-[12px] text-text-muted">paired {ago(pairedDevice.first_seen_ms)}</div>
              </div>
            ) : qr ? (
              <img src={qr} alt={`QR code for ${url}`} width={190} height={190} className="rounded-xl bg-white p-2 ring-1 ring-border" style={{ height: 190, width: 190 }} />
            ) : (
              <div className="rounded-xl bg-surface-warm" style={{ height: 190, width: 190 }} />
            )}
            <div className="mt-2 text-center">
              {pairedDevice
                ? <button onClick={showNewCode} className="text-xs text-text-muted underline hover:text-accent">Pair another device</button>
                : signsInAutomatically
                  ? <button onClick={showNewCode} className="text-xs text-text-muted underline hover:text-accent">Show a new code</button>
                  : null}
            </div>
          </div>

          {/* Three steps, as steps: a numbered badge and a short line each,
              instead of a paragraph pretending to be instructions. */}
          <div className="min-w-0 flex-1">
            {pairedDevice ? (
              <>
                <h3 className="text-[15px] font-semibold text-text-primary">A device paired</h3>
                <p className="mt-2 text-sm leading-relaxed text-text-secondary">
                  <span className="font-medium text-text-primary">{pairedDevice.label}</span> at{" "}
                  <span className="font-mono text-xs">{pairedDevice.ip}</span> used the code and can now reach this vault.
                  If that is not your phone, cut it off now. The code itself is already spent and cannot be used again.
                </p>
                <button
                  onClick={() => void revokePaired()}
                  disabled={revoking}
                  data-testid="remote-revoke-paired"
                  className="mt-3 inline-flex items-center gap-1.5 rounded-lg border border-warn/50 bg-warn/10 px-3 py-1.5 text-sm font-semibold text-warn disabled:opacity-50"
                >
                  {revoking ? "Disconnecting..." : "That wasn't me, disconnect it"}
                </button>
              </>
            ) : (
              <>
            <h3 className="text-[15px] font-semibold text-text-primary">Scan it with your phone</h3>
            <ol className="mt-3 space-y-2.5">
              {[
                ["Point your camera at the code", "Then open the link it offers."],
                signsInAutomatically
                  ? ["You are signed in.", "No password to type. The code works once, expires in two minutes, and this Mac tells you which device used it."]
                  : ["Sign in", "Use the username and password from Network."],
                ["Keep it on your home screen", "iPhone: Share, then Add to Home Screen. Android: menu, then Install app."],
              ].map(([title, sub], i) => (
                <li key={title} className="flex gap-3">
                  <span className="mt-0.5 flex h-5 w-5 shrink-0 items-center justify-center rounded-full bg-accent-soft text-[12px] font-bold text-accent ring-1 ring-accent-border">{i + 1}</span>
                  <div className="min-w-0">
                    <div className="text-sm font-medium leading-snug text-text-primary">{title}</div>
                    <div className="text-xs leading-snug text-text-muted">{sub}</div>
                  </div>
                </li>
              ))}
            </ol>
              </>
            )}
            <div className="mt-3 flex items-center gap-2">
              <code className="min-w-0 flex-1 truncate rounded-md border border-border bg-background px-2 py-1 text-xs text-text-primary" data-testid="remote-primary-url">{url}</code>
              <CopyButton text={url} />
            </div>
            <div className="mt-1.5 text-[12px] text-text-muted">
              {primaryIsTunnel
                ? "Over the internet, so it works from anywhere."
                : status?.via_tailscale
                  ? "Over Tailscale, private to your devices."
                  : "Same Wi-Fi as this Mac."}
              {" This Mac must stay on."}
            </div>
          </div>
        </div>
      ) : (
        <div className="px-5 py-5 text-sm text-text-muted">
          Turn on <span className="font-medium text-text-primary">Reachable from other devices</span> for a same-Wi-Fi address, or share over the internet below.
        </div>
      )}

      {/* Ways in, as a table with one obvious state per row. */}
      <div className="border-t border-border-subtle px-5 py-4">
        <div className="mb-2 text-[12px] font-semibold text-text-muted">Ways to reach it</div>
        <div className="divide-y divide-border-subtle">
          <ReachRow icon={Wifi} label="Same Wi-Fi" value={status?.lan_url} active={!!status?.lan_url && url === status?.lan_url} testid="remote-lan"
            empty="Not on a network this Mac can share." />
          <ReachRow icon={ShieldCheck} label="Tailscale" value={status?.tailscale_url} active={!!status?.tailscale_url && url === status?.tailscale_url} testid="remote-tailscale"
            empty="Tailscale is not running on this Mac." />
          <div className="flex flex-wrap items-center gap-x-3 gap-y-1.5 py-2" data-testid="remote-tunnel">
            <Globe className="h-4 w-4 shrink-0 text-text-muted" />
            <span className="w-24 shrink-0 text-sm font-medium text-text-primary">Internet</span>
            {tunnelOn ? (
              <>
                <code className="min-w-0 flex-1 truncate text-xs text-text-secondary" data-testid="remote-tunnel-url">{status!.tunnel_url}</code>
                {primaryIsTunnel && <ActiveChip />}
                <CopyButton text={status!.tunnel_url} />
                <button onClick={() => void stopShare()} className="shrink-0 rounded-md border border-border px-2 py-1 text-xs text-text-muted hover:text-warn">Stop sharing</button>
              </>
            ) : status && !status.cloudflared_installed ? (
              <>
                <span className="min-w-0 flex-1 text-xs text-text-muted">Needs cloudflared</span>
                <code className="shrink-0 rounded border border-border bg-background px-1.5 py-0.5 text-[12px]">{BREW_CLOUDFLARED}</code>
                <CopyButton text={BREW_CLOUDFLARED} label="Copy command" />
              </>
            ) : (
              <>
                <span className="min-w-0 flex-1 text-xs text-text-muted">{tunnelStarting ? "Asking Cloudflare for an address..." : "A public https address. No account, no router setup."}</span>
                <button onClick={() => void share()} disabled={tunnelStarting || !status?.running} className="shrink-0 rounded-md bg-accent px-2.5 py-1 text-xs font-semibold text-on-accent disabled:opacity-50">
                  {tunnelStarting ? "Starting..." : "Share over the internet"}
                </button>
              </>
            )}
          </div>
        </div>
        {tunnelError && <div className="mt-2 rounded-md border border-warn/40 bg-warn/10 px-3 py-2 text-xs text-warn" data-testid="remote-tunnel-error">{tunnelError}</div>}
        <div className="mt-3 flex items-start gap-1.5 text-[12px] text-text-muted">
          <Mic className="mt-0.5 h-3.5 w-3.5 shrink-0" />
          <span>Hold-to-talk needs the internet address: browsers only open the microphone on https. Everything else works over Wi-Fi.</span>
        </div>
      </div>

      <DeviceList devices={status?.devices ?? []} onChanged={setStatus} />
    </div>
  );
}

// Who is signed in, and the means to end it. A phone keeps its session until
// it is revoked here, so this is the honest answer to "what can reach my
// vault right now" and the only place to change that answer.
function DeviceList({ devices, onChanged }: { devices: Device[]; onChanged: (s: WebuiStatus) => void }) {
  const [busy, setBusy] = useState("");
  async function revoke(id: string) {
    setBusy(id);
    try { onChanged(await invoke<WebuiStatus>("webui_device_revoke", { id })); } catch { /* the poll will correct it */ }
    finally { setBusy(""); }
  }
  async function revokeAll() {
    setBusy("all");
    try { onChanged(await invoke<WebuiStatus>("webui_device_revoke_all")); } catch { /* ignore */ }
    finally { setBusy(""); }
  }
  return (
    <div className="border-t border-border-subtle px-5 py-4" data-testid="remote-devices">
      <div className="mb-2 flex items-center justify-between">
        <div className="text-[12px] font-semibold text-text-muted">
          Connected phones{devices.length > 0 ? ` (${devices.filter(isLive).length} of ${devices.length} live)` : ""}
        </div>
        {devices.length > 0 && (
          <button onClick={() => void revokeAll()} disabled={busy !== ""} className="text-xs text-text-muted underline hover:text-warn disabled:opacity-50">
            Disconnect all
          </button>
        )}
      </div>
      {devices.length === 0 ? (
        <div className="text-xs text-text-muted">Nothing is connected. Scan the code above to add a phone.</div>
      ) : (
        <div className="divide-y divide-border-subtle">
          {devices.map((d) => (
            <div key={d.id} className="flex flex-wrap items-center gap-x-3 gap-y-1 py-2.5" data-device={d.id}>
              {/* A live green pulse, because "is my phone actually connected"
                  should be answerable from across the room. It goes grey when
                  we have not heard from the device in a couple of minutes,
                  which on a phone usually means the screen is off. */}
              <span className="relative flex h-2.5 w-2.5 shrink-0" title={isLive(d) ? "Connected now" : "Idle"} data-live={isLive(d) ? "1" : "0"}>
                {isLive(d) && <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-ok opacity-75" />}
                <span className={`relative inline-flex h-2.5 w-2.5 rounded-full ${isLive(d) ? "bg-ok" : "bg-text-muted/40"}`} />
              </span>
              <Smartphone className="h-4 w-4 shrink-0 text-text-muted" />
              <span className="text-sm font-medium text-text-primary">{d.label}</span>
              <span className="font-mono text-[12px] text-text-muted">{d.ip}</span>
              <span className="min-w-0 flex-1 text-[12px]">
                <span className={isLive(d) ? "font-semibold text-ok" : "text-text-muted"}>{isLive(d) ? "Connected" : `Idle, last seen ${ago(d.last_seen_ms)}`}</span>
                <span className="text-text-muted">{d.via === "qr" ? " · paired by code" : " · signed in"}</span>
              </span>
              <button onClick={() => void revoke(d.id)} disabled={busy !== ""} className="shrink-0 rounded-md border border-border px-2 py-1 text-xs text-text-muted hover:border-warn/50 hover:text-warn disabled:opacity-50">
                Disconnect
              </button>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

function ActiveChip() {
  return <span className="shrink-0 rounded-full bg-accent-soft px-2 py-0.5 text-[12px] font-semibold text-accent ring-1 ring-accent-border">In the QR</span>;
}

// One way in: icon, name, address, and whether it is the one the QR points at.
function ReachRow({ icon: Icon, label, value, active, testid, empty }: {
  icon: typeof Wifi; label: string; value?: string; active: boolean; testid: string; empty: string;
}) {
  return (
    <div className="flex flex-wrap items-center gap-x-3 gap-y-1.5 py-2" data-testid={testid}>
      <Icon className="h-4 w-4 shrink-0 text-text-muted" />
      <span className="w-24 shrink-0 text-sm font-medium text-text-primary">{label}</span>
      {value ? (
        <>
          <code className="min-w-0 flex-1 truncate font-mono text-xs text-text-secondary">{value}</code>
          {active && <ActiveChip />}
          <CopyButton text={value} />
        </>
      ) : (
        <span className="min-w-0 flex-1 text-xs text-text-muted">{empty}</span>
      )}
    </div>
  );
}

// ── The Phone screen ──────────────────────────────────────────────────

// Turning phone access on is one button, not a tour of the network settings:
// mint a password if there isn't one, switch reachability on, start the bridge.
async function enablePhoneAccess(): Promise<void> {
  let pass = "";
  try { pass = await invoke<string>("webui_secret_get"); } catch { /* keychain unavailable */ }
  if (!pass) {
    pass = Math.random().toString(36).slice(2, 10) + Math.random().toString(36).slice(2, 6);
    try { await invoke("webui_secret_set", { pass }); } catch { /* ignore */ }
  }
  const port = Number(getPref(PREF.webuiPort, "8787")) || 8787;
  const user = getPref(PREF.webuiUser, "admin");
  setPref(PREF.webuiRemote, "1");
  await invoke("webui_start", { port, user, pass, remote: true });
}

export function PhoneSection() {
  const { status, refresh } = useWebuiStatus();
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState("");

  async function turnOn() {
    setBusy(true); setErr("");
    try { await enablePhoneAccess(); await refresh(); }
    catch (e) { setErr(String(e instanceof Error ? e.message : e)); }
    finally { setBusy(false); }
  }
  async function turnOff() {
    setBusy(true); setErr("");
    // Stopping the bridge revokes every device with it: no phone keeps a way
    // in after you have said no.
    try { await invoke("webui_stop"); await refresh(); }
    catch (e) { setErr(String(e instanceof Error ? e.message : e)); }
    finally { setBusy(false); }
  }

  const running = !!status?.running;
  const bunker = !!status?.bunker_blocking;
  const port = String(status?.port || getPref(PREF.webuiPort, "8787"));

  return (
    <>
      <SettingsHeader
        title="Phone"
        subtitle="Your phone, as a window onto this Mac."
        icon={Smartphone}
      />
      <DesktopOnly feature="Phone setup">
        {bunker ? (
          <div className="rounded-lg border border-accent-border bg-accent-soft px-6 py-6">
            <div className="flex items-start gap-3">
              <ShieldCheck className="mt-0.5 h-5 w-5 shrink-0 text-accent" />
              <div className="min-w-0">
                <div className="text-base font-semibold text-text-primary">Bunker Mode is on, so phones cannot connect</div>
                <p className="mt-1 text-sm text-text-secondary">
                  Bunker Mode promises that nothing leaves this Mac, and a phone on your network is another way off it. The bridge stays on this machine only, and sharing over the internet is refused, until you turn Bunker Mode off.
                </p>
                <button
                  onClick={() => window.dispatchEvent(new CustomEvent("prevail:open-settings", { detail: "privacy" }))}
                  className="mt-3 text-[13px] font-medium text-accent hover:underline"
                >
                  Open Privacy
                </button>
              </div>
            </div>
          </div>
        ) : !running ? (
          <div className="max-w-xl">
            <Smartphone className="h-6 w-6 text-accent" />
            <div className="mt-2 text-[15px] font-semibold text-text-primary">Put Glyph Studio on your phone</div>
            <p className="mt-1 text-[14px] text-text-secondary">
              Turn this on and a QR code appears. Scan it and your phone is signed in, with no password to type. It installs to the home screen like a normal app.
            </p>
            <button onClick={() => void turnOn()} disabled={busy} className="mt-4 rounded-md bg-accent px-3.5 py-1.5 text-[13px] font-medium text-on-accent disabled:opacity-50">
              {busy ? "Starting..." : "Turn on phone access"}
            </button>
            {err && <div className="mt-3 text-[13px] text-warn">{err}</div>}
            <div className="mt-3 text-[12px] text-text-muted">This Mac must stay on and awake for the phone to reach it.</div>
          </div>
        ) : (
          <>
            <RemotePairCard port={port} />
            <div className="mt-3 flex flex-wrap items-center justify-between gap-2">
              <div className="text-xs text-text-muted">
                Port, username and password live in{" "}
                <button onClick={() => window.dispatchEvent(new CustomEvent("prevail:open-settings", { detail: "remote" }))} className="underline hover:text-accent">
                  Network
                </button>.
              </div>
              <button onClick={() => void turnOff()} disabled={busy} className="rounded-md border border-border px-3 py-1.5 text-xs font-medium text-text-secondary hover:border-warn/50 hover:text-warn disabled:opacity-50">
                {busy ? "Turning off..." : "Turn off phone access"}
              </button>
            </div>
            {err && <div className="mt-3 rounded-md border border-warn/40 bg-warn/10 px-3 py-2 text-xs text-warn">{err}</div>}
          </>
        )}
      </DesktopOnly>
    </>
  );
}
