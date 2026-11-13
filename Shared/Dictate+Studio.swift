import SwiftUI
import GlyphCapture

/// Studio's one line onto Glyph's shared mic (GlyphCapture's DictateButton and `.dictatable`): the
/// words land in the field as you talk, in office green. Nothing here records; GlyphCapture does.
enum StudioMic {
    static let green = Color(red: 0, green: 128 / 255, blue: 0)
}

extension View {
    /// A mic at the field's trailing edge (GlyphCapture's `.dictatable`, with a name for tests).
    func studioDictatable(_ text: Binding<String>, id: String = "field") -> some View {
        HStack(alignment: .center, spacing: 6) { self; FieldMic(text: text, id: id) }
    }
}

/// The mic for a message box, on Glyph's shared engine (GlyphCapture `LiveDictation`, on-device),
/// drawn like the shared `DictateButton`. The box owns the dictation, so it knows when you are talking:
/// Send stops the take first and sends all of it, and nothing said after Send refills the box (the owner's
/// "Get" was sent mid-sentence and the rest landed in the empty box). `id` names it for tests.
struct Mic: View {
    @Binding var text: String
    var dictation: LiveDictation
    var id: String
    var label: String? = nil
    @State private var before = ""

    var body: some View {
        Button {
            if !dictation.on { before = text.trimmingCharacters(in: .whitespacesAndNewlines) }
            dictation.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: dictation.on ? "stop.fill" : "mic.fill")
                    .symbolEffect(.variableColor.iterative, isActive: dictation.on)
                if let label { Text(dictation.on ? "Done" : label).fontWeight(.semibold) }
            }
            .font(label == nil ? .body : .body.weight(.semibold))
            .foregroundStyle(label == nil && !dictation.on ? StudioMic.green : .white)
            .padding(.horizontal, label == nil ? 8 : 14)
            .frame(minWidth: 36, minHeight: 36)
            .background(label == nil && !dictation.on ? AnyShapeStyle(StudioMic.green.opacity(0.12)) : AnyShapeStyle(dictation.on ? Color.red.opacity(0.85) : StudioMic.green), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(dictation.on ? "Stop talking" : "Talk instead of typing")
        .accessibilityIdentifier("mic:\(id)")
        .help(dictation.problem ?? (dictation.on ? "Tap to stop" : "Tap and say it"))
        #if os(macOS)
        .probeFrame("mic:\(id)")
        #endif
        .onChange(of: dictation.text) { _, words in
            guard dictation.on, !words.isEmpty else { return } // after Send, late words never come back
            text = before.isEmpty ? words : before + " " + words
        }
    }
}

extension LiveDictation {
    /// Ends a take for Send: the box keeps what was heard so far, and the dictation lets go.
    func finishForSend() { if on { stop() } }
}

/// A field's own mic (for one-line fields): the shared `DictateButton`, with a name for tests.
struct FieldMic: View {
    @Binding var text: String
    var id: String
    var body: some View {
        DictateButton(text: $text, tint: StudioMic.green).accessibilityIdentifier("mic:\(id)")
        #if os(macOS)
            .probeFrame("mic:\(id)")
        #endif
    }
}
