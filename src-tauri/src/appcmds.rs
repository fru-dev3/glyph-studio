// App-shell commands — generic file read/write, vault bootstrap + sample-vault
// import, domain creation, OS integration (Finder, move-to-Applications),
// diagnostics, uninstall, paste attachments, and session save. The grab-bag of
// lifecycle/file-IO commands the desktop shell needs. Extracted from lib.rs.

use std::fs;
use std::path::{Path, PathBuf};

use serde::Deserialize;
use tauri_plugin_shell::ShellExt;

use crate::engine;
use crate::paths::safe_domain_subdir;
use crate::read_to_string_retry;
use crate::vault::Domain;

/// Defense-in-depth for the generic read primitive, mirroring
/// `reject_sensitive_write`. `read_file`/`read_text_file` took an arbitrary
/// absolute path with no validation while the write side was guarded — an
/// asymmetry an XSS (none today) would exploit to exfiltrate credentials. We
/// refuse the classic secret-read targets (SSH/cloud creds, browser cookie and
/// login stores, the login keychain, shell rc files). Vault files, the app-
/// support tree, and ordinary Documents reads are unaffected.
fn reject_sensitive_read(path: &str) -> Result<(), String> {
    let home = std::env::var("HOME").unwrap_or_default();
    let blocked_suffixes = [
        "/.zshrc", "/.zshenv", "/.zprofile", "/.bashrc", "/.bash_profile",
        "/.profile", "/.netrc", "/.npmrc",
    ];
    let blocked_dirs = [
        format!("{home}/.ssh/"),
        format!("{home}/.aws/"),
        format!("{home}/.config/gcloud/"),
        format!("{home}/.gnupg/"),
        format!("{home}/Library/Keychains/"),
        format!("{home}/Library/Cookies/"),
        format!("{home}/Library/Application Support/Google/Chrome/"),
        format!("{home}/Library/Application Support/Firefox/"),
        format!("{home}/Library/Application Support/BraveSoftware/"),
        format!("{home}/Library/Application Support/com.apple.TCC/"),
    ];
    let lower = path.to_lowercase();
    if blocked_suffixes.iter().any(|s| path.ends_with(s))
        || blocked_dirs.iter().any(|d| path.starts_with(d.as_str()))
        || lower.contains("/cookies.sqlite")
        || lower.contains("/login data")
    {
        return Err("refused: reading from a sensitive credential location is not allowed".into());
    }
    Ok(())
}

#[tauri::command(async)]
pub(crate) fn read_file(path: String) -> Result<String, String> {
    reject_sensitive_read(&path)?;
    read_to_string_retry(&path).map_err(|e| format!("read {}: {}", path, e))
}

// Diagnostic: the frontend's fatal-error handler writes the crash here so
// production render failures (blank window) are inspectable from disk. Written
// into the per-user app-support tree (not a world-shared, predictable /tmp path
// where a pre-positioned symlink could redirect the write), and opened with
// O_NOFOLLOW so an existing symlink at the target is refused rather than
// followed.
#[tauri::command(async)]
pub(crate) fn log_fatal(msg: String) {
    let dir = fatal_log_dir();
    let _ = fs::create_dir_all(&dir);
    let path = dir.join("prevail-fatal.log");
    // On Unix, open with O_NOFOLLOW so a pre-positioned symlink at the target is
    // refused rather than followed. Windows uses a per-user LOCALAPPDATA dir
    // (not world-writable), so a plain write is sufficient there.
    #[cfg(unix)]
    {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        if let Ok(mut f) = fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&path)
        {
            let _ = f.write_all(msg.as_bytes());
        }
    }
    #[cfg(not(unix))]
    {
        let _ = fs::write(&path, msg.as_bytes());
    }
}

// Per-user directory for the fatal-crash log. Not a world-shared /tmp path.
fn fatal_log_dir() -> PathBuf {
    #[cfg(target_os = "windows")]
    {
        if let Ok(local) = std::env::var("LOCALAPPDATA") {
            return Path::new(&local).join("sh.prevail.desktop");
        }
    }
    if let Ok(home) = std::env::var("HOME") {
        return Path::new(&home).join("Library/Application Support/sh.prevail.desktop");
    }
    std::env::temp_dir()
}

fn copy_dir_recursive(src: &Path, dst: &Path) -> std::io::Result<()> {
    fs::create_dir_all(dst)?;
    for entry in fs::read_dir(src)? {
        let entry = entry?;
        let from = entry.path();
        let to = dst.join(entry.file_name());
        if entry.file_type()?.is_dir() {
            copy_dir_recursive(&from, &to)?;
        } else {
            fs::copy(&from, &to)?;
        }
    }
    Ok(())
}

// Where we remember the last-chosen vault so it survives a webview-cache
// wipe (which clears localStorage). Read on boot as a fallback.
fn bootstrap_vault_path() -> Option<std::path::PathBuf> {
    let home = std::env::var("HOME").ok()?;
    Some(Path::new(&home).join("Library/Application Support/sh.prevail.desktop/bootstrap-vault.txt"))
}

fn write_bootstrap_vault(path: &str) {
    if let Some(bf) = bootstrap_vault_path() {
        if let Some(p) = bf.parent() {
            let _ = fs::create_dir_all(p);
        }
        let _ = fs::write(&bf, path);
    }
}

/// Copy the bundled sample vault into the user's Documents and return its
/// path, so a new user can explore every feature without creating domains.
#[tauri::command(async)]
pub(crate) fn import_sample_vault(app: tauri::AppHandle) -> Result<String, String> {
    use tauri::Manager;
    let src = app
        .path()
        .resolve("resources/sample-vault", tauri::path::BaseDirectory::Resource)
        .map_err(|e| format!("resolve sample resource: {e}"))?;
    if !src.exists() {
        return Err(format!("bundled sample vault not found at {}", src.display()));
    }
    let home = std::env::var("HOME").map_err(|e| e.to_string())?;
    // App-managed demo sandbox (NOT ~/Documents): the switch-to-production flow
    // and any re-seed only ever touch a folder WE own and have marked as demo,
    // so real user data is never at risk. (DEMO-MODE-PLAN: demo lives in app
    // storage, not dumped into the user's Documents.)
    let dest = Path::new(&home).join(".prevail/demo-vault");
    let marker = dest.join(".prevail-demo");
    // Non-destructive refresh: only wipe a path that carries our own demo
    // marker. Never remove a folder we didn't create (hard rule: never delete
    // user data).
    if dest.exists() && marker.exists() {
        let _ = fs::remove_dir_all(&dest);
    }
    if !dest.exists() {
        if let Some(parent) = dest.parent() {
            fs::create_dir_all(parent).map_err(|e| format!("create demo dir: {e}"))?;
        }
        copy_dir_recursive(&src, &dest).map_err(|e| format!("copy sample vault: {e}"))?;
    }
    // Stamp the demo marker so future re-seeds and the switch-to-production flow
    // can safely identify (and only then clear) this app-owned sandbox.
    let _ = fs::write(&marker, "demo sandbox — safe to clear on switch-to-production\n");
    let dest_str = dest.to_string_lossy().to_string();
    write_bootstrap_vault(&dest_str);
    Ok(dest_str)
}

/// True if `path` is an existing directory — used on launch to detect a stale
/// remembered vault (e.g. a demo vault the user deleted) so we can re-seed.
#[tauri::command(async)]
pub(crate) fn vault_exists(path: String) -> bool {
    !path.is_empty() && Path::new(&path).is_dir()
}

/// Persist the chosen vault path so it survives a cache wipe.
#[tauri::command(async)]
pub(crate) fn remember_vault(path: String) {
    write_bootstrap_vault(&path);
}

/// Boot fallback: the last vault we remembered (when localStorage was wiped).
#[tauri::command(async)]
pub(crate) fn bootstrap_vault() -> Option<String> {
    let bf = bootstrap_vault_path()?;
    let s = read_to_string_retry(&bf).ok()?;
    let s = s.trim();
    if s.is_empty() || !Path::new(s).exists() {
        return None;
    }
    Some(s.to_string())
}


// Create a new domain folder under the vault root. Writes a minimal
// state.md skeleton so scan_vault picks it up immediately.
#[tauri::command(async)]
pub(crate) fn create_domain(app: tauri::AppHandle, vault: String, name: String) -> Result<Domain, String> {
    let slug: String = name
        .trim()
        .to_lowercase()
        .chars()
        .map(|c| if c.is_alphanumeric() { c } else { '-' })
        .collect::<String>()
        .split('-')
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join("-");
    if slug.is_empty() {
        return Err("name cannot be empty".into());
    }
    let root = PathBuf::from(&vault);
    if !root.exists() {
        return Err(format!("vault not found: {vault}"));
    }
    // Canonical home for a new domain: data/domains/<slug> on a migrated vault,
    // the vault root on a legacy flat vault (resolve_domain_base handles both and
    // preserves any existing domain in place).
    let domain_dir = crate::paths::resolve_domain_base(&vault, &slug);
    if domain_dir.exists() {
        return Err(format!("domain '{slug}' already exists"));
    }
    fs::create_dir_all(&domain_dir).map_err(|e| format!("mkdir failed: {e}"))?;
    let title = slug
        .split('-')
        .map(|p| {
            let mut c = p.chars();
            match c.next() {
                Some(f) => f.to_uppercase().collect::<String>() + c.as_str(),
                None => String::new(),
            }
        })
        .collect::<Vec<_>>()
        .join(" ");
    let stub = format!(
        "# {title}\n\n_State for the {title} domain. Edit freely._\n\n## Current focus\n\n- (none yet)\n\n## Open decisions\n\n- (none yet)\n"
    );
    let state_path = domain_dir.join("state.md");
    crate::vaultio::write_atomic(&state_path, &stub).map_err(|e| format!("write state.md failed: {e}"))?;
    // Seed the bundled default skills for this domain (when a pack exists) so a
    // new domain arrives with high-quality skills out of the box, not empty.
    seed_domain_skills(&app, &slug, &domain_dir);
    Ok(Domain {
        name: slug,
        path: domain_dir.to_string_lossy().to_string(),
        has_state: true,
        state_preview: Some(stub.chars().take(120).collect()),
    })
}

// Copy the bundled default skill pack for `slug` (resources/skill-packs/domains/
// <slug>/_skills) into the new domain's _skills/. Best-effort and never clobbers
// a user's skill; a missing pack is a no-op.
fn seed_domain_skills(app: &tauri::AppHandle, slug: &str, domain_dir: &Path) {
    use tauri::Manager;
    let Ok(base) = app
        .path()
        .resolve("resources/skill-packs", tauri::path::BaseDirectory::Resource)
    else {
        return;
    };
    let src = base.join("domains").join(slug).join("_skills");
    if src.is_dir() {
        let _ = copy_dir_no_clobber(&src, &domain_dir.join("_skills"));
    }
}

fn copy_dir_no_clobber(src: &Path, dest: &Path) -> std::io::Result<()> {
    fs::create_dir_all(dest)?;
    for entry in fs::read_dir(src)? {
        let entry = entry?;
        let to = dest.join(entry.file_name());
        if entry.file_type()?.is_dir() {
            copy_dir_no_clobber(&entry.path(), &to)?;
        } else if !to.exists() {
            fs::copy(entry.path(), &to)?;
        }
    }
    Ok(())
}

// Open/reveal a path in the OS default file manager (Finder on macOS).
/// The path itself, or its nearest existing parent (at most three levels up).
fn nearest_existing(path: &str) -> std::path::PathBuf {
    let mut p = std::path::PathBuf::from(path);
    for _ in 0..3 {
        if p.exists() { break; }
        match p.parent() { Some(up) => p = up.to_path_buf(), None => break }
    }
    p
}

#[cfg(test)]
mod reveal_tests {
    #[test]
    fn a_missing_files_folder_reveals_its_parent() {
        let dir = std::env::temp_dir().join(format!("reveal-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let missing = dir.join("files");
        assert_eq!(super::nearest_existing(missing.to_str().unwrap()), dir);
        assert_eq!(super::nearest_existing(dir.to_str().unwrap()), dir);
        let _ = std::fs::remove_dir_all(&dir);
    }
}

#[tauri::command]
pub(crate) async fn open_in_finder(app: tauri::AppHandle, path: String) -> Result<(), String> {
    // Harden against a frontend bug/injection turning this into "launch an
    // arbitrary app": resolve the real path, refuse executable bundles, and for
    // files use `-R` (reveal in Finder) rather than `open` (which would run an
    // .app/.command). Directories are safe to open directly. (O36)
    // A folder that does not exist yet (an entity's files/ before its first
    // file) reveals its nearest existing parent instead of failing silently.
    let canon = std::fs::canonicalize(nearest_existing(&path)).map_err(|e| format!("no such path: {e}"))?;
    let lower = canon.to_string_lossy().to_lowercase();
    if [".app", ".command", ".workflow", ".scpt", ".applescript", ".term"]
        .iter()
        .any(|ext| lower.ends_with(ext))
    {
        return Err("refusing to open an application/script bundle".into());
    }
    let target = canon.to_string_lossy().to_string();
    let bin = if cfg!(target_os = "macos") { "open" } else { "xdg-open" };
    let args: Vec<String> = if cfg!(target_os = "macos") && canon.is_file() {
        vec!["-R".into(), target] // reveal the file, never execute it
    } else {
        vec![target]
    };
    app.shell()
        .command(bin)
        .args(args)
        .output()
        .await
        .map_err(|e| format!("open failed: {e}"))?;
    Ok(())
}

// Copy the running .app bundle to /Applications/ under its own name (an
// install updated from Prevail keeps the Prevail.app folder name; a fresh
// install is "Glyph Studio.app"). Tries a plain `cp -R` first; if that fails
// (permissions), falls back to `osascript` which can prompt for admin.
// The source path must end in ".app".
#[tauri::command]
pub(crate) async fn move_to_applications(app: tauri::AppHandle, source: String) -> Result<String, String> {
    if !cfg!(target_os = "macos") {
        return Err("move_to_applications is macOS-only".into());
    }
    if source.starts_with("/Applications/") {
        return Ok("already in /Applications/".into());
    }
    let bundle = std::path::Path::new(source.trim_end_matches('/'))
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .filter(|n| n.ends_with(".app"))
        .unwrap_or_else(|| "Glyph Studio.app".into());
    let dest = format!("/Applications/{bundle}");
    let dest = dest.as_str();
    // Remove existing copy first so cp -R succeeds cleanly.
    let _ = std::fs::remove_dir_all(dest);
    let out = app.shell()
        .command("cp")
        .args(["-R", &source, dest])
        .output()
        .await
        .map_err(|e| format!("cp failed: {e}"))?;
    if out.status.success() {
        return Ok(format!("Copied to {dest}. Quit and relaunch from /Applications/."));
    }
    // Fallback: osascript with administrator privileges.
    let script = format!(
        r#"do shell script "cp -R '{}' '{}'" with administrator privileges"#,
        source.replace('\'', "'\\''"),
        dest
    );
    let out2 = app.shell()
        .command("osascript")
        .args(["-e", &script])
        .output()
        .await
        .map_err(|e| format!("osascript failed: {e}"))?;
    if out2.status.success() {
        Ok(format!("Copied to {dest}. Quit and relaunch from /Applications/."))
    } else {
        let err = String::from_utf8_lossy(&out2.stderr).to_string();
        Err(format!("Could not copy: {err}"))
    }
}

// SkillEntry + skill-description parsing live in domain.rs.


// Read the full content of a single skill (SKILL.md, README.md, or
// skill.md — whichever is present). Used by the Skills tab to expand
// a skill inline so the user can read its contents.
#[tauri::command(async)]
pub(crate) fn read_skill(path: String) -> Result<String, String> {
    let dir = PathBuf::from(&path);
    for candidate in &["SKILL.md", "README.md", "skill.md"] {
        let f = dir.join(candidate);
        if f.exists() {
            return read_to_string_retry(&f).map_err(|e| e.to_string());
        }
    }
    Err(format!("no SKILL.md/README.md/skill.md in {}", dir.display()))
}

// Append one generated spark to the on-disk archive at <vault>/_sparks.jsonl.
// JSONL + append-only, so the full history is preserved permanently WITHOUT ever
// being loaded into the app's working context (the user browses it on demand).
// Each record carries the spark text, its generated-at timestamp (ms + ISO), the
// model that produced it, and the generation config (field, register, batch,
// seed). Best-effort: any failure is returned and the caller ignores it, because
// archiving must never block or break spark generation.
#[tauri::command(async)]
pub(crate) fn spark_archive_append(vault: String, record: serde_json::Value) -> Result<(), String> {
    let _serial = crate::vaultio::serial();
    let root = PathBuf::from(&vault);
    if !root.exists() {
        return Err(format!("vault not found: {vault}"));
    }
    let path = root.join("_sparks.jsonl");
    let mut line =
        serde_json::to_string(&record).map_err(|e| format!("serialize spark failed: {e}"))?;
    line.push('\n');
    crate::vaultio::append_line(&path, &line)
        .map_err(|e| format!("append spark failed: {e}"))?;
    Ok(())
}

// Read recent sparks back from the archive (newest first), capped so browsing the
// history never floods memory. Returns the parsed JSONL records; malformed lines
// are skipped rather than failing the whole read.
#[tauri::command(async)]
pub(crate) fn spark_archive_read(vault: String, limit: Option<usize>) -> Result<Vec<serde_json::Value>, String> {
    let path = PathBuf::from(&vault).join("_sparks.jsonl");
    if !path.exists() {
        return Ok(Vec::new());
    }
    let body = read_to_string_retry(&path).map_err(|e| e.to_string())?;
    let cap = limit.unwrap_or(200);
    let mut out: Vec<serde_json::Value> = body
        .lines()
        .rev()
        .filter_map(|l| serde_json::from_str(l.trim()).ok())
        .take(cap)
        .collect();
    out.shrink_to_fit();
    Ok(out)
}

// CLI model verification (VerifyArgs, verify_cli_model) lives in chat.rs.


// Ideal State / user.md / memory.md commands live in idealstate.rs.

// Generic text file read/write — used by config export/import (the frontend
// picks a path via the dialog plugin, then calls these). Kept generic so
// other features can reuse them.

/// Defense-in-depth for the generic write primitive. The frontend is the only
/// caller (deliberately NOT in the WebUI allowlist), and there is no XSS vector
/// today (react-markdown renders untrusted content without raw HTML, behind a
/// `script-src 'self'` CSP). But a "write any absolute path" command is exactly
/// what injected code would reach for to gain persistence, so refuse the
/// classic auto-run / credential targets regardless of caller. Legitimate
/// config export (Documents/Downloads, the app-support tree) is unaffected.
fn reject_sensitive_write(path: &str) -> Result<(), String> {
    let home = std::env::var("HOME").unwrap_or_default();
    let blocked_suffixes = [
        "/.zshrc", "/.zshenv", "/.zprofile", "/.bashrc", "/.bash_profile",
        "/.profile", "/.config/fish/config.fish",
    ];
    let blocked_dirs = [
        format!("{home}/.ssh/"),
        format!("{home}/Library/LaunchAgents/"),
        format!("{home}/.config/autostart/"),
    ];
    let lower = path.to_lowercase();
    if blocked_suffixes.iter().any(|s| path.ends_with(s))
        || blocked_dirs.iter().any(|d| path.starts_with(d.as_str()))
        || lower.contains("/launchdaemons/")
    {
        return Err("refused: writing to a sensitive system location is not allowed".into());
    }
    Ok(())
}

#[tauri::command(async)]
pub(crate) fn write_text_file(path: String, contents: String) -> Result<(), String> {
    let _serial = crate::vaultio::serial();
    reject_sensitive_write(&path)?;
    fs::write(&path, contents).map_err(|e| format!("write {path}: {e}"))
}
#[tauri::command(async)]
pub(crate) fn read_text_file(path: String) -> Result<String, String> {
    reject_sensitive_read(&path)?;
    read_to_string_retry(&path).map_err(|e| format!("read {path}: {e}"))
}

/// Append pasted-attachment index records (one JSON object per image) to the
/// shared ledger <vault>/build/_meta/attachments/index.jsonl. Written at SEND
/// time, when the conversation context (domain/thread/session/message) is
/// known, with vault-RELATIVE file paths so records survive the vault living
/// at different roots per machine. The engine's captioning pass reads and
/// enriches the same file.
#[tauri::command(async)]
pub(crate) fn attachments_index_append(
    vault: String,
    records: Vec<serde_json::Value>,
) -> Result<(), String> {
    let _serial = crate::vaultio::serial();
    if records.is_empty() {
        return Ok(());
    }
    let dir = Path::new(&vault).join("build").join("_meta").join("attachments");
    fs::create_dir_all(&dir).map_err(|e| format!("create attachments dir: {e}"))?;
    let file = dir.join("index.jsonl");
    let mut out = String::new();
    for r in &records {
        if r.get("file").and_then(|f| f.as_str()).map(|f| !f.trim().is_empty()) == Some(true) {
            out.push_str(&serde_json::to_string(r).map_err(|e| e.to_string())?);
            out.push('\n');
        }
    }
    if out.is_empty() {
        return Ok(());
    }
    use std::io::Write as _;
    let mut f = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&file)
        .map_err(|e| format!("open attachments index: {e}"))?;
    f.write_all(out.as_bytes()).map_err(|e| format!("append attachments index: {e}"))
}

/// Save an image pasted into a composer to the vault's attachments dir and
/// return its absolute path. The path is then attached to the turn like any
/// file attachment; the model reads it with its (multimodal) file tools. Only
/// well-known raster extensions are accepted and the decoded payload is capped
/// so a runaway clipboard can't fill the disk.
#[tauri::command(async)]
pub(crate) fn save_pasted_image(
    vault: String,
    data_base64: String,
    ext: String,
) -> Result<String, String> {
    use base64::Engine as _;
    const MAX_BYTES: usize = 15 * 1024 * 1024; // 15MB decoded
    let ext = ext.to_ascii_lowercase();
    if !matches!(ext.as_str(), "png" | "jpg" | "jpeg" | "gif" | "webp") {
        return Err(format!("unsupported image type: {ext}"));
    }
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(data_base64.as_bytes())
        .map_err(|e| format!("decode image: {e}"))?;
    if bytes.is_empty() {
        return Err("empty image".into());
    }
    if bytes.len() > MAX_BYTES {
        return Err(format!(
            "image too large ({} MB, max 15 MB)",
            bytes.len() / (1024 * 1024)
        ));
    }
    let dir = Path::new(&vault).join("build").join("_meta").join("attachments");
    fs::create_dir_all(&dir).map_err(|e| format!("create attachments dir: {e}"))?;
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    let file = dir.join(format!("pasted-{stamp}.{ext}"));
    fs::write(&file, &bytes).map_err(|e| format!("write image: {e}"))?;
    Ok(file.to_string_lossy().to_string())
}

// Diagnostics for the About → Run Diagnosis / Debug Dump panel. Gathers the
// app + engine versions, key paths, and OS so support issues are one copy away.
#[tauri::command(async)]
pub(crate) fn app_diagnostics() -> serde_json::Value {
    let home = std::env::var("HOME").unwrap_or_default();
    let engine_bin = engine::resolve_prevail_bin();
    let engine_version = std::process::Command::new(&engine_bin)
        .arg("--version")
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .filter(|s| !s.is_empty());
    serde_json::json!({
        "desktop_version": env!("CARGO_PKG_VERSION"),
        "engine_bin": engine_bin,
        "engine_version": engine_version,
        "engine_bundled": engine_bin.contains(".app/Contents/MacOS"),
        "os": std::env::consts::OS,
        "arch": std::env::consts::ARCH,
        "app_support": format!("{home}/Library/Application Support/sh.prevail.desktop"),
        "home": home,
    })
}

// (close-to-tray flag moved to settings.rs)

// Uninstall — spawns a detached cleanup script (so it can delete the running
// app bundle after we quit) and exits. scope "app" removes just the .app;
// "data" also removes app data, caches, and stored secrets. The user's VAULT
// is NEVER touched (hard rule: never delete user data).
#[tauri::command(async)]
pub(crate) fn app_uninstall(app: tauri::AppHandle, scope: String) -> Result<(), String> {
    let home = std::env::var("HOME").unwrap_or_default();
    let mut script = String::from("#!/bin/bash\nsleep 2\n");
    if scope == "data" {
        // G11: the Tauri dirs below do NOT cover the engine's machine-local
        // secrets under ~/.prevail — OAuth refresh tokens (every connector), the
        // MCP server token, the Telegram bot token, app config, the passcode
        // verifier, and session caches. Without this they survive a "remove all
        // data and secrets" uninstall. The engine's `reset` purges exactly those
        // while PRESERVING the vault (and an encrypted vault's keyring), so we
        // delegate rather than rm -rf ~/.prevail (which could nuke a default-
        // located vault). Best-effort: a missing/unrunnable sidecar is a no-op.
        let _ = crate::engine::run_engine_json(&["reset", "--yes"]);
        for p in [
            format!("{home}/Library/Application Support/sh.prevail.desktop"),
            format!("{home}/Library/WebKit/sh.prevail.desktop"),
            format!("{home}/Library/Caches/sh.prevail.desktop"),
            format!("{home}/Library/Caches/prevail-desktop"),
            format!("{home}/Library/WebKit/prevail-desktop"),
        ] {
            script.push_str(&format!("rm -rf \"{p}\"\n"));
        }
        // Stored secrets (best-effort; one item per call).
        script.push_str("security delete-generic-password -s prevail.providers >/dev/null 2>&1\n");
        script.push_str("security delete-generic-password -s prevail.ingestion >/dev/null 2>&1\n");
    }
    // The bundle is "Glyph Studio.app" on a fresh install and stays "Prevail.app"
    // on one updated in place from Prevail (same bundle id, same app).
    script.push_str("rm -rf \"/Applications/Glyph Studio.app\" \"/Applications/Prevail.app\"\n");
    let tmp = std::env::temp_dir().join("prevail-uninstall.sh");
    fs::write(&tmp, &script).map_err(|e| format!("write uninstaller: {e}"))?;
    std::process::Command::new("bash")
        .arg(tmp.to_string_lossy().to_string())
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .map_err(|e| format!("spawn uninstaller: {e}"))?;
    app.exit(0);
    Ok(())
}

// read_memory_md lives in idealstate.rs.

#[tauri::command(async)]
pub(crate) fn write_paste_attachment(vault: String, body: String) -> Result<String, String> {
    let dir = PathBuf::from(&vault).join("_paste");
    fs::create_dir_all(&dir).map_err(|e| format!("mkdir _paste: {e}"))?;
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let (y, m, d, hh, mm, ss) = secs_to_ymdhms(now as i64);
    let name = format!("{y:04}-{m:02}-{d:02}_{hh:02}-{mm:02}-{ss:02}.txt");
    let p = dir.join(&name);
    crate::vaultio::write_atomic(&p, &body).map_err(|e| format!("write paste: {e}"))?;
    Ok(p.to_string_lossy().to_string())
}

/// C4: save a recorded voice memo (base64 audio) under <vault>/_voice and return
/// the path. Fallback capture for platforms without the Web Speech API (the
/// desktop WKWebView): we can still record + keep the audio even if we can't
/// transcribe it live. Type-guarded to common recorder outputs; 50 MB cap.
#[tauri::command(async)]
pub(crate) fn write_voice_note(vault: String, base64: String, ext: String) -> Result<String, String> {
    use ::base64::Engine as _;
    let ext = ext.to_lowercase();
    if !matches!(ext.as_str(), "webm" | "mp4" | "m4a" | "ogg" | "wav") {
        return Err(format!("unsupported audio type: {ext}"));
    }
    let bytes = ::base64::engine::general_purpose::STANDARD
        .decode(base64.trim())
        .map_err(|e| format!("decode audio: {e}"))?;
    if bytes.len() > 50 * 1024 * 1024 {
        return Err("recording is larger than 50 MB".into());
    }
    let dir = PathBuf::from(&vault).join("_voice");
    fs::create_dir_all(&dir).map_err(|e| format!("mkdir _voice: {e}"))?;
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let (y, m, d, hh, mm, ss) = secs_to_ymdhms(now as i64);
    let name = format!("{y:04}-{m:02}-{d:02}_{hh:02}-{mm:02}-{ss:02}.{ext}");
    let p = dir.join(&name);
    fs::write(&p, &bytes).map_err(|e| format!("write audio: {e}"))?;
    Ok(p.to_string_lossy().to_string())
}

// Save a chat session as a markdown transcript under <domain>/_log/.
// Filename format: YYYY-MM-DD_HH-MM-SS_session.md so directory listings
// sort newest-last and the user can scan when each happened. Nothing is
// thrown away — every prompt + reply is appended.
#[derive(Deserialize)]
pub struct SessionTurn {
    pub role: String,
    pub cli: Option<String>,
    pub model: Option<String>,
    pub content: String,
}
#[tauri::command(async)]
pub(crate) fn save_session(
    vault: String,
    domain: Option<String>,
    title: Option<String>,
    turns: Vec<SessionTurn>,
) -> Result<String, String> {
    let _serial = crate::vaultio::serial();
    if turns.is_empty() {
        return Err("session is empty".into());
    }
    let log_dir = safe_domain_subdir(&vault, &domain, "_log")?;
    fs::create_dir_all(&log_dir).map_err(|e| format!("mkdir _log: {e}"))?;
    // Use chrono-free timestamp by formatting from std time.
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    // YYYY-MM-DD_HH-MM-SS via a tiny formatter.
    let secs = now as i64;
    let (year, month, day, hh, mm, ss) = secs_to_ymdhms(secs);
    let stem = format!("{year:04}-{month:02}-{day:02}_{hh:02}-{mm:02}-{ss:02}");
    // Two saves within the same second (e.g. an auto-save racing a manual
    // "save & clear") would otherwise collide on the same filename. Add a
    // numeric suffix so neither is silently overwritten. (feedback v0.4.1 B10)
    let mut file = log_dir.join(format!("{stem}_session.md"));
    let mut dup = 2;
    while file.exists() {
        file = log_dir.join(format!("{stem}-{dup}_session.md"));
        dup += 1;
    }
    let mut body = String::new();
    body.push_str("---\n");
    if let Some(t) = &title { body.push_str(&format!("title: {t}\n")); }
    if let Some(d) = &domain { body.push_str(&format!("domain: {d}\n")); }
    body.push_str(&format!("turns: {}\n", turns.len()));
    body.push_str("---\n\n");
    for t in &turns {
        let speaker = if t.role == "user" {
            "You".to_string()
        } else {
            let cli = t.cli.as_deref().unwrap_or("assistant");
            let model = t.model.as_deref().map(|m| format!(" · {m}")).unwrap_or_default();
            format!("{cli}{model}")
        };
        body.push_str(&format!("## {speaker}\n\n{}\n\n", t.content.trim()));
    }
    crate::vaultio::write_atomic(&file, &body).map_err(|e| format!("write session: {e}"))?;

    // Append a one-line summary to _journal.md so the user has a
    // running record of every session without having to open _log/.
    if domain.is_some() {
        // v4-aware + resolved: the running-record journal belongs in the domain's
        // journal (memory/journal.md on a migrated domain), not a stray
        // <vault>/<domain>/_journal.md at the vault root.
        let journal_path = crate::paths::v4_content_path(
            &crate::paths::domain_dir(&vault, &domain),
            "memory/journal.md",
            "_journal.md",
        );
        let first_user = turns.iter()
            .find(|t| t.role == "user")
            .map(|t| t.content.lines().next().unwrap_or("").trim().to_string())
            .unwrap_or_else(|| title.clone().unwrap_or_else(|| "session".into()));
        let truncated: String = first_user.chars().take(140).collect();
        let entry = format!(
            "- {year:04}-{month:02}-{day:02} {hh:02}:{mm:02} · [{file}](_log/{file}) · {turns} turns · {snippet}\n",
            year = year, month = month, day = day, hh = hh, mm = mm,
            file = file.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default(),
            turns = turns.len(),
            snippet = truncated,
        );
        let existing = read_to_string_retry(&journal_path).unwrap_or_else(|_| "# Journal\n\n".into());
        let merged = if existing.contains("# Journal") {
            format!("{existing}{entry}")
        } else {
            format!("# Journal\n\n{entry}")
        };
        let _ = crate::vaultio::write_atomic(&journal_path, &merged);
    }
    Ok(file.to_string_lossy().to_string())
}

// Days-since-epoch → date. Good enough for log filenames, no chrono.
pub(crate) fn secs_to_ymdhms(secs: i64) -> (i32, u32, u32, u32, u32, u32) {
    let day_secs = 86_400i64;
    let mut days = secs.div_euclid(day_secs);
    let mut rem = secs.rem_euclid(day_secs);
    let hh = (rem / 3600) as u32; rem %= 3600;
    let mm = (rem / 60) as u32;
    let ss = (rem % 60) as u32;
    // Convert days from 1970-01-01 to ymd (Gregorian).
    let mut year = 1970i32;
    loop {
        let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;
        let ydays = if leap { 366 } else { 365 };
        if days < ydays as i64 { break; }
        days -= ydays as i64;
        year += 1;
    }
    let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;
    let month_lens = if leap {
        [31u32,29,31,30,31,30,31,31,30,31,30,31]
    } else {
        [31u32,28,31,30,31,30,31,31,30,31,30,31]
    };
    let mut month = 0u32;
    for (i, &ml) in month_lens.iter().enumerate() {
        if days < ml as i64 { month = i as u32 + 1; break; }
        days -= ml as i64;
    }
    let day = days as u32 + 1;
    (year, month, day, hh, mm, ss)
}
