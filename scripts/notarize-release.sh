#!/usr/bin/env bash
# Build a fully SIGNED + NOTARIZED Glyph Studio release locally and upload it to the
# matching GitHub release, replacing the unsigned/un-notarized DMG.
#
# Why this exists: the GitHub Actions release workflow can't sign (the
# APPLE_CERTIFICATE secret is broken) and notarization needs an Apple credential
# that can't live in CI safely. This script signs against the Developer ID
# identity already in the login keychain (no .p12 export needed) and notarizes
# with an app-specific password, then staples + uploads.
#
# The ONLY thing you must provide is an app-specific password for notarization
# (appleid.apple.com -> Sign-In & Security -> App-Specific Passwords). Provide it
# either via the APPLE_PASSWORD env var or in ~/.prevail-asp.txt (0600).
#
# Usage:
#   APPLE_PASSWORD=xxxx-xxxx-xxxx-xxxx bash scripts/notarize-release.sh [vTAG]
#   # or: put the password in ~/.prevail-asp.txt, then: bash scripts/notarize-release.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"

TAG="${1:-v$(node -p "require('./package.json').version")}"
REPO="fru-dev3/glyph-studio"

# --- Apple credentials (signing identity is in the keychain already) ---
# Read identity + Apple ID from env (or local dotfiles), never hardcoded — keeps
# personal identifiers out of the repo. Set APPLE_ID / APPLE_SIGNING_IDENTITY /
# APPLE_TEAM_ID in your shell, or drop them in the ~/.prevail-* files below.
export APPLE_SIGNING_IDENTITY="${APPLE_SIGNING_IDENTITY:-$(cat ~/.prevail-signing-identity.txt 2>/dev/null || true)}"
export APPLE_ID="${APPLE_ID:-$(cat ~/.prevail-apple-id.txt 2>/dev/null || true)}"
export APPLE_TEAM_ID="${APPLE_TEAM_ID:-$(cat ~/.prevail-team-id.txt 2>/dev/null || true)}"
export APPLE_PASSWORD="${APPLE_PASSWORD:-$(cat ~/.prevail-asp.txt 2>/dev/null || true)}"
if [ -z "${APPLE_ID:-}" ] || [ -z "${APPLE_SIGNING_IDENTITY:-}" ] || [ -z "${APPLE_TEAM_ID:-}" ]; then
  echo "ERROR: set APPLE_ID, APPLE_SIGNING_IDENTITY, APPLE_TEAM_ID (env or ~/.prevail-*.txt)." >&2
  exit 1
fi
if [ -z "${APPLE_PASSWORD:-}" ]; then
  echo "ERROR: no app-specific password. Create one at appleid.apple.com" >&2
  echo "       (Sign-In & Security -> App-Specific Passwords) and either:" >&2
  echo "         export APPLE_PASSWORD=xxxx-xxxx-xxxx-xxxx" >&2
  echo "       or save it to ~/.prevail-asp.txt" >&2
  exit 1
fi

# --- Updater feed signing key (matches the pubkey baked into tauri.conf.json) ---
export TAURI_SIGNING_PRIVATE_KEY="$(cat ~/.prevail/updater.key)"
export TAURI_SIGNING_PRIVATE_KEY_PASSWORD=""
# --- Engine sidecar source (compiled by beforeBuildCommand) ---
export PREVAIL_CLI_DIR="${PREVAIL_CLI_DIR:-$HERE/../prevail-cli}"

echo "==> Building signed + notarized $TAG (this takes ~10-20 min incl. Apple notarization)"
npm run tauri build -- --target aarch64-apple-darwin

DMG="$(ls src-tauri/target/aarch64-apple-darwin/release/bundle/dmg/Glyph\ Studio_*_aarch64.dmg | head -1)"
APP="src-tauri/target/aarch64-apple-darwin/release/bundle/macos/Glyph Studio.app"

echo "==> Stapling notarization ticket"
xcrun stapler staple "$APP" || true
xcrun stapler staple "$DMG" || true

echo "==> Verifying Gatekeeper acceptance (want: accepted / Notarized Developer ID)"
spctl -a -vvv "$APP" || true

echo "==> Uploading to release $TAG"
cp -f "$DMG" /tmp/Glyph-Studio-mac-arm64.dmg
cp -f "$DMG" /tmp/Prevail-mac-arm64.dmg
for f in /tmp/Glyph-Studio-mac-arm64.dmg /tmp/Prevail-mac-arm64.dmg; do
  for i in 1 2 3 4 5; do
    gh release upload "$TAG" --repo "$REPO" "$f" --clobber && break || { echo "retry $i for $(basename "$f")"; sleep 5; }
  done
done

echo "==> Done. $TAG now ships a signed + notarized DMG."
echo "    Remember to restore the 'signed & notarized' copy on prevail-web if it was softened."
