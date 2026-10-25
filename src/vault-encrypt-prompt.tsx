// First-run "encrypt your vault" prompt (C4: encryption-at-rest default-ON).
//
// Reuses the SAME, already-proven engine flow as the settings encryption card
// (backup → engine_vault_encrypt → show one-time recovery code → unlock →
// restart). Shown once for a fresh, unencrypted vault; defaults to encrypting
// (the decided default-ON posture) with an explicit "Not now" opt-out.
//
// Safety: the recovery code is the only lockout escape, so the dialog cannot be
// dismissed after encryption until the user acknowledges they saved it.

import { useState } from "react";
import { Loader2, Shield } from "lucide-react";
import { invoke } from "./bridge";
import { backupVaultNow } from "./backup";

const OFFERED_KEY = "prevail.onboarding.encryptOffered";

export function vaultEncryptOffered(): boolean {
  try { return localStorage.getItem(OFFERED_KEY) === "1"; } catch { return false; }
}
function markOffered() {
  try { localStorage.setItem(OFFERED_KEY, "1"); } catch { /* ignore */ }
}

export function VaultEncryptPrompt({ vaultPath, onClose }: { vaultPath: string; onClose: () => void }) {
  const [pass, setPass] = useState("");
  const [confirm, setConfirm] = useState("");
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState<string | null>(null);
  const [recovery, setRecovery] = useState<string | null>(null);

  function skip() { markOffered(); onClose(); }

  async function encrypt() {
    if (pass.length < 8) { setNote("Passcode must be at least 8 characters."); return; }
    if (pass !== confirm) { setNote("Passcodes don't match."); return; }
    setBusy(true); setNote(null);
    try {
      await backupVaultNow(vaultPath); // automatic pre-encryption snapshot
      const r = await invoke<{ ok: boolean; recoveryCode?: string | null; error?: string }>(
        "engine_vault_encrypt", { vault: vaultPath, passcode: pass },
      );
      if (r.ok) {
        markOffered();
        await invoke("engine_vault_unlock", { vault: vaultPath, passcode: pass }).catch(() => {});
        setPass(""); setConfirm("");
        if (r.recoveryCode) {
          setRecovery(r.recoveryCode); // gate dismissal until acknowledged
        } else {
          onClose();
        }
      } else {
        setNote(r.error ?? "Encryption failed.");
      }
    } catch (e) {
      setNote(`Failed: ${String(e)}`);
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="fixed inset-0 z-[200] flex items-center justify-center bg-black/60 backdrop-blur-sm">
      <div className="mx-4 w-full max-w-md rounded-xl border border-border bg-surface p-6 shadow-2xl">
        <div className="flex items-center gap-2 text-[11px] font-bold text-text-primary">
          <Shield className="h-4 w-4" /> Encrypt your vault
        </div>

        {!recovery ? (
          <>
            <p className="mt-2 text-sm text-text-muted">
              Encrypt your vault at rest with AES-256-GCM so it can't be read off disk without your
              passcode. Recommended. You'll get a one-time recovery code, save it.
            </p>
            <div className="mt-4 flex flex-col gap-2">
              <input
                type="password" value={pass} onChange={(e) => setPass(e.target.value)}
                placeholder="New passcode (min 8 chars)" autoFocus
                className="rounded-md border border-border bg-background px-3 py-2 text-sm focus:border-accent-border focus:outline-none"
              />
              <input
                type="password" value={confirm} onChange={(e) => setConfirm(e.target.value)}
                placeholder="Confirm passcode"
                className="rounded-md border border-border bg-background px-3 py-2 text-sm focus:border-accent-border focus:outline-none"
              />
            </div>
            {note && <div className="mt-2 text-xs text-warn">{note}</div>}
            <div className="mt-4 flex items-center justify-end gap-2">
              <button onClick={skip} disabled={busy}
                className="rounded-md border border-border bg-background px-3 py-1.5 text-sm hover:bg-surface-warm disabled:opacity-50">
                Not now
              </button>
              <button onClick={encrypt} disabled={busy || pass.length < 8 || pass !== confirm}
                className="inline-flex items-center gap-2 rounded-md border border-accent-border bg-accent px-3 py-1.5 text-sm text-background hover:opacity-90 disabled:opacity-50">
                {busy ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <Shield className="h-3.5 w-3.5" />} Encrypt vault
              </button>
            </div>
          </>
        ) : (
          <div className="mt-3 rounded-lg border border-accent-border bg-accent-soft p-3">
            <div className="text-[11px] font-bold text-accent">Recovery code: save this now</div>
            <div className="mt-1 select-all font-mono text-base text-text-primary">{recovery}</div>
            <div className="mt-1 text-[11px] text-text-muted">
              If you forget your passcode, this is the ONLY other way to unlock your vault. It won't be shown again.
            </div>
            <button onClick={() => window.location.reload()}
              className="mt-3 rounded-md bg-accent px-3 py-1.5 text-sm font-medium text-background hover:bg-accent-hover">
              I saved it · Restart Glyph Studio
            </button>
          </div>
        )}
      </div>
    </div>
  );
}
