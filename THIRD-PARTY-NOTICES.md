# Third-Party Notices

Glyph Studio (desktop app, formerly Prevail) is distributed under GPL-3.0-only.
It bundles or depends on the third-party components below, each under its own
license, reproduced/attributed here as those licenses require. This file
satisfies the attribution obligations of the MIT/ISC/Apache-2.0 components we
redistribute (notably playwright-core, whose Apache-2.0 NOTICE and
ThirdPartyNotices.txt ship inside the app bundle).

## Bundled at distribution time

- **@playwright/test** — Apache-2.0 — Microsoft
- **react** — MIT — Meta
- **react-dom** — MIT — Meta
- **react-markdown** — MIT — Espen Hovlandsdal
- **lucide-react** — ISC — Lucide Contributors
- **simple-icons** — CC0-1.0 — Simple Icons Collaborators
- **framer-motion** — MIT — Framer B.V.
- **posthog-js** — MIT — PostHog
- **@sentry/browser** — MIT — Functional Software (Sentry)
- **@tauri-apps/api** — MIT/Apache-2.0 — Tauri Programme
- **@tanstack/react-virtual** (with @tanstack/virtual-core): MIT, Tanner Linsley

## Full dependency set

The complete, resolved dependency tree and each package's license text are
available from the lockfile (`package-lock.json` / `bun.lock`) and under
`node_modules/<pkg>/LICENSE` after install. Run `npx license-checker --summary`
(or `bunx license-checker`) to regenerate a full inventory. No dependency is
under a license incompatible with GPL-3.0 distribution.

Fonts (desktop): Inter, Fraunces, JetBrains Mono — SIL OFL 1.1; see
`public/fonts/OFL.txt`.
