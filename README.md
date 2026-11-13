<h1 align="center">Glyph Bot</h1>

<p align="center"><b>The agentic harness of the Glyph family, native on the Mac.</b></p>

<p align="center">
  <a href="https://github.com/fru-dev3/glyph-studio/releases/latest/download/Glyph-Bot.dmg">Download for Mac</a> ·
  <a href="https://glyph.fru.dev/bot">glyph.fru.dev/bot</a> ·
  <a href="#build-from-source">Build from source</a>
</p>

Chat with your agents. Each reply shows what it read (numbered, cited) and what it asks to save,
and nothing is saved until you say Save. Sources shows the vault and each Glyph app it reads: Well,
Time, Jot, CRM (people, places, products, things) and Omega (mission, vision, values, goals).
Replies render Markdown. Your vault is read-only to the app; agents save to it through Glyph Engine,
with Undo. It runs on your Mac, in light and dark, and has a demo vault of made-up data to try it with.

## Install

The easiest way is Glyph Native, which installs Glyph Bot and keeps it up to date.
Or [download Glyph-Bot.dmg](https://github.com/fru-dev3/glyph-studio/releases/latest/download/Glyph-Bot.dmg),
open it and drag Glyph Bot to Applications. It is signed and notarized by Apple and needs macOS 26.

The Glyph Engine is inside the app. Its source is [fru-dev3/glyph-engine](https://github.com/fru-dev3/glyph-engine).

## Build from source

You need macOS 26, Xcode 26 and [xcodegen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate
xcodebuild -project Studio.xcodeproj -scheme Studio -configuration Release -derivedDataPath build build
```

That builds `build/Build/Products/Release/Glyph Bot.app` signed with your own team (set one in Xcode
or pass `DEVELOPMENT_TEAM=<id>`). Agents need the Glyph Engine: copy a `glyph-bot` build to
`Glyph Bot.app/Contents/MacOS/prevail`. `scripts/release.sh` is the full signed, notarized release
(Developer ID certificate, App Store Connect key, `GLYPH_ENGINE=<engine binary>`).

## The earlier app

Glyph Bot 0.4.x was a Tauri app. It is retired; its source stays on the
[`tauri` branch](https://github.com/fru-dev3/glyph-studio/tree/tauri) (tag `tauri-final`). Its
Windows installer is attached to the 0.5.0 release as it was and gets no further updates.

## Versions

- **0.5.0** Glyph Bot is now a native Mac app, built with Swift and SwiftUI. The earlier app (0.4.x) is retired and its source is kept on the tauri branch. Windows: the last build of the earlier app is attached to this release and gets no further updates.

## License

MIT, © 2026 Inspired Nation, LLC.
