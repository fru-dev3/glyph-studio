// The phone's half of QR pairing, exercised through the REAL browser path.
//
// This file deliberately does NOT install the Tauri mock: with
// __TAURI_INTERNALS__ absent, bridge.ts takes the HTTP route a phone takes, so
// /api/pair is actually called. The promise under test is the one a phone
// keyboard makes expensive to break: scanning the code gets you in, and a
// password field never appears.
import { test, expect } from "@playwright/test";
import { FIXTURES } from "./tauri-mock";

const CODE = "deadbeefdeadbeefdeadbeefdeadbeef";

async function serveBridge(page: import("@playwright/test").Page, opts: { pairStatus?: number; overrides?: Record<string, unknown> } = {}) {
  const pairCalls: string[] = [];
  await page.route("**/api/pair", async (route) => {
    pairCalls.push(route.request().postData() ?? "");
    const status = opts.pairStatus ?? 200;
    await route.fulfill({
      status,
      contentType: "application/json",
      body: JSON.stringify(status === 200 ? { token: "paired-token" } : { error: "this code has expired, show a new one on your Mac" }),
    });
  });
  await page.route("**/api/invoke", async (route) => {
    const { cmd } = JSON.parse(route.request().postData() || "{}") as { cmd: string };
    const table = { ...FIXTURES, ...(opts.overrides ?? {}) };
    await route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify({ data: table[cmd] ?? null }) });
  });
  // EventSource: answer so the stream opens and closes rather than hanging.
  await page.route("**/api/events**", (route) => route.fulfill({ status: 200, contentType: "text/event-stream", body: "" }));
  await page.addInitScript(() => {
    localStorage.setItem("prevail.desktop.vaultPath", "/tmp/smoke-vault");
    localStorage.setItem("prevail.onboarding.seen", "1");
    localStorage.setItem("prevail.onboarding.encryptOffered", "1");
  });
  return pairCalls;
}

test("a scanned code signs the phone in, and no password field is ever shown", async ({ page }) => {
  const pairCalls = await serveBridge(page);
  await page.goto(`/#p=${CODE}`);

  await expect(page.getByText("What should we work on?")).toBeVisible({ timeout: 20_000 });
  await expect(page.getByPlaceholder("Password")).toHaveCount(0);
  expect(pairCalls).toHaveLength(1);
  expect(pairCalls[0]).toContain(CODE);

  // The code is spent, so it must not linger in the address bar, in history,
  // or in a link the user shares from the phone afterwards.
  expect(await page.evaluate(() => window.location.hash)).not.toContain("p=");
  // And the session it bought is kept, so reopening the home-screen app does
  // not ask again.
  expect(await page.evaluate(() => localStorage.getItem("prevail.web.token"))).toBe("paired-token");
});

test("an expired code falls back to the sign-in form instead of a dead end", async ({ page }) => {
  const pairCalls = await serveBridge(page, { pairStatus: 401 });
  await page.goto(`/#p=${CODE}`);

  // Refused: the user still gets a way in, plus a pointer back to the QR.
  await expect(page.getByRole("heading", { name: "Glyph Studio Web" })).toBeVisible({ timeout: 20_000 });
  await expect(page.getByPlaceholder("Password")).toBeVisible();
  await expect(page.getByText(/scan the QR code/i)).toBeVisible();
  expect(pairCalls).toHaveLength(1);
  expect(await page.evaluate(() => localStorage.getItem("prevail.web.token"))).toBeNull();
});

// The vault lives on the Mac. A phone is a window onto it, so it must never be
// asked to choose a folder: there is no meaningful folder to choose there.
test("the phone inherits the Mac's vault and is never shown a folder picker", async ({ page }) => {
  await serveBridge(page);
  await page.goto(`/#p=${CODE}`);
  await expect(page.getByText("What should we work on?")).toBeVisible({ timeout: 20_000 });
  await expect(page.getByText("Pick your vault folder")).toHaveCount(0);
});

test("when the Mac has no vault the phone says so, rather than offering a folder picker", async ({ page }) => {
  await serveBridge(page, { overrides: { bootstrap_vault: null, engine_config_vault: null } });
  await page.goto(`/#p=${CODE}`);
  await expect(page.getByRole("heading", { name: "Your Mac has no vault yet" })).toBeVisible({ timeout: 20_000 });
  await expect(page.getByText("Pick your vault folder")).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Try again" })).toBeVisible();
});
