# Security Policy

## Reporting a vulnerability
Please **do not** open a public issue for security problems. Email
**security@example.com** (or DM the maintainer) with details and steps to reproduce.
We aim to acknowledge within 72 hours.

## Threat model & design notes
Glyph Studio is local-first; your vault, chats, and the intent ledger never leave your
machine unless you enable an integration. Key considerations:

- **Vault data** lives on disk in your chosen folder. It is **not encrypted at
  rest** — treat the vault like any sensitive documents folder.
- **Secrets** (provider API keys, the Telegram bot token, notarization creds) are
  stored in the macOS **Keychain** (`prevail.providers`), never in the vault or
  localStorage. Key values are never returned to the frontend
  (`provider_key_exists` is a presence check). The engine redacts API-key/PII
  patterns before text is persisted or sent (`privacy.ts`); enable
  **Settings → Safety → Redact secrets** for the desktop capture path too.
- **Subprocesses** (the engine, the AI CLIs) are spawned with argument arrays
  (no shell) and a **scrubbed environment**: the child inherits a denylisted copy
  of the process env with provider keys and `*_TOKEN`/`*_SECRET`/`*_PASSWORD`
  patterns stripped (`scrubbed_env_pairs`, mirroring the CLI's `scrubbedEnv`), so
  a prompt-injected model that runs `env` cannot exfiltrate secrets.
- **Bunker Mode** (default ON) is the app-wide local-only guarantee. Every model
  spawn — native chat, engine chat, the Telegram bridge, distillation, and
  proactive surface generation — passes through a guard that refuses cloud
  providers while Bunker is on; `bunker_set` is **not** WebUI-reachable, so a
  remote browser can never disable it.
- **WebUI (Remote)** is **off by default**. When enabled it binds `127.0.0.1`
  only (reach it remotely via Tailscale/SSH tunnel, never `0.0.0.0`), requires a
  username + password, and issues a random per-session token. It **allowlists**
  the commands a browser may invoke: no secret access, no arbitrary file I/O
  (`read_file`/`write_text_file` are desktop-only), and no Bunker toggle. It
  **does** permit vault-content operations needed for full browser use — saving,
  renaming and deleting threads/sessions, task edits, and sample-vault import —
  which are path-confined to the vault (domain/thread IDs are validated; unsafe
  names are rejected, not redirected). Treat an enabled WebUI as a control plane
  for your vault and only enable it on trusted networks.
- **CSP** is enabled with `default-src 'self'`, `script-src 'self'`,
  `object-src 'none'`, and `base-uri 'self'`.

## Secrets and credentials

Glyph Studio's rule: credentials live in the OS keychain where possible, on as few
disks as possible, and are never committed or synced.

| Credential | Storage | At rest | Synced? |
|---|---|---|---|
| Provider API keys (OpenRouter, direct) | macOS Keychain `prevail.providers/*` | OS keychain | No |
| Composio / Nango gateway token | Keychain `prevail.ingestion/composio` | OS keychain | No |
| WebUI bridge password | Keychain `prevail.webui/password` (min 10 chars) | OS keychain | No |
| Google OAuth tokens | external `gws` CLI keyring (`~/.config/gws*`) | gws keyring (Keychain on macOS) | No |
| Imported Chrome cookies (browser automation) | Playwright state under the app data dir | filesystem perms only | No (excluded from vault) |
| App API-key lane tokens | in the vault | vault encryption **when the vault is encrypted** (production default) | Yes if the vault syncs |
| Updater signing key | `~/.prevail/updater.key`, local only | filesystem perms | No |

Known trade-offs: imported browser cookies can't go in the keychain (they sit
under the app data dir, never the vault, and Vault Lock doesn't grant the model
access to them); a raw API key pasted into an app lane lands in the vault, so
keep vault encryption on and prefer OAuth/gateway lanes. The telemetry keys are
write/ingest-only client keys (not secrets) and are injected from CI, so forks
carry none. The updater **public** key in `tauri.conf.json` is required to
verify updates; the private key is never committed.

**Adding a new secret:** route it to the OS keychain, never the vault or a
plaintext file, and exclude it from vault sync.

## Supported versions
The latest released version receives security fixes.
