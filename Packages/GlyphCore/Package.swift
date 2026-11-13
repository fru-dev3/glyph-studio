// swift-tools-version: 6.2
// GlyphCore: the one thing the Glyph apps (Studio, Dictate, Mobile, Record, Code) share.
// No app code, no UI, no dependency on any app. Three products, so an app links only
// what it uses:
//   GlyphVault    the plain-file vault (docs/vault-format.md): read, write, links,
//                 suggestions, search, tasks, a Library that follows the disk
//   GlyphCapture  recording (mic + system audio to .m4a), on-device transcription, who spoke
//                 when (FluidAudio, Apache-2.0; its NemoTextProcessing binary trait is off)
//   GlyphAI       summaries and heard names with Apple's on-device model
// GlyphCore re-exports all three. Version: VERSION; changes: CHANGELOG.md.
import PackageDescription

let package = Package(
    name: "GlyphCore",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "GlyphVault", targets: ["GlyphVault"]),
        .library(name: "GlyphCapture", targets: ["GlyphCapture"]),
        .library(name: "GlyphAI", targets: ["GlyphAI"]),
        .library(name: "GlyphCore", targets: ["GlyphCore"]),
        .executable(name: "glyphcore-report", targets: ["glyphcore-report"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7", traits: []),
    ],
    targets: [
        .target(name: "GlyphVault"),
        .target(name: "GlyphCapture", dependencies: ["GlyphVault", "GlyphAI", .product(name: "FluidAudio", package: "FluidAudio")]),
        .target(name: "GlyphAI", dependencies: ["GlyphVault"]),
        .target(name: "GlyphCore", dependencies: ["GlyphVault", "GlyphCapture", "GlyphAI"]),
        .executableTarget(name: "glyphcore-report", dependencies: ["GlyphVault", "GlyphAI"]),
        .testTarget(name: "GlyphVaultTests", dependencies: ["GlyphVault"], resources: [.copy("Fixtures"), .copy("Golden")]),
        .testTarget(name: "GlyphCaptureTests", dependencies: ["GlyphCapture", "GlyphAI", "GlyphVault"]),
        .testTarget(name: "GlyphAITests", dependencies: ["GlyphAI", "GlyphVault"]),
    ]
)
