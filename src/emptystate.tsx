// D4 — one shared empty/loading vocabulary. Before this, empty states were
// ad-hoc one-liners ("No notes yet.", "Nothing scheduled…") with inconsistent
// tone and no call to action, and loading was bare spinners. These two
// primitives give panels a consistent, designed baseline.
import type { ReactNode } from "react";
import type { LucideIcon } from "lucide-react";
import { Monitor } from "lucide-react";
import { isBrowser } from "./bridge";

export function EmptyState({
  icon: Icon,
  title,
  body,
  action,
}: {
  icon?: LucideIcon;
  title: string;
  body?: string;
  action?: { label: string; onClick: () => void };
}) {
  return (
    <div className="flex flex-col items-center justify-center px-6 py-12 text-center">
      {Icon && (
        <div className="mb-3 flex h-11 w-11 items-center justify-center rounded-xl border border-border-subtle bg-surface-warm text-text-muted">
          <Icon className="h-5 w-5" />
        </div>
      )}
      <div className="text-sm font-semibold text-text-primary">{title}</div>
      {body && <p className="mt-1 max-w-xs text-balance text-xs text-text-muted">{body}</p>}
      {action && (
        <button
          onClick={action.onClick}
          className="mt-3 rounded-md bg-accent px-3 py-1.5 text-xs font-semibold text-on-accent hover:opacity-90"
        >
          {action.label}
        </button>
      )}
    </div>
  );
}

// E3: gate desktop-only features when the app is served to a browser (WebUI).
// The same React bundle renders remotely, but many controls (bridge setup, vault
// encryption, the WebUI server toggle itself) hit the deny-by-default allowlist
// and just error. Rather than showing a control that silently fails, explain it
// is desktop-only. `inline` renders a compact note for a small row.
export function DesktopOnly({ children, feature, inline }: { children: ReactNode; feature: string; inline?: boolean }) {
  if (!isBrowser()) return <>{children}</>;
  if (inline) {
    return (
      <div className="flex items-center gap-2 rounded-md border border-border-subtle bg-surface-warm px-3 py-2 text-xs text-text-muted">
        <Monitor className="h-3.5 w-3.5 shrink-0" />
        {feature} is available in the Glyph Studio desktop app.
      </div>
    );
  }
  return <EmptyState icon={Monitor} title="Desktop only" body={`${feature} is configured in the Glyph Studio desktop app, not the web view.`} />;
}
