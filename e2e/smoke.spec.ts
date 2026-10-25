// The five load-bearing flows (G2). Not pixel tests: each asserts the screen
// actually renders its purpose and that its primary control invokes the right
// backend command. A crash, a dead button, or a gutted section fails here
// before a tag can build.
import { test, expect } from "@playwright/test";
import { mockTauri, invokedCommands } from "./tauri-mock";

test.beforeEach(async ({ page }) => {
  await mockTauri(page);
  page.on("pageerror", (err) => { throw new Error(`frontend crashed: ${err.message}`); });
  await page.goto("/");
});

test("1 · home renders: headline, composer, and a trust ribbon that says only what matters", async ({ page }) => {
  await expect(page.getByText("What should we work on?")).toBeVisible({ timeout: 15_000 });
  // Everything is in its protective state in the fixtures, so the ribbon says
  // so once rather than printing three segments that each describe the
  // ordinary state. The detail is on the segment.
  const protectedSeg = page.getByText(/^Protected$/);
  await expect(protectedSeg).toBeVisible();
  await expect(protectedSeg).toHaveAttribute("title", /Vault Locked.*Guardrail ON/is);
  await expect(page.getByText(/Guardrail on/i)).toHaveCount(0);
  await expect(page.getByText(/Vault locked/i)).toHaveCount(0);
  // Self-hosted fonts must actually load (no runtime Google fetch, no silent
  // fallback). Confirm the bundled Inter face is available.
  const interLoaded = await page.evaluate(() => (document as unknown as { fonts: { check: (f: string) => boolean } }).fonts.check("16px Inter"));
  expect(interLoaded).toBe(true);
  // And nothing tried to reach Google Fonts.
  const gf = await page.evaluate(() => performance.getEntriesByType("resource").map((r) => (r as PerformanceResourceTiming).name).filter((n) => n.includes("fonts.g")));
  expect(gf).toEqual([]);
  // Home is the headline, the subtitle and the composer: no search box, no
  // runtime strip, no waiting pill, no readiness pill.
  await expect(page.getByPlaceholder("Search conversations and domains")).toHaveCount(0);
  await expect(page.locator('[title*="validated"]')).toHaveCount(0);
  await expect(page.getByTestId("home-waiting")).toHaveCount(0);
  await expect(page.getByText(/Life Readiness/)).toHaveCount(0);
  // What is waiting lives on the sidebar Inbox row instead, in the accent colour.
  const inbox = page.getByTestId("nav-inbox");
  await expect(inbox).toContainText("2", { timeout: 10_000 });
  await expect(inbox.locator(".bg-accent")).toHaveCount(1);
  // And the readiness score is one plain line on Insights.
  await page.getByRole("button", { name: "Insights" }).click();
  await expect(page.getByTestId("life-readiness")).toHaveText("Life Readiness 62 of 100 across 2 domains", { timeout: 10_000 });
});

test("2 · the Inbox page: tabs filter the column, the detail is the picked item; approving uses the token spine", async ({ page }) => {
  await page.getByText("What should we work on?").waitFor({ timeout: 15_000 });
  await page.getByTestId("nav-inbox").click();
  const inbox = page.getByTestId("inbox-page");
  await expect(inbox).toBeVisible({ timeout: 10_000 });
  // Header with tabs, then the column, then the detail.
  const header = page.getByTestId("work-page").getByTestId("page-header").first();
  await expect(header).toContainText("Inbox");
  await expect(header.getByTestId("tab-all")).toContainText("2", { timeout: 10_000 });
  await expect(header.getByTestId("tab-actions")).toContainText("1");
  await expect(header.getByTestId("tab-google")).toContainText("1");
  // Empty categories stay out of the way.
  await expect(header.getByTestId("tab-automations")).toHaveCount(0);
  await expect(header.getByTestId("tab-tasks")).toHaveCount(0);
  const col = inbox.getByTestId("inbox-spine");
  await expect(col).toHaveAttribute("data-spine-column");
  await expect(col.getByTestId("inbox-row")).toHaveCount(2);
  await page.screenshot({ path: `${process.env.MOBILE_SHOTS_DIR || "/tmp"}/desktop-inbox.png` });
  // A tab filters the column.
  await header.getByTestId("tab-actions").click();
  await expect(col.getByTestId("inbox-row")).toHaveCount(1);
  await expect(col.getByTestId("inbox-row")).toContainText("PayPal: create_invoice");
  // The detail shows the picked item's card, not the others.
  const detail = inbox.getByTestId("decision-inbox");
  await expect(detail).toContainText("PayPal: create_invoice");
  await expect(detail).not.toContainText("Gmail: send");
  // The sensitive act shows the explicit release wording, not a plain approve.
  await detail.getByText(/Approve including sensitive info/i).click();
  const cmds = await invokedCommands(page);
  expect(cmds).toContain("loop_request_approval");
  expect(cmds.indexOf("engine_acts_approve")).toBeGreaterThan(cmds.indexOf("loop_request_approval"));
});

test("3 · Privacy & Safety: each control has its own row; the guardrail toggle drives both engine flags", async ({ page }) => {
  await page.getByText("What should we work on?").waitFor({ timeout: 15_000 });
  await page.evaluate(() => window.dispatchEvent(new CustomEvent("prevail:open-settings", { detail: "privacy" })));
  // The old Privacy id opens the page on its first control.
  await expect(page.getByTestId("hub-detail-bunker")).toContainText("Bunker Mode", { timeout: 10_000 });
  const col = page.getByTestId("hub-privacy-safety");
  for (const row of ["bunker", "vault-lock", "incognito", "guardrail", "always", "telemetry", "autonomy", "safety-access", "safety-guardrails"]) {
    await expect(col.getByTestId(`hub-row-${row}`)).toBeVisible();
  }
  await col.getByTestId("hub-row-vault-lock").click();
  await expect(page.getByTestId("hub-detail-vault-lock")).toContainText("Vault Lock");
  await col.getByTestId("hub-row-guardrail").click();
  await expect(page.getByText(/nothing reaches another party without you/i)).toBeVisible();
  await page.getByLabel("Outbound guardrail").click();
  const cmds = await invokedCommands(page);
  expect(cmds).toContain("email_policy_set");
  expect(cmds).toContain("egress_guard_set");
});

test("4 · Editor sections switch without crashing (tools, skills, usage, intent)", async ({ page }) => {
  await page.getByText("What should we work on?").waitFor({ timeout: 15_000 });
  for (const section of ["tools", "skills", "usage", "intents"]) {
    await page.evaluate((s) => window.dispatchEvent(new CustomEvent("prevail:open-settings", { detail: s })), section);
    await page.waitForTimeout(400); // sections lazy-load; a crash throws pageerror
  }
});

// Remote: the pair card must show the same-Wi-Fi address with no Tailscale on
// the phone, and one tap must turn on the internet tunnel and move the QR to
// its https address (the one that makes the phone mic work).
test("6 · Remote: Wi-Fi address in the pair card; Share over the internet swaps the QR to the tunnel", async ({ page }) => {
  const off = {
    running: true, port: 8787, user: "admin", remote: true,
    remote_url: "http://192.168.1.20:8787", via_tailscale: false,
    lan_url: "http://192.168.1.20:8787", tailscale_url: "", tunnel_url: "",
    tunnel_state: "off", tunnel_error: "", cloudflared_installed: true, pair_ready: true, bunker_blocking: false,
    devices: [{ id: "d_1", label: "iPhone (Safari)", ip: "192.168.1.44", first_seen_ms: Date.now() - 60000, last_seen_ms: Date.now() - 5000, via: "qr" }],
  };
  const on = { ...off, remote_url: "https://witty-otter-cat.trycloudflare.com", tunnel_url: "https://witty-otter-cat.trycloudflare.com", tunnel_state: "on" };
  await mockTauri(page, { webui_status: off, webui_secret_get: "hunter2", webui_tunnel_start: on, webui_tunnel_stop: off, webui_pair_code: "http://192.168.1.20:8787/#p=deadbeefdeadbeef" });
  await page.goto("/");
  await page.getByText("What should we work on?").waitFor({ timeout: 15_000 });
  await page.evaluate(() => window.dispatchEvent(new CustomEvent("prevail:open-settings", { detail: "phone" })));
  const card = page.getByTestId("remote-pair");
  await expect(card).toBeVisible({ timeout: 10_000 });
  await expect(page.getByTestId("remote-primary-url")).toHaveText("http://192.168.1.20:8787");
  await expect(page.getByTestId("remote-lan")).toContainText("192.168.1.20");
  await expect(card.getByAltText(/QR code for http:\/\/192\.168\.1\.20:8787/)).toBeVisible();
  await expect(card.getByText(/Same Wi-Fi as this Mac/)).toBeVisible();

  await card.getByRole("button", { name: "Share over the internet" }).click();
  // The status poll must agree with what the start command returned.
  await page.evaluate((s) => { (window as unknown as { __fixtures: Record<string, unknown> }).__fixtures.webui_status = s; }, on);
  await expect(page.getByTestId("remote-tunnel-url")).toHaveText("https://witty-otter-cat.trycloudflare.com");
  await expect(page.getByTestId("remote-primary-url")).toHaveText("https://witty-otter-cat.trycloudflare.com");
  await expect(card.getByAltText(/QR code for https:\/\/witty-otter-cat\.trycloudflare\.com/)).toBeVisible();
  await expect(card.getByText(/Over the internet/)).toBeVisible();
  const cmds = await invokedCommands(page);
  expect(cmds).toContain("webui_tunnel_start");
  await page.screenshot({ path: `${process.env.MOBILE_SHOTS_DIR || "/tmp"}/desktop-remote-tunnel.png` });

  await card.getByRole("button", { name: "Stop sharing" }).click();
  await page.evaluate((s) => { (window as unknown as { __fixtures: Record<string, unknown> }).__fixtures.webui_status = s; }, off);
  await expect(card.getByRole("button", { name: "Share over the internet" })).toBeVisible();
  await expect(page.getByTestId("remote-primary-url")).toHaveText("http://192.168.1.20:8787");
});

// Phone is its own destination in the sidebar, and turning it on is one
// button: mobile access used to be buried inside the WebUI panel.
test("7 · Phone is a top-level section and turns itself on in one tap", async ({ page }) => {
  const offline = { running: false, port: 8787, user: "admin", remote: false, remote_url: "", via_tailscale: false, lan_url: "", tailscale_url: "", tunnel_url: "", tunnel_state: "off", tunnel_error: "", cloudflared_installed: true, pair_ready: false, devices: [], bunker_blocking: false };
  const live = { ...offline, running: true, remote: true, remote_url: "http://192.168.1.20:8787", lan_url: "http://192.168.1.20:8787", pair_ready: true };
  await mockTauri(page, { webui_status: offline, webui_secret_get: "", webui_pair_code: "http://192.168.1.20:8787/#p=deadbeefdeadbeef" });
  await page.goto("/");
  await page.getByText("What should we work on?").waitFor({ timeout: 15_000 });

  // Reachable by name from the Settings sidebar, not only by deep link: the
  // Connections row, then Phone in its side column.
  await page.getByRole("button", { name: "Settings" }).click();
  await page.getByTestId("app-sidebar").getByRole("button", { name: "Connections", exact: true }).click();
  const phoneNav = page.getByTestId("hub-row-phone");
  await expect(phoneNav).toBeVisible({ timeout: 10_000 });
  await expect(phoneNav).toContainText("Off");
  await phoneNav.click();
  await expect(page.getByText("Put Glyph Studio on your phone")).toBeVisible();

  await page.getByRole("button", { name: "Turn on phone access" }).click();
  await page.evaluate((s) => { (window as unknown as { __fixtures: Record<string, unknown> }).__fixtures.webui_status = s; }, live);
  await expect(page.getByTestId("remote-pair")).toBeVisible({ timeout: 10_000 });
  const cmds = await invokedCommands(page);
  expect(cmds).toContain("webui_start");
  // A password was minted and stored, so the user never had to invent one.
  expect(cmds).toContain("webui_secret_set");
  // The QR must promise a no-typing sign-in, which is the whole point.
  await expect(page.getByText(/You are signed in\./)).toBeVisible();
  await page.screenshot({ path: `${process.env.MOBILE_SHOTS_DIR || "/tmp"}/desktop-phone-section.png` });
});

test("5 · telemetry: section navigation emits allowlisted feature_used events only", async ({ page }) => {
  await page.getByText("What should we work on?").waitFor({ timeout: 15_000 });
  await page.evaluate(() => window.dispatchEvent(new CustomEvent("prevail:open-settings", { detail: "skills" })));
  await page.waitForTimeout(300);
  const log = await page.evaluate(() => localStorage.getItem("prevail.telemetry.log") ?? "[]");
  const events = JSON.parse(log) as Array<{ event: string; props: Record<string, unknown> }>;
  const feats = events.filter((e) => e.event === "feature_used");
  expect(feats.length).toBeGreaterThan(0);
  // The scrubber must have dropped anything not in the closed enum.
  for (const f of feats) {
    if (typeof f.props.feature === "string") expect(f.props.feature).toMatch(/^[a-z_]+$/);
  }
});

// Multiple phones, each revocable on its own, and a master off switch.
test("8 · connected phones are listed and can be disconnected one at a time", async ({ page }) => {
  const two = [
    { id: "d_1", label: "iPhone (Safari)", ip: "192.168.1.44", first_seen_ms: Date.now() - 600000, last_seen_ms: Date.now() - 4000, via: "qr" },
    { id: "d_2", label: "iPad (Safari)", ip: "192.168.1.45", first_seen_ms: Date.now() - 90000, last_seen_ms: Date.now() - 600000, via: "password" },
  ];
  const live = {
    running: true, port: 8787, user: "admin", remote: true,
    remote_url: "http://192.168.1.20:8787", via_tailscale: false,
    lan_url: "http://192.168.1.20:8787", tailscale_url: "", tunnel_url: "",
    tunnel_state: "off", tunnel_error: "", cloudflared_installed: true, pair_ready: true,
    bunker_blocking: false, devices: two,
  };
  const afterRevoke = { ...live, devices: [two[1]] };
  await mockTauri(page, { webui_status: live, webui_secret_get: "x", webui_pair_code: "http://192.168.1.20:8787/#p=abc123abc123", webui_device_revoke: afterRevoke, webui_device_revoke_all: { ...live, devices: [] } });
  await page.goto("/");
  await page.getByText("What should we work on?").waitFor({ timeout: 15_000 });
  await page.evaluate(() => window.dispatchEvent(new CustomEvent("prevail:open-settings", { detail: "phone" })));

  const list = page.getByTestId("remote-devices");
  await expect(list).toBeVisible({ timeout: 10_000 });
  await expect(list).toContainText("Connected phones (1 of 2 live)");
  await expect(list.locator("[data-device=d_1]")).toContainText("iPhone (Safari)");
  await expect(list.locator("[data-device=d_1]")).toContainText("paired by code");
  // A live device shows a green pulse; one we have not heard from does not.
  await expect(list.locator("[data-device=d_1] [data-live='1']")).toBeVisible();
  await expect(list.locator("[data-device=d_1]")).toContainText("Connected");
  await expect(list.locator("[data-device=d_2]")).toContainText("iPad (Safari)");
  await expect(list.locator("[data-device=d_2] [data-live='0']")).toBeVisible();
  await expect(list.locator("[data-device=d_2]")).toContainText("Idle");

  await list.locator("[data-device=d_1]").getByRole("button", { name: "Disconnect" }).click();
  await page.evaluate((s) => { (window as unknown as { __fixtures: Record<string, unknown> }).__fixtures.webui_status = s; }, afterRevoke);
  await expect(list.locator("[data-device=d_1]")).toHaveCount(0);
  await expect(list.locator("[data-device=d_2]")).toBeVisible();
  const cmds = await invokedCommands(page);
  expect(cmds).toContain("webui_device_revoke");
  await page.screenshot({ path: `${process.env.MOBILE_SHOTS_DIR || "/tmp"}/desktop-phone-devices.png` });

  // And the master switch stops the bridge, which takes every device with it.
  await page.getByRole("button", { name: "Turn off phone access" }).click();
  expect(await invokedCommands(page)).toContain("webui_stop");
});

// Bunker Mode's promise is that nothing leaves this Mac, and a phone on the
// network is a way off it. The screen must say so rather than silently fail.
test("9 · Bunker Mode blocks phone access and explains why", async ({ page }) => {
  const blocked = {
    running: false, port: 8787, user: "admin", remote: false, remote_url: "", via_tailscale: false,
    lan_url: "", tailscale_url: "", tunnel_url: "", tunnel_state: "off", tunnel_error: "",
    cloudflared_installed: true, pair_ready: false, devices: [], bunker_blocking: true,
  };
  await mockTauri(page, { webui_status: blocked });
  await page.goto("/");
  await page.getByText("What should we work on?").waitFor({ timeout: 15_000 });
  await page.evaluate(() => window.dispatchEvent(new CustomEvent("prevail:open-settings", { detail: "phone" })));
  await expect(page.getByText("Bunker Mode is on, so phones cannot connect")).toBeVisible({ timeout: 10_000 });
  // No way to switch it on from here: the block is real, not advisory.
  await expect(page.getByRole("button", { name: "Turn on phone access" })).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Open Privacy" })).toBeVisible();
});

// A pairing code is a credential on a screen. Anyone who can see that screen,
// or a photo of it, can race the owner to redeem it. The old card hid that
// completely: it printed "Phone paired" and silently minted the next code, so
// a stolen scan looked exactly like your own phone arriving. What must happen
// instead is that the Mac names what got in and offers to cut it off, and that
// showing another code takes a deliberate tap.
test("10 · a spent pairing code names the device that used it and offers to cut it off", async ({ page }) => {
  const stranger = { id: "d_x", label: "Android phone (Chrome)", ip: "192.168.1.99", first_seen_ms: Date.now() - 2000, last_seen_ms: Date.now() - 1000, via: "qr" };
  const base = {
    running: true, port: 8787, user: "admin", remote: true,
    remote_url: "http://192.168.1.20:8787", via_tailscale: false,
    lan_url: "http://192.168.1.20:8787", tailscale_url: "", tunnel_url: "",
    tunnel_state: "off", tunnel_error: "", cloudflared_installed: true,
    bunker_blocking: false,
  };
  const waiting = { ...base, pair_ready: true, devices: [] };
  const spent = { ...base, pair_ready: false, devices: [stranger] };
  await mockTauri(page, {
    webui_status: waiting, webui_secret_get: "x",
    webui_pair_code: "http://192.168.1.20:8787/#p=abc123abc123",
    webui_device_revoke: { ...base, pair_ready: false, devices: [] },
  });
  await page.goto("/");
  await page.getByText("What should we work on?").waitFor({ timeout: 15_000 });
  await page.evaluate(() => window.dispatchEvent(new CustomEvent("prevail:open-settings", { detail: "phone" })));
  const card = page.getByTestId("remote-pair");
  await expect(card).toBeVisible({ timeout: 10_000 });
  await expect(card.getByRole("img", { name: /QR code/ })).toBeVisible();

  // Somebody redeems the code: pair_ready falls and a device appears.
  await page.evaluate((s) => { (window as unknown as { __fixtures: Record<string, unknown> }).__fixtures.webui_status = s; }, spent);

  // The card says WHO, not just "paired", and stops showing a code.
  await expect(card.getByTestId("remote-paired")).toContainText("Android phone (Chrome)", { timeout: 10_000 });
  await expect(card).toContainText("192.168.1.99");
  await expect(card.getByRole("img", { name: /QR code/ })).toHaveCount(0);
  await expect(card.getByRole("button", { name: /Pair another device/ })).toBeVisible();

  // And ending that session is one tap from the confirmation itself.
  await card.getByTestId("remote-revoke-paired").click();
  expect(await invokedCommands(page)).toContain("webui_device_revoke");
});


// The point of collapsing the ribbon is that an exception stands out. When an
// axis is open, it must be named there, in its own right, rather than hidden
// behind a word that claims everything is fine.
test("11 · the trust ribbon names an axis that is not protective", async ({ page }) => {
  await mockTauri(page, { vault_lock_status: { enabled: false }, egress_guard_get: { mode: "off" } });
  await page.goto("/");
  await expect(page.getByText("What should we work on?")).toBeVisible({ timeout: 15_000 });
  await expect(page.getByText(/^Vault unlocked$/)).toBeVisible();
  await expect(page.getByText(/^Guardrail off$/)).toBeVisible();
  // And it does not also claim to be protected.
  await expect(page.getByText(/^Protected$/)).toHaveCount(0);
});

// The worst defect this app can have is a safety control that claims
// protection it does not have. Bunker Mode keeps a localStorage mirror so
// deeply-nested code can read it synchronously, and that mirror defaults to ON
// so an unknown state fails CLOSED for readers. Displaying that guess is a
// different matter: the call that corrects it used to run before sign-in, 401
// into a silent catch, and leave the ribbon and the Privacy screen both
// announcing "fully local, nothing leaves your machine" while the engine had
// Bunker Mode off. The backend is the only thing allowed to answer this.
test("12 · the trust ribbon never claims Bunker Mode the engine does not have", async ({ page }) => {
  await mockTauri(page, { bunker_status: { enabled: false, network_blocked: false, web_blocked: false, cloud_blocked: false, local_available: false } });
  // Seed the optimistic mirror, exactly as a stale or pre-auth state would.
  await page.addInitScript(() => localStorage.setItem("prevail.pref.bunkerMode", "1"));
  await page.goto("/");
  await expect(page.getByText("What should we work on?")).toBeVisible({ timeout: 15_000 });
  // The engine says off, so nothing on screen may say otherwise.
  await expect(page.getByText(/Bunker mode/i)).toHaveCount(0);
  // And the mirror is corrected rather than left lying for the next reader.
  await expect
    .poll(() => page.evaluate(() => localStorage.getItem("prevail.pref.bunkerMode")), { timeout: 10_000 })
    .toBe("0");
});

// ── Approvals in the flow, Waiting for you, and conversation schedules ─────
// A General thread whose last reply hit the gate: the tool result carried the
// [prevail-act:<id>] marker, so the approval card belongs right under it.
const FOO_THREAD = "/tmp/smoke-vault/_threads/foo-thread.md";
function chatFixtures(act: Record<string, unknown>) {
  return {
    // Sending a turn reads these; the real engine always answers with text.
    read_ideal_state: "",
    read_omega: "",
    read_user_md: "",
    read_memory_md: "",
    list_threads: [{ path: FOO_THREAD, slug: "foo-thread", title: "Foo report", domain: null, created: 1783000000, updated: 1783000000, turn_count: 2, preview: "", cli: "claude", model: null }],
    load_thread: {
      meta: { path: FOO_THREAD, slug: "foo-thread", title: "Foo report", domain: null, created: 1783000000, updated: 1783000000, turn_count: 2, preview: "", cli: "claude", model: null },
      turns: [
        { role: "user", cli: null, model: null, content: "Send the foo report" },
        { role: "assistant", cli: "claude", model: null, content: "Sending it needs your approval. [prevail-act:act_chat1]" },
      ],
    },
    engine_acts_pending: [{ id: "act_chat1", domain: "general", summary: "Foo: send_report", tool: "mcp__claude_ai_Foo__send_report", argsJson: "{}", categories: [], ts: Date.now() - 20000, actionClass: "write", ...act }],
    engine_waiting: { total: 1, items: [{ kind: "act", id: "act_chat1", domain: "general", summary: "Foo: send_report", since: Date.now() - 20000, thread: "foo-thread" }] },
  };
}
async function openFooThread(page: import("@playwright/test").Page) {
  await page.getByText("What should we work on?").waitFor({ timeout: 15_000 });
  await page.getByTestId("threads-list").getByText("Foo report").first().click();
  await expect(page.getByText("Sending it needs your approval.")).toBeVisible({ timeout: 10_000 });
}
const sentFollowUp = (page: import("@playwright/test").Page) => page.evaluate(() =>
  ((window as unknown as { __invokeLog: Array<{ cmd: string; args: unknown }> }).__invokeLog ?? [])
    .some((e) => ["engine_chat", "chat_send", "engine_agent_run"].includes(e.cmd) && JSON.stringify(e.args).includes("Approved. Go ahead.")));

test("13 · a held act renders in the chat flow; Allow approves with the token spine and sends the follow-up", async ({ page }) => {
  await mockTauri(page, chatFixtures({ alwaysEligible: true }));
  await page.goto("/");
  await openFooThread(page);
  const card = page.getByTestId("act-card");
  await expect(card).toBeVisible({ timeout: 10_000 });
  await expect(card).toContainText("Foo: send_report");
  // The raw marker is for the app, never shown to the reader.
  await expect(page.getByText(/prevail-act:/)).toHaveCount(0);
  await expect(card.getByTestId("act-always")).toBeVisible();
  await page.screenshot({ path: `${process.env.MOBILE_SHOTS_DIR || "/tmp"}/desktop-act-card.png` });
  await card.getByTestId("act-allow").click();
  await expect(card).toHaveAttribute("data-state", "approved");
  const cmds = await invokedCommands(page);
  expect(cmds).toContain("loop_request_approval");
  expect(cmds.indexOf("engine_acts_approve")).toBeGreaterThan(cmds.indexOf("loop_request_approval"));
  await expect.poll(() => sentFollowUp(page), { timeout: 10_000 }).toBe(true);
});

test("14 · Always is hidden for an ineligible act; Deny declines without a follow-up", async ({ page }) => {
  await mockTauri(page, chatFixtures({ alwaysEligible: false }));
  await page.goto("/");
  await openFooThread(page);
  const card = page.getByTestId("act-card");
  await expect(card).toBeVisible({ timeout: 10_000 });
  await expect(card.getByTestId("act-always")).toHaveCount(0);
  await card.getByTestId("act-deny").click();
  await expect(card).toContainText("Declined");
  const cmds = await invokedCommands(page);
  expect(cmds).toContain("engine_acts_deny");
  expect(cmds).not.toContain("engine_acts_approve");
  await page.waitForTimeout(500);
  expect(await sentFollowUp(page)).toBe(false);
});

test("15 · Waiting for you: the thread row says so, and the sidebar Inbox count opens the Inbox", async ({ page }) => {
  await mockTauri(page, chatFixtures({ alwaysEligible: true }));
  await page.goto("/");
  await page.getByText("What should we work on?").waitFor({ timeout: 15_000 });
  const row = page.getByTestId("threads-list").locator("li", { hasText: "Foo report" });
  await expect(row.getByTestId("waiting-chip")).toBeVisible({ timeout: 10_000 });
  const inbox = page.getByTestId("nav-inbox");
  await expect(inbox).toContainText("1");
  await inbox.click();
  await expect(inbox).toHaveAttribute("aria-current", "page", { timeout: 10_000 });
  await expect(page.getByText("Foo: send_report")).toBeVisible();
  // Answering clears it everywhere: the next poll reports nothing waiting.
  await page.evaluate(() => { const fx = (window as unknown as { __fixtures: Record<string, unknown> }).__fixtures; fx.engine_waiting = { total: 0, items: [] }; fx.engine_acts_pending = []; });
  await page.evaluate(() => window.dispatchEvent(new Event("prevail:acts-changed")));
  await expect(page.getByTestId("threads-list").getByTestId("waiting-chip")).toHaveCount(0, { timeout: 10_000 });
});

test("16 · the chat header schedules the conversation in the flow", async ({ page }) => {
  await mockTauri(page, chatFixtures({ alwaysEligible: true }));
  await page.goto("/");
  await openFooThread(page);
  await page.getByTestId("open-schedule").click();
  const panel = page.getByTestId("schedule-panel");
  await expect(panel).toBeVisible();
  // Prefilled from the last thing the user asked.
  await expect(panel.getByLabel("Prompt")).toHaveValue("Send the foo report");
  await panel.getByRole("radio", { name: "Weekdays" }).click();
  await page.screenshot({ path: `${process.env.MOBILE_SHOTS_DIR || "/tmp"}/desktop-schedule-panel.png` });
  // The engine now lists it (and one for another thread, which stays out).
  await page.evaluate(() => {
    (window as unknown as { __fixtures: Record<string, unknown> }).__fixtures.engine_schedule_list = [
      { id: "s_foo", name: "Send the foo report", cron: "0 8 * * 1-5", enabled: true, last_run: null, thread: { domain: "general", session: "foo-thread" }, prompt: "Send the foo report" },
      { id: "s_bar", name: "Bar digest", cron: "0 9 * * *", enabled: true, last_run: null, thread: { domain: "career", session: "bar-thread" }, prompt: "Bar digest" },
    ];
  });
  await panel.getByTestId("schedule-save").click();
  await expect(panel.getByTestId("schedule-saved")).toBeVisible();
  const call = await page.evaluate(() =>
    ((window as unknown as { __invokeLog: Array<{ cmd: string; args: Record<string, unknown> }> }).__invokeLog ?? [])
      .find((e) => e.cmd === "engine_schedule_thread_add")?.args ?? null);
  expect(call).toMatchObject({ domain: "general", session: "foo-thread", prompt: "Send the foo report", cron: "0 8 * * 1-5" });
  // This conversation's schedules are managed right here, with tiny icon actions.
  const row = panel.getByTestId("thread-schedules").locator("[data-schedule=s_foo]");
  await expect(row).toContainText("Weekdays at 8:00 AM");
  await expect(panel.locator("[data-schedule=s_bar]")).toHaveCount(0);
  await row.getByRole("button", { name: "Run now" }).click();
  await row.getByRole("button", { name: "Pause" }).click();
  await expect(row).toContainText("paused");
  await row.getByRole("button", { name: "Remove" }).click();
  await expect.poll(() => invokedCommands(page)).toEqual(expect.arrayContaining(["engine_schedule_run", "engine_schedule_set_enabled", "engine_schedule_remove"]));
  const toggled = await page.evaluate(() =>
    ((window as unknown as { __invokeLog: Array<{ cmd: string; args: Record<string, unknown> }> }).__invokeLog ?? [])
      .find((e) => e.cmd === "engine_schedule_set_enabled")?.args ?? null);
  expect(toggled).toMatchObject({ id: "s_foo", enabled: false });
});

test("17 · Autonomy lists what runs without asking, with a revoke per row", async ({ page }) => {
  await page.getByText("What should we work on?").waitFor({ timeout: 15_000 });
  await page.evaluate(() => window.dispatchEvent(new CustomEvent("prevail:open-settings", { detail: "privacy" })));
  const row = page.getByTestId("hub-row-always");
  await expect(row).toHaveText(/Runs without asking/, { timeout: 10_000 });
  // It sits under Autonomy, not Privacy.
  expect(await row.evaluate((el) => el.closest("[data-hub-group]")?.getAttribute("data-hub-group") ?? null)).toBe("Autonomy");
  await row.click();
  const list = page.getByTestId("always-allowed");
  await expect(list).toBeVisible({ timeout: 10_000 });
  await expect(list).toContainText("Foo: list items");
  await page.evaluate(() => { (window as unknown as { __fixtures: Record<string, unknown> }).__fixtures.engine_acts_rules = []; });
  await list.getByTestId("rule-revoke").click();
  expect(await invokedCommands(page)).toContain("engine_acts_rule_revoke");
  await expect(list).toContainText("Nothing yet");
});

test("17b · Settings > Vault has no Rebuild structure or hygiene tools", async ({ page }) => {
  await page.getByText("What should we work on?").waitFor({ timeout: 15_000 });
  await page.evaluate(() => window.dispatchEvent(new CustomEvent("prevail:open-settings", { detail: "vault" })));
  await expect(page.getByTestId("hub-row-vault")).toHaveAttribute("aria-current", "true", { timeout: 10_000 });
  await expect(page.getByText("Rebuild structure")).toHaveCount(0);
  await expect(page.getByText(/hygiene|Normalize|Consolidate/i)).toHaveCount(0);
});

test("18 · the Inbox approves a queued Google write with the token spine", async ({ page }) => {
  await page.getByText("What should we work on?").waitFor({ timeout: 15_000 });
  await page.evaluate(() => window.dispatchEvent(new CustomEvent("prevail:open-settings", { detail: "inbox" })));
  await page.getByTestId("tab-google").click();
  await expect(page.getByTestId("inbox-row")).toHaveCount(1);
  await page.getByTestId("inbox-row").click();
  await expect(page.getByTestId("decision-inbox")).not.toContainText("PayPal: create_invoice");
  await page.getByRole("button", { name: /Approve & run/ }).click();
  await expect.poll(() => invokedCommands(page)).toContain("engine_gws_approve");
  const cmds = await invokedCommands(page);
  expect(cmds.indexOf("engine_gws_approve")).toBeGreaterThan(cmds.indexOf("loop_request_approval"));
  const args = await page.evaluate(() =>
    ((window as unknown as { __invokeLog: Array<{ cmd: string; args: Record<string, unknown> }> }).__invokeLog ?? [])
      .find((e) => e.cmd === "engine_gws_approve")?.args ?? null);
  expect(args).toMatchObject({ id: "gws_smoke1", approval: "smoke-approval-token" });
});

test("19 · apps live in Products: no APPS section; Products opens the Apps page in Home", async ({ page }) => {
  await page.getByText("What should we work on?").waitFor({ timeout: 15_000 });
  await expect(page.getByTestId("sidebar-apps")).toHaveCount(0);
  await page.evaluate(() => window.dispatchEvent(new CustomEvent("prevail:work-section", { detail: "products" })));
  await page.getByTestId("products-open-apps").click();
  await expect(page.getByTestId("apps-view")).toBeVisible({ timeout: 10_000 });
  // Still Home: the sidebar did not flip into Settings.
  await expect(page.getByTestId("nav-home")).toBeVisible();
  await expect(page.getByRole("button", { name: /Back to Home/ })).toHaveCount(0);
  // The Settings group carries no duplicate Apps row.
  await page.getByRole("button", { name: "Settings" }).click();
  await expect(page.getByRole("button", { name: "Connections", exact: true })).toBeVisible({ timeout: 10_000 });
  await expect(page.getByRole("button", { name: "Apps", exact: true })).toHaveCount(0);
});

test("20 · links to removed screens land on Home; old ids reach their new pages", async ({ page }) => {
  await page.getByText("What should we work on?").waitFor({ timeout: 15_000 });
  for (const gone of ["spark", "automations", "loopboard", "calendar", "notes"]) {
    // Leave Home first, so landing back on it proves the route.
    await page.getByTestId("nav-inbox").click();
    await expect(page.getByTestId("inbox-page")).toBeVisible({ timeout: 10_000 });
    await page.evaluate((s) => window.dispatchEvent(new CustomEvent("prevail:open-settings", { detail: s })), gone);
    await expect(page.getByText("What should we work on?")).toBeVisible({ timeout: 10_000 });
    await expect(page.getByTestId("nav-home")).toHaveAttribute("aria-current", "page");
    await page.evaluate((s) => window.dispatchEvent(new CustomEvent("prevail:work-section", { detail: s })), gone);
    await expect(page.getByText("What should we work on?")).toBeVisible();
  }
  // The Work board id opens Tasks; the old Settings Apps id opens the Home Apps page.
  await page.evaluate(() => window.dispatchEvent(new CustomEvent("prevail:open-settings", { detail: "tasks" })));
  await expect(page.getByTestId("tasks-list")).toBeVisible({ timeout: 10_000 });
  await page.evaluate(() => window.dispatchEvent(new CustomEvent("prevail:settings-section", { detail: "connectors" })));
  await expect(page.getByTestId("apps-view")).toBeVisible({ timeout: 10_000 });
  await expect(page.getByTestId("nav-home")).toBeVisible();
});

test("21 · Tasks is a plain list: rows, the waiting chip, no board or view switcher", async ({ page }) => {
  await mockTauri(page, {
    tasks_read_all: [
      { id: "t1", domain: "career", text: "Draft the foo plan", status: "todo", owner: "me", due: null, priority: null },
      { id: "t2", domain: "health", text: "Book the bar check", status: "blocked", owner: "ai", due: null, priority: "high" },
    ],
  });
  await page.goto("/");
  await page.getByText("What should we work on?").waitFor({ timeout: 15_000 });
  await page.getByRole("button", { name: /^Tasks/ }).click();
  const list = page.getByTestId("tasks-list");
  await expect(list).toBeVisible({ timeout: 10_000 });
  await expect(list.getByTestId("task-row")).toHaveCount(2);
  await expect(list.getByTestId("task-row").filter({ hasText: "Book the bar check" }).getByTestId("waiting-chip")).toBeVisible();
  await expect(list.getByTestId("task-row").filter({ hasText: "Draft the foo plan" }).getByTestId("waiting-chip")).toHaveCount(0);
  await expect(page.getByTitle("Board view")).toHaveCount(0);
  await expect(page.getByTitle(/Horizon view/)).toHaveCount(0);
  await expect(page.getByRole("button", { name: /Needs you/ })).toHaveCount(0);
  await expect(page.getByText("Work board")).toHaveCount(0);
  // Opening a task shows its detail.
  await list.getByRole("button", { name: "Draft the foo plan" }).click();
  await expect(page.getByRole("button", { name: /Discuss with AI/ })).toBeVisible();
});

test("22 · the Briefing: dismissing a row shares the Recommendations set; hiding flips the pref", async ({ page }) => {
  const recs = [
    { id: "r1", category: "rules", title: "Foo rule to adopt", detail: "You keep asking for foo.", action: { kind: "open_rules" } },
    { id: "r2", category: "projects", title: "Bar project is stuck", detail: "No prompts in two weeks.", action: { kind: "open_projects" } },
  ];
  await mockTauri(page, { engine_recommendations: { ok: true, recommendations: recs } });
  await page.addInitScript(() => localStorage.setItem("prevail.pref.showHomeBriefing", "1"));
  await page.goto("/");
  const briefing = page.getByTestId("home-briefing");
  await expect(briefing).toBeVisible({ timeout: 15_000 });
  await expect(briefing.getByTestId("briefing-row")).toHaveCount(2);
  const first = briefing.locator("[data-rec=r1]");
  await first.hover();
  await first.getByTestId("briefing-dismiss").click();
  await expect(briefing.locator("[data-rec=r1]")).toHaveCount(0);
  await expect(briefing.getByTestId("briefing-row")).toHaveCount(1);
  expect(await page.evaluate(() => localStorage.getItem("prevail.recs.dismissed"))).toContain("r1");
  // The Recommendations page counts it as dismissed.
  await page.getByTestId("app-sidebar").getByRole("button", { name: "For You", exact: true }).click();
  await expect(page.getByRole("button", { name: /Show dismissed 1/ })).toBeVisible({ timeout: 10_000 });
  await expect(page.getByText("Foo rule to adopt")).toHaveCount(0);
  // Back Home, hide the whole Briefing: the Settings switch turns off.
  await page.getByTestId("nav-home").click();
  await expect(briefing).toBeVisible({ timeout: 10_000 });
  await briefing.getByTestId("briefing-hide").click();
  await expect(page.getByText("Briefing hidden. Turn it back on in Settings.")).toBeVisible();
  await expect(briefing).toHaveCount(0);
  expect(await page.evaluate(() => localStorage.getItem("prevail.pref.showHomeBriefing"))).toBe("0");
});

test("23 · Context: one click shows Memory, a Source file previews inline, the folder opens in Finder", async ({ page }) => {
  await mockTauri(page, {
    read_memory_md: "# Foo memory\nThe bar is open on weekdays.",
    read_text_file: "# Foo goals\nShip the foo.",
    domain_context: { state: "", journal: "", recent_logs: [], skills: [], layoutV4: true },
  });
  await page.goto("/");
  await page.getByText("What should we work on?").waitFor({ timeout: 15_000 });
  await page.getByTestId("open-context").first().click();
  const view = page.getByTestId("context-view");
  await expect(view).toBeVisible({ timeout: 10_000 });
  await view.getByTestId("ctx-row-memory").click();
  await expect(view.getByTestId("ctx-detail-memory").getByTestId("ctx-markdown")).toContainText("The bar is open on weekdays.");
  await view.getByTestId("ctx-row-source").click();
  await view.getByTestId("ctx-item-source/goals.md").click();
  await expect(view.getByTestId("ctx-preview")).toContainText("Ship the foo.");
  const folder = view.getByTestId("ctx-folder");
  // An icon, the path only on hover: no raw path on the page.
  await expect(folder).toHaveAttribute("title", /\/tmp\/smoke-vault/);
  await expect(view).not.toContainText("tmp/smoke-vault");
  await folder.click();
  await expect.poll(() => invokedCommands(page)).toContain("open_in_finder");
  const args = await page.evaluate(() =>
    ((window as unknown as { __invokeLog: Array<{ cmd: string; args: Record<string, unknown> }> }).__invokeLog ?? [])
      .find((e) => e.cmd === "open_in_finder")?.args ?? null);
  expect(args).toEqual({ path: "/tmp/smoke-vault" });
});

// Council: named councils. The old single-panel page (runtime groups in the
// column, a seat diagram) is gone; these replace its test.
const councilPrefs = (page: import("@playwright/test").Page) => page.evaluate(() => {
  const log = (window as unknown as { __invokeLog: Array<{ cmd: string; args: { json?: string } }> }).__invokeLog ?? [];
  const last = [...log].reverse().find((e) => e.cmd === "ui_prefs_set");
  return last?.args.json ? JSON.parse(last.args.json) as Record<string, string> : {};
});

test("24 · Council: build a named council, and the legacy panel keys follow the Default", async ({ page }) => {
  await page.getByText("What should we work on?").waitFor({ timeout: 15_000 });
  await page.evaluate(() => window.dispatchEvent(new CustomEvent("prevail:open-settings", { detail: "council" })));
  const col = page.getByTestId("council-list");
  await expect(col.getByTestId("council-row-default")).toBeVisible({ timeout: 10_000 });
  // An upgrade keeps the old panel as "Default council"; no runtime groups, no seat diagram.
  await expect(col.getByTestId("council-row-default")).toContainText("Default council");
  await expect(col.getByTestId("council-default-mark")).toHaveCount(1);
  await expect(col.locator("[data-testid^=council-row-claude]")).toHaveCount(0);
  await expect(page.getByTestId("council-seats")).toHaveCount(0);

  // The builder: pick models, see the cost, name it, pick a chair, create.
  await page.getByTestId("council-new").click();
  const b = page.getByTestId("council-builder");
  await expect(b.getByTestId("council-cost-seats")).toHaveText("0");
  const picks = b.locator("[data-council-model]");
  const k1 = await picks.nth(0).getAttribute("data-council-model");
  const k2 = await picks.nth(1).getAttribute("data-council-model");
  await picks.nth(0).click();
  await picks.nth(1).click();
  await expect(b.getByTestId("council-cost-seats")).toHaveText("2");
  await expect(b.getByTestId("council-cost-per")).toContainText(/about \$|Free/);
  await b.getByTestId("council-name-input").fill("Foo council");
  await b.getByTestId("council-chair-select").selectOption(k2!);
  await b.getByTestId("council-create").click();
  const row = col.locator("[data-council-name='Foo council']");
  await expect(row).toHaveAttribute("aria-current", "true");
  const detail = page.getByTestId("council-detail");
  await expect(detail.getByTestId("council-members")).toContainText("Chair");

  // Make it the Default: the list, the default id and the legacy keys all follow.
  await detail.getByTestId("council-make-default").click();
  await expect(row.getByTestId("council-default-mark")).toBeVisible();
  await expect.poll(async () => {
    const p = await councilPrefs(page);
    const list = JSON.parse(p["prevail.council.list"] ?? "[]") as Array<{ id: string; name: string; seats: string[]; chair: string }>;
    const foo = list.find((c) => c.name === "Foo council");
    return !!foo && p["prevail.council.defaultId"] === foo.id && p["prevail.council.defaultChair"] === k2
      && JSON.parse(p["prevail.council.defaultMembers"] ?? "[]").sort().join() === [k1, k2].sort().join();
  }, { timeout: 10_000 }).toBe(true);
});

test("24b · Council: Use in chat opens the chat Council tab on that council, and the chat never rewrites the saved chair", async ({ page }) => {
  await page.getByText("What should we work on?").waitFor({ timeout: 15_000 });
  await page.evaluate(() => {
    localStorage.setItem("prevail.council.list", JSON.stringify([
      { id: "default", name: "Default council", seats: ["claude::sonnet"], chair: "claude::sonnet" },
      { id: "foo", name: "Foo council", seats: ["claude::opus", "claude::sonnet"], chair: "claude::opus" },
    ]));
    localStorage.setItem("prevail.council.defaultId", "default");
    window.dispatchEvent(new Event("prevail:council-changed"));
    window.dispatchEvent(new CustomEvent("prevail:open-settings", { detail: "council" }));
  });
  await page.getByTestId("council-row-foo").click();
  await page.getByTestId("council-use-in-chat").click();
  const picker = page.getByTestId("council-picker");
  await expect(picker).toBeVisible({ timeout: 10_000 });
  await expect(picker).toHaveValue("foo");
  await picker.selectOption("default");
  await expect(picker).toHaveValue("default");
  // The saved Default chair is untouched by the chat.
  expect(await page.evaluate(() => localStorage.getItem("prevail.council.defaultChair"))).not.toBe("claude::opus");
  expect(await page.evaluate(() => localStorage.getItem("prevail.council.defaultId"))).toBe("default");
});

test("25 · Arena: the page header holds the handoff to Glyph Arena", async ({ page }) => {
  await mockTauri(page);
  await page.goto("/");
  await page.getByText("What should we work on?").waitFor({ timeout: 15_000 });
  await page.evaluate(() => window.dispatchEvent(new CustomEvent("prevail:open-settings", { detail: "benchmark" })));
  const header = page.locator("[data-shell=header]");
  await expect(header).toContainText("Arena", { timeout: 10_000 });
  await expect(page.getByTestId("open-glyph-arena")).toBeVisible();
});

const TOOLKIT_FX = {
  scan_skills: [
    { domain: "career", name: "foo-review", path: "/tmp/smoke-vault/data/domains/career/memory/skills/foo-review", description: "Review the foo", enabled: true },
    { domain: "health", name: "bar-check", path: "/tmp/smoke-vault/data/domains/health/memory/skills/bar-check", description: "Check the bar", enabled: false },
  ],
  read_skill: "# Foo review\nCheck the foo twice.",
  skill_set_enabled: null,
};

test("26 · Toolkit: one page with Skills, Tools and Frameworks; a skill turns off with the same command", async ({ page }) => {
  await mockTauri(page, TOOLKIT_FX);
  await page.goto("/");
  await page.getByText("What should we work on?").waitFor({ timeout: 15_000 });
  await page.getByRole("button", { name: "Settings" }).click();
  await page.getByRole("button", { name: "Toolkit", exact: true }).click();
  for (const gone of ["Skills", "Tools", "Frameworks"]) {
    await expect(page.getByTestId("app-sidebar").getByRole("button", { name: gone, exact: true })).toHaveCount(0);
  }
  await expect(page.getByTestId("page-header")).toContainText("Toolkit", { timeout: 10_000 });
  const col = page.getByTestId("toolkit-list");
  await expect(col.getByTestId("toolkit-group-skills")).toContainText("1 of 2 on");
  await expect(col.getByTestId("toolkit-group-tools")).toBeVisible();
  await expect(col.getByTestId("toolkit-group-frameworks")).toBeVisible();
  // Groups start collapsed: open Skills, then the career source.
  await col.getByTestId("toolkit-group-skills").click();
  await col.getByTestId("toolkit-src-career").click();
  await col.getByTestId("toolkit-skill-foo-review").click();
  const detail = page.getByTestId("toolkit-detail-skill");
  await expect(detail.getByTestId("toolkit-skill-body")).toContainText("Check the foo twice.");
  await detail.getByLabel("Turn off foo-review").click();
  await expect.poll(() => page.evaluate(() =>
    ((window as unknown as { __invokeLog: Array<{ cmd: string; args: Record<string, unknown> }> }).__invokeLog ?? [])
      .find((e) => e.cmd === "skill_set_enabled")?.args ?? null)).toMatchObject({ domain: "career", name: "foo-review", enabled: false });
  await expect(col.getByTestId("toolkit-group-skills")).toContainText("0 of 2 on");
  // A tool and a framework open in the same pane.
  await col.getByTestId("toolkit-group-tools").click();
  await col.getByTestId("toolkit-tool-Memory").click();
  await expect(page.getByTestId("toolkit-detail-tool")).toContainText("Remember and recall durable facts");
});

test("27 · old Skills, Tools and Frameworks links open Toolkit on that group", async ({ page }) => {
  await mockTauri(page, TOOLKIT_FX);
  await page.goto("/");
  await page.getByText("What should we work on?").waitFor({ timeout: 15_000 });
  await page.evaluate(() => window.dispatchEvent(new CustomEvent("prevail:open-settings", { detail: "skills" })));
  await expect(page.getByTestId("toolkit-list")).toBeVisible({ timeout: 10_000 });
  await expect(page.getByTestId("toolkit-detail-skill")).toContainText("Foo Review");
  await page.evaluate(() => window.dispatchEvent(new CustomEvent("prevail:open-settings", { detail: "frameworks" })));
  await expect(page.getByTestId("toolkit-detail-fw")).toBeVisible({ timeout: 10_000 });
  await page.evaluate(() => window.dispatchEvent(new CustomEvent("prevail:settings-section", { detail: "tools" })));
  await expect(page.getByTestId("toolkit-detail-tool")).toBeVisible({ timeout: 10_000 });
});

// Context & Memory pages, laid out like Models: the header first, the side
// column below it, and a pick in the column changes the detail.
async function headerAboveColumn(page: import("@playwright/test").Page, title: string, columnId: string) {
  const header = page.getByTestId("settings-page").getByTestId("page-header").first();
  await expect(header).toContainText(title, { timeout: 10_000 });
  const col = page.getByTestId(columnId);
  await expect(col).toHaveAttribute("data-spine-column");
  const hb = await header.boundingBox();
  const cb = await col.boundingBox();
  expect(hb!.y + hb!.height).toBeLessThanOrEqual(cb!.y + 1);
  return col;
}
async function openSettings(page: import("@playwright/test").Page, section: string) {
  await page.getByText("What should we work on?").waitFor({ timeout: 15_000 });
  await page.evaluate((s) => window.dispatchEvent(new CustomEvent("prevail:open-settings", { detail: s })), section);
}

test("28 · Ideals live in the Compass: an old Ideals link opens its Ideals view; picking a domain shows its ideal", async ({ page }) => {
  await openSettings(page, "ideal-state");
  await expect(page.getByTestId("work-page").getByTestId("page-header").first()).toContainText("Compass", { timeout: 10_000 });
  await expect(page.getByTestId("tab-ideals")).toHaveAttribute("aria-selected", "true");
  const col = page.getByTestId("ideals-list");
  await expect(col.getByTestId("ideal-row-mission")).toHaveAttribute("aria-current", "true");
  await expect(page.getByTestId("ideal-detail-mission")).toBeVisible();
  await col.getByTestId("ideal-row-domain:career").click();
  const detail = page.getByTestId("ideal-detail-domain");
  await expect(detail).toContainText("Career");
  await expect(detail).toContainText("Financial security with a 6-month runway.");
  await expect(page.getByTestId("ideal-detail-mission")).toHaveCount(0);
});

test("29 · Daemons live in Settings: each routine is a side row; picking one shows its controls", async ({ page }) => {
  await openSettings(page, "daemons");
  const col = await headerAboveColumn(page, "Settings", "hub-settings");
  await expect(col.getByTestId("hub-row-daemon:distill")).toHaveAttribute("aria-current", "true");
  await expect(page.getByTestId("daemon-detail-distill")).toContainText("Hub only");
  await col.getByTestId("hub-row-daemon:reminders").click();
  await expect(page.getByTestId("daemon-detail-reminders")).toContainText("Reminders interval");
  await expect(page.getByTestId("daemon-detail-distill")).toHaveCount(0);
  await col.getByTestId("hub-row-daemon:role").click();
  await expect(page.getByTestId("daemon-detail-role")).toContainText("This machine's role");
});

test("30 · Activity: kinds with counts; picking one filters the feed", async ({ page }) => {
  await mockTauri(page, {
    activity_read: [
      { ts: Date.now() - 60_000, type: "briefing", domain: "career", title: "Foo briefing sent" },
      { ts: Date.now() - 120_000, type: "sync", domain: "health", title: "Bar app synced" },
      { ts: Date.now() - 180_000, type: "sync", domain: "health", title: "Bar app synced again" },
    ],
  });
  await page.goto("/");
  await openSettings(page, "activity");
  const col = await headerAboveColumn(page, "Activity", "activity-list");
  await expect(col.getByTestId("activity-kind-all")).toContainText("3");
  await expect(col.getByTestId("activity-kind-sync")).toContainText("2");
  await expect(col.getByTestId("activity-kind-loop_run")).toHaveCount(0);
  const detail = page.getByTestId("activity-detail");
  await expect(detail).toContainText("Foo briefing sent");
  await col.getByTestId("activity-kind-sync").click();
  await expect(detail.getByRole("heading", { level: 2 })).toContainText("Syncs");
  await expect(detail).toContainText("Bar app synced");
  await expect(detail).not.toContainText("Foo briefing sent");
});

test("31 · Usage is part of Activity: views in its column; a breakdown replaces the overview", async ({ page }) => {
  await openSettings(page, "usage");
  const col = await headerAboveColumn(page, "Activity", "activity-list");
  await expect(col.getByTestId("usage-view-overview")).toHaveAttribute("aria-current", "true");
  await page.getByTestId("settings-page").getByRole("button", { name: "All time" }).click();
  const detail = page.getByTestId("activity-detail");
  await expect(detail).toContainText("When you use it");
  await col.getByTestId("usage-view-domain").click();
  await expect(detail.getByRole("heading", { level: 2 })).toHaveText("By domain");
  await expect(detail).toContainText("career");
  await expect(detail).not.toContainText("When you use it");
});

test("31b · Usage leads with every AI tool's own records: API price, paid, and the estimate labeled", async ({ page }) => {
  await openSettings(page, "usage");
  const panel = page.getByTestId("ai-all-tools");
  await expect(panel).toContainText("All AI tools", { timeout: 10_000 });
  await expect(page.getByTestId("ai-all-tools-usd")).toHaveText("$84.50");
  await expect(panel).toContainText("2 machines");
  await expect(panel).toContainText("paid $20.00");
  await expect(panel.getByTestId("ai-tool-row")).toHaveCount(3);
  await expect(panel.getByTestId("ai-tool-row").filter({ hasText: "Wispr Flow" })).toContainText("31 prompts");
  await expect(panel).toContainText("estimated");
  expect(await invokeArgs(page, "engine_ai_usage")).toContainEqual({ vault: "/tmp/smoke-vault", month: null });
});

// Ideals moved into the Compass (a Home page) in Goals G1.
// Entities left Settings for the Home sidebar (ia-plan.md).
const EDITOR_ROWS = ["Models", "Council", "Toolkit", "Arena", "Intent", "Activity", "Connections", "Privacy & Safety", "Settings"];

test("32 · the Settings nav is 9 rows, and each opens a header above a side column", async ({ page }) => {
  await page.getByText("What should we work on?").waitFor({ timeout: 15_000 });
  await page.getByRole("button", { name: "Settings" }).click();
  const nav = page.getByTestId("app-sidebar");
  await expect(nav.getByRole("button", { name: "Back to Home" })).toBeVisible({ timeout: 10_000 });
  const labels = await nav.locator("button[aria-current], button").evaluateAll((els) =>
    els.map((e) => (e as HTMLElement).innerText.trim()));
  for (const l of EDITOR_ROWS) expect(labels).toContain(l);
  for (const gone of ["Phone", "Gateway", "MCP", "Hooks", "Network", "Autonomy", "Privacy", "Safety", "Profiles", "Vault", "General", "About", "Daemons", "Usage", "Ideals"]) {
    expect(labels, `${gone} should be a side row now, not a nav row`).not.toContain(gone);
  }
  for (const l of EDITOR_ROWS) {
    await nav.getByRole("button", { name: l, exact: true }).click();
    const pageEl = page.getByTestId("settings-page");
    const header = pageEl.getByTestId("page-header").filter({ hasText: l }).first();
    await expect(header).toBeVisible({ timeout: 10_000 });
    // Intent with no captured prompts shows its empty state, not a column.
    if (l === "Intent" || l === "Arena") continue; // Arena is a one-card handoff to Glyph Arena since 0.4.10
    const col = pageEl.locator("[data-spine-column]").first();
    await expect(col).toBeVisible();
    const hb = await header.boundingBox();
    const cb = await col.boundingBox();
    expect(hb!.y + hb!.height, `${l}: header above the column`).toBeLessThanOrEqual(cb!.y + 1);
  }
});

test("33 · old Settings ids land on the new page with the right row picked", async ({ page }) => {
  await page.getByText("What should we work on?").waitFor({ timeout: 15_000 });
  const cases: Array<[string, string, string]> = [
    ["privacy", "hub-privacy-safety", "hub-row-bunker"],
    ["phone", "hub-connections", "hub-row-phone"],
    ["usage", "activity-list", "usage-view-overview"],
    ["daemons", "hub-settings", "hub-row-daemon:distill"],
    ["about", "hub-settings", "hub-row-about"],
    ["remote", "hub-connections", "hub-row-network"],
    ["profiles", "hub-settings", "hub-row-profiles"],
  ];
  for (const [id, col, row] of cases) {
    await page.evaluate((s) => window.dispatchEvent(new CustomEvent("prevail:open-settings", { detail: s })), id);
    await expect(page.getByTestId(col).getByTestId(row), id).toHaveAttribute("aria-current", "true", { timeout: 10_000 });
  }
  // The sidebar highlight follows the page, not the old id.
  await expect(page.getByTestId("app-sidebar").locator("[aria-current=page]")).toHaveText("Settings");
});

// ── Entity chat ────────────────────────────────────────────────────────────
const FOO_ENTITY = {
  entities_list: { generated_ts: 1, total: 1, entities: [{ id: "person/foo", name: "Foo Bar", kind: "person", aliases: [], mention_count: 1, conversations: 1, last_ts: 1, saved: true, has_page: true }] },
  entities_show: { found: true, id: "person/foo", name: "Foo Bar", kind: "person", aliases: [], kinds: ["person"], mention_count: 1, conversations: 1, last_ts: 1783000000000, mentions: [], co_mentions: [], page_path: "data/entities/people/foo.md", saved: true, digest: "", notes: "" },
  engine_entity_note_append: { ok: true },
};
const FOO_ENTITY_THREAD = "/tmp/smoke-vault/data/domains/general/_threads/foo-entity.md";
const withThread = {
  ...FOO_ENTITY,
  engine_entity_threads: [{ slug: "foo-entity", domain: "general", title: "Lunch with Foo", updated: 1783000000000, turns: 2 }],
  list_threads: [{ path: FOO_ENTITY_THREAD, slug: "foo-entity", title: "Lunch with Foo", domain: null, created: 1783000000, updated: 1783000000, turn_count: 2, preview: "", cli: "claude", model: null, entity: "person/foo" }],
  load_thread: {
    meta: { path: FOO_ENTITY_THREAD, slug: "foo-entity", title: "Lunch with Foo", domain: null, created: 1783000000, updated: 1783000000, turn_count: 2, preview: "", cli: "claude", model: null, entity: "person/foo" },
    turns: [
      { role: "user", cli: null, model: null, content: "Where should I take Foo for lunch?" },
      { role: "assistant", cli: "claude", model: null, content: "Foo likes the bar by the river." },
    ],
  },
};
const invokeArgs = (page: import("@playwright/test").Page, cmd: string) => page.evaluate((c) =>
  ((window as unknown as { __invokeLog: Array<{ cmd: string; args: Record<string, unknown> }> }).__invokeLog ?? [])
    .filter((e) => e.cmd === c).map((e) => e.args), cmd);

async function openFoo(page: import("@playwright/test").Page) {
  await page.getByText("What should we work on?").waitFor({ timeout: 15_000 });
  await page.evaluate(() => window.dispatchEvent(new CustomEvent("prevail:open-settings", { detail: "entities" })));
  await expect(page.getByTestId("entity-detail")).toContainText("Foo Bar", { timeout: 10_000 });
}

test("34 · Chat on an entity is a tab of the detail pane and every turn carries --entity", async ({ page }) => {
  await mockTauri(page, { ...FOO_ENTITY, read_ideal_state: "", read_omega: "", read_user_md: "", read_memory_md: "", engine_entity_threads: [], save_thread: "/tmp/smoke-vault/data/domains/general/_threads/foo-new.md" });
  await page.goto("/");
  await openFoo(page);
  await page.getByTestId("entity-tab-chat").click();
  const chat = page.getByTestId("entity-chat");
  await expect(chat).toBeVisible({ timeout: 10_000 });
  await expect(chat.getByTestId("entity-chat-empty")).toContainText("Foo Bar");
  const box = chat.locator("[data-tour=composer] textarea");
  await box.fill("What do I know about Foo?");
  await box.press("Enter");
  await expect.poll(async () => (await invokeArgs(page, "engine_chat"))[0] ?? null, { timeout: 10_000 })
    .toMatchObject({ entity: "person/foo", domain: "general", message: expect.stringContaining("What do I know about Foo?") });
  // Saved like a General thread, tagged with the entity.
  await expect.poll(async () => (await invokeArgs(page, "save_thread"))[0] ?? null, { timeout: 10_000 })
    .toMatchObject({ domain: null, entity: "person/foo" });
  await page.getByTestId("entity-tab-overview").click();
  await expect(page.getByTestId("entity-overview")).toBeVisible();
});

test("35 · Add to notes appends a reply to the entity's notes", async ({ page }) => {
  await mockTauri(page, withThread);
  await page.goto("/");
  await openFoo(page);
  await page.getByTestId("entity-tab-chat").click();
  const chat = page.getByTestId("entity-chat");
  const reply = chat.getByText("Foo likes the bar by the river.");
  await expect(reply).toBeVisible({ timeout: 10_000 });
  await reply.hover();
  await chat.getByTitle("Add to notes").click();
  await expect.poll(async () => (await invokeArgs(page, "engine_entity_note_append"))[0] ?? null)
    .toEqual({ vault: "/tmp/smoke-vault", id: "person/foo", text: "Foo likes the bar by the river." });
  await expect(page.getByText("Added to notes.")).toBeVisible();
});

test("36 · Your conversations lists the entity's threads and opens one; the General rail marks it", async ({ page }) => {
  await mockTauri(page, withThread);
  await page.goto("/");
  await page.getByText("What should we work on?").waitFor({ timeout: 15_000 });
  await expect(page.getByTestId("threads-list").getByTestId("thread-entity-chip")).toContainText("Foo Bar", { timeout: 10_000 });
  await openFoo(page);
  await page.getByTestId("entity-tab-conversations").click();
  const convo = page.getByTestId("entity-conversations").getByTestId("entity-conversation");
  await expect(convo).toContainText("Lunch with Foo");
  await convo.click();
  const chat = page.getByTestId("entity-chat");
  await expect(chat.getByText("Foo likes the bar by the river.")).toBeVisible({ timeout: 10_000 });
  await expect(page.getByTestId("entity-thread-picker")).toHaveValue("foo-entity");
  await page.screenshot({ path: `${process.env.MOBILE_SHOTS_DIR || "/tmp"}/desktop-entity-chat.png` });
  expect(await invokeArgs(page, "engine_entity_threads")).toContainEqual({ vault: "/tmp/smoke-vault", id: "person/foo" });
});

// ── Goals and Tasks, laid out like Intent > Projects ────────────────────────
test("37 · Compass > Goals: domain goals, a new goal writes source/goals.md, a goal opens its detail", async ({ page }) => {
  await mockTauri(page, {
    goals_files_read: [{ domain: "health", path: "/tmp/smoke-vault/data/domains/health/source/goals.md", body: "- [ ] Run a foo marathon ~id:g-1 ~status:active ~due:2026-12-31 ~progress:40\n  why: Feel strong again.\n" }],
    goals_file_write: "/tmp/smoke-vault/data/domains/general/source/goals.md",
  });
  await page.goto("/");
  await page.getByText("What should we work on?").waitFor({ timeout: 15_000 });
  await page.getByRole("button", { name: "Compass" }).click();
  await expect(page.getByTestId("work-page").getByTestId("page-header").first()).toContainText("Compass", { timeout: 10_000 });
  await page.getByTestId("tab-goals").click();
  await expect(page.getByTestId("tab-active")).toHaveAttribute("aria-selected", "true");
  const col = page.getByTestId("goals-list");
  // A goal row opens its detail.
  await col.getByTestId("goal-row").filter({ hasText: "Run a foo marathon" }).click();
  const detail = page.getByTestId("goal-detail");
  await expect(detail.getByLabel("Goal title")).toHaveValue("Run a foo marathon");
  await expect(detail.getByLabel("Why it matters")).toHaveValue("Feel strong again.");
  await expect(detail.getByLabel("Target date")).toHaveValue("2026-12-31");
  // New goal goes to General's source/goals.md.
  await col.getByTestId("goal-new").click();
  await expect.poll(() => page.evaluate(() =>
    ((window as unknown as { __invokeLog: Array<{ cmd: string; args: Record<string, unknown> }> }).__invokeLog ?? [])
      .find((e) => e.cmd === "goals_file_write")?.args ?? null)).toMatchObject({ vault: "/tmp/smoke-vault", domain: "general", body: expect.stringMatching(/^- \[ \] New goal ~id:g-\S+ ~status:active\n$/) });
  await expect(page.getByTestId("goal-detail").getByLabel("Goal title")).toHaveValue("New goal");
});

test("38 · Tasks: a task opens in the right pane, and no fixed side panel exists", async ({ page }) => {
  await mockTauri(page, {
    tasks_read_all: [
      { id: "t1", domain: "career", text: "Draft the foo plan", status: "todo", owner: "me", due: null, priority: null },
      { id: "t2", domain: "career", text: "Answer the bar email", status: "blocked", owner: "ai", due: null, priority: null },
      { id: "t3", domain: "health", text: "Old foo chore", status: "done", owner: "me", due: null, priority: null },
    ],
  });
  await page.goto("/");
  await page.getByText("What should we work on?").waitFor({ timeout: 15_000 });
  await page.getByRole("button", { name: /^Tasks/ }).click();
  const header = page.getByTestId("work-page").getByTestId("page-header").first();
  await expect(header.getByTestId("tab-open")).toContainText("2", { timeout: 10_000 });
  await expect(header.getByTestId("tab-waiting")).toContainText("1");
  const list = page.getByTestId("tasks-list");
  await expect(list.getByTestId("task-row")).toHaveCount(2);
  await header.getByTestId("tab-waiting").click();
  await expect(list.getByTestId("task-row")).toHaveCount(1);
  await expect(list.getByTestId("task-row").getByTestId("waiting-chip")).toBeVisible();
  await header.getByTestId("tab-open").click();
  await list.getByTestId("task-row").filter({ hasText: "Draft the foo plan" }).click();
  const detail = page.getByTestId("spine-detail").getByTestId("task-detail");
  await expect(detail.getByLabel("Task title")).toHaveValue("Draft the foo plan");
  await expect(detail.getByRole("button", { name: /Discuss with AI/ })).toBeVisible();
  // Nothing floats over the page from the right.
  const fixed = await page.evaluate(() => [...document.querySelectorAll("body *")].filter((el) => {
    const cs = getComputedStyle(el);
    return cs.position === "fixed" && el.getBoundingClientRect().width > 300 && el.getBoundingClientRect().left > window.innerWidth / 2;
  }).length);
  expect(fixed).toBe(0);
});

// ── The mission: edit a section in place, versions, restore ─────────────────
const MISSION = "# Foo ideal\n\nLive a calm foo life.\n\n## Operating Vision\n\nQuiet mornings.\n\n## Core Principles\n\nBe kind to bar.\n";
const missionFx = {
  read_ideal_state: MISSION,
  ideal_state_versions: [
    { name: "2026-09-26T10-00-00Z", path: "/tmp/smoke-vault/build/ideal-state.versions/2026-09-26T10-00-00Z.md", ts: 1 },
    { name: "2026-09-20T10-00-00Z", path: "/tmp/smoke-vault/build/ideal-state.versions/2026-09-20T10-00-00Z.md", ts: 0 },
  ],
  ideal_state_version_read: "# Foo ideal\n\nLive a calm foo life.\n\n## Operating Vision\n\nSlow mornings.\n",
  write_ideal_state: null,
};
async function openMission(page: import("@playwright/test").Page) {
  await page.getByText("What should we work on?").waitFor({ timeout: 15_000 });
  await page.evaluate(() => window.dispatchEvent(new CustomEvent("prevail:open-settings", { detail: "ideal-state" })));
  await expect(page.getByTestId("mission-editor-page")).toBeVisible({ timeout: 10_000 });
}
const writes = (page: import("@playwright/test").Page) => page.evaluate(() =>
  ((window as unknown as { __invokeLog: Array<{ cmd: string; args: Record<string, unknown> }> }).__invokeLog ?? [])
    .filter((e) => e.cmd === "write_ideal_state").map((e) => String(e.args.body)));

test("39 · Constitution: clicking a section edits it in place; saving writes it and refreshes the versions", async ({ page }) => {
  await mockTauri(page, missionFx);
  await page.goto("/");
  await openMission(page);
  const section = page.locator("[data-testid=mission-section][data-heading='Core Principles']");
  await section.click();
  const box = page.getByTestId("mission-editor").getByRole("textbox");
  await expect(box).toHaveValue(/Be kind to bar\./);
  await box.fill("## Core Principles\n\nBe very kind to bar.");
  const before = (await invokedCommands(page)).filter((c) => c === "ideal_state_versions").length;
  await box.press("Meta+Enter");
  await expect.poll(() => writes(page)).toHaveLength(1);
  const saved = (await writes(page))[0];
  expect(saved).toContain("Be very kind to bar.");
  expect(saved).toContain("Quiet mornings.");
  // The backend keeps the old text as a version on that write; the list is re-read.
  await expect.poll(async () => (await invokedCommands(page)).filter((c) => c === "ideal_state_versions").length).toBeGreaterThan(before);
  await expect(page.getByTestId("mission-editor")).toHaveCount(0);
  // Esc cancels without writing.
  await page.locator("[data-testid=mission-section][data-heading='Operating Vision']").click();
  await page.getByTestId("mission-editor").getByRole("textbox").press("Escape");
  await expect(page.getByTestId("mission-editor")).toHaveCount(0);
  expect(await writes(page)).toHaveLength(1);
});

test("40 · Constitution versions: newest first with Latest on top; Restore saves a new latest", async ({ page }) => {
  await mockTauri(page, missionFx);
  await page.goto("/");
  await openMission(page);
  await page.getByTestId("tab-versions").click();
  const rows = page.getByTestId("mission-versions").getByTestId("version-row");
  await expect(rows).toHaveCount(3);
  await expect(rows.first().getByTestId("version-latest")).toHaveText("Latest");
  await expect(rows.nth(1)).toContainText("Sep 26");
  await expect(rows.nth(2)).toContainText("Sep 20");
  await expect(rows.first()).toContainText(/Changed|words|Reworded/);
  await rows.nth(1).click();
  await expect(page.getByTestId("version-detail")).toContainText("Slow mornings.");
  await page.getByTestId("version-restore").click();
  await expect.poll(() => writes(page)).toHaveLength(1);
  expect((await writes(page))[0]).toContain("Slow mornings.");
  await expect(rows.first()).toHaveAttribute("aria-current", "true");
});

// ── The Compass: drafted lines wait as Proposed until the user confirms ─────
const COMPASS = `# Compass

## Mission

Live a calm foo life.
~status:proposed
  words: "Live a calm foo life."
  from: build/ideal-state.md

## Values

- Peace of mind ~id:v-peace ~rank:1 ~status:proposed
  words: "Grow foo while preserving peace of mind."
  from: build/ideal-state.md
- Freedom ~id:v-free ~rank:2
  words: "So work becomes a choice."
  enough: two foo days a week

## Non-negotiables

- Home for dinner ~id:nn-dinner ~status:proposed
  words: "Home for dinner five nights."
  from: data/domains/general/memory/memory.md
`;
const compassWrites = (page: import("@playwright/test").Page) => page.evaluate(() =>
  ((window as unknown as { __invokeLog: Array<{ cmd: string; args: Record<string, unknown> }> }).__invokeLog ?? [])
    .filter((e) => e.cmd === "compass_write").map((e) => e.args as { body: string; changes: Array<{ id: string; to: string }> }));

test("41 · Compass: proposed lines show their words and source; confirm one, drop one, then confirm all", async ({ page }) => {
  await mockTauri(page, { compass_read: COMPASS, compass_write: null, compass_versions: [], compass_ledger: [] });
  await page.goto("/");
  await page.getByText("What should we work on?").waitFor({ timeout: 15_000 });
  await page.getByRole("button", { name: "Compass" }).click();
  const header = page.getByTestId("work-page").getByTestId("page-header").first();
  await expect(header).toContainText("Compass", { timeout: 10_000 });
  await expect(page.getByTestId("tab-compass")).toHaveAttribute("aria-selected", "true");
  // Overview: the mission, the ranked values, and what waits.
  await expect(page.getByTestId("compass-needs-you")).toContainText("3 lines drafted from your notes");
  await expect(page.getByTestId("compass-detail-overview")).toContainText("Live a calm foo life.");
  // Values: words, enough and the source file on each line.
  await page.getByTestId("compass-row-values").click();
  const peace = page.locator("[data-testid=compass-item][data-id=v-peace]");
  // A line opens to its words and fields.
  await peace.getByTestId("line-open").click();
  await expect(peace).toContainText("Grow foo while preserving peace of mind.");
  await expect(peace).toContainText("From Your constitution");
  await expect(peace.getByTestId("compass-proposed")).toBeVisible();
  await page.locator("[data-testid=compass-item][data-id=v-free]").getByTestId("line-open").click();
  await expect(page.locator("[data-testid=compass-item][data-id=v-free]")).toContainText("Enough: two foo days a week");
  await peace.getByRole("button", { name: "Confirm Peace of mind" }).click();
  await expect.poll(async () => (await compassWrites(page)).length).toBe(1);
  const first = (await compassWrites(page))[0];
  expect(first.changes).toEqual([{ id: "v-peace", from: "proposed", to: "confirmed", reason: "confirmed", by: "user" }]);
  expect(first.body).toContain("- Peace of mind ~id:v-peace ~rank:1\n  words:");
  expect(first.body).toContain("- Freedom ~id:v-free ~rank:2\n  words: \"So work becomes a choice.\"\n  enough: two foo days a week\n");
  await expect(peace.getByTestId("compass-proposed")).toHaveCount(0);
  // Drop the rule: it leaves the file; the backend keeps a version and the ledger.
  await page.getByTestId("compass-row-rules").click();
  // One primary action per row (Confirm); "Not mine" lives in the row menu.
  await page.getByRole("button", { name: /^More for Home for dinner/ }).click();
  await page.getByRole("menuitem", { name: /Not mine/ }).click();
  await expect.poll(async () => (await compassWrites(page)).length).toBe(2);
  expect((await compassWrites(page))[1].body).not.toContain("Home for dinner");
  // Confirm all takes what is left (the mission).
  await header.getByTestId("compass-confirm-all").click();
  await expect.poll(async () => (await compassWrites(page)).length).toBe(3);
  expect((await compassWrites(page))[2].changes.map((c) => c.id)).toEqual(["mission"]);
  await expect(header.getByTestId("compass-confirm-all")).toHaveCount(0);
});

test("42 · Compass: with nothing yet, one button drafts it from the vault", async ({ page }) => {
  await mockTauri(page, { compass_read: "", engine_compass_bootstrap: { added: [], rejected: [], method: "model" } });
  await page.goto("/");
  await page.getByText("What should we work on?").waitFor({ timeout: 15_000 });
  await page.getByRole("button", { name: "Compass" }).click();
  await page.getByTestId("compass-draft").click();
  await expect.poll(async () => (await invokedCommands(page)).includes("engine_compass_bootstrap")).toBe(true);
});

// ── Insights > Metrics: the week against your normal, with sources ─────────
const N = (lo: number, hi: number, learning = false) => ({ median: (lo + hi) / 2, lo, hi, weeks: learning ? 2 : 8, learning, learningWeeksLeft: learning ? 2 : 0 });
const METRICS_FX = {
  glance: {
    week: "2026-09-28", through: "2026-10-02", computed: 1, surprise: "Commits: 40 this week, above your normal of 5 to 12.",
    rows: [
      { id: "m-ai-spend", title: "AI spend", unit: "usd", tier: "measured", family: "AI and building", value: 42.5, normal: N(20, 50), spark: [10, 20, 30, 25, 40, 35, 30, 20, 45, 50, 30, 42.5], documentary: false, coverage: "one Mac (foo-mac), 2026-08-01 to 2026-10-02", citations: [{ file: "build/_meta/events/claude/2026-10.foo-mac.jsonl", note: "12 records this week" }] },
      { id: "m-shipped", title: "Things shipped", unit: "count", tier: "derived", family: "AI and building", value: 3, normal: N(0, 2, true), spark: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 3], documentary: false, coverage: "one Mac (foo-mac)", citations: [] },
      { id: "m-trips", title: "Trips", unit: "count", tier: "measured", family: "Exploration", value: 0, normal: N(0, 0, true), spark: [], documentary: true, coverage: "your vault; trip atlas scanned 2026-09-25", citations: [{ file: "data/domains/content/memory/skills/foo-atlas/trips.json", note: "2026-09-12" }], record: "Latest: Hike, Foo Valley on 2026-09-12" },
    ],
  },
  list: [
    { id: "m-ai-spend", title: "AI spend", family: "AI and building", per: "week", unit: "usd", tier: "measured", documentary: false, status: "tracking", from: "every AI tool's own records", thisWeek: 42.5, normal: N(20, 50), coverage: "one Mac", citations: [], spark: [1, 2, 3] },
    { id: "m-commits", title: "Commits", family: "AI and building", per: "week", unit: "count", tier: "measured", documentary: false, status: "tracking", from: "git", thisWeek: 40, normal: N(5, 12), coverage: "one Mac", citations: [], spark: [5, 9, 40] },
    { id: "m-trips", title: "Trips", family: "Exploration", per: "month", unit: "count", tier: "measured", documentary: true, status: "tracking", from: "the trip atlas", thisWeek: 0, normal: N(0, 0, true), coverage: "your vault", citations: [], spark: [] },
  ],
  rhythm: [{ day: "2026-10-01", hour: 9.5, kind: "prompt" }, { day: "2026-10-01", hour: 22, kind: "commit" }, { day: "2026-09-30", hour: 14, kind: "prompt" }],
  sources: [{ id: "ai", kind: "machine", files: [], events: 120, first: "2026-08-01", last: "2026-10-02", hosts: ["foo-mac"] }, { id: "trips", kind: "vault", files: [], events: 3, note: "trip atlas scanned 2026-09-25" }],
};

test("43 · Insights > Metrics: the week against your normal, tiers, coverage and sources; families, rhythm, sources", async ({ page }) => {
  await mockTauri(page);
  await page.addInitScript((fx) => {
    (window as unknown as { __fixtures: Record<string, unknown> }).__fixtures.engine_metrics = (a: { view: string }) => (fx as Record<string, unknown>)[a.view];
  }, METRICS_FX);
  await page.goto("/");
  await page.getByText("What should we work on?").waitFor({ timeout: 15_000 });
  await page.getByTestId("app-sidebar").getByRole("button", { name: "Insights" }).click();
  await page.getByTestId("tab-metrics").click();
  const week = page.getByTestId("metrics-week");
  await expect(week).toContainText("This week, Sep 28 to Oct 2", { timeout: 10_000 });
  const spend = week.locator("[data-testid=glance-row][data-id=m-ai-spend]");
  await expect(spend.getByTestId("glance-value")).toHaveText("$42.50");
  await expect(spend.getByTestId("glance-tier")).toHaveText("Measured");
  await expect(spend).toContainText("normal $20.00 to $50.00");
  await expect(spend.getByTestId("glance-coverage")).toHaveText("one Mac (foo-mac), 2026-08-01 to 2026-10-02");
  await expect(spend.getByTestId("normal-band")).toHaveCount(1);
  await spend.getByTestId("metric-sources-toggle").click();
  await expect(spend.getByTestId("metric-sources")).toContainText("build/_meta/events/claude/2026-10.foo-mac.jsonl, 12 records this week");
  await expect(week.locator("[data-testid=glance-row][data-id=m-shipped]")).toContainText("learning your normal, 2 more weeks");
  const trips = week.locator("[data-testid=glance-row][data-id=m-trips]");
  await expect(trips).toContainText("A record, no target");
  await expect(trips).toContainText("Latest: Hike, Foo Valley on 2026-09-12");
  await expect(trips.getByTestId("glance-value")).toHaveCount(0);
  await expect(page.getByTestId("glance-surprise")).toContainText("Commits: 40 this week");
  // A family: small multiples.
  await page.getByTestId("metrics-row-family:AI and building").click();
  await expect(page.getByTestId("metrics-family").getByTestId("metric-card")).toHaveCount(2);
  // Rhythm: one dot per prompt and commit.
  await page.getByTestId("metrics-row-rhythm").click();
  await expect(page.getByTestId("rhythm-plot").locator("circle")).toHaveCount(3);
  await expect(page.getByTestId("metrics-rhythm")).toContainText("2 prompts, 1 commits");
  // Sources.
  await page.getByTestId("metrics-row-sources").click();
  await expect(page.getByTestId("source-row")).toHaveCount(2);
  await expect(page.getByTestId("metrics-sources")).toContainText("On foo-mac");
  expect(await invokeArgs(page, "engine_metrics")).toContainEqual({ vault: "/tmp/smoke-vault", view: "glance", week: null });
});
