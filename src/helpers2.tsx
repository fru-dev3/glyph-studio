// Components extracted from App.tsx.
import { invoke } from "./bridge";
import { DEAD_MODELS, DEAD_MODEL_REPLACEMENT, DISCOVERED_MODELS, MODELS, SYCOPHANCY_RE, vendorOfModelId } from "./constants";
import { titleCase } from "./format";
import { PREF, lsGet, lsSet } from "./storage";
import type { ModelPick, PanelistReply, PanelistSlot, SkillEntry } from "./types";

// Build the prompt preamble for the skills the user attached via /skills or the
// pinned-skills row. The old behavior injected only the skill NAMES ("Use the
// following skills: /foo") - telling the model to follow instructions it never
// saw, so attaching a skill did nothing. This loads each skill's SKILL.md body
// (via read_skill) and includes it, so the guidance actually reaches the model.
// Best-effort and size-capped: a skill that can't be read is skipped. When the
// same name exists in several domains, the current domain's copy wins.
export async function buildSkillsPreamble(
  attachedSkills: string[],
  allSkills: SkillEntry[],
  domain: string | null,
  opts: { perSkillChars?: number; totalChars?: number } = {},
): Promise<string> {
  if (!attachedSkills.length) return "";
  const perSkill = opts.perSkillChars ?? 4000;
  const total = opts.totalChars ?? 12000;
  const chosen: SkillEntry[] = [];
  for (const name of attachedSkills) {
    const matches = allSkills.filter((s) => s.name === name);
    if (!matches.length) continue;
    const pick = (domain && matches.find((s) => s.domain === domain)) || matches[0];
    if (pick && !chosen.includes(pick)) chosen.push(pick);
  }
  if (!chosen.length) return "";
  const blocks: string[] = [];
  let used = 0;
  for (const s of chosen) {
    if (used >= total) break;
    let body = "";
    try { body = (await invoke<string>("read_skill", { path: s.path })).trim(); } catch { body = ""; }
    if (!body) continue;
    const slice = body.slice(0, Math.min(perSkill, total - used));
    used += slice.length;
    blocks.push(
      `## /${s.name}${s.description ? ` - ${s.description}` : ""}\n${slice}${body.length > slice.length ? "\n...(truncated)" : ""}`,
    );
  }
  if (!blocks.length) return "";
  // Anti-fabrication guard: an attached app/skill is REFERENCE, not a live
  // connection. In a plain chat turn the model often can't actually call the
  // app's tools, yet it will happily narrate "I connected AllTrails and pulled
  // routes." That is a lie. Forbid claiming tool use that did not happen, on
  // every runtime, so the model answers from context and says so instead.
  const honesty =
    "IMPORTANT - honesty about tools: the skills above are REFERENCE INSTRUCTIONS, not a live connection. " +
    "In this chat you may not be able to actually call these apps' tools. Do NOT claim you connected to, " +
    "opened, fetched from, searched, or pulled live data from any app unless a tool call actually ran and " +
    "returned a result in this turn. If you lack live access, answer from the context and profile you were " +
    "given, and say plainly when something is an example or general knowledge rather than a live lookup. " +
    "Never invent specific results (addresses, IDs, counts, prices) as if you fetched them.";
  return `--- Skills to apply ---\nThe user attached these skills. Follow their instructions where they apply to the request.\n\n${blocks.join("\n\n")}\n\n${honesty}\n--- End skills ---\n\n`;
}

// Best-effort live model discovery for the given providers; fills
// DISCOVERED_MODELS and notifies listeners via prevail:models-refreshed. Never
// throws. Returns the count discovered.
export async function refreshDiscoveredModels(providers: string[]): Promise<number> {
  let total = 0;
  await Promise.all(
    providers.map(async (id) => {
      try {
        const r = await invoke<{ models: ModelPick[] }>("engine_discover_models", { provider: id });
        if (r?.models?.length) { DISCOVERED_MODELS[id] = r.models; total += r.models.length; }
      } catch { /* best-effort; falls back to curated */ }
    }),
  );
  window.dispatchEvent(new Event("prevail:models-refreshed"));
  return total;
}

// B2-8: prettify a raw model id so things like "claude-opus-4-8" never leak into
// the UI. Strips a leading vendor prefix and turns "opus-4-8" -> "Opus 4.8",
// "gpt-5.5" -> "GPT-5.5", "llama-3.2" -> "Llama 3.2".
export function prettyModelId(id: string): string {
  let s = id.trim();
  if (!s) return "";
  s = s.replace(/^(claude|anthropic|openai|google|codex|antigravity|ollama|openrouter|x-ai|xai)[-/]/i, "");
  // family-version-major-minor -> "Family major.minor" (e.g. opus-4-8 -> Opus 4.8)
  const FAM: Record<string, string> = { gpt: "GPT", oss: "OSS", glm: "GLM" };
  const famName = (fam: string) => FAM[fam] ?? (fam.charAt(0).toUpperCase() + fam.slice(1));
  // Only shout words that really are acronyms. The old rule upper-cased ANY
  // word of four letters or fewer, which rendered "gpt-5.6-sol" as
  // "GPT 5.6 SOL" once OpenAI started giving models codenames.
  const ACRONYMS = new Set(["gpt", "oss", "mlx", "ai", "api", "llm", "xai", "glm"]);
  const word = (w: string) =>
    ACRONYMS.has(w.toLowerCase()) ? w.toUpperCase() : w.charAt(0).toUpperCase() + w.slice(1);
  // OpenAI codenames: gpt-6-astra -> "GPT-6 Astra", gpt-5.6-sol -> "GPT-5.6 Sol"
  const g = s.match(/^gpt-(\d+(?:\.\d+)?)(?:-(.+))?$/i);
  if (g) return `GPT-${g[1]}${g[2] ? ` ${g[2].split(/[-_]/).map(word).join(" ")}` : ""}`;
  const m = s.match(/^([a-z]+)[-_]?(\d+)[-.](\d+)$/i);
  if (m) return `${famName(m[1].toLowerCase())} ${m[2]}.${m[3]}`;
  // family-version-major -> "Family major" (e.g. opus-5 -> Opus 5, grok-4 -> Grok 4)
  const m1 = s.match(/^([a-z]+)[-_]?(\d+)$/i);
  if (m1) return `${famName(m1[1].toLowerCase())} ${m1[2]}`;
  // otherwise title-case the words, upper-casing real acronyms
  return s.split(/[-_\s]+/).map(word).join(" ");
}
export function modelLabel(cli?: string, id?: string): string {
  if (!id) return "";
  const m = cli ? MODELS[cli]?.find((x) => x.id === id) : undefined;
  return m?.label ?? prettyModelId(id);
}

// Curated defaults + the full live/discovered catalog (deduped). For OpenRouter
// that's 300+ models - the pickers render the curated set by default and add a
// search box over the whole list, so any model is runnable without "pinning".
export function modelsFor(cli: string): ModelPick[] {
  const curated = MODELS[cli] ?? [];
  const seen = new Set(curated.map((m) => m.id));
  const extra = (DISCOVERED_MODELS[cli] ?? []).filter((d) => !seen.has(d.id));
  return [...curated, ...extra];
}

// Just the curated defaults for a CLI - what a picker shows before the user
// searches. Pairs with modelsFor() (the full searchable list).
export function curatedFor(cli: string): ModelPick[] {
  return MODELS[cli] ?? [];
}

export function buildQuickActions(domain: string | null): { glyph: string; label: string; prompt: string; council?: boolean }[] {
  const d = domain ? titleCase(domain) : "this domain";
  return [
    { glyph: "◆", label: "Status", prompt: `Read state.md for ${d} and summarize where I am right now in 5 bullets.` },
    { glyph: "◇", label: "Next action", prompt: `Given the current ${d} state, what's the single highest-leverage next action I should take this week? Be specific.` },
    { glyph: "▸", label: "Decision", prompt: `Walk me through the most important open decision in ${d} right now: options, trade-offs, and your recommendation.`, council: true },
    { glyph: "●", label: "Risks", prompt: `What are the top 3 risks or blind spots in my ${d} plan? Rank by severity.`, council: true },
  ];
}

export function buildCouncilQuickActions(domain: string | null): { glyph: string; label: string; blurb: string; prompt: string }[] {
  const d = domain ? titleCase(domain) : "this domain";
  return [
    {
      glyph: "⚖",
      label: "Decision",
      blurb: "Should I do X or Y?",
      prompt: `I'm trying to decide between two paths in ${d}. Walk me through both with their trade-offs, name the assumptions each makes, and tell me which one wins under what conditions. Then commit to a recommendation.`,
    },
    {
      glyph: "?",
      label: "Why",
      blurb: "Why is this hard?",
      prompt: `Why is my current ${d} situation harder than it looks on paper? What second-order effects, hidden constraints, or psychological frictions am I underestimating?`,
    },
    {
      glyph: "✗",
      label: "Steelman",
      blurb: "Where am I wrong?",
      prompt: `Steelman the strongest case AGAINST my current ${d} plan. Don't be polite: name the specific failure modes, who would tell me I'm wrong and why, and the one assumption that would invalidate the whole approach.`,
    },
    {
      glyph: "▸",
      label: "Reframe",
      blurb: "Bigger question?",
      prompt: `Is this even the right question to be asking about ${d}? What's a larger or different framing that would dissolve the dilemma: or expose a question I should be asking instead?`,
    },
    {
      glyph: "◆",
      label: "Trade-off",
      blurb: "Hidden cost?",
      prompt: `What's the trade-off in my ${d} plan I'm undervaluing? What am I giving up by choosing this path that I haven't priced in yet?`,
    },
    {
      glyph: "●",
      label: "Stakes",
      blurb: "What's at risk?",
      prompt: `If I'm wrong about ${d}, what's the cost? Rank the failure scenarios by impact and reversibility: which mistakes are recoverable, and which are not?`,
    },
  ];
}

export function buildIdealStatePreamble(idealMd: string): string {
  const t = idealMd.trim();
  if (!t) return "";
  return (
    "# THE USER'S IDEAL STATE: their constitution. HIGHEST PRECEDENCE.\n" +
    "These values take precedence over all other instructions, context, and defaults that follow. " +
    "Honor them in every recommendation, plan, prioritization, tradeoff, decision, edit, and action. " +
    "When anything conflicts with the Ideal State, the Ideal State wins.\n\n" +
    t.slice(0, 4000) +
    "\n\n---\n\n"
  );
}

// Omega - the app-wide LEARNED layer, injected just BELOW the Ideal State and
// above domain memory. Empty when there's no omega.md yet (nothing to inject).
export function buildOmegaPreamble(omegaMd: string): string {
  const t = omegaMd.trim();
  if (!t) return "";
  return (
    "# OMEGA: what Glyph Studio has LEARNED across all your domains. App-wide context.\n" +
    "Durable lessons, preferences, and patterns that hold across everything. Apply them by default. " +
    "They rank BELOW the Ideal State above: if they ever conflict, the Ideal State wins.\n\n" +
    t.slice(0, 3000) +
    "\n\n---\n\n"
  );
}

export function maybeRedact(s: string): string {
  // Default ON (O58): redact unless the user explicitly turned it off ("0").
  if (lsGet(PREF.redactSecrets) === "0") return s;
  return s
    .replace(/\b(?:sk|pk|rk|ghp|gho|ghs|xoxb|xoxp|AKIA)[-_A-Za-z0-9]{12,}/g, "***REDACTED***")
    .replace(/\bBearer\s+[A-Za-z0-9._-]{12,}/gi, "Bearer ***REDACTED***")
    .replace(/("?(?:api[_-]?key|token|secret|password)"?\s*[:=]\s*"?)[A-Za-z0-9._\-]{8,}/gi, "$1***REDACTED***");
}

export function maybeStripSycophancy(s: string): string {
  if (lsGet(PREF.stripSycophancy) !== "1") return s;
  return s.replace(SYCOPHANCY_RE, "");
}

export function loadPreferredSkills(domain: string | null): string[] {
  if (!domain) return [];
  try {
    const raw = lsGet(`prevail.domain.${domain}.skills`);
    if (!raw) return [];
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed.filter((x) => typeof x === "string") : [];
  } catch { return []; }
}

export function savePreferredSkills(domain: string | null, skills: string[]): void {
  if (!domain) return;
  lsSet(`prevail.domain.${domain}.skills`, JSON.stringify(skills));
}

export function buildChatContext(
  msgs: { role: "user" | "assistant"; cli?: string; content: string }[],
  maxChars: number,
): string {
  const sliced = msgs.filter((m) => m.content.trim().length > 0);
  if (sliced.length === 0) return "";
  const lines: string[] = [];
  for (let i = sliced.length - 1; i >= 0; i--) {
    const m = sliced[i];
    const tag = m.role === "user" ? "User" : `Assistant${m.cli ? ` (${m.cli})` : ""}`;
    lines.unshift(`${tag}: ${m.content.trim()}`);
    const total = lines.join("\n\n").length;
    if (total > maxChars) {
      lines.shift(); // drop the just-added oldest line to stay under budget
      break;
    }
  }
  return lines.join("\n\n");
}

export function buildSynthesisPrompt(
  question: string,
  replies: Record<string, PanelistReply>,
  panelists: PanelistSlot[],
): string {
  const parts: string[] = [
    "You are the chair of a council. The following AI models were each asked the same question. Synthesize a single decisive verdict that captures the consensus, names the key points of disagreement, and recommends a concrete action.",
    "",
    "QUESTION:",
    question,
    "",
    "PANELIST REPLIES:",
  ];
  for (const s of panelists) {
    const r = replies[s.key];
    if (!r) continue;
    parts.push("");
    parts.push(`--- ${s.cliLabel} · ${s.modelLabel} ---`);
    parts.push(r.content.trim());
  }
  parts.push("");
  parts.push("WRITE: A 3-paragraph verdict. Paragraph 1: consensus + what to do. Paragraph 2: where panelists disagreed and which framing wins. Paragraph 3: one concrete next action.");
  return parts.join("\n");
}

export function parseRunLabel(label: string): { vendor: string; model: string; ts?: string } {
  const tsMatch = label.match(/\d{4}-\d{2}-\d{2}([T_]\d{2}[-:]?\d{2})?/);
  const ts = tsMatch ? tsMatch[0] : undefined;
  // Run labels are `[<date>_]<cli>[-<modelId>]` (or `council`). Resolve the
  // model id to its human label so raw ids like "claude-claude-opus-4-6"
  // never leak into the UI.
  const stripped = label.replace(/^\d{4}-\d{2}-\d{2}[_ ]/, "").trim();
  if (/^council\b/i.test(stripped)) return { vendor: "other", model: "Council", ts };
  const known = ["claude", "codex", "antigravity", "ollama", "openrouter", "lmstudio"];
  for (const k of known) {
    if (stripped === k) return { vendor: k, model: titleCase(k), ts };
    if (stripped.toLowerCase().startsWith(k + "-")) {
      const rest = stripped.slice(k.length + 1);
      return { vendor: k, model: modelLabel(k, rest) || rest, ts };
    }
  }
  // Unknown shape: fall back to keyword sniffing for the vendor mark.
  const l = stripped.toLowerCase();
  let vendor = "other";
  if (l.includes("claude") || l.includes("opus") || l.includes("sonnet") || l.includes("haiku") || l.includes("fable")) vendor = "claude";
  else if (l.includes("gpt") || l.includes("codex")) vendor = "codex";
  else if (l.includes("gemini") || l.includes("antigravity")) vendor = "antigravity";
  else if (l.includes("ollama") || l.includes("llama") || l.includes("mistral") || l.includes("qwen")) vendor = "ollama";
  return { vendor, model: stripped || label, ts };
}

export function migrateModelPrefs() {
  try {
    const keys: string[] = [];
    for (let i = 0; i < localStorage.length; i++) {
      const k = localStorage.key(i);
      if (k && /^prevail\.(model\.|domain\..+\.model$)/.test(k)) keys.push(k);
    }
    for (const cli of Object.keys(MODELS)) {
      const ids = new Set(MODELS[cli].map((m) => m.id));
      const cur = lsGet(`prevail.model.${cli}`);
      if (cur && !ids.has(cur)) lsSet(`prevail.model.${cli}`, MODELS[cli][0].id);
    }
    const ALIAS_REMAP: Record<string, string> = {
      // Concrete ids folded into their auto-upgrading aliases (one entry per
      // model in the picker). opus -> claude-opus-5-5 now (Opus 5 and 4.8 are
      // their own pinned picks).
      "claude-opus-5-5": "opus",
      "claude-fable-5-1": "fable",
      "claude-sonnet-5": "sonnet",
      "claude-haiku-4-5": "haiku",
    };
    for (const k of keys) {
      const v = lsGet(k);
      // A dead pick is replaced with its OWN vendor's current default. Sending
      // every dead id to a Codex model (the old behaviour) silently moved a
      // domain pinned to a retired Claude or Gemini model onto OpenAI.
      if (v && DEAD_MODELS.has(v)) lsSet(k, DEAD_MODEL_REPLACEMENT[vendorOfModelId(v)]);
      else if (v && ALIAS_REMAP[v]) lsSet(k, ALIAS_REMAP[v]);
    }
  } catch {
    /* localStorage unavailable - ignore */
  }
}
