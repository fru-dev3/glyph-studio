import React from "react";
import ReactDOM from "react-dom/client";
import { invoke } from "./bridge";
import { fatalLogText } from "./fatallog";
import App from "./App";
import { Toaster } from "./toast";
import { APP_VERSION } from "./constants";
import { initCrashReporting, osFamily, reportError, track } from "./telemetry";
import "./index.css";
import { installCopyOnSelect } from "./copyonselect";

// Anonymous, consent-gated, allowlisted. Logs locally always (transparency);
// only transmitted when the user opts in AND build-time keys exist.
track("app_opened", { version: APP_VERSION, os: osFamily() });

// X8: register the notification service worker in the WebUI (browser). Lets
// notifications persist / show while the tab is backgrounded, and is the hook
// for server-sent Web Push. Desktop (Tauri) uses native notifications instead.
if (typeof window !== "undefined" && !("__TAURI_INTERNALS__" in window) && "serviceWorker" in navigator) {
  window.addEventListener("load", () => { navigator.serviceWorker.register("/sw.js").catch(() => { /* SW optional */ }); });
}

// Attach Sentry's global crash handlers if (and only if) the user has opted into
// crash reports and a DSN was built in. Uncaught errors / unhandled rejections
// are then captured automatically; React render crashes are reported explicitly
// from the ErrorBoundary below (React swallows those from window.onerror).
initCrashReporting();

// Surface fatal startup/render errors instead of a blank white window.
function showFatal(msg: string, err?: unknown) {
  void invoke("log_fatal", { msg: fatalLogText("fatal", err) }).catch(() => {});
  const el = document.getElementById("root");
  if (el) {
    el.innerHTML =
      '<div style="height:100vh;overflow:auto;background:#faf8f1;padding:24px;' +
      'font:13px ui-monospace,SFMono-Regular,Menlo,monospace">' +
      '<div style="color:#1a1a1a;font-weight:700;margin-bottom:6px">Glyph Studio hit an error and stopped this view.</div>' +
      '<div style="color:#555;margin-bottom:14px">Your vault data is safe on disk. Reload to continue.</div>' +
      '<button onclick="location.reload()" style="padding:8px 18px;border-radius:8px;border:1px solid var(--color-accent,#008000);' +
      'background:var(--color-accent,#008000);color:#fff;font:600 13px ui-monospace,monospace;cursor:pointer;margin-bottom:18px">Reload Glyph Studio</button>' +
      '<pre style="white-space:pre-wrap;color:#b3261e;margin:0">' +
      msg.replace(/</g, "&lt;") +
      "</pre></div>";
  }
}
window.addEventListener("error", (e) =>
  showFatal((e.error && (e.error.stack || e.error.message)) || e.message || "unknown error", e.error),
);
// A stray promise rejection should NOT nuke the whole app - log it and keep
// running. Only render/startup errors (the "error" listener + ErrorBoundary
// above) are fatal.
window.addEventListener("unhandledrejection", (e) => {
  const msg = (e.reason && (e.reason.stack || e.reason.message)) || String(e.reason);
  console.error("[prevail] unhandled rejection (non-fatal):", msg);
  void invoke("log_fatal", { msg: fatalLogText("unhandledrejection (non-fatal)", e.reason) }).catch(() => {});
});

class ErrorBoundary extends React.Component<{ children: React.ReactNode }, { err: unknown }> {
  state = { err: null as unknown };
  static getDerivedStateFromError(err: unknown) {
    return { err };
  }
  componentDidCatch(err: unknown) {
    reportError(err); // no-op unless crash consent is on + DSN built in
    showFatal((err as Error)?.stack || (err as Error)?.message || String(err), err);
  }
  render() {
    return this.state.err ? null : this.props.children;
  }
}

installCopyOnSelect();

try {
  ReactDOM.createRoot(document.getElementById("root") as HTMLElement).render(
    <ErrorBoundary>
      <App />
      {/* F6: single app-wide toast host. Fixed-position, so it overlays every
          top-level view (lock screen, chat, work, editor) from the root. */}
      <Toaster />
    </ErrorBoundary>,
  );
} catch (err) {
  showFatal((err as Error)?.stack || (err as Error)?.message || String(err), err);
}
