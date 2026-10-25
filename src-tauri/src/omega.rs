// Omega — the app-wide LEARNED knowledge layer. A single `<vault>/omega.md`
// capturing durable, cross-cutting lessons / preferences / meta-patterns across
// EVERY domain + the app. The learned counterpart to ideal-state.md (which is
// authored). Injected into every model turn just BELOW the Ideal State (see
// cli-bridge findOmega on the engine side, and the desktop chat preamble).
// See docs/OMEGA-PLAN.md.

use std::fs;
use std::path::PathBuf;

use crate::engine;
use crate::paths::enumerate_domain_dirs;
use crate::{read_dir_retry, read_to_string_retry, secs_to_ymdhms};

// The distiller owns the text between these markers; everything above the start
// marker is the user's hand-authored region and is never touched.
const AUTO_START: &str = "<!-- omega:auto:start -->";
const AUTO_END: &str = "<!-- omega:auto:end -->";

/// Read `<vault>/omega.md`. Returns "" when absent — Omega is a LEARNED layer,
/// so a fresh vault has nothing to inject (no boilerplate template, unlike the
/// authored ideal-state.md). The UI shows an empty state + "Distill now".
#[tauri::command]
pub(crate) async fn read_omega(vault: String) -> Result<String, String> {
    let p = crate::idealstate::config_read_path(&vault, "omega.md");
    if !p.exists() {
        return Ok(String::new());
    }
    let raw = read_to_string_retry(&p).map_err(|e| e.to_string())?;
    Ok(engine::maybe_decrypt(&p, raw))
}

/// Write `<vault>/omega.md`, snapshotting the prior text into
/// _meta/omega-versions/ first (same safety as the constitution).
#[tauri::command(async)]
pub(crate) fn write_omega(vault: String, body: String) -> Result<(), String> {
    let _serial = crate::vaultio::serial();
    let p = crate::idealstate::config_write_path(&vault, "omega.md");
    if let Some(parent) = p.parent() { let _ = fs::create_dir_all(parent); }
    if let Ok(existing) = read_to_string_retry(&p) {
        let existing = engine::maybe_decrypt(&p, existing);
        if existing.trim() != body.trim() && !existing.trim().is_empty() {
            let vdir = crate::paths::build_root(&vault).join("_meta").join("omega-versions");
            let _ = fs::create_dir_all(&vdir);
            let secs = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs() as i64)
                .unwrap_or(0);
            let (y, mo, d, h, mi, s) = secs_to_ymdhms(secs);
            let vp = vdir.join(format!("{y:04}-{mo:02}-{d:02}_{h:02}{mi:02}{s:02}.md"));
            let _ = fs::write(&vp, engine::maybe_encrypt(&vp, &existing));
        }
    }
    fs::write(&p, engine::maybe_encrypt(&p, &body)).map_err(|e| format!("write omega.md: {e}"))
}

/// Dated snapshots of omega.md, newest first.
#[tauri::command(async)]
pub(crate) fn omega_versions(vault: String) -> Result<Vec<serde_json::Value>, String> {
    let vdir = crate::paths::build_root(&vault).join("_meta").join("omega-versions");
    let mut out = Vec::new();
    if let Ok(it) = read_dir_retry(&vdir) {
        for e in it.flatten() {
            let p = e.path();
            if p.extension().and_then(|s| s.to_str()) == Some("md") {
                out.push(serde_json::json!({
                    "name": p.file_stem().and_then(|s| s.to_str()).unwrap_or(""),
                    "path": p.to_string_lossy(),
                }));
            }
        }
    }
    out.sort_by(|a, b| b["name"].as_str().cmp(&a["name"].as_str()));
    Ok(out)
}

fn build_omega_prompt(ctx: &str) -> String {
    format!(
        "You are Prevail's meta-learning analyst. Below is what Prevail has learned in EACH of the \
user's life domains (distilled memory + key intents), grouped by domain.\n\n\
Your job: lift out ONLY the DURABLE, CROSS-CUTTING things that hold ACROSS domains or are global \
about the user / how they work — recurring preferences, decision patterns, working style, standing \
constraints, lessons that repeat. NOT domain-specific facts.\n\n\
Strict bar: include an item only if it is supported across 2+ domains OR is clearly a global \
preference/constraint. When in doubt, leave it out. Domain-specific detail stays in that domain.\n\n\
Return a SHORT markdown bullet list ONLY — no preamble, no headings, no code fences. 3-10 bullets, \
most important first, each one concrete line that is directly useful as standing guidance for every \
future answer (e.g. \"- Prefers terse, decision-first answers; skip caveats unless asked\").\n\n\
CONTEXT (per domain):\n{ctx}\n"
    )
}

/// Strip any accidental code fences / leading prose the model added, keeping the
/// bullet list. Caps length so the managed block can't balloon.
fn clean_block(out: &str) -> String {
    let mut t = out.trim();
    if let Some(rest) = t.strip_prefix("```markdown") { t = rest; }
    else if let Some(rest) = t.strip_prefix("```md") { t = rest; }
    else if let Some(rest) = t.strip_prefix("```") { t = rest; }
    let t = t.trim_end_matches("```").trim();
    // Keep only bullet lines (defensive: drop any stray prose the model prefixed).
    let bullets: Vec<&str> = t
        .lines()
        .map(|l| l.trim_end())
        .filter(|l| {
            let s = l.trim_start();
            s.starts_with("- ") || s.starts_with("* ") || s.starts_with("• ")
        })
        .collect();
    let body = if bullets.is_empty() { t.to_string() } else { bullets.join("\n") };
    body.chars().take(2800).collect()
}

/// Replace (or insert) the distiller-owned block, preserving the user's
/// hand-authored region above the start marker.
fn merge_managed(existing: &str, block: &str) -> String {
    let managed = format!(
        "{AUTO_START}\n## Learned across your domains (auto)\n_Distilled by Glyph Studio across all your domains. Edit anything ABOVE this line; this block is rewritten on each distill._\n\n{block}\n{AUTO_END}"
    );
    if let (Some(s), Some(e_rel)) = (existing.find(AUTO_START), existing.find(AUTO_END)) {
        let e = e_rel + AUTO_END.len();
        let before = existing[..s].trim_end();
        let after = existing[e..].trim_start();
        let mut o = String::new();
        o.push_str(before);
        if !before.is_empty() { o.push_str("\n\n"); }
        o.push_str(&managed);
        if !after.is_empty() { o.push_str("\n\n"); o.push_str(after); }
        o.push('\n');
        o
    } else {
        let trimmed = existing.trim_end();
        if trimmed.is_empty() { format!("{managed}\n") } else { format!("{trimmed}\n\n{managed}\n") }
    }
}

/// The reusable distillation core — called by the manual command (and, later,
/// the daemon). Reads each domain's distilled memory + the cross-domain intents,
/// runs ONE model pass that keeps only durable cross-cutting items, and writes
/// them into omega.md's managed block. Returns the full merged omega.md text.
pub(crate) async fn distill_omega_core(
    vault: &str,
    provider: &str,
    model: &str,
) -> Result<String, String> {
    let root = PathBuf::from(vault);
    let mut ctx = String::new();
    let mut domains_with_signal = 0;
    for (dom, dir) in enumerate_domain_dirs(&root) {
        let mut chunk = String::new();
        if let Ok(mem) = read_to_string_retry(&dir.join("_memory.md")) {
            let mem = engine::maybe_decrypt(&dir.join("_memory.md"), mem);
            let head: String = mem.trim().chars().take(1200).collect();
            if !head.trim().is_empty() {
                chunk.push_str(&format!("memory:\n{head}\n"));
            }
        }
        if !chunk.trim().is_empty() {
            domains_with_signal += 1;
            ctx.push_str(&format!("### domain: {dom}\n{chunk}\n"));
        }
    }
    // Cross-domain intents (titles + goals) add signal even before memory builds.
    if let Ok(raw) = read_to_string_retry(&crate::paths::build_root(vault).join("_meta").join("intents_distilled.json")) {
        let raw = engine::maybe_decrypt(&crate::paths::build_root(vault).join("_meta").join("intents_distilled.json"), raw);
        if let Ok(doc) = serde_json::from_str::<serde_json::Value>(&raw) {
            if let Some(arr) = doc.get("intents").and_then(|v| v.as_array()) {
                let mut lines = String::new();
                for it in arr.iter().take(12) {
                    let title = it.get("title").and_then(|v| v.as_str()).unwrap_or("");
                    let goal = it.get("goal").and_then(|v| v.as_str()).unwrap_or("");
                    if !title.is_empty() || !goal.is_empty() {
                        lines.push_str(&format!("- {title}: {goal}\n"));
                    }
                }
                if !lines.trim().is_empty() {
                    ctx.push_str(&format!("### cross-domain intents\n{lines}\n"));
                }
            }
        }
    }
    if ctx.trim().is_empty() || domains_with_signal == 0 {
        return Err("Not enough learned across your domains yet. Chat in a few domains (memory builds as you go), then distill.".into());
    }

    let ideal = crate::ideal_state_preamble(std::path::Path::new(vault));
    let prompt = format!("{ideal}{}", build_omega_prompt(&ctx));

    crate::bunker::guard_cli(provider)?;
    let model_opt = if model.is_empty() { None } else { Some(model) };
    let out = crate::telegram_bridge::run_cli(provider, model_opt, &prompt).await?;
    if out.trim().is_empty() {
        return Err("Omega distiller produced no output.".into());
    }
    let block = clean_block(&out);
    if block.trim().is_empty() {
        return Err("Omega distiller found nothing durable + cross-cutting yet.".into());
    }
    // omega.md lives in build/ on a migrated vault (read_omega/write_omega are
    // already build-aware); build_root() falls back to the vault root for legacy
    // flat vaults, so the distiller and the editor agree on one location.
    let p = crate::paths::build_root(vault).join("omega.md");
    let existing = read_to_string_retry(&p)
        .map(|raw| engine::maybe_decrypt(&p, raw))
        .unwrap_or_default();
    let merged = merge_managed(&existing, &block);
    fs::write(&p, engine::maybe_encrypt(&p, &merged)).map_err(|e| format!("write omega.md: {e}"))?;
    Ok(merged)
}

/// Distill omega.md from everything learned across the vault's domains. One model
/// pass (a cheap model is plenty). Returns the merged omega.md text.
#[tauri::command]
pub(crate) async fn omega_distill(
    vault: String,
    provider: String,
    model: String,
) -> Result<String, String> {
    distill_omega_core(&vault, &provider, &model).await
}
