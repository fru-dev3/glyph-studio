#!/bin/zsh
# Build Glyph Bot for the Mac, sign it with Developer ID (hardened runtime), notarize and staple the
# disk image, and publish a release on GitHub: Glyph-Bot-<version>.dmg plus Glyph-Bot.dmg (the stable
# releases/latest/download link). Run it in the public clone (publish-bot.sh copies this file there
# as scripts/release.sh).
# Needs a "Developer ID Application" certificate in the keychain, an App Store Connect API key for
# notarization (ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH), the GitHub CLI signed in, xcodegen, and the
# Glyph Engine binary: GLYPH_ENGINE=<path to the glyph-bot build> (github.com/fru-dev3/glyph-engine).
# Optional: EXTRA_ASSETS="file ..." attaches more files to the same release (the earlier app's
# installers, kept so the older links and update checks still resolve).
set -euo pipefail
cd "${0:A:h}/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
: ${ASC_KEY_ID:?set ASC_KEY_ID} ${ASC_ISSUER_ID:?set ASC_ISSUER_ID} ${ASC_KEY_PATH:?set ASC_KEY_PATH}
: ${GLYPH_ENGINE:?set GLYPH_ENGINE to the glyph-bot engine binary}
[[ -x $GLYPH_ENGINE ]] || { echo "no engine at $GLYPH_ENGINE"; exit 1; }
identity=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')
[[ -n $identity ]] || { echo "no Developer ID Application certificate in the keychain"; exit 1; }
team=${identity##*\(}; team=${team%\)}
version=$(awk '/MARKETING_VERSION: "/{gsub(/"/,"",$2); print $2; exit}' project.yml)
repo=fru-dev3/glyph-studio
# Released from committed and pushed code only.
[[ -z $(git status --porcelain) ]] || { echo "uncommitted changes: commit and push first"; exit 1; }
git fetch -q origin && [[ $(git rev-parse HEAD) == $(git rev-parse origin/main) ]] || { echo "HEAD is not origin/main: push first"; exit 1; }

echo "building Glyph Bot $version"
xcodegen generate --quiet
# The hub address is read from the environment at build time; a public build carries none.
env -u GLYPH_VAULT_URL xcodebuild -project Studio.xcodeproj -scheme Studio -configuration Release -arch arm64 -derivedDataPath build -quiet \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" DEVELOPMENT_TEAM="$team" OTHER_CODE_SIGN_FLAGS=--timestamp \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO build # no get-task-allow: notarization refuses it
app="build/Build/Products/Release/Glyph Bot.app"
main="$app/Contents/MacOS/Glyph Bot"

# The Glyph Engine rides inside, where the app looks for it.
cp "$GLYPH_ENGINE" "$app/Contents/MacOS/prevail"
# The linker's debug map and SwiftPM's baked resource-bundle path carry the build machine's user name
# and home folder. Strip the app's symbols and blank that path (same length). The engine is a compiled
# runtime with its program appended, so it is never stripped.
strip -S -x "$main"
python3 - "$main" <<'PY'
import re, sys
p = sys.argv[1]; b = open(p, "rb").read()
b = re.sub(rb"/Use[r]s/[ -~]*?\.bundle", lambda m: (b"/nonexistent" + b"/" * len(m.group(0)))[:len(m.group(0))], b)
open(p, "wb").write(b)
PY
# Sign again, the engine first (its own entitlements), then the app (keeping its own).
codesign --force --options runtime --timestamp --entitlements scripts/engine.entitlements --sign "$identity" "$app/Contents/MacOS/prevail"
codesign --force --options runtime --timestamp --preserve-metadata=entitlements --sign "$identity" "$app"
# Nothing of the build machine may be left in the app. The engine is the one exception: Bun, which
# compiled it, left its own build machines' paths (a CI runner and a build host) in it; any
# other name in it is a leak.
if grep -rqa --exclude=prevail '/Use[r]s/' "$app"; then echo "source paths left in the app"; grep -rla --exclude=prevail '/Use[r]s/' "$app"; exit 1; fi
if grep -aoE '/Use[r]s/[A-Za-z0-9._-]+' "$app/Contents/MacOS/prevail" | sort -u | grep -vE '^/Use[r]s/(runner|administrator)$'; then echo "source paths left in the engine"; exit 1; fi
codesign --verify --strict --deep "$app"
for f in "$app/Contents/MacOS/prevail" "$app"; do
  [[ $(codesign -dvv "$f" 2>&1) == *"Developer ID Application"* ]] || { echo "$f is not Developer ID signed"; exit 1; }
done
"$app/Contents/MacOS/prevail" --version >/dev/null || { echo "the signed engine does not run"; exit 1; }

echo "making the disk image"
rm -rf dist && mkdir -p dist/stage
cp -R "$app" dist/stage/ && ln -s /Applications dist/stage/Applications
dmg=dist/Glyph-Bot-$version.dmg
hdiutil create -volname "Glyph Bot $version" -srcfolder dist/stage -fs HFS+ -format UDZO -ov "$dmg" -quiet
codesign --sign "$identity" --timestamp "$dmg"

echo "notarizing (a few minutes)"
# Submit, then poll: --wait has hung on Apple's side for an hour. A hung submission can be
# resubmitted by running this again.
id=$(xcrun notarytool submit "$dmg" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" | awk '/^ *id:/ && !s {print $2; s=1}')
[[ -n $id ]] || { echo "notarize: no submission id"; exit 1; }
echo "submission $id"
nstate=""
for _ in {1..90}; do
  nstate=$(xcrun notarytool info "$id" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" 2>&1 | awk '/^ *status:/ && !s {print $2; s=1}')
  [[ $nstate == Accepted || $nstate == Invalid || $nstate == Rejected ]] && break
  sleep 30
done
if [[ $nstate != Accepted ]]; then
  xcrun notarytool log "$id" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" || true
  echo "notarization was not accepted (status: ${nstate:-none})"; exit 1
fi
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"

echo "checking a downloaded copy passes Gatekeeper"
cp "$dmg" dist/check.dmg
xattr -w com.apple.quarantine "0081;00000000;Safari;" dist/check.dmg
spctl --assess --type open --context context:primary-signature -v dist/check.dmg
rm dist/check.dmg
cp "$dmg" dist/Glyph-Bot.dmg

# The version's whole entry in the README (its first line and the indented lines under it).
notes=$(awk -v v="**$version**" 'index($0, "- " v) == 1 {sub(/^- /, ""); out=$0; on=1; next} on && /^  /{sub(/^ +/, ""); out=out " " $0; next} on{exit} END{print out}' README.md)
# A draft first, so the release is never live with half its files; then published as the latest.
if gh release view "v$version" --repo $repo >/dev/null 2>&1; then
  gh release upload "v$version" "$dmg" dist/Glyph-Bot.dmg ${=EXTRA_ASSETS:-} --repo $repo --clobber
else
  gh release create "v$version" "$dmg" dist/Glyph-Bot.dmg ${=EXTRA_ASSETS:-} --repo $repo --draft --target main \
    --title "Glyph Bot $version" --notes "${notes:-Glyph Bot $version}"
  gh release edit "v$version" --repo $repo --draft=false --latest
fi
echo "released: https://github.com/$repo/releases/tag/v$version"
