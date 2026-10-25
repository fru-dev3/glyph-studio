// Memory watchdog: a background guard that keeps the app and the model
// subprocesses it spawns from exhausting machine memory and freezing the host.
//
// It is a SAFETY NET, not a throttle. It samples memory every few seconds and
// only acts when Prevail's TOTAL footprint (this process + every spawned engine
// /model subtree) crosses a high fraction of physical RAM. In normal use it
// never fires — a legitimate, concurrency-capped council stays well under the
// threshold. When a genuine runaway pushes the machine toward an out-of-memory
// freeze, it kills the single largest offending session subtree (reclaiming the
// most memory for the least disruption) and emits a `system:memory-warning`
// event the UI can surface.
//
// Because the killed session's engine is a direct child of THIS process, the
// desktop-side `child.wait()` in chat_send / benchmark returns when we kill it,
// so that session's normal chat:done / benchmark:done still fires and the UI
// recovers on its own. We kill the whole subtree (engine + model CLIs) with
// SIGKILL so memory is actually reclaimed and so model-CLI wrappers that ignore
// SIGTERM (e.g. gemini's launcher) cannot survive.

use std::collections::{HashMap, HashSet};
use std::time::Duration;
use tauri::{AppHandle, Emitter};

// How often to sample. One cheap `ps` call per tick; negligible overhead.
const POLL_SECS: u64 = 8;
// Fractions of physical RAM. WARN surfaces a heads-up; KILL reclaims memory.
const WARN_FRACTION: f64 = 0.50;
const KILL_FRACTION: f64 = 0.65;
// Clamp the kill ceiling so a tiny-RAM machine still gets a sane floor and a
// huge-RAM machine never lets one app eat everything before we step in.
const MIN_KILL_BYTES: u64 = 8 * 1024 * 1024 * 1024;
const MAX_KILL_BYTES: u64 = 48 * 1024 * 1024 * 1024;
// Only kill when a single tracked subtree accounts for at least this share of
// the footprint. If the footprint is high but no one subprocess dominates (e.g.
// the WebView itself), killing a small session would be futile, so we only warn.
const DOMINANCE: u64 = 4; // biggest_rss * 4 >= footprint  ==>  >= 25%

#[derive(Clone, serde::Serialize)]
struct MemoryWarning {
    kind: &'static str, // "warn" | "killed"
    session: Option<String>,
    footprint_mb: u64,
    limit_mb: u64,
    message: String,
}

// Total physical RAM in bytes (sysctl hw.memsize). Falls back to 16 GB.
fn physical_ram_bytes() -> u64 {
    std::process::Command::new("sysctl")
        .args(["-n", "hw.memsize"])
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .and_then(|s| s.trim().parse::<u64>().ok())
        .filter(|&b| b > 0)
        .unwrap_or(16 * 1024 * 1024 * 1024)
}

// One snapshot of every process: pid -> (ppid, rss_bytes). `ps` reports RSS in
// kilobytes on macOS.
fn process_table() -> HashMap<i32, (i32, u64)> {
    let mut table = HashMap::new();
    let out = match std::process::Command::new("ps")
        .args(["-axo", "pid=,ppid=,rss="])
        .output()
    {
        Ok(o) => o,
        Err(_) => return table,
    };
    let text = String::from_utf8_lossy(&out.stdout);
    for line in text.lines() {
        let mut it = line.split_whitespace();
        if let (Some(pid), Some(ppid), Some(rss)) = (it.next(), it.next(), it.next()) {
            if let (Ok(pid), Ok(ppid), Ok(rss_kb)) =
                (pid.parse::<i32>(), ppid.parse::<i32>(), rss.parse::<u64>())
            {
                table.insert(pid, (ppid, rss_kb * 1024));
            }
        }
    }
    table
}

// pid -> [child pids], derived from the ppid links.
fn children_of(table: &HashMap<i32, (i32, u64)>) -> HashMap<i32, Vec<i32>> {
    let mut kids: HashMap<i32, Vec<i32>> = HashMap::new();
    for (&pid, &(ppid, _)) in table {
        kids.entry(ppid).or_default().push(pid);
    }
    kids
}

// All pids in `root`'s subtree, inclusive.
fn subtree_pids(root: i32, kids: &HashMap<i32, Vec<i32>>) -> Vec<i32> {
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    let mut stack = vec![root];
    while let Some(p) = stack.pop() {
        if !seen.insert(p) {
            continue;
        }
        out.push(p);
        if let Some(cs) = kids.get(&p) {
            stack.extend(cs);
        }
    }
    out
}

fn rss_of(pids: &[i32], table: &HashMap<i32, (i32, u64)>) -> u64 {
    pids.iter().filter_map(|p| table.get(p).map(|&(_, r)| r)).sum()
}

pub fn start(app: AppHandle) {
    let ram = physical_ram_bytes();
    let kill_limit =
        ((ram as f64 * KILL_FRACTION) as u64).clamp(MIN_KILL_BYTES, MAX_KILL_BYTES);
    let warn_limit = ((ram as f64 * WARN_FRACTION) as u64).min(kill_limit);

    tauri::async_runtime::spawn(async move {
        // Suppress repeated warns until the footprint recovers below warn_limit.
        let mut warned = false;
        loop {
            tokio::time::sleep(Duration::from_secs(POLL_SECS)).await;
            let table = process_table();
            if table.is_empty() {
                continue;
            }
            let kids = children_of(&table);

            // Footprint = our own subtree (WebView + helpers) plus every tracked
            // engine session subtree, each pid counted once.
            let mut counted: HashSet<i32> = HashSet::new();
            let mut footprint: u64 = 0;
            let own = std::process::id() as i32;
            for p in subtree_pids(own, &kids) {
                if counted.insert(p) {
                    if let Some(&(_, r)) = table.get(&p) {
                        footprint += r;
                    }
                }
            }

            // Largest single tracked session subtree — the kill target.
            let mut biggest: Option<(String, i32, u64)> = None;
            for (key, pid) in crate::children::snapshot_children() {
                let pid = pid as i32;
                let pids = subtree_pids(pid, &kids);
                let rss = rss_of(&pids, &table);
                for p in &pids {
                    if counted.insert(*p) {
                        if let Some(&(_, r)) = table.get(p) {
                            footprint += r;
                        }
                    }
                }
                if biggest.as_ref().map(|b| rss > b.2).unwrap_or(true) {
                    biggest = Some((key, pid, rss));
                }
            }

            let gb = |b: u64| b as f64 / 1024.0 / 1024.0 / 1024.0;

            if footprint >= kill_limit {
                match biggest {
                    Some((key, pid, rss)) if rss.saturating_mul(DOMINANCE) >= footprint => {
                        // Kill the whole offending subtree so memory is actually
                        // reclaimed; SIGKILL because model-CLI wrappers can
                        // swallow SIGTERM.
                        for p in subtree_pids(pid, &kids) {
                            #[cfg(unix)]
                            unsafe {
                                libc::kill(p, libc::SIGKILL);
                            }
                        }
                        crate::children::unregister_child(&key);
                        let _ = app.emit(
                            "system:memory-warning",
                            MemoryWarning {
                                kind: "killed",
                                session: Some(key.clone()),
                                footprint_mb: footprint / 1024 / 1024,
                                limit_mb: kill_limit / 1024 / 1024,
                                message: format!(
                                    "Glyph Studio was using {:.1} GB and risked freezing your Mac, so the largest running task was stopped ({:.1} GB reclaimed). Your data is safe.",
                                    gb(footprint),
                                    gb(rss),
                                ),
                            },
                        );
                    }
                    _ => {
                        // High footprint but no single subprocess dominates —
                        // nothing safe to kill (likely the UI itself). Warn only.
                        if !warned {
                            let _ = app.emit(
                                "system:memory-warning",
                                MemoryWarning {
                                    kind: "warn",
                                    session: None,
                                    footprint_mb: footprint / 1024 / 1024,
                                    limit_mb: kill_limit / 1024 / 1024,
                                    message: format!(
                                        "Glyph Studio is using {:.1} GB. Consider closing a long conversation to free memory.",
                                        gb(footprint),
                                    ),
                                },
                            );
                        }
                    }
                }
                warned = true;
            } else if footprint >= warn_limit {
                if !warned {
                    let _ = app.emit(
                        "system:memory-warning",
                        MemoryWarning {
                            kind: "warn",
                            session: None,
                            footprint_mb: footprint / 1024 / 1024,
                            limit_mb: kill_limit / 1024 / 1024,
                            message: format!(
                                "Glyph Studio is using {:.1} GB. If it keeps climbing, the largest task will be stopped to protect your Mac.",
                                gb(footprint),
                            ),
                        },
                    );
                    warned = true;
                }
            } else {
                warned = false;
            }
        }
    });
}
