// Settings sections extracted from App.tsx: the Vault encryption card.
import { useEffect, useState } from "react";
import { Loader2, Shield } from "lucide-react";
import { invoke } from "./bridge";
import { DesktopOnly } from "./emptystate";
import { backupVaultNow } from "./backup";

// Vault encryption (F4 Phase 1) - encrypt the vault at rest, or decrypt it back.
// Self-verifying in the engine (auto-rollback if anything is unreadable), and
// shows the one-time recovery code on encryption.

export function VaultEncryptionCard({ vaultPath }: { vaultPath: string }) {
  const [status, setStatus] = useState<{ encrypted: boolean; unlocked: boolean } | null>(null);
  const [pass, setPass] = useState("");
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState<string | null>(null);
  const [recovery, setRecovery] = useState<string | null>(null);
  const refresh = async () => {
    try { setStatus(await invoke("engine_vault_status", { vault: vaultPath })); } catch { setStatus(null); }
  };
  useEffect(() => { void refresh(); /* eslint-disable-next-line */ }, [vaultPath]);
  async function encrypt() {
    if (pass.length < 8) { setNote("Passcode must be at least 8 characters."); return; }
    if (!window.confirm("Encrypt this vault? Make sure you have a backup first. You'll get a one-time recovery code: save it.")) return;
    setBusy(true); setNote(null); setRecovery(null);
    try {
      await backupVaultNow(vaultPath); // automatic pre-encryption snapshot
      const r = await invoke<{ ok: boolean; recoveryCode?: string | null; error?: string }>("engine_vault_encrypt", { vault: vaultPath, passcode: pass });
      if (r.ok) {
        if (r.recoveryCode) setRecovery(r.recoveryCode);
        await invoke("engine_vault_unlock", { vault: vaultPath, passcode: pass }).catch(() => {});
        setNote("Vault encrypted. Save your recovery code somewhere safe.");
        setPass("");
        await refresh();
      } else {
        setNote(r.error ?? "Encryption failed.");
      }
    } catch (e) { setNote(`Failed: ${String(e)}`); } finally { setBusy(false); }
  }
  async function decrypt() {
    setBusy(true); setNote(null);
    try {
      await backupVaultNow(vaultPath); // automatic pre-decryption snapshot
      const r = await invoke<{ ok: boolean; error?: string }>("engine_vault_decrypt", { vault: vaultPath, passcode: pass });
      if (r.ok) { setNote("Vault decrypted back to plaintext. Reloading…"); setPass(""); await refresh(); setTimeout(() => window.location.reload(), 800); }
      else setNote(r.error ?? "Wrong passcode.");
    } catch (e) { setNote(`Failed: ${String(e)}`); } finally { setBusy(false); }
  }
  if (!status) return null;
  return (
    <DesktopOnly feature="Vault encryption">
    <div className="mb-4 border-t border-border-subtle pt-4">
      <div className="flex items-center gap-2 text-[14px] font-semibold text-text-primary">
        <Shield className="h-3.5 w-3.5" /> Vault encryption {status.encrypted ? "· on" : "· off"}
      </div>
      <p className="mt-2 text-xs text-text-muted">
        {status.encrypted
          ? "Your vault files are encrypted at rest with AES-256-GCM. They're unreadable on disk without your passcode."
          : "Encrypt your vault files at rest so they can't be read off disk. Editing in external apps (Obsidian, Finder) stops working while encrypted."}
      </p>
      <div className="mt-3 flex items-center gap-2">
        <input
          type="password"
          value={pass}
          onChange={(e) => setPass(e.target.value)}
          placeholder={status.encrypted ? "Passcode" : "New passcode (min 8 chars)"}
          className="w-56 rounded-md border border-border bg-background px-3 py-1.5 text-sm focus:border-accent-border focus:outline-none"
        />
        {status.encrypted ? (
          <button onClick={decrypt} disabled={busy || !pass} className="inline-flex items-center gap-2 rounded-md border border-border bg-background px-3 py-1.5 text-sm hover:bg-surface-warm disabled:opacity-50">
            {busy ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : null} Decrypt vault
          </button>
        ) : (
          <button onClick={encrypt} disabled={busy || pass.length < 8} className="inline-flex items-center gap-2 rounded-md border border-accent-border bg-accent px-3 py-1.5 text-sm text-background hover:opacity-90 disabled:opacity-50">
            {busy ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <Shield className="h-3.5 w-3.5" />} Encrypt vault
          </button>
        )}
      </div>
      {recovery && (
        <div className="mt-3 rounded-lg border border-accent-border bg-accent-soft p-3">
          <div className="text-[12px] font-bold text-accent">Recovery code: save this now</div>
          <div className="mt-1 select-all font-mono text-sm text-text-primary">{recovery}</div>
          <div className="mt-1 text-[12px] text-text-muted">If you forget your passcode, this is the only other way to unlock your vault. It won't be shown again.</div>
          <button
            onClick={() => window.location.reload()}
            className="mt-2 rounded-md bg-accent px-3 py-1.5 text-sm font-medium text-background hover:bg-accent-hover"
          >
            I saved it · Restart Glyph Studio
          </button>
          <span className="ml-2 text-[12px] text-text-muted">Restarting re-opens the vault through the unlock screen so every view reads it correctly.</span>
        </div>
      )}
      {note && <div className="mt-2 text-xs text-text-secondary">{note}</div>}
    </div>
    </DesktopOnly>
  );
}
