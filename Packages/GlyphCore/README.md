# GlyphCore

The engine the Glyph apps share (Record, Studio, Mobile, Dictate, Code). It has no UI,
no app code, and depends on no app: each app links only the products it uses, and
installs and ships on its own. Everything runs on the device: Apple's speech
recognition and Apple's on-device model, no servers.

Version: [VERSION](VERSION) (semver). Changes: [CHANGELOG.md](CHANGELOG.md).
Swift 6, macOS 26 (GlyphVault also builds for iOS 26).

| Product | What it does | Links |
|---|---|---|
| `GlyphVault` | The plain-file vault ([docs/vault-format.md](../../docs/vault-format.md)): read, write, People and Accounts notes, links, suggestions, search, tasks, a `Library` that follows the disk; `TimeLog`, Glyph Time's sessions | Foundation |
| `GlyphCapture` | `Recorder` (mic + the Mac's sound into one `.m4a`), `Transcriber` (on-device speech to text), `Permissions` | GlyphVault, AVFoundation, ScreenCaptureKit, Speech |
| `GlyphAI` | `Summarizer` (notes.md from a transcript), `LinkSuggester` (who and what a call is about) | GlyphVault, FoundationModels |
| `GlyphCore` | All three re-exported, for an app that uses the whole engine | |

```swift
// Package.swift of an app
.package(path: "../Packages/GlyphCore"),
.product(name: "GlyphVault", package: "GlyphCore"),
```

## On a Mac: the app agents for shells and MCP

```sh
glyphcore-report agents                        # every agent, its tools, their JSON argument schemas
glyphcore-report run well log_entry '{"text":"Rice and beans","kind":"food","minutesAgo":0}' [--vault <path>]
glyphcore-report undo '<the undo object of a result>' [--vault <path>]
```

`run` calls the same tool the iPhone driver gives that agent and writes into the vault (`--vault`, else
`GLYPH_VAULT`) what the hub would write (GlyphAI `MacHub`: every route the agents use, kept in step with
the hub). `undo` takes one result back the way the app's Undo does (archive moves, never a delete).
Time's tools only queue a request: they report `waiting`.

## Rules it keeps

- **Disk always wins.** Nothing is cached; every write reads the file first. Files may be
  edited by hand, by Memosa or by git at any time.
- **Atomic writes:** a `*.tmp` beside the target, fsync, rename. A reader never sees half a file.
- **Exact format.** JSON is written the way Memosa's serde_json writes it, so a file both
  apps touch never churns in git. `Tests/GlyphVaultTests/Golden` pins every file byte for
  byte: a change to the format fails `contractFilesMatchGolden`.
- **Never deletes.** `trash` moves a conversation into `.memosa/trash/` inside the vault.
  There is no retention, purge or auto-delete anywhere.
- **No global state**, and no writes outside the vault folder and the file URLs you pass.

## GlyphVault

```swift
import GlyphVault

let vault = Vault(root: folderURL)
try vault.ensure()

// A conversation: Work/Acme/2026-10-20-weekly-sync (then -2, -3 if taken)
var meta = try vault.createConversation(in: "Work/Acme", title: "Weekly sync")
try vault.writeTranscript(transcript, for: meta.id)        // + transcript.txt
try vault.writeNotes(Notes(summary: "…", decisions: ["…"],
    actions: [ActionItem(text: "Send the order form", owner: "Ken Lee", due: "2026-10-24")]), for: meta.id)
try vault.setTask(meta.id, text: "Send the order form", done: true)

meta.durationSec = 1_820
try vault.write(meta)                                       // meta.json as is
let id = try vault.rename(meta.id, title: "Acme renewal")   // re-slugs the folder
let moved = try vault.move(id, to: "Work/Archive")
try vault.trash(moved)                                      // into .memosa/trash, never deleted
try vault.createFolder("Home/Kitchen")

// Links: names resolve through aliases, tags are tidied (#Q4 Renewal -> q4-renewal),
// a new name gets a stub note in People/ or Accounts/.
try vault.setLinks(id, people: ["Kenny", "Kim Park"], accounts: ["acme"], tags: ["#Q4 Renewal"])
try vault.answerSuggestion(id, .person("Kim Park"), accept: true)
try vault.answerSuggestion(id, .tag("budget"), accept: false)   // remembered in dismissed

// People and Accounts. Renaming rewrites the name in every meta.json and in people's account.
var ken = Entity(kind: .person, name: "Ken Lee")
ken.account = "Acme Corp"; ken.aliases = ["Kenny"]
try vault.saveEntity(ken)
ken.name = "Kenneth Lee"
try vault.saveEntity(ken, renamingFrom: "Ken Lee")

// Reading
vault.tree()                                  // domains > folders > conversations
vault.conversations()                         // newest first
vault.conversations(in: "Work/Acme")
vault.conversations(linkedTo: .account("Acme Corp"))   // includes calls with its people
vault.directory()                             // people, accounts, tags with counts
vault.search("hold the price")                // conversation ids, any case
vault.tasks().filter { !$0.item.done }        // every action item, with its conversation
vault.transcript(id); vault.notes(id); vault.entities()
```

Errors are `VaultError` with a message ready to show.

### Library (for SwiftUI)

`@MainActor @Observable`. Reads run off the main actor; the published values change on it.
It reloads when anything under the vault changes on disk (FSEvents on the Mac; on iOS the
vault folder's own entries).

```swift
@State var library = Library(vault: Vault(root: folderURL))

List(library.conversations, id: \.id) { Text($0.title) }
    .task { library.start() }

library.tree; library.directory; library.tasks; library.generation
let hits = await library.search("deposit")
let withKen = await library.conversations(linkedTo: .person("Ken Lee"))
```

Writes go through `library.vault`; the watcher picks them up (or call `reload()`).

## GlyphCapture

### Recorder

`@MainActor @Observable`. Mixes the inputs into one 48 kHz mono AAC `.m4a`. The microphone is
the clock; the Mac's sound (ScreenCaptureKit, without this app's own sound) is summed in.

```swift
import GlyphCapture

let recorder = Recorder()
let audio = vault.url(id).appending(path: "audio.m4a")
do {
    try await recorder.start(to: audio, capturing: [.microphone, .systemAudio])
} catch CaptureError.screenRecordingDenied {
    Permissions.requestScreenRecording()      // or record the mic alone
}
recorder.state          // .idle, .recording, .paused
recorder.elapsed        // seconds written, pauses left out
recorder.levels         // [.microphone: 0...1, .systemAudio: 0...1] for a meter
recorder.warning        // set if the Mac's sound stops; the mic keeps going
recorder.pause(); recorder.resume()
let recording = try await recorder.stop()     // file complete when it returns
```

`Permissions.microphone` and `Permissions.screenRecording` read without prompting, so a UI
can explain what is missing before Record. `start` asks for the microphone if it was never
asked, and throws `CaptureError.microphoneDenied` / `.screenRecordingDenied` (messages say
where in System Settings to fix it). The app needs `NSMicrophoneUsageDescription`.

For tests and imports, feed buffers instead of devices:

```swift
let feed = try recorder.start(to: url, feeding: [.microphone])
feed.append(buffer, from: .microphone)        // any thread, any PCM format
try await recorder.stop()
```

### Transcriber

Apple's SpeechAnalyzer + SpeechTranscriber, on the device. The model ships with macOS but
downloads on first use; `transcribe` fetches it and reports progress.

```swift
let transcriber = Transcriber()                       // the Mac's language, else en-US
if await transcriber.status() == .needsDownload { try await transcriber.prepare { print($0) } }
let transcript = try await transcriber.transcribe(audio, names: vault.knownNames()) { event in
    // .downloadingModel(0...1) or .transcribing(0...1)
}
try vault.writeTranscript(transcript, for: id)
```

`names` (people, accounts, their aliases) go to the recognizer as context so they are spelled
right. `TranscriptionError.serviceLost` means the process lost Apple's speech service; only
relaunching the app fixes it.

## GlyphAI

Apple's on-device model (Apple Intelligence). `OnDeviceModel.status` says whether it can run;
calls throw `AIError.unavailable(.appleIntelligenceOff)` and so on, with a message to show.

```swift
import GlyphAI

let notes = try await Summarizer().summarize(id, in: vault)   // writes notes.md
try await LinkSuggester().suggest(id, in: vault)              // fills meta.suggested
```

The model reads about 4,096 tokens, so a long call is noted in parts of about 7,000
characters and the notes are summarized. Owners and due dates are kept only when the
transcript says them (the model invents both now and then), and repeats are dropped.
`LinkSuggester` works without the model too: then suggestions come from the People and
Accounts notes alone.

## Testing

```sh
cd Packages/GlyphCore
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

The transcription and summary tests use the real on-device models and are cancelled (with the
reason printed) when the Mac doesn't have them. Fixtures use made-up names only.

Reader parity with Memosa (must print identical JSON):

```sh
swift build --product glyphcore-report
.build/debug/glyphcore-report <vault> acme deposit "Hold the price"
# in the Memosa source, src-tauri:
MEMOSA_VAULT=<vault> cargo run -q --example vault_report -- acme deposit "Hold the price"
```

Filing documents (`glyphcore-report file`, GlyphAI `Filer`): one PDF or photo into the vault, named,
placed, noted and linked. Read, OCR, classify, extract (dates and money by code; the on-device model
only labels, and only what the text backs), decide, write, link, update, log; below the bar it waits in
`data/apps/filing/review/`. Personal rules live in the vault's `data/apps/filing/rules.json`, never here.

```sh
swift build -c release --product glyphcore-report
.build/release/glyphcore-report file ~/Downloads/statement.pdf --from billing@example.com --dry-run --json
```

A format change on purpose: update docs/vault-format.md and CHANGELOG.md (a major version
if old files no longer read), then `GLYPH_WRITE_GOLDEN=1 swift test --filter contract` and
review the golden diff.

## Dictate first (GlyphCapture)

Every text input in a Glyph app offers the mic: tap, talk, tap to stop; words appear as you speak,
on the device. `TextField(...).dictatable($text)`, or `DictateButton(text: $text, onFinal: {...})`,
or `DictateButton { words in ... }` to fill a form from what was said. AppKit:
`DictateButton.hostingView { words in ... }` or `LiveDictation` with `onText`/`onFinal`.
Tests inject the words with `GLYPH_DICTATION_TEXT`.
