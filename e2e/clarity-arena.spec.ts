// Since 0.4.10 benchmarking lives in its own app, Glyph Arena. Studio's Arena tab
// is a handoff: it explains the move and opens the app (or its page).
import { test, expect } from "@playwright/test";
import { mockTauri } from "./tauri-mock";

test("Arena tab hands off to Glyph Arena", async ({ page }) => {
  await mockTauri(page, { open_glyph_arena: true });
  page.on("pageerror", (err) => { throw new Error(`frontend crashed: ${err.message}`); });
  await page.goto("/");
  await page.getByText("What should we work on?").waitFor({ timeout: 15_000 });
  await page.evaluate(() => window.dispatchEvent(new CustomEvent("prevail:open-settings", { detail: "benchmark" })));
  const handoff = page.getByTestId("arena-handoff");
  await expect(handoff).toBeVisible({ timeout: 10_000 });
  await expect(handoff.getByRole("heading", { name: "Arena is now Glyph Arena" })).toBeVisible();
  await handoff.getByTestId("open-glyph-arena").click();
  const calls = await page.evaluate(() => ((window as unknown as { __invokeLog: { cmd: string }[] }).__invokeLog ?? []).map((e) => e.cmd));
  expect(calls).toContain("open_glyph_arena");
});
