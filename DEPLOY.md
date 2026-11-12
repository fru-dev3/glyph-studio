# Deploy and release: Glyph Bot

## Build a release DMG locally

```bash
npm install
npm run tauri build
```

Produces:
- `src-tauri/target/release/bundle/macos/Glyph Bot.app`: bare app bundle
- `src-tauri/target/release/bundle/dmg/Glyph Bot_<version>_aarch64.dmg`: installable DMG

The `aarch64` suffix means Apple Silicon only. For Intel Macs, set up cross-compile per the [Tauri docs](https://tauri.app/distribute/sign/macos/) and re-run.

## Cut a GitHub release

```bash
VERSION=$(node -p "require('./package.json').version")
gh release create "v$VERSION" \
  --title "v$VERSION" \
  --notes-file CHANGELOG.md \
  "src-tauri/target/release/bundle/dmg/Glyph Bot_${VERSION}_aarch64.dmg#Glyph-Bot-macOS-arm64.dmg"
```

The `#Glyph-Bot-macOS-arm64.dmg` part renames the asset on the release page to something humans can recognize.

## Signing + notarization (v0.2+)

For v0.1 the DMG ships **unsigned**. End users right-click → Open the first launch and confirm Gatekeeper.

For v0.2:

1. **Apple Developer ID Application certificate** in Keychain
2. Set env vars before `tauri build`:
   ```bash
   export APPLE_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)"
   export APPLE_ID="your-apple-id@example.com"
   export APPLE_PASSWORD="app-specific-password"
   export APPLE_TEAM_ID="TEAMID"
   ```
3. Re-run `npm run tauri build`. Tauri signs + notarizes automatically.

See: [Tauri macOS code signing](https://tauri.app/distribute/sign/macos/) and [notarization](https://tauri.app/distribute/sign/macos/#notarization).

## Auto-update (v0.2+)

Tauri 2 supports a built-in updater that reads a JSON manifest from a URL and updates the app from a hosted DMG. Setup:

1. Add `tauri-plugin-updater` to `Cargo.toml`
2. Generate signing keys: `npm run tauri signer generate`
3. Host an `updates.json` (e.g. on the GitHub release asset URL or your own bucket)
4. Sign each release DMG with `npm run tauri signer sign`

Defer until enough user feedback to justify the maintenance burden.

## Future: Windows + Linux

`npm run tauri build` on those platforms produces native installers. CI matrix recommended (GitHub Actions has runners for both).

## Compatibility asset names (one release after the Glyph Bot rename)

Every release also uploads the DMG and the Windows installer under the old
`Glyph-Studio-*` and `Prevail-*` names, because the Glyph Native installer and
older links download by name. Drop the `Glyph-Studio-*` copies from
`release.yml`, `release.sh` and `notarize-release.sh` one release later. An
existing `Glyph Studio.app` that auto-updates keeps its file name (the updater
swaps the contents in place); only the name shown by the app changes.
