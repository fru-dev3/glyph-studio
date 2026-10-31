// The family's look, held in place: one typeface and one accent. Glyph Studio is
// not SwiftUI, so nothing enforces this but a test (Fru, 2026-10-31: a serif and a
// second hue made the app read as somebody else's software).
import { test, expect } from "@playwright/test";
import { mockTauri } from "./tauri-mock";

test("no serif, and no second hue on screen", async ({ page }) => {
  await mockTauri(page);
  await page.goto("/");
  await page.getByText("What should we work on?").waitFor({ timeout: 15_000 });

  // Every heading is in the body's face.
  const serif = await page.evaluate(() =>
    [...document.querySelectorAll("h1,h2,h3,[class*=display]")]
      .filter((el) => {
        const f = getComputedStyle(el).fontFamily.toLowerCase();
        return /\b(serif|georgia|instrument)\b/.test(f) && !f.includes("sans-serif");
      })
      .map((el) => `${el.tagName}.${String(el.className).slice(0, 40)}`)
      .slice(0, 5));
  expect(serif, "a heading is still set in a serif").toEqual([]);

  // Nothing is painted cyan or purple: the accent is the only hue, grey carries the rest.
  const hues = await page.evaluate(() => {
    const off = (c: string) => {
      const m = c.match(/rgba?\((\d+), *(\d+), *(\d+)(?:, *([\d.]+))?/);
      if (!m) return false;
      const [r, g, b, a] = [+m[1], +m[2], +m[3], m[4] === undefined ? 1 : +m[4]];
      if (a < 0.05) return false;
      const cyan = b > r + 40 && g > r + 25 && b > 120;      // blue-green
      const purple = b > g + 50 && r > g + 25 && b > 120;    // violet
      return cyan || purple;
    };
    const hits: string[] = [];
    for (const el of document.querySelectorAll("*")) {
      const s = getComputedStyle(el);
      if (off(s.color) || off(s.backgroundColor) || off(s.borderTopColor)) {
        hits.push(`${el.tagName}.${String(el.className).slice(0, 40)}`);
        if (hits.length > 4) break;
      }
    }
    return hits;
  });
  expect(hues, "something is still painted in a second hue").toEqual([]);
});
