// Pure data constants extracted from App.tsx.
import type { Framework, Lens, ModelPick, Palette, ScoreBreakdown } from "./types";

// App version, injected by Vite at build time. Shared so any surface (the
// Bunker ribbon, the About section) shows the same string.
declare const __APP_VERSION__: string;
export const APP_VERSION = __APP_VERSION__;

export const DOMAIN_BLURBS: Record<string, string> = {
  wealth: "Your money, savings, and the path to financial freedom.",
  finance: "Your money, savings, and the path to financial freedom.",
  health: "Your energy, fitness, and long-term wellbeing.",
  fitness: "Your energy, fitness, and long-term wellbeing.",
  tax: "Filings, deadlines, and keeping more of what you earn.",
  taxes: "Filings, deadlines, and keeping more of what you earn.",
  career: "Your work, growth, and where you're headed next.",
  work: "Your work, growth, and where you're headed next.",
  business: "Your ventures, clients, and what you're building.",
  insurance: "Coverage, renewals, and protecting what matters.",
  estate: "Your legacy, documents, and looking after your people.",
  calendar: "What's coming up, and making time for what counts.",
  schedule: "What's coming up, and making time for what counts.",
  benefits: "Perks, plans, and everything your employer offers.",
  brand: "Your name, your voice, and how the world sees you.",
  content: "Ideas, posts, and the things you create.",
  "real-estate": "Property, home, and the roof over your head.",
  realestate: "Property, home, and the roof over your head.",
  home: "Your space, your projects, and daily life at home.",
  records: "Important documents, kept safe and easy to find.",
  vision: "The big picture: where you're going, and why.",
  social: "Friends, connections, and staying in touch.",
  family: "The people closest to you, and staying connected.",
  learning: "Skills, courses, and growing your mind.",
  learn: "Skills, courses, and growing your mind.",
  intel: "Research, signals, and staying in the know.",
  intelligence: "Research, signals, and staying in the know.",
  explore: "Curiosities, trips, and things worth discovering.",
  travel: "Curiosities, trips, and things worth discovering.",
  chief: "Your command center for today's priorities and what matters now.",
  mail: "Your inbox: important threads handled, noise filtered, nothing dropped.",
  email: "Your inbox: important threads handled, noise filtered, nothing dropped.",
  inbox: "Your inbox: important threads handled, noise filtered, nothing dropped.",
};
export const VENDOR_BRAND: Record<string, { hex: string; accent: string; name: string }> = {
  claude:      { hex: "#cc785c", accent: "#cc785c", name: "Anthropic Claude" },
  codex:       { hex: "#10a37f", accent: "#10a37f", name: "OpenAI Codex" },
  antigravity: { hex: "#ffffff", accent: "#4285f4", name: "Google Antigravity" },
  ollama:      { hex: "#0a0a0a", accent: "#6b7280", name: "Ollama (local)" },
  lmstudio:    { hex: "#4f46e5", accent: "#6366f1", name: "LM Studio (local)" },
  mlx:         { hex: "#1f2937", accent: "#9ca3af", name: "oMLX (local)" },
  openrouter:  { hex: "#6566f1", accent: "#6566f1", name: "OpenRouter" },
  // Additional CLI runtime families (shown in the Runtimes catalog so the user
  // can set them up). Brand-ish accents; monogram tiles render in marks.tsx.
  codebuddy:   { hex: "#1e6fff", accent: "#1e6fff", name: "Tencent CodeBuddy" },
  copilot:     { hex: "#0a0a0a", accent: "#8957e5", name: "GitHub Copilot" },
  opencode:    { hex: "#374151", accent: "#9ca3af", name: "OpenCode" },
  openclaw:    { hex: "#e5533c", accent: "#e5533c", name: "OpenClaw" },
  hermes:      { hex: "#111827", accent: "#a78bfa", name: "Hermes" },
  gemini:      { hex: "#ffffff", accent: "#4285f4", name: "Google Gemini" },
  pi:          { hex: "#0a0a0a", accent: "#f59e0b", name: "Pi" },
  cursor:      { hex: "#0a0a0a", accent: "#6b7280", name: "Cursor" },
  kimi:        { hex: "#111827", accent: "#7c3aed", name: "Kimi (Moonshot)" },
  kiro:        { hex: "#7c3aed", accent: "#a855f7", name: "Kiro" },
  paperclip:   { hex: "#0f766e", accent: "#14b8a6", name: "Paperclip" },
  motorcar:    { hex: "#9a3412", accent: "#f97316", name: "Multica AI" },
  other:       { hex: "#6b7280", accent: "#6b7280", name: "-" },
};

// Runtime catalog metadata. `category` separates the two kinds of runtime:
//   • "cli"     — a primary vendor coding-agent CLI (Claude Code, Codex, Gemini,
//                 Antigravity, …). These are the ones offered on the homepage
//                 composer picker.
//   • "harness" — a separate agent harness/wrapper that runs ON a base protocol
//                 (Pi, OpenCode, Hermes, OpenClaw, Paperclip, Motorcar). These
//                 are listed ONLY in the Runtimes catalog (their own group), never
//                 on the homepage.
// `protocol` is the base CLI protocol the runtime speaks (so dispatch can route to
// a known handler). `install` drives the "Set up" prompt. Detection: detect_clis.
// `cmd` (optional): a copy-paste install command for macOS, set ONLY where the
// exact command is known/safe — the UI shows a "Copy install command" button
// when present, and falls back to the docs link otherwise.
export const RUNTIME_META: Record<string, { blurb: string; install: string; protocol: "claude" | "codex" | "gemini" | "openai"; category: "cli" | "harness"; cmd?: string }> = {
  // ── Primary CLIs (homepage + catalog) ──
  claude:      { blurb: "Anthropic's agentic CLI.", install: "https://claude.com/claude-code", protocol: "claude", category: "cli", cmd: "npm install -g @anthropic-ai/claude-code" },
  codex:       { blurb: "OpenAI's coding agent CLI.", install: "https://developers.openai.com/codex/cli", protocol: "codex", category: "cli", cmd: "npm install -g @openai/codex" },
  antigravity: { blurb: "Google's agentic CLI (agy).", install: "https://antigravity.google", protocol: "gemini", category: "cli", cmd: "curl -fsSL https://antigravity.google/cli/install.sh | bash" },
  // ── Local model runtimes (on-device, no subscription) ──
  ollama:      { blurb: "Run open models locally with Ollama, private, offline, free.", install: "https://ollama.com/download", protocol: "openai", category: "cli", cmd: "brew install ollama" },
  lmstudio:    { blurb: "LM Studio: a local model server with a desktop GUI.", install: "https://lmstudio.ai", protocol: "openai", category: "cli", cmd: "brew install --cask lm-studio" },
  mlx:         { blurb: "Apple-silicon local inference via MLX.", install: "https://github.com/ml-explore/mlx", protocol: "openai", category: "cli", cmd: "pip install mlx-lm" },
  omlx:        { blurb: "Apple-silicon local inference via MLX (oMLX server).", install: "https://github.com/ml-explore/mlx", protocol: "openai", category: "cli", cmd: "pip install mlx-lm" },
  // ── Harnesses (catalog only, NOT homepage) ──
  opencode:    { blurb: "Open-source terminal coding harness.", install: "https://opencode.ai", protocol: "openai", category: "harness", cmd: "brew install opencode" },
  openclaw:    { blurb: "Claude-protocol gateway harness.", install: "https://github.com/openclaw/openclaw", protocol: "claude", category: "harness", cmd: "curl -fsSL https://openclaw.ai/install.sh | bash" },
  hermes:      { blurb: "Hermes agent harness.", install: "https://github.com/hermes-cli/hermes", protocol: "openai", category: "harness" },
  pi:          { blurb: "Pi agent harness.", install: "https://pi.ai", protocol: "openai", category: "harness", cmd: "npm install -g @earendil-works/pi-coding-agent" },
};

// Convenience: is this runtime id a harness (vs a primary CLI)? Unknown ids are
// treated as CLIs (the conservative homepage default).
export function isHarnessRuntime(id: string): boolean {
  return RUNTIME_META[id]?.category === "harness";
}
export const SEVERITY_ORDER: Record<string, number> = { critical: 0, warn: 1, info: 2 };
export const SEVERITY_LABEL: Record<string, string> = {
  critical: "Critical",
  warn: "Warnings",
  info: "Suggestions",
};
export const ANSI_RE = /\x1b\[[0-9;?]*[ -/]*[@-~]/g;
export const SYCOPHANCY_RE = /\b(you're absolutely right!?|you are absolutely right!?|great question!?|excellent question!?|that's a great point!?)\b\s*/gi;
export const SKILL_TOKEN_RE = /(^|\s)(\/[a-zA-Z][a-zA-Z0-9_-]*)/g;
export const DOMAIN_PALETTE = [
  "#cc785c", "#2d7fe4", "#5fae74", "#2dd4bf", "#a78bfa", "#e0823d",
  "#3fa6a0", "#c44e8a", "#7c83ff", "#6b8e23", "#d2674f", "#5b7a99",
];
export const INTEGRATION_LABEL: Record<string, string> = {
  api: "Direct API", oauth: "OAuth", browser: "Browser", mcp: "MCP server", manual: "Manual drop",
};
export const STATUS_TINT: Record<string, string> = { connected: "#2fb87a", expired: "#d8a657", error: "#e06c75", "not-configured": "#2fb87a" };
export const LOCAL_CLI_IDS = new Set(["ollama", "lmstudio", "mlx"]);

export const MODELS: Record<string, ModelPick[]> = {
  claude: [
    // "Auto" is a sentinel model id: the engine reads the prompt and routes it to
    // the best model in this runtime (see model-routing.ts). Listed first so it
    // reads as the smart default. Non-breaking: any other id is today's path.
    { id: "auto",            label: "Auto",      blurb: "route to the best model" },
    // Labels show the ACTUAL model name/version - no "latest" tag. The alias ids
    // (opus/sonnet/haiku) still resolve to the current release at runtime, so
    // these run the right model; bump the label when Anthropic ships a new one.
    // Claude Code exposes no machine-readable model list (verified), so this is a
    // curated list by necessity.
    { id: "opus",            label: "Opus 5.5",  blurb: "flagship · complex tasks", resolved: "claude-opus-5-5" },
    { id: "fable",           label: "Fable 5.1", blurb: "most capable · long-horizon work", resolved: "claude-fable-5-1" },
    { id: "claude-opus-5",   label: "Opus 5",    blurb: "previous flagship" },
    { id: "claude-opus-4-8", label: "Opus 4.8",  blurb: "legacy flagship" },
    { id: "claude-opus-4-7", label: "Opus 4.7",  blurb: "legacy flagship" },
    { id: "claude-opus-4-6", label: "Opus 4.6",  blurb: "legacy flagship" },
    { id: "claude-fable-5",  label: "Fable 5",   blurb: "previous frontier" },
    { id: "sonnet",          label: "Sonnet 5",  blurb: "balanced · efficient", resolved: "claude-sonnet-5" },
    { id: "haiku",           label: "Haiku 4.5", blurb: "fast + cheap", resolved: "claude-haiku-4-5" },
  ],
  codex: [
    // GPT-6 family: Astra (flagship, GA 2026-09-03), then Sol (everyday
    // default) and Luna (fastest/cheapest), both GA 2026-09-22. There is no
    // GPT-6 Terra, so GPT-5.6 Terra stays as the balanced tier. The older 5.6
    // tiers stay listed so a saved pick is never reset. Each accepts a reasoning
    // effort. The "@<effort>" suffix is parsed in cli_args() (lib.rs) into
    // `-c model_reasoning_effort=<effort>`; minimal effort 400s, so only
    // default / medium / high are offered.
    // NOTE on Codex-with-ChatGPT-login: which models this account accepts is
    // ACCOUNT-SPECIFIC. GPT-6 Sol/Astra/Luna are confirmed working on the
    // production Codex login (2026-09-25); some accounts return 400 "model not
    // supported" until the rollout reaches them (older codex CLIs / lower plan
    // tiers). The 5.6 tiers and gpt-5.5 are kept as fallbacks for those accounts.
    { id: "auto",             label: "Auto",              blurb: "route to the best model" },
    { id: "gpt-6-sol",        label: "GPT-6 Sol",         blurb: "Codex default · fast" },
    { id: "gpt-6-sol@medium", label: "GPT-6 Sol (medium)", blurb: "balanced reasoning" },
    { id: "gpt-6-sol@high",   label: "GPT-6 Sol (high)",  blurb: "more reasoning" },
    { id: "gpt-6-astra",      label: "GPT-6 Astra",       blurb: "flagship · most capable" },
    { id: "gpt-6-astra@high", label: "GPT-6 Astra (high)", blurb: "flagship · max reasoning" },
    { id: "gpt-6-luna",       label: "GPT-6 Luna",        blurb: "fastest · cheapest" },
    { id: "gpt-5.6-terra",    label: "GPT-5.6 Terra",     blurb: "balanced · lower cost" },
    { id: "gpt-5.6-terra@high", label: "GPT-5.6 Terra (high)", blurb: "balanced · more reasoning" },
    { id: "gpt-5.6-sol",      label: "GPT-5.6 Sol",       blurb: "previous default" },
    { id: "gpt-5.6-sol@medium", label: "GPT-5.6 Sol (medium)", blurb: "previous · balanced reasoning" },
    { id: "gpt-5.6-sol@high", label: "GPT-5.6 Sol (high)", blurb: "previous · max reasoning" },
    { id: "gpt-5.6-luna",     label: "GPT-5.6 Luna",      blurb: "previous fast tier" },
    { id: "gpt-5.5",          label: "GPT-5.5",           blurb: "previous flagship (fallback)" },
    { id: "gpt-5.5@high",     label: "GPT-5.5 (high)",    blurb: "previous · max reasoning" },
  ],
  antigravity: [
    { id: "auto",                         label: "Auto",                         blurb: "route to the best model" },
    { id: "Gemini 3.8 Flash (High)",      label: "Gemini 3.8 Flash (High)",      blurb: "newest · fast + reasoning" },
    { id: "Gemini 3.8 Flash (Medium)",    label: "Gemini 3.8 Flash (Medium)",    blurb: "balanced" },
    { id: "Gemini 3.8 Flash (Low)",       label: "Gemini 3.8 Flash (Low)",       blurb: "fastest" },
    { id: "Gemini 3.7 Flash (High)",      label: "Gemini 3.7 Flash (High)",      blurb: "previous generation" },
    { id: "Gemini 3.6 Flash (High)",      label: "Gemini 3.6 Flash (High)",      blurb: "older · stable" },
    { id: "Gemini 3.1 Pro (High)",        label: "Gemini 3.1 Pro (High)",        blurb: "pro tier · extra reasoning" },
    { id: "Gemini 3.1 Pro (Low)",         label: "Gemini 3.1 Pro (Low)",         blurb: "pro tier · less reasoning" },
    { id: "Claude Sonnet 4.6 (Thinking)", label: "Claude Sonnet 4.6 (Thinking)", blurb: "via Antigravity" },
    { id: "Claude Opus 4.6 (Thinking)",   label: "Claude Opus 4.6 (Thinking)",   blurb: "via Antigravity" },
    { id: "GPT-OSS 120B (Medium)",        label: "GPT-OSS 120B (Medium)",        blurb: "open model" },
  ],
  ollama: [
    { id: "auto",     label: "Auto",       blurb: "route to the best local model" },
    { id: "llama3.2", label: "Llama 3.2",  blurb: "local · meta" },
    { id: "qwen2.5",  label: "Qwen 2.5",   blurb: "local · alibaba" },
    { id: "mistral",  label: "Mistral 7B", blurb: "local · mistral" },
  ],
  openrouter: [
    // Ids verified live against openrouter.ai/api/v1/models on 2026-09-25. The
    // models they replaced stay at the bottom so a saved pick is never reset.
    { id: "anthropic/claude-opus-5.5",       label: "Claude Opus 5.5",   blurb: "flagship · via OpenRouter" },
    { id: "anthropic/claude-fable-5.1",      label: "Claude Fable 5.1",  blurb: "most capable · via OpenRouter" },
    { id: "anthropic/claude-sonnet-5",       label: "Claude Sonnet 5",   blurb: "via OpenRouter" },
    { id: "openai/gpt-6-astra",              label: "GPT-6 Astra",       blurb: "flagship · via OpenRouter" },
    { id: "openai/gpt-6-sol",                label: "GPT-6 Sol",         blurb: "via OpenRouter" },
    { id: "openai/gpt-6-luna",               label: "GPT-6 Luna",        blurb: "fast + cheap · via OpenRouter" },
    { id: "openai/gpt-5.6-terra",            label: "GPT-5.6 Terra",     blurb: "balanced · via OpenRouter" },
    { id: "google/gemini-3.8-flash",         label: "Gemini 3.8 Flash",  blurb: "via OpenRouter" },
    { id: "x-ai/grok-4.7",                   label: "Grok 4.7",          blurb: "via OpenRouter" },
    { id: "moonshotai/kimi-k3",              label: "Kimi K3",           blurb: "via OpenRouter" },
    { id: "deepseek/deepseek-v4-pro-0813",   label: "DeepSeek V4 Pro",   blurb: "via OpenRouter" },
    { id: "qwen/qwen3.8-max-prime",          label: "Qwen3.8 Max Prime", blurb: "via OpenRouter" },
    { id: "z-ai/glm-5.3-prime",              label: "GLM 5.3 Prime",     blurb: "via OpenRouter" },
    { id: "meta-llama/llama-4-maverick",     label: "Llama 4 Maverick",  blurb: "via OpenRouter" },
    { id: "anthropic/claude-opus-5",         label: "Claude Opus 5",     blurb: "previous · via OpenRouter" },
    { id: "openai/gpt-5.6-sol",              label: "GPT-5.6 Sol",       blurb: "previous · via OpenRouter" },
    { id: "openai/gpt-5.6-luna",             label: "GPT-5.6 Luna",      blurb: "previous · via OpenRouter" },
    { id: "x-ai/grok-4.6",                   label: "Grok 4.6",          blurb: "previous · via OpenRouter" },
    { id: "qwen/qwen3.8-max-0902",           label: "Qwen3.8 Max",       blurb: "previous · via OpenRouter" },
    { id: "z-ai/glm-5.3",                    label: "GLM 5.3",           blurb: "previous · via OpenRouter" },
  ],
};

export const DISCOVERED_MODELS: Record<string, ModelPick[]> = {};

// Model ids that no longer run anywhere: retired by the vendor, or dropped from
// a CLI's catalog. A saved pick (global or per-domain) pointing at one of these
// is healed on launch by migrateModelPrefs().
export const DEAD_MODELS = new Set([
  // OpenAI / Codex — gpt-5.4 and gpt-5.4-mini retired 2026-08-31.
  "gpt-5-codex", "gpt-5", "gpt-5-high", "gpt-5-mini", "gpt-5.1",
  "gpt-5.5-codex", "gpt-4o", "o3", "o4-mini",
  "gpt-5.2", "gpt-5.3-codex", "gpt-5.4", "gpt-5.4-mini",
  // Antigravity — 3.5 Flash left the `agy models` catalog.
  "Gemini 3.5 Flash (High)", "Gemini 3.5 Flash (Medium)", "Gemini 3.5 Flash (Low)",
]);

// Where each dead id goes when a saved pick is healed. Per-provider, because a
// domain-level pref records only the model id: sending a stale Claude or Gemini
// pin to a Codex model (the old behaviour) changed the domain's vendor.
export const DEAD_MODEL_REPLACEMENT: Record<string, string> = {
  claude: "opus",
  codex: "gpt-6-sol",
  antigravity: "Gemini 3.8 Flash (High)",
};

// Best-effort vendor guess for a bare model id, so a healed pick lands on the
// right provider's default.
export function vendorOfModelId(id: string): keyof typeof DEAD_MODEL_REPLACEMENT {
  const l = id.toLowerCase();
  if (/^gemini|^claude sonnet|^claude opus|^gpt-oss/.test(l)) return "antigravity";
  if (/claude|opus|sonnet|haiku|fable/.test(l)) return "claude";
  return "codex";
}

export const FRAMEWORKS: Framework[] = [
  { id: "none", label: "OFF", blurb: "No framework, model's default response shape", instruction: "" },
  { id: "bluf", label: "BLUF", blurb: "Bottom Line Up Front, lead with the answer", instruction: "Apply the BLUF framework. Your first sentence MUST be the bottom line: the single most important conclusion or recommendation. Then provide supporting context in 1-3 short paragraphs. Never bury the conclusion under context." },
  { id: "win", label: "WIN", blurb: "What's Important Now, name the ONE next move", instruction: "Apply the WIN (What's Important Now) framework. Identify the ONE most important next move the user should make. State that move in the first sentence. Drop everything that doesn't directly serve that next step." },
  { id: "scqa", label: "SCQA", blurb: "Situation → Complication → Question → Answer", instruction: "Structure your response as SCQA: a one-line Situation, a one-line Complication, a one-line Question, then a decisive Answer." },
  { id: "sbar", label: "SBAR", blurb: "Situation · Background · Assessment · Recommendation", instruction: "Structure your response as SBAR: Situation, Background, Assessment, Recommendation. Each in 1-2 lines max." },
  { id: "ooda", label: "OODA", blurb: "Observe → Orient → Decide → Act", instruction: "Structure your response as an OODA loop: Observe, Orient, Decide, Act. Each step labelled and one line." },
  { id: "proscons", label: "PROS/CONS", blurb: "Structured trade-off with weight", instruction: "Structure your response as a PROS/CONS analysis. Two columns. End with a one-line Weight verdict naming the winner." },
  { id: "steelman", label: "STEELMAN", blurb: "Strongest version of the other side first", instruction: "Steelman the opposing position first: give it the strongest framing you can. Then give your verdict." },
  { id: "go-nogo", label: "GO / NO-GO", blurb: "Rigorous analysis, then one committed verdict: GO or NO-GO", instruction: "Apply the GO / NO-GO framework for a decision. Do a rigorous, honest analysis: state the decision, the key evidence for and against, the biggest risks and unknowns, and what would change the answer. Then commit to ONE verdict - either GO or NO-GO, never both, never a maybe. Open with the verdict in bold (**GO** or **NO-GO**), one line of the single most important reason, then the supporting analysis, and end with the top 2-3 conditions or next steps that follow from it." },
];

export const LENSES: Lens[] = [
  { id: "none", label: "OFF", blurb: "No lens, single response, default angle", instruction: "" },
  { id: "first-principles", label: "FIRST PRINCIPLES", blurb: "Strip the problem to fundamentals", instruction: "Approach this problem from first principles. Forget conventional wisdom, prior advice, industry best practice, or what 'most people do.' Strip the problem to its fundamental mechanics and rebuild the answer from there." },
  { id: "outsider", label: "OUTSIDER", blurb: "Challenge the thinking; ignore prior context", instruction: "Approach this as a complete outsider with no prior context. Challenge every assumption that the question seems to bake in." },
  { id: "contrarian", label: "CONTRARIAN", blurb: "Argue the strongest case against the obvious answer", instruction: "Argue the strongest possible case against the obvious or expected answer. Don't be devil's advocate: actually pressure-test the consensus until something cracks." },
  { id: "expansionist", label: "EXPANSIONIST", blurb: "What's the bigger version of this question?", instruction: "Don't answer the question as asked. First ask: what's the bigger version of this question? Then answer THAT." },
  { id: "executor", label: "EXECUTOR", blurb: "Skip the framing, literal next step today", instruction: "Skip all framing. The user wants the literal next step they should take today. State the action in one imperative sentence, then list 2-3 concrete tasks." },
  { id: "alien", label: "ALIEN", blurb: "An outsider notices what's obvious to you", instruction: "You are an alien observer with no familiarity with this user's biases. State what is plainly obvious about their situation that they themselves are too close to see." },
  { id: "mom", label: "MOM", blurb: "Plain English, what would she actually do?", instruction: "Answer as a wise mom would: plain English, no jargon, sentimentally honest, practical. What would she actually tell her child to do?" },
  { id: "dad", label: "DAD", blurb: "Hard-nosed, what's the trap you're not seeing?", instruction: "Answer as a hard-nosed dad would: direct, no coddling. Name the trap the user is not seeing. Tell them what they will regret in 10 years if they get this wrong." },
];

export const PALETTES: { id: Palette; name: string; blurb: string; swatch: { bg: string; surface: string; accent: string; ai: string } }[] = [
  { id: "prevail",   name: "Glyph",          blurb: "Office green and cyan on graphite",                 swatch: { bg: "#0a0a0c", surface: "#141416", accent: "#2e9e2e", ai: "#3cd8ff" } },
  { id: "vault",     name: "Vault",     blurb: "Cream + teal, focused, calm",                       swatch: { bg: "#faf8f1", surface: "#ffffff", accent: "#0d7a6e", ai: "#60a8c0" } },
  { id: "midnight",  name: "Midnight",  blurb: "Deep blue-violet with cool accents",                  swatch: { bg: "#0a0d1f", surface: "#131730", accent: "#818cf8", ai: "#60a8c0" } },
  { id: "ember",     name: "Ember",     blurb: "Warm crimson and bronze, forge vibes",               swatch: { bg: "#1a0a06", surface: "#2a130c", accent: "#ef6c4a", ai: "#60a8c0" } },
  { id: "mono",      name: "Mono",      blurb: "Clean grayscale, minimal and focused",               swatch: { bg: "#f7f7f8", surface: "#ffffff", accent: "#18181b", ai: "#60a8c0" } },
  { id: "cyberpunk", name: "Cyberpunk", blurb: "Neon green on black, matrix terminal",               swatch: { bg: "#030a06", surface: "#08130c", accent: "#22ff77", ai: "#60a8c0" } },
  { id: "slate",     name: "Slate",     blurb: "Cool slate blue, focused developer theme",           swatch: { bg: "#0c1220", surface: "#131b2e", accent: "#38bdf8", ai: "#60a8c0" } },
];

export const MODEL_SEP = "::";

export const SETTINGS_ROW = "flex items-center gap-3 rounded-lg border border-border-subtle bg-surface px-4 py-3 transition-colors";

export const SCORE_DIMENSIONS: { key: keyof ScoreBreakdown; label: string }[] = [
  { key: "coverage", label: "Coverage" },
  { key: "density", label: "Density" },
  { key: "freshness", label: "Freshness" },
  { key: "structure", label: "Structure" },
  { key: "activity", label: "Activity" },
  { key: "config_completeness", label: "Config" },
];
