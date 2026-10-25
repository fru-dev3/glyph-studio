# Contributing to Glyph Studio

Thanks for your interest! Glyph Studio (formerly Prevail) is a local-first "life-OS", a Tauri 2 +
React desktop app driving a bundled engine (Glyph Engine, the `prevail` CLI) over a JSON/NDJSON
contract.

## Prerequisites
- **Node 20+** and **npm**
- **Rust** (stable) + the Xcode Command Line Tools (macOS)
- **Bun ≥ 1.3** (to build the engine sidecar)
- The engine repo (`fd-apps-prevail-cli`) checked out **next to** this repo —
  `scripts/prepare-sidecar.sh` builds the sidecar from it at `tauri build` time.

## Run it
```bash
npm install
npm run tauri dev        # hot-reloading desktop app
```

## Before you push
```bash
npx tsc --noEmit         # frontend typecheck
npm run build            # frontend production build
cd src-tauri && cargo test && cargo clippy
```
CI runs the same checks (`.github/workflows/test.yml`). Keep them green.

## Conventions
- **Conventional commits** (`feat(desktop): …`, `fix(engine): …`).
- **Icons, never emojis** in UI (lucide).
- New on-disk formats get a Rust round-trip test (see `usage_tests` / `distill::tests`).
- The frontend talks to the backend only through `src/bridge.ts` (Tauri IPC on
  desktop, HTTP/SSE in the browser) — don't import `@tauri-apps/api` directly.

## Security
Found a vulnerability? See [SECURITY.md](SECURITY.md) — please disclose privately.

## Good first issues
Browse issues labelled [`good first issue`](https://github.com/fru-dev3/glyph-studio/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22).
Recurring themes: App.tsx decomposition, lib.rs split, and broader error-boundary
coverage — all approachable entry points.
