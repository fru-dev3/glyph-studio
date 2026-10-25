// Chat — spawn a model CLI with a prompt and stream its output back to the
// frontend as Tauri events; the pre-flight model verification path; and the
// shared CLI/env spawn helpers (build_cli_env, scrubbed_env_pairs,
// ideal_state_preamble, resolve_bin_abs, is_secret_env_key) the rest of the
// crate uses — they live here because chat is the canonical spawn site, and
// lib.rs re-exports them at the crate root so other modules keep calling
// crate::<name>. Extracted from lib.rs.

use std::path::Path;

use serde::Deserialize;
use tauri::Emitter;

use crate::children::{register_child, unregister_child};
use crate::{bunker, read_to_string_retry};

#[derive(Deserialize)]
pub struct ChatArgs {
    pub cli: String,        // "claude" | "codex" | "antigravity" | "ollama"
    pub prompt: String,
    pub session_id: String, // unique id so the UI knows which session each chunk belongs to
    #[serde(default)]
    pub model: Option<String>,
    // Hard cap on how long the child is allowed to run. After this
    // expires the child is killed and chat:done emits with a synthetic
    // code so the UI can show a "timed out" reply rather than a hang.
    #[serde(default)]
    pub timeout_sec: Option<u64>,
    // Per-turn web access (the chat "Web access" Modes toggle). Some(false) =>
    // hard-block web for this turn. None => unconstrained (back-compat).
    #[serde(default)]
    pub web: Option<bool>,
}

// Vault Lock guardrail for the chat agent. Mirrors the CLI bridge's preamble so
// the desktop chat path (which spawns the agent CLI directly) enforces the same
// hard filesystem scope. The agent must refuse anything outside the vault.
fn vault_lock_preamble() -> String {
    "# FILESYSTEM SCOPE - VAULT LOCK IS ON. HARD CONSTRAINT.\n\
     You may only read, write, list, search, or modify files inside the vault (this working directory and its data/ and build/ folders). \
     Do NOT access, read, list, search, or execute ANYTHING outside the vault: no other directories, no home folder, no system paths, no temp dirs, \
     and no tools or commands that reach beyond the vault (e.g. scanning the Mac for files). \
     If a request would require touching files outside the vault, REFUSE and state that Vault Lock is enabled (turn it off in Settings to allow full-machine access).\n\n---\n\n".to_string()
}

/// The exact install one-liners the runtime cards may run, mirrored from the
/// frontend RUNTIME_META `cmd` fields. `open_in_terminal` accepts ONLY a string
/// from this set — the Rust side no longer trusts the renderer's claim that a
/// command "came from the trusted table". Adding a runtime to the frontend means
/// adding its command here too; an unmirrored command fails closed (refused),
/// never executed. This is what stops an XSS from running arbitrary shell in
/// Terminal via this command.
const ALLOWED_INSTALL_COMMANDS: &[&str] = &[
    "npm install -g @anthropic-ai/claude-code",
    "npm install -g @openai/codex",
    "curl -fsSL https://antigravity.google/cli/install.sh | bash",
    "brew install ollama",
    "brew install --cask lm-studio",
    "pip install mlx-lm",
    "brew install opencode",
    "curl -fsSL https://openclaw.ai/install.sh | bash",
    "npm install -g @earendil-works/pi-coding-agent",
];

/// Open Terminal.app and run a one-line install command, so a runtime setup is
/// one click but still fully transparent: the user sees the exact command run,
/// can authenticate (sudo/brew), and confirm — never a silent background install.
/// The command must be one of ALLOWED_INSTALL_COMMANDS; anything else is refused
/// server-side. macOS-only (the app ships on macOS).
#[tauri::command(async)]
pub(crate) fn open_in_terminal(command: String) -> Result<(), String> {
    let cmd = command.trim();
    if cmd.is_empty() {
        return Err("empty command".into());
    }
    if !ALLOWED_INSTALL_COMMANDS.contains(&cmd) {
        return Err("refused: command is not an approved runtime install command".into());
    }
    // Escape for an AppleScript string literal.
    let escaped = cmd.replace('\\', "\\\\").replace('"', "\\\"");
    let script = format!(
        "tell application \"Terminal\"\nactivate\ndo script \"{escaped}\"\nend tell"
    );
    std::process::Command::new("osascript")
        .arg("-e")
        .arg(script)
        .spawn()
        .map_err(|e| format!("failed to open Terminal: {e}"))?;
    Ok(())
}

fn cli_args(cli: &str, prompt: &str, model: Option<&str>, web_denied: bool) -> (String, Vec<String>) {
    // Match the prevail CLI's dispatch table. -p / --prompt for one-shot
    // non-interactive mode. When `model` is supplied, inject the right
    // flag for each vendor (ollama uses a positional arg, the rest use
    // --model <id>).
    // Vault Lock: when ON, the agent is confined to the vault. We (1) prepend a
    // hard scope rule, (2) drop the Bash escape hatch + confine file tools to the
    // vault via --add-dir, and (3) skip external MCP servers - so a prompt
    // like "scan my Mac for big files" cannot reach outside the vault.
    let locked = crate::vault_lock::vault_lock_enabled();
    let vault = crate::engine::vault_root();
    // "auto" is Prevail's router, not a model any CLI knows, and "" means the
    // CLI's own default. Either way, no --model flag.
    let model = model.map(str::trim).filter(|m| !m.is_empty() && !m.eq_ignore_ascii_case("auto"));
    let prompt_owned = if locked { format!("{}{}", vault_lock_preamble(), prompt) } else { prompt.to_string() };
    let prompt = prompt_owned.as_str();
    match cli {
        "claude" => {
            let mut v = vec!["--dangerously-skip-permissions".to_string()];
            // Tools removed from the model's context. --disallowedTools wins over
            // --dangerously-skip-permissions, so these stay genuinely unavailable.
            let mut disallowed: Vec<String> = Vec::new();
            if locked {
                if let Some(ref vp) = vault { v.push("--add-dir".to_string()); v.push(vp.clone()); }
                // Remove the shell escape hatch so the agent can't du/find the
                // whole filesystem; vault file ops still work via Read/Glob/Grep.
                disallowed.push("Bash".to_string());
            }
            // Web lockdown: WebSearch/WebFetch are the only built-ins that make
            // outbound requests; removing them hard-blocks web for this turn.
            if web_denied { disallowed.push("WebSearch".to_string()); disallowed.push("WebFetch".to_string()); }
            if !disallowed.is_empty() {
                v.push("--disallowedTools".to_string());
                v.extend(disallowed);
            }
            if let Some(m) = model {
                v.push("--model".to_string());
                v.push(m.to_string());
            }
            v.push("-p".to_string());
            // `--` ends option parsing so a prompt that starts with "--"
            // (e.g. the "--- Conversation so far ---" preamble) is treated as
            // the positional prompt, not an unknown flag.
            v.push("--".to_string());
            v.push(prompt.to_string());
            ("claude".to_string(), v)
        }
        "codex" => {
            let mut v = vec!["exec".to_string(), "--skip-git-repo-check".to_string()];
            if let Some(m) = model {
                // Model id may carry a reasoning-effort suffix as
                // "<model>@<effort>" (e.g. "gpt-5.5@high"). Split it off
                // and pass the effort via `-c model_reasoning_effort`,
                // since codex has no per-model "high" id.
                let (base, effort) = match m.split_once('@') {
                    Some((b, e)) => (b, Some(e)),
                    None => (m, None),
                };
                v.push("--model".to_string());
                v.push(base.to_string());
                if let Some(e) = effort {
                    v.push("-c".to_string());
                    v.push(format!("model_reasoning_effort={e}"));
                }
            }
            v.push("--".to_string()); // end options — prompt may start with "--"
            v.push(prompt.to_string());
            ("codex".to_string(), v)
        }
        "antigravity" => {
            let mut v = vec!["--dangerously-skip-permissions".to_string()];
            if locked {
                if let Some(ref vp) = vault { v.push("--add-dir".to_string()); v.push(vp.clone()); }
                // agy has NO --disallowedTools flag (that's Claude-only). Passing
                // it made agy abort with "flags provided but not defined" and dump
                // its usage. agy's terminal/shell restriction is --sandbox, so use
                // that to drop the Bash escape hatch under Vault Lock.
                v.push("--sandbox".to_string());
            }
            if let Some(m) = model {
                v.push("--model".to_string());
                v.push(m.to_string());
            }
            // agy's -p/--print takes the prompt as a VALUE (unlike claude/codex
            // where it's a positional). Use `--print=<value>` so a prompt that
            // starts with "--" (the "--- Conversation so far ---" preamble) is
            // passed safely without `--` being parsed as the value.
            v.push(format!("--print={prompt}"));
            ("agy".to_string(), v)
        }
        "ollama" => {
            // ollama uses positional model arg. Fall back to llama3.2.
            let m = model.unwrap_or("llama3.2");
            (
                "ollama".to_string(),
                // `--` ends options — prompt may start with "--".
                vec!["run".to_string(), m.to_string(), "--".to_string(), prompt.to_string()],
            )
        }
        "gemini" => {
            // Legacy Gemini CLI: --skip-trust, -m <model>, -p <prompt> (value).
            let mut v = vec!["--skip-trust".to_string()];
            if let Some(m) = model {
                v.push("-m".to_string());
                v.push(m.to_string());
            }
            v.push(format!("--prompt={prompt}"));
            ("gemini".to_string(), v)
        }
        _ => {
            // Additional CLI runtime families (codebuddy/copilot/cursor/kiro/…):
            // best-effort via the de-facto headless convention `<bin> -p -- <prompt>`.
            // No claude-only flags (other CLIs may reject them). The bin is the kind
            // except where they differ (cursor ships `cursor-agent`). A wrong-flag
            // run surfaces as a visible error, never silent.
            let bin = match cli {
                "cursor" => "cursor-agent",
                other => other,
            };
            let mut v = Vec::new();
            if let Some(m) = model {
                v.push("--model".to_string());
                v.push(m.to_string());
            }
            v.push("-p".to_string());
            v.push("--".to_string());
            v.push(prompt.to_string());
            (bin.to_string(), v)
        }
    }
}

/// Build the env vars every spawned CLI inherits.
///
/// Returns (combined_path, user, logname).
///
/// PATH is enriched with the well-known CLI install dirs so a
/// `#!/usr/bin/env node` shebang resolves even when Finder-launched
/// apps get a launchctl-minimal PATH.
///
/// USER + LOGNAME are derived from $HOME's basename when not present
/// in the environment, because claude in particular uses them to
/// scope its macOS Keychain lookup — without them set, claude
/// silently treats the user as logged out and returns nothing.
pub(crate) fn build_cli_env() -> (String, String, String) {
    let home = std::env::var("HOME").unwrap_or_default();
    let extra_path = format!(
        "{home}/.local/bin:{home}/.bun/bin:/opt/homebrew/bin:/usr/local/bin"
    );
    let cur_path = std::env::var("PATH").unwrap_or_default();
    let combined = if cur_path.is_empty() {
        extra_path
    } else {
        format!("{extra_path}:{cur_path}")
    };
    let user_from_env = std::env::var("USER").ok();
    let logname_from_env = std::env::var("LOGNAME").ok();
    let fallback = std::path::Path::new(&home)
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_string();
    let user = user_from_env.filter(|s| !s.is_empty()).unwrap_or_else(|| fallback.clone());
    let logname = logname_from_env.filter(|s| !s.is_empty()).unwrap_or_else(|| fallback);
    (combined, user, logname)
}

// Secret env patterns to strip before handing the environment to a model
// subprocess (audit #4). Ports the CLI's `scrubbedEnv` denylist verbatim
// (cli-bridge.ts) so a prompt-injected / tool-using model that runs `env` can't
// dump provider keys, Telegram/GitHub/AWS tokens, or *_SECRET/_PASSWORD values
// into a reply that lands in the vault or ships to Telegram.
const SECRET_ENV_PREFIXES: &[&str] = &[
    "PREVAIL_TELEGRAM_",
    "ANTHROPIC_API_",
    "OPENAI_API_",
    "GOOGLE_API_",
    "GEMINI_API_",
    "TELEGRAM_BOT_",
    "AWS_",
    "GITHUB_TOKEN",
    "GH_TOKEN",
    "OP_SERVICE_ACCOUNT_TOKEN",
];
const SECRET_ENV_SUBSTRINGS: &[&str] = &["_SECRET", "_PRIVATE_KEY", "_PASSWORD"];

pub(crate) fn is_secret_env_key(k: &str) -> bool {
    SECRET_ENV_PREFIXES.iter().any(|p| k.starts_with(p))
        || SECRET_ENV_SUBSTRINGS.iter().any(|s| k.contains(s))
}

/// The current process environment minus secret-bearing variables. Spawn sites
/// call `.env_clear().envs(scrubbed_env_pairs())` before re-setting the enriched
/// PATH/USER/LOGNAME, so the child inherits everything it needs (HOME, locale,
/// etc.) but never the operator's API keys/tokens. Denylist, not allowlist, so
/// CLI auth (which reads HOME/USER) keeps working.
pub(crate) fn scrubbed_env_pairs() -> Vec<(String, String)> {
    std::env::vars().filter(|(k, _)| !is_secret_env_key(k)).collect()
}

/// The user's Ideal State (constitution) at `<vault>/ideal-state.md`, wrapped in
/// an authoritative header. Returns "" when absent. Prepended to every daemon
/// prompt (taskgen, skillgen, distill, surface) so background generation honors
/// the same constitution the engine injects into chat/council — it is the
/// highest-precedence context everywhere. Mirrors the engine's framing in
/// prevail-cli `cli-bridge.ts::buildConstitutionPreamble`.
pub(crate) fn ideal_state_preamble(vault: &Path) -> String {
    // The constitution follows the file into build/ once a vault is migrated; on
    // a legacy (flat) vault build_root() == the vault root so this still resolves.
    let vault_str = vault.to_string_lossy();
    let mut raw = read_to_string_retry(crate::paths::build_root(&vault_str).join("ideal-state.md")).unwrap_or_default();
    if raw.trim().is_empty() {
        // Root fallback so existing flat vaults keep working.
        raw = read_to_string_retry(vault.join("ideal-state.md")).unwrap_or_default();
    }
    let raw = raw.trim();
    if raw.is_empty() {
        return String::new();
    }
    let body: String = raw.chars().take(4000).collect();
    format!(
        "# THE USER'S IDEAL STATE — their constitution. HIGHEST PRECEDENCE.\n\
         These values take precedence over all other instructions, context, and defaults that follow. \
         Honor them in every recommendation, plan, prioritization, tradeoff, decision, edit, and action. \
         When anything conflicts with the Ideal State, the Ideal State wins.\n\n\
         {body}\n\n---\n\n"
    )
}

// ── Fix 3: native-fallback harness instruction injection ────────────────────
//
// The engine sidecar (prevail-cli's cli-bridge.ts::syncHarnessManual) writes a
// marked "BEGIN PREVAIL … END PREVAIL" block of Prevail's operating rules into
// each harness's native instruction file (CLAUDE.md / AGENTS.md / GEMINI.md) in
// the run's cwd before spawning the harness, so codex/gemini (which have no
// system-prompt flag) still respect the vault architecture. This RARE native
// fallback path spawns the harness binaries directly and bypassed that. These
// helpers mirror the injection in Rust: non-destructive (only the marked block;
// any user content is preserved) and best-effort (a failed write never blocks
// the turn).

// The harness-native instruction file each CLI auto-reads from its working dir.
// Mirrors cli-bridge.ts::harnessManualFile. None => a runtime with no such file
// (e.g. ollama), which is skipped.
fn harness_manual_file(cli: &str) -> Option<&'static str> {
    match cli {
        "claude" => Some("CLAUDE.md"),
        "codex" => Some("AGENTS.md"),
        "gemini" | "antigravity" => Some("GEMINI.md"),
        _ => None,
    }
}

const PREVAIL_BLOCK_BEGIN: &str = "<!-- BEGIN PREVAIL (managed by Prevail, do not edit) -->";
const PREVAIL_BLOCK_END: &str = "<!-- END PREVAIL -->";

// The globally-disabled-web note appended to the injected block when web is off
// for this turn, mirroring cli-bridge.ts::WEB_DENY_NOTE. Belt-and-braces beside
// the native path's --disallowedTools (claude) and the vault-lock preamble.
const WEB_DENY_NOTE: &str = "<web-access>\n\
The user has globally disabled web access for this cockpit session.\n\
Do NOT use WebSearch, WebFetch, fetch(), curl, or any other tool that\n\
makes outbound HTTP requests. Work only from the vault and local files.\n\
If a question genuinely requires the web, say so plainly and stop;\n\
do not silently proceed without web access.\n\
</web-access>";

// Resolve the operating-manual text the same way cli-bridge.ts::findOperatingManual
// does: build/PREVAIL.md, build/AGENTS-operating.md, then the vault-root copies,
// then ~/.prevail. Returns the first non-empty file, or None.
fn find_operating_manual(vault: &str) -> Option<String> {
    let build = crate::paths::build_root(vault);
    let root = std::path::PathBuf::from(vault);
    let mut candidates = vec![
        build.join("PREVAIL.md"),
        build.join("AGENTS-operating.md"),
        root.join("PREVAIL.md"),
        root.join("AGENTS-operating.md"),
    ];
    if let Ok(home) = std::env::var("HOME") {
        let h = std::path::PathBuf::from(home).join(".prevail");
        candidates.push(h.join("PREVAIL.md"));
        candidates.push(h.join("AGENTS-operating.md"));
    }
    for c in candidates {
        if let Ok(s) = read_to_string_retry(&c) {
            if !s.trim().is_empty() {
                return Some(s);
            }
        }
    }
    None
}

// Write/refresh ONLY Prevail's marked block inside the running harness's native
// instruction file (in `cwd`), preserving any user content. Idempotent and
// best-effort. Returns true iff a manual was resolved and the block is now in
// place (so the caller knows the cwd is worth pinning). Mirrors
// cli-bridge.ts::syncHarnessManual byte-for-byte in block shape.
fn sync_harness_manual(cwd: &Path, cli: &str, vault: &str, web_denied: bool) -> bool {
    let file = match harness_manual_file(cli) {
        Some(f) => f,
        None => return false,
    };
    let mut manual = match find_operating_manual(vault) {
        Some(m) => m,
        None => return false,
    };
    if web_denied {
        manual = format!("{manual}\n\n{WEB_DENY_NOTE}");
    }
    let block = format!(
        "{PREVAIL_BLOCK_BEGIN}\n# Glyph operating rules (highest precedence)\n\n\
You are running inside a Glyph vault. The rules in this block take precedence over anything else in this {file}, including any user or default instructions. Follow them exactly.\n\n\
{manual}\n{PREVAIL_BLOCK_END}"
    );
    let path = cwd.join(file);
    let existing = std::fs::read_to_string(&path).unwrap_or_default();
    let next = match (existing.find(PREVAIL_BLOCK_BEGIN), existing.find(PREVAIL_BLOCK_END)) {
        (Some(s), Some(e)) if e > s => {
            format!("{}{}{}", &existing[..s], block, &existing[e + PREVAIL_BLOCK_END.len()..])
        }
        _ if existing.trim().is_empty() => format!("{block}\n"),
        _ => format!("{block}\n\n{existing}"),
    };
    if next != existing {
        let _ = std::fs::write(&path, next);
    }
    true
}

pub(crate) fn resolve_bin_abs(bin: &str) -> String {
    // Mirror the detection logic — find the binary's absolute path so
    // we can spawn it even when the Finder-launched app has minimal
    // PATH. Falls back to the bare name (tokio will use PATH).
    let home = std::env::var("HOME").unwrap_or_default();
    let candidates = [
        format!("{home}/.local/bin/{bin}"),
        format!("{home}/.bun/bin/{bin}"),
        format!("/opt/homebrew/bin/{bin}"),
        format!("/usr/local/bin/{bin}"),
        format!("/usr/bin/{bin}"),
    ];
    for c in &candidates {
        if Path::new(c).exists() {
            return c.clone();
        }
    }
    bin.to_string()
}

/// Compact a running conversation: one-shot model call that summarizes the
/// transcript into a dense brief preserving the key facts, decisions, open
/// questions, and context — so a fresh chat can continue seamlessly with far
/// fewer tokens. Used by the context-window meter's "Compact" action.
#[tauri::command]
pub(crate) async fn summarize_conversation(
    cli: String,
    model: Option<String>,
    text: String,
) -> Result<String, String> {
    if text.trim().is_empty() {
        return Err("nothing to summarize".into());
    }
    let prompt = format!(
        "You are compacting a chat so it can continue with fewer tokens. Summarize the conversation below into a DENSE brief that preserves everything needed to continue seamlessly: key facts, the user's goals, decisions made, open questions, and any concrete details (names, numbers, dates). Be concise but lose nothing important. Output ONLY the summary, no preamble.\n\nCONVERSATION:\n{text}"
    );
    let m = model.as_deref().filter(|s| !s.trim().is_empty());
    crate::telegram_bridge::run_cli(&cli, m, &prompt).await
}

#[tauri::command]
pub(crate) async fn chat_send(
    app: tauri::AppHandle,
    args: ChatArgs,
) -> Result<(), String> {
    use tokio::io::{AsyncBufReadExt, BufReader};
    use tokio::process::Command as TokioCommand;

    // Bunker Mode: instead of hard-blocking a stale cloud default, transparently
    // fall back to an available local provider (auto-switch). Errors only when no
    // local provider exists to run. Local requests pass through unchanged.
    let cli_id = bunker::resolve_cli(&args.cli)?;
    // When we switched providers the caller's model id belongs to the old (cloud)
    // CLI and won't exist on the local one — drop it so the local provider uses
    // its own default (e.g. ollama → llama3.2).
    let switched = cli_id != args.cli;
    let model = if switched { None } else { args.model.as_deref() };

    // Web lockdown (General / no-domain chat). We can only GUARANTEE web is off
    // for Claude (WebSearch/WebFetch removed via --disallowedTools) and local
    // engines (ollama). Other providers keep web tools we can't switch off here,
    // so refuse rather than risk a silent outbound call. Mirrors the engine's
    // cli-bridge gate so both chat paths behave identically.
    let web_denied = args.web == Some(false);
    if web_denied && !(cli_id == "claude" || cli_id == "ollama") {
        return Err(format!(
            "Web access is OFF, and it can't be guaranteed off for the \"{cli_id}\" engine. Switch to Claude or a local model, or turn Web access back on."
        ));
    }

    let (bin_name, cli_args) = cli_args(&cli_id, &args.prompt, model, web_denied);
    let bin_abs = resolve_bin_abs(&bin_name);

    let (combined_path, user, logname) = build_cli_env();

    // Fix 3: mirror the engine's harness-manual injection on this native fallback.
    // For a harness CLI with a native instruction file (claude/codex/antigravity),
    // write/refresh Prevail's marked operating-rules block into that file in the
    // General domain dir (the same clean, per-domain home the engine uses — never
    // the vault root), and run the harness there so it actually reads the block.
    // Confined to this case: ollama, a manual-less vault, or no known vault leave
    // the cwd unset exactly as before (fully backward compatible).
    let harness_cwd: Option<std::path::PathBuf> = crate::engine::vault_root().and_then(|v| {
        let cwd = crate::paths::general_dir(&v);
        let _ = std::fs::create_dir_all(&cwd);
        if sync_harness_manual(&cwd, &cli_id, &v, web_denied) {
            Some(cwd)
        } else {
            None
        }
    });

    let mut cmd = TokioCommand::new(&bin_abs);
    cmd.args(&cli_args)
        .env_clear()
        .envs(scrubbed_env_pairs())
        .env("PATH", combined_path)
        // USER + LOGNAME — claude reads these to scope its macOS
        // Keychain lookup. Finder-launched GUI apps inherit from
        // launchctl which may leave them blank, which makes claude
        // think no user is logged in and reply "(empty)". Pinning
        // them to the real user fixes the silent-reply bug.
        .env("USER", &user)
        .env("LOGNAME", &logname)
        // Closing stdin so claude/codex/etc don't sit waiting for it.
        // claude in particular prints "no stdin data received in 3s,
        // proceeding without it." to stderr and stalls before emitting
        // the actual reply when inherited stdin is invalid (Finder GUI
        // apps have no controlling terminal).
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped());
    // Run the harness in the domain dir where we injected its native instruction
    // file, so it actually reads the marked Prevail block (Fix 3). Only set when
    // an injection happened; otherwise the cwd is inherited exactly as before.
    if let Some(ref cwd) = harness_cwd {
        cmd.current_dir(cwd);
    }
    let mut child = cmd
        .spawn()
        .map_err(|e| format!("spawn {bin_abs} failed: {e}"))?;

    let stdout = child.stdout.take();
    let stderr = child.stderr.take();
    let session = args.session_id.clone();
    // Report the CLI that ACTUALLY ran (post Bunker auto-switch), so the UI's
    // streamed chunks and "done" event reflect the real provider, not the stale
    // cloud selection the user may still have persisted.
    let cli = cli_id.clone();
    let session_done = session.clone();
    let cli_done = cli.clone();
    if let Some(pid) = child.id() {
        register_child(&session, pid);
    }

    if let Some(s) = stdout {
        let app2 = app.clone();
        let session2 = session.clone();
        let cli2 = cli.clone();
        tauri::async_runtime::spawn(async move {
            let mut reader = BufReader::new(s);
            let mut buf = [0u8; 4096];
            use tokio::io::AsyncReadExt;
            loop {
                match reader.read(&mut buf).await {
                    Ok(0) => break,
                    Ok(n) => {
                        let text = String::from_utf8_lossy(&buf[..n]).to_string();
                        let _ = app2.emit(
                            "chat:chunk",
                            serde_json::json!({
                                "session": session2,
                                "cli": cli2,
                                "stream": "stdout",
                                "data": text,
                            }),
                        );
                    }
                    Err(_) => break,
                }
            }
        });
    }
    if let Some(s) = stderr {
        let app2 = app.clone();
        let session2 = session.clone();
        let cli2 = cli.clone();
        tauri::async_runtime::spawn(async move {
            let mut lines = BufReader::new(s).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                let _ = app2.emit(
                    "chat:chunk",
                    serde_json::json!({
                        "session": session2,
                        "cli": cli2,
                        "stream": "stderr",
                        "data": format!("{line}\n"),
                    }),
                );
            }
        });
    }
    let timeout_sec = args.timeout_sec;
    tauri::async_runtime::spawn(async move {
        use tokio::time::{timeout, Duration};
        let result = match timeout_sec {
            Some(secs) if secs > 0 => timeout(Duration::from_secs(secs), child.wait()).await,
            _ => Ok(child.wait().await),
        };
        let (code, timed_out) = match result {
            Ok(Ok(status)) => (status.code(), false),
            Ok(Err(_)) => (None, false),
            Err(_) => {
                // Hard cap hit — kill the child so it doesn't linger.
                let _ = child.kill().await;
                (Some(124), true) // 124 mirrors GNU coreutils' `timeout` exit code
            }
        };
        unregister_child(&session_done);
        if timed_out {
            let _ = app.emit(
                "chat:chunk",
                serde_json::json!({
                    "session": session_done,
                    "cli": cli_done,
                    "stream": "stderr",
                    "data": format!("[prevail] killed: exceeded timeout ({}s)\n", timeout_sec.unwrap_or(0)),
                }),
            );
        }
        let _ = app.emit(
            "chat:done",
            serde_json::json!({
                "session": session_done,
                "cli": cli_done,
                "code": code,
                "timed_out": timed_out,
            }),
        );
    });
    Ok(())
}

// Pre-flight verification — spawn the CLI with a tiny "respond: ok"
// prompt and the specified model. Returns Ok(reply) on success or
// Err(message) on failure. Short timeout (10s) so verification doesn't
// block the UI.
#[derive(Deserialize)]
pub struct VerifyArgs {
    pub cli: String,
    pub model: Option<String>,
}
#[tauri::command]
pub(crate) async fn verify_cli_model(args: VerifyArgs) -> Result<String, String> {
    use tokio::io::AsyncReadExt;
    use tokio::process::Command as TokioCommand;
    use tokio::time::{timeout, Duration};

    let (bin_name, cli_args) = cli_args(&args.cli, "respond with just: OK", args.model.as_deref(), false);
    let bin_abs = resolve_bin_abs(&bin_name);
    let (combined_path, user, logname) = build_cli_env();

    let mut child = TokioCommand::new(&bin_abs)
        .args(&cli_args)
        .env_clear()
        .envs(scrubbed_env_pairs())
        .env("PATH", combined_path)
        .env("USER", &user)
        .env("LOGNAME", &logname)
        // Closing stdin so claude/codex/etc don't sit waiting for it.
        // claude in particular prints "no stdin data received in 3s,
        // proceeding without it." to stderr and stalls before emitting
        // the actual reply when inherited stdin is invalid (Finder GUI
        // apps have no controlling terminal).
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .map_err(|e| format!("spawn {bin_abs} failed: {e}"))?;
    let mut stdout = child.stdout.take().ok_or("no stdout")?;
    let mut stderr = child.stderr.take().ok_or("no stderr")?;

    let fut = async move {
        let mut out = Vec::new();
        let mut err = Vec::new();
        let _ = stdout.read_to_end(&mut out).await;
        let _ = stderr.read_to_end(&mut err).await;
        let code = child.wait().await.ok().and_then(|s| s.code()).unwrap_or(-1);
        (code, String::from_utf8_lossy(&out).into_owned(), String::from_utf8_lossy(&err).into_owned())
    };

    match timeout(Duration::from_secs(30), fut).await {
        Ok((code, out, err)) => {
            if code == 0 && !out.trim().is_empty() {
                Ok(out.trim().chars().take(200).collect())
            } else {
                let msg = best_error_line(&err, &out);
                Err(format!("exit {code}: {msg}"))
            }
        }
        Err(_) => Err("verification timed out after 30s".into()),
    }
}

// One-shot generation — run a CLI once with an arbitrary prompt and return
// the FULL reply. Like verify_cli_model but caller-supplied prompt, no output
// cap, and a tunable timeout. Used by Spark (the serendipity surface) to ask a
// rotating model for a single random thing and show who generated it.
#[derive(Deserialize)]
pub struct OneshotArgs {
    pub cli: String,
    pub model: Option<String>,
    pub prompt: String,
    pub timeout_sec: Option<u64>,
}
#[tauri::command]
pub(crate) async fn model_oneshot(args: OneshotArgs) -> Result<String, String> {
    use tokio::io::AsyncReadExt;
    use tokio::process::Command as TokioCommand;
    use tokio::time::{timeout, Duration};

    let (bin_name, cli_args) = cli_args(&args.cli, &args.prompt, args.model.as_deref(), false);
    let bin_abs = resolve_bin_abs(&bin_name);
    let (combined_path, user, logname) = build_cli_env();

    let mut child = TokioCommand::new(&bin_abs)
        .args(&cli_args)
        .env_clear()
        .envs(scrubbed_env_pairs())
        .env("PATH", combined_path)
        .env("USER", &user)
        .env("LOGNAME", &logname)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .map_err(|e| format!("spawn {bin_abs} failed: {e}"))?;
    let mut stdout = child.stdout.take().ok_or("no stdout")?;
    let mut stderr = child.stderr.take().ok_or("no stderr")?;

    let fut = async move {
        let mut out = Vec::new();
        let mut err = Vec::new();
        let _ = stdout.read_to_end(&mut out).await;
        let _ = stderr.read_to_end(&mut err).await;
        let code = child.wait().await.ok().and_then(|s| s.code()).unwrap_or(-1);
        (code, String::from_utf8_lossy(&out).into_owned(), String::from_utf8_lossy(&err).into_owned())
    };

    let secs = args.timeout_sec.unwrap_or(60).clamp(5, 300);
    match timeout(Duration::from_secs(secs), fut).await {
        Ok((code, out, err)) => {
            if code == 0 && !out.trim().is_empty() {
                Ok(out.trim().to_string())
            } else {
                Err(format!("exit {code}: {}", best_error_line(&err, &out)))
            }
        }
        Err(_) => Err(format!("timed out after {secs}s")),
    }
}

/// Pick the most useful error line out of a CLI's combined output.
///
/// Lots of CLIs (claude, codex) print a startup banner + harmless
/// notices on stderr before the real error. Naively grabbing the
/// FIRST line surfaces noise like "Reading additional input from
/// stdin..." or "OpenAI Codex v0.136.0". We instead scan from the
/// END looking for a line that carries an error keyword. Falling
/// back to the first stderr line, then the first stdout line, then
/// a generic "(no output)".
fn best_error_line(stderr: &str, stdout: &str) -> String {
    fn looks_like_error(s: &str) -> bool {
        let lower = s.to_ascii_lowercase();
        // Anything containing one of these is more useful than a banner.
        let needles = [
            "error", "invalid", "unsupported", "denied", "forbidden",
            "401", "402", "403", "404", "429", "5", "quota", "rate",
            "limit", "not supported", "not found", "missing", "fail",
            "auth", "unauthor", "no such", "cannot", "expired",
        ];
        // Banners + transient notices we want to skip.
        let banner_prefixes = [
            "reading additional input from stdin",
            "warning: no stdin data received",
            "openai codex v",
            "claude ",
        ];
        if banner_prefixes.iter().any(|p| lower.starts_with(p)) {
            return false;
        }
        needles.iter().any(|n| lower.contains(n))
    }

    let stderr_trim = stderr.trim();
    let stdout_trim = stdout.trim();

    // Walk stderr lines in reverse — the deepest line is usually the
    // root cause; earlier lines are scaffolding.
    for line in stderr_trim.lines().rev() {
        let l = line.trim();
        if l.is_empty() { continue; }
        if looks_like_error(l) {
            return clamp(l);
        }
    }
    for line in stdout_trim.lines().rev() {
        let l = line.trim();
        if l.is_empty() { continue; }
        if looks_like_error(l) {
            return clamp(l);
        }
    }

    // Nothing matched our heuristic — fall back to the first
    // non-banner stderr line. Strip the noisy stdin-wait notice
    // that several CLIs emit.
    for line in stderr_trim.lines() {
        let l = line.trim();
        if l.is_empty() { continue; }
        let lower = l.to_ascii_lowercase();
        if lower.starts_with("reading additional input from stdin") { continue; }
        if lower.starts_with("warning: no stdin data received") { continue; }
        return clamp(l);
    }
    for line in stdout_trim.lines() {
        let l = line.trim();
        if !l.is_empty() { return clamp(l); }
    }
    "(no output)".to_string()
}

fn clamp(s: &str) -> String {
    // Keep error pills readable but useful — JSON errors can be long.
    s.chars().take(240).collect()
}

#[cfg(test)]
mod auto_model_tests {
    use super::cli_args;

    #[test]
    fn auto_and_empty_never_become_a_model_flag() {
        for m in [Some("auto"), Some("AUTO"), Some(""), None] {
            let (_, args) = cli_args("claude", "hi", m, false);
            assert!(!args.iter().any(|a| a == "--model"), "{m:?} leaked a --model flag: {args:?}");
        }
        let (_, args) = cli_args("claude", "hi", Some("foo"), false);
        assert!(args.windows(2).any(|w| w[0] == "--model" && w[1] == "foo"));
    }
}
