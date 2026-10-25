// Apps > Stack (apps plan A2 to A4) and Insights > Metrics > Sources (metrics
// plan M3): the stack view with its tabs, Needs you cards, categories, rows
// that open inline, the unknown inbox, the Full Disk Access line, and the
// consent screen. Invented apps only. With STACK_SHOTS=<dir>, each view is
// captured at 390, 768, 1280 and 1920.
import { test, expect, type Page } from "@playwright/test";
import { mockTauri } from "./tauri-mock";

const usage = (id: string, d30: number, minutes = 0) => ({ id, active_days: { d7: Math.min(7, d30), d30, d90: d30 + 5 }, minutes_30d: minutes, device_minutes_30d: minutes ? { mac: minutes - 20, "device-abc": 20 } : {}, web_visits_30d: 12, ai_sessions_30d: 0, trend: "flat", signals: [{ kind: "domain", value: `${id}.example` }], hosts: ["mac-a"] });
const APPS = [
  { id: "foo-notes", name: "Foo Notes", kind: "app", category: "notes", lifecycle: "in use", usage: usage("foo-notes", 28, 640), monthly: 10, cost_source: "card statements", cost_per_active_day: 0.36, renewal: { next: "2026-10-14", period: "monthly" }, health: "ok", verdict: "keep", why: [] },
  { id: "bar-notes", name: "Bar Notes With A Rather Long Product Name", kind: "app", category: "notes", lifecycle: "in use", usage: usage("bar-notes", 1), monthly: 8, health: null, verdict: "cancel", why: ["1 active day in 30"] },
  { id: "baz-ai", name: "Baz AI", kind: "ai-tool", category: "ai", lifecycle: "in use", usage: usage("baz-ai", 30, 2400), monthly: 200, value_multiple: 5.7, api_equivalent_month: 1140, health: "capture_gap", health_detail: "no prompt captured since 2026-09-20", verdict: "keep", why: [] },
  { id: "qux-video", name: "Qux Video", kind: "app", category: "content", lifecycle: "in use", usage: usage("qux-video", 0), monthly: 24, price_up: { from: 20, to: 24, date: "2026-09-06" }, trial: { ends: "2026-10-04" }, health: "auth_expired", verdict: "review", why: ["price up from $20 to $24"] },
];
const CARDS = [
  { key: "aaaaaaaaaaa1", kind: "failing", app: "baz-ai", title: "Baz AI: prompts are not being captured", why: "no prompt captured since 2026-09-20", actions: ["fix", "snooze"], urgent: true },
  { key: "aaaaaaaaaaa2", kind: "unused", app: "bar-notes", title: "Bar Notes: $8.00 a month, 1 active day in 30", why: "paid and barely used", actions: ["keep", "cancel-steps", "snooze"], urgent: false },
  { key: "aaaaaaaaaaa3", kind: "duplicate", app: "bar-notes", title: "2 paid notes apps: Foo Notes, Bar Notes With A Rather Long Product Name", why: "Bar Notes: 1 active days in 30", actions: ["keep", "review"], urgent: false },
];
const STACK = {
  ts: Date.parse("2026-10-02T12:00:00Z"), usage_since: "2026-07-01", month_total: 242, in_use: 3, apps: APPS,
  categories: [{ id: "notes", title: "Notes", count: 2 }, { id: "ai-tools", title: "AI tools", count: 1 }, { id: "content", title: "Content", count: 1 }],
  archived_seen: [], unknown: 2, fda: [{ host: "mac-a", state: "needs-fda" }], ai: { paid_monthly: 200, api_equivalent: 1140, value_multiple: 5.7 }, cards: CARDS,
};
const UNKNOWN = [
  { kind: "domain", value: "quux-tools.example", days: 6, last: "2026-10-01", n: 30, suggestion: "foo-notes" },
  { kind: "merchant", value: "CORGE SUBSCRIPTION EXAMPLE", days: 3, last: "2026-09-21", n: 3, freq: "monthly" },
];
const src = (id: string, title: string, wave: number, on: boolean, extra: Record<string, unknown> = {}) => ({ id, title, wave, reads: `what ${title} counts`, never: "the content", defaultOn: on, emits: [], on, decided: false, state: on ? "ok" : "off", ...extra });
const SOURCES = [
  src("browsers", "Browser domains", 1, true, { last_sync: "2026-10-02T10:00:00Z" }),
  src("screentime", "Screen Time", 2, true, { fda: true, state: "needs-fda", note: "grant Full Disk Access to Glyph Studio to read Screen Time" }),
  src("gmail", "Gmail headers", 2, true, { state: "auth-failed", note: "sign in again" }),
  src("apple-health", "Apple Health export", 3, false, { connect: "drop export.zip in the inbox folder" }),
  src("photos", "Apple Photos", 4, false, { localOnly: true, fda: true }),
  src("writing-themes", "Writing themes", 4, false, { localOnly: true, localModel: true }),
];
const FIX = {
  engine_apps_stack: STACK, engine_apps_unknown: UNKNOWN,
  engine_apps_card: { ok: true, draft: "data/apps/bar-notes/offboarding-2026-10-02.md" }, engine_apps_map: { ok: true, app: "foo-notes" },
  engine_apps_offboard: { ok: true, path: "data/apps/foo-notes/offboarding-2026-10-02.md" }, engine_apps_doctor: {},
  engine_sources: SOURCES, engine_source_consent: { ok: true }, engine_source_sync: { state: "ok", note: "read" },
  engine_apps_stack_diff: { month: "2026-10", items: [
    { kind: "missing", tool: "Qux Term", detail: "used on 9 of the last 30 days, not in your stack", proposed: "add Qux Term" },
    { kind: "unused", tool: "Bar Notes", detail: "listed, no use in the last 30 days", proposed: "mark Bar Notes unused" },
    { kind: "status", tool: "Foo Edit", detail: "the doctor finds it needing sign-in", proposed: "connected to needs sign-in" },
  ] },
  engine_apps_stack_diff_accept: { ok: true, applied: 3, backup: "data/domains/general/source/tool-stack.md.pre-diff-2026-10-02" },
  engine_apps_imports: { reminder: false, line: null, last: [], apps: [
    { id: "chatgpt", name: "ChatGPT", how: "Settings, Data controls, Export data", url: "https://chatgpt.com/", inbox: "data/apps/chatgpt/inbox", waiting: 1 },
    { id: "claude-ai", name: "claude.ai", how: "Settings, Privacy, Export data", url: "https://claude.ai/", inbox: "data/apps/claude-ai/inbox", waiting: 0 },
    { id: "gemini", name: "Gemini", how: "Google Takeout, My Activity, Gemini Apps", url: "https://takeout.google.com/", inbox: "data/apps/gemini/inbox", waiting: 0 },
  ] },
  engine_apps_imports_run: [{ app: "chatgpt", written: 12, prompts: 14 }], engine_apps_imports_reminder: { reminder: true },

};

const SHOTS = process.env.STACK_SHOTS;
async function shot(page: Page, name: string) {
  if (!SHOTS) return;
  await page.waitForTimeout(300);
  await page.screenshot({ path: `${SHOTS}/${name}-${page.viewportSize()?.width}.png` });
}
const calls = (page: Page, cmd: string) => page.evaluate((c) =>
  ((window as unknown as { __invokeLog: Array<{ cmd: string; args: Record<string, unknown> }> }).__invokeLog ?? [])
    .filter((e) => e.cmd === c).map((e) => e.args), cmd);

async function noOverflow(page: Page) {
  const over = await page.evaluate(() => {
    const vw = document.documentElement.clientWidth;
    return [...document.querySelectorAll("[data-testid]")].filter((e) => {
      const r = (e as HTMLElement).getBoundingClientRect();
      const s = getComputedStyle(e as HTMLElement);
      // A tab strip that scrolls sideways (phone) may hold tabs past the edge; the strip itself must fit.
      if ((e as HTMLElement).parentElement?.closest("[data-scroll-x]")) return false;
      return r.width > 0 && s.visibility !== "hidden" && (r.right > vw + 1 || r.left < -1);
    }).map((e) => (e as HTMLElement).dataset.testid).slice(0, 5);
  });
  expect(over).toEqual([]);
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth + 1)).toBe(true);
}

async function openApps(page: Page, width: number) {
  page.on("pageerror", (err) => { throw new Error(`frontend crashed: ${err.message}`); });
  await page.setViewportSize({ width, height: width < 500 ? 844 : 900 });
  await mockTauri(page, FIX);
  await page.goto("/");
  await page.getByText("What should we work on?").waitFor({ timeout: 15_000 });
  await page.evaluate(() => window.dispatchEvent(new CustomEvent("prevail:work-section", { detail: "apps" })));
  await expect(page.getByTestId("apps-view")).toBeVisible({ timeout: 10_000 });
}

for (const width of [390, 768, 1280, 1920]) {
  const phone = width < 500;
  test.describe(`apps stack · ${width}`, () => {
    test("the stack: tabs, Needs you, categories, a row opened, unknown, the Full Disk Access line", async ({ page }) => {
      await openApps(page, width);
      await expect(page.getByTestId("tab-stack")).toHaveAttribute("aria-selected", "true");
      await expect(page.getByTestId("stack-fda")).toContainText("Screen Time needs Full Disk Access for Glyph Studio");
      if (!phone) await expect(page.getByText("$242 a month known · 3 in use")).toBeVisible();
      if (phone) await page.getByTestId("stack-spine-needs").click();
      await expect(page.getByTestId("stack-card")).toHaveCount(3);
      await noOverflow(page);
      await shot(page, "stack-needs");
      // One answer shows on the row; the rest are in its menu.
      await expect(page.getByTestId("stack-card").nth(1).getByTestId("card-keep")).toHaveCount(1);
      await page.getByTestId("stack-card").nth(1).getByRole("button", { name: "More actions" }).click();
      await page.getByRole("menuitem", { name: "Draft cancel steps" }).click();
      await expect.poll(() => calls(page, "engine_apps_card")).toEqual([{ vault: "/tmp/smoke-vault", key: "aaaaaaaaaaa2", answer: "cancel-steps" }]);
      if (phone) await page.getByRole("button", { name: "Stack", exact: true }).click();
      await page.getByTestId("stack-spine-all").click();
      await expect(page.getByTestId("stack-row-foo-notes")).toBeVisible();
      await page.getByTestId("stack-row-baz-ai").getByRole("button").first().click();
      await expect(page.getByTestId("stack-detail")).toContainText("$1,140 at API prices this month, 5.7x what you pay");
      await noOverflow(page);
      await shot(page, "stack-all");
      await page.getByTestId("stack-offboard").click();
      await expect.poll(() => calls(page, "engine_apps_offboard")).toEqual([{ vault: "/tmp/smoke-vault", id: "baz-ai" }]);
      if (phone) await page.getByRole("button", { name: "Stack", exact: true }).click();
      await page.getByTestId("stack-spine-unknown").click();
      await expect(page.getByTestId("stack-unknown")).toHaveCount(2);
      await page.getByTestId("unknown-map").first().selectOption("foo-notes");
      await expect.poll(() => calls(page, "engine_apps_map")).toEqual([{ vault: "/tmp/smoke-vault", kind: "domain", value: "quux-tools.example", target: "foo-notes" }]);
      await noOverflow(page);
      await shot(page, "stack-unknown");
      await page.getByTestId("tab-connectors").click();
      await expect(page.getByTestId("tab-connectors")).toHaveAttribute("aria-selected", "true");
      await noOverflow(page);
    });

    test("the Sources consent screen: waves, badges, a confirm before a wave 4 source", async ({ page }) => {
      await openApps(page, width);
      await page.evaluate(() => window.dispatchEvent(new CustomEvent("prevail:work-section", { detail: "insights" })));
      await page.getByTestId("tab-metrics").click();
      await page.getByTestId("metrics-row-sources").click();
      const c = page.getByTestId("sources-consent");
      await expect(c.getByTestId("consent-row-photos")).toContainText("Stays on this Mac");
      await expect(c.getByTestId("consent-row-writing-themes")).toContainText("Local model");
      await expect(c.getByTestId("consent-row-screentime")).toContainText("Needs Full Disk Access");
      await c.getByTestId("consent-row-photos").getByTestId("source-toggle").click();
      await expect(c.getByTestId("source-confirm")).toContainText("Turn on Apple Photos on this Mac?");
      await noOverflow(page);
      await shot(page, "sources-confirm");
      await c.getByTestId("source-confirm-on").click();
      await expect.poll(() => calls(page, "engine_source_consent")).toEqual([{ vault: "/tmp/smoke-vault", id: "photos", on: true }]);
      await c.getByTestId("consent-row-gmail").getByTestId("source-toggle").click();
      await expect.poll(async () => (await calls(page, "engine_source_consent")).length).toBe(2);
      await c.getByTestId("consent-row-gmail").getByTestId("source-sync").click();
      await expect.poll(() => calls(page, "engine_source_sync")).toEqual([{ vault: "/tmp/smoke-vault", id: "gmail" }]);
    });
  });
}

// Apps A5: said vs used for the stated stack (nothing changes until Accept),
// and imports of the official exports with the quarterly reminder off.
for (const width of [390, 768, 1280, 1920]) {
  test(`apps A5 · said vs used and imports (${width})`, async ({ page }) => {
    await openApps(page, width);
    const back = async () => { if (width < 500) await page.getByRole("button", { name: "Stack", exact: true }).click().catch(() => {}); };
    await expect(page.getByTestId("stack-spine-said")).toContainText("3");
    await page.getByTestId("stack-spine-said").click();
    await expect(page.getByTestId("stack-diff-item")).toHaveCount(3);
    await noOverflow(page);
    await shot(page, "a5-said");
    await page.getByTestId("stack-diff-accept").click();
    await expect.poll(() => calls(page, "engine_apps_stack_diff_accept")).toEqual([{ vault: "/tmp/smoke-vault" }]);
    await expect(page.getByTestId("stack-diff-msg")).toContainText("Applied 3");
    await back();
    await page.getByTestId("stack-spine-imports").click();
    await expect(page.getByTestId("import-app")).toHaveCount(3);
    await expect(page.getByTestId("imports-reminder-toggle")).toHaveAttribute("aria-checked", "false");
    await page.getByTestId("imports-reminder-toggle").click();
    await expect.poll(() => calls(page, "engine_apps_imports_reminder")).toEqual([{ vault: "/tmp/smoke-vault", on: true }]);
    await page.getByTestId("imports-run").click();
    await expect(page.getByTestId("imports-msg")).toContainText("chatgpt: 12 new of 14 prompts");
    await noOverflow(page);
    await shot(page, "a5-imports");
  });
}

