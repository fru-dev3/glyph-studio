// The accent is a token. The code default is office green #008000; a saved
// palette may override it at runtime, so nothing in the components may
// hard-code the green (or any other accent) instead of var(--color-accent).
import { describe, expect, it } from "vitest";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

const files = (dir: string): string[] => readdirSync(dir).flatMap((n) => {
  const p = join(dir, n);
  return statSync(p).isDirectory() ? files(p) : /\.(tsx|ts)$/.test(n) && !/\.test\./.test(n) ? [p] : [];
});

describe("accent", () => {
  it("defaults to office green", () => {
    const css = readFileSync(join(__dirname, "index.css"), "utf8");
    expect(/:root\s*\{[^}]*--color-accent:\s*#008000;/.test(css) || /@theme\s*\{[^}]*--color-accent:\s*#008000;/.test(css)).toBe(true);
  });
  it("components use the token, not a literal green", () => {
    const bad: string[] = [];
    for (const p of files(__dirname)) {
      const name = p.split("/").pop()!;
      // Profile avatar colors are a user's pick, not the accent.
      if (name === "profiles.ts") continue;
      // The Glyph Studio mark is fixed artwork in brand green, whatever the accent.
      if (name === "GlyphStudioLogo.tsx") continue;
      readFileSync(p, "utf8").split("\n").forEach((line, i) => {
        const literal = /#008000|rgba?\(\s*0\s*,\s*128\s*,\s*0/i.test(line) && !/var\(--color-accent,\s*#008000\)/.test(line);
        if (literal) bad.push(`${name}:${i + 1}`);
      });
    }
    expect(bad).toEqual([]);
  });
});
