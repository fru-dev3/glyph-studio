#!/usr/bin/env bash
# Build the prevail engine as a standalone binary and place it where Tauri
# expects the `externalBin` sidecar. Runs as part of `beforeBuildCommand`
# so a `tauri build` always bundles a fresh, self-contained engine — the
# downloaded app never depends on a separately-installed `prevail` CLI.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"            # desktop repo root
# Engine repo location: $PREVAIL_CLI_DIR override (used by CI) else the sibling
# checkout used in local dev.
if [ -n "${PREVAIL_CLI_DIR:-}" ]; then
  CLI="$(cd "$PREVAIL_CLI_DIR" 2>/dev/null && pwd || true)"
else
  # Sibling checkout used in local dev. Accept either naming convention so a
  # release builds without anyone having to set PREVAIL_CLI_DIR by hand.
  CLI="$(cd "$HERE/../fd-apps-prevail-cli" 2>/dev/null && pwd || true)"
  [ -n "${CLI:-}" ] || CLI="$(cd "$HERE/../prevail-cli" 2>/dev/null && pwd || true)"
fi

if [ -z "${CLI:-}" ] || [ ! -f "$CLI/package.json" ]; then
  echo "prepare-sidecar: cannot find the prevail-cli engine repo (set PREVAIL_CLI_DIR or check it out next to the desktop repo)" >&2
  exit 1
fi

TRIPLE="$(rustc -Vv | sed -n 's/host: //p')"
# Windows binaries need a .exe extension — both what Bun emits and what Tauri
# expects for the externalBin sidecar (prevail-<triple>.exe).
EXT=""
case "$TRIPLE" in *windows*) EXT=".exe" ;; esac
echo "prepare-sidecar: building prevail engine for $TRIPLE"
# --external chromium-bidi: playwright-core has a dead chromium-bidi require that
# bun's --compile can't resolve; the engine never uses BiDi (CDP only), so we
# exclude it. Must match the cli's own build scripts.
( cd "$CLI" && bun build --compile --external chromium-bidi --outfile="dist/prevail$EXT" src/index.tsx )

mkdir -p "$HERE/src-tauri/binaries"
# Remove first: copying over a binary macOS has already run replaces the bytes under
# a cached code signature, and the next run of it is killed on the spot (exit 137).
rm -f "$HERE/src-tauri/binaries/prevail-$TRIPLE$EXT"
cp "$CLI/dist/prevail$EXT" "$HERE/src-tauri/binaries/prevail-$TRIPLE$EXT"
echo "prepare-sidecar: sidecar ready -> src-tauri/binaries/prevail-$TRIPLE$EXT ($(du -h "$HERE/src-tauri/binaries/prevail-$TRIPLE$EXT" | cut -f1))"

# Stage the default skill packs as a bundled resource. The engine seeds these
# into new domains/apps on creation; in the packaged app the sidecar finds them
# via PREVAIL_SKILL_PACKS_DIR (engine::skill_packs_path → Contents/Resources).
if [ -d "$CLI/skill-packs" ]; then
  rm -rf "$HERE/src-tauri/resources/skill-packs"
  cp -R "$CLI/skill-packs" "$HERE/src-tauri/resources/skill-packs"
  echo "prepare-sidecar: skill-packs staged -> src-tauri/resources/skill-packs"
fi

# Stage playwright-core ON DISK next to the bundled engine. The compiled sidecar
# CANNOT use its in-binary copy of playwright-core: at runtime playwright's
# internals resolve their package.json/browser registry relative to the CI BUILD
# path (".../engine/node_modules/playwright-core"), which does not exist on the
# user's machine — so a browser skill fails with "Cannot find module .../$bunfs/".
# The fix: ship a REAL playwright-core folder as a Tauri resource. It lands in
# Contents/Resources/node_modules/playwright-core, and the engine's
# src/playwright-resolve.ts resolves it at runtime relative to process.execPath
# (Contents/MacOS/<sidecar> -> ../Resources/node_modules/playwright-core), NOT a
# path baked at compile time. playwright-core has no runtime npm deps, so the
# single package directory is self-contained (it bundles its own lib/).
PW_SRC="$CLI/node_modules/playwright-core"
if [ -d "$PW_SRC" ]; then
  rm -rf "$HERE/src-tauri/resources/node_modules/playwright-core"
  mkdir -p "$HERE/src-tauri/resources/node_modules"
  cp -R "$PW_SRC" "$HERE/src-tauri/resources/node_modules/playwright-core"
  echo "prepare-sidecar: playwright-core staged -> src-tauri/resources/node_modules/playwright-core ($(du -sh "$HERE/src-tauri/resources/node_modules/playwright-core" | cut -f1))"
else
  echo "prepare-sidecar: ERROR: playwright-core not found at $PW_SRC — browser automation will be unavailable in this build. Run 'bun install' in the engine repo." >&2
  exit 1
fi
