# Releasing (release rings)

Glyph Studio ships through a **beta → soak → stable** ring so a bad tag never
auto-updates every user at once.

1. **Tag** `vX.Y.Z` on `main`. CI builds, signs, notarizes, runs the smoke
   ring, and publishes the release as a **prerelease**. The in-app
   auto-updater reads GitHub's "latest" feed, which excludes prereleases, so
   **this build ships to nobody automatically yet.**
2. **Soak.** Download the prerelease build, install it, and run it. If
   telemetry is on, glance at the crash rate. Prereleases are the beta ring.
3. **Promote.** Run the **Promote to stable** workflow (Actions tab) with the
   tag + `yes`. It flips the release to "latest"; from then on every user's
   auto-updater offers it.
4. **Rollback (if needed).** Run the **Rollback stable** workflow with the bad
   tag + the last good tag. It pulls the bad build from "latest" and restores
   the good one. Two edits, no rebuild - users flip back on their next update
   check.

Notes:
- Version bumps live in `package.json` + `src-tauri/tauri.conf.json`; push the
  CLI engine (`glyph-engine`, formerly `prevail-cli`) `main` before tagging desktop.
- Follow-up (not yet built): an opt-in in-app "beta channel" so testers
  auto-receive prereleases via a second updater endpoint. Today the beta ring
  is a manual prerelease install.
