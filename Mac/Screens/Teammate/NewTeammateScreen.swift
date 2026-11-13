import SwiftUI

/// A new teammate: a sheet over the canvas. Name it, pick its shape and colour (the big avatar
/// follows), write its role as your intent for that part of life, and Create makes the domain in
/// the vault and opens its chat. Or let Ben interview you to write it.
struct NewTeammateScreen: View {
    @Environment(AppModel.self) private var model
    @State private var draft = TeammateDraft()
    @State private var problem: String?
    @State private var busy = false

    var body: some View {
        ZStack(alignment: .top) {
            Color(hex: 0xEEF0ED)
            sheet.padding(.top, 22)
        }
        .onChange(of: draft.name) { problem = nil }
    }

    private var sheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("New teammate").font(.ui(17, .semibold))
                Spacer()
                Button("Cancel", action: cancel).buttonStyle(.plain).font(.ui(13)).foregroundStyle(Ink.tertiary)
                    .keyboardShortcut(.cancelAction).probe("Cancel", action: cancel)
            }
            HStack(alignment: .center, spacing: 22) {
                Self.swatch(draft.shape, size: 84).fill(Color(fixed: draft.color)).frame(width: 84, height: 84)
                    .overlay {
                        if TeamGlyph.drawn.contains(draft.glyph) {
                            TeamGlyph(name: draft.glyph).stroke(.white, style: StrokeStyle(lineWidth: 3.4 * 43 / 40, lineCap: .round, lineJoin: .round)).frame(width: 43, height: 43)
                        } else {
                            Image(systemName: draft.glyph).font(.system(size: 30, weight: .semibold)).foregroundStyle(.white)
                        }
                    }
                    .animation(.snappy(duration: 0.2), value: draft.look)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    TextField("", text: $draft.name, prompt: Text("Name").foregroundStyle(Ink.tertiary))
                .studioDictatable($draft.name)
                        .textFieldStyle(.plain).font(.ui(17, .semibold))
                        .padding(.horizontal, 14).frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(hex: 0xF3F4F2)))
                        .onSubmit(create)
                        .probeField("name", text: $draft.name, submit: create)
                    HStack(spacing: 10) { ForEach(Look.Shape.allCases, id: \.self, content: shapeButton) }.padding(.top, 12)
                    HStack(spacing: 8) { ForEach(Look.palette, id: \.self, content: colorButton) }.padding(.top, 10)
                }
            }
            .padding(.top, 18)
            if let problem {
                Text(problem).font(.ui(12.5)).foregroundStyle(Ink.warn).padding(.top, 10).probe("problem-name")
            }
            Text("ITS ROLE IS YOUR INTENT FOR THIS PART OF LIFE").font(.ui(12, .semibold)).foregroundStyle(Ink.tertiary).padding(.top, 22)
            field("Purpose, in your words", "What this teammate is for, in a sentence", $draft.purpose, id: "purpose")
            field("Trade-offs", "X over Y · one per line", $draft.tradeOffs, id: "trade-offs")
            field("May do alone", "Read, draft, book calls under $100", $draft.mayAlone, id: "may")
            field("Must ask", "Paying, signing, contacting anyone new", $draft.mustAsk, id: "must-ask")
            HStack {
                Button(action: interview) {
                    Text("\(model.chiefName) can interview you to write this").font(.ui(13)).foregroundStyle(Ink.green)
                }
                .buttonStyle(.plain).probe("interview", action: interview)
                Spacer()
                PillButton(title: busy ? "Creating" : "Create", primary: true, id: "Create", action: create)
                    .disabled(busy)
            }
            .padding(.top, 18)
        }
        .padding(.horizontal, 30).padding(.vertical, 26)
        .frame(width: 640)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Ink.surface)
            .shadow(color: .black.opacity(0.18), radius: 22, y: 18))
    }

    private func field(_ label: String, _ hint: String, _ text: Binding<String>, id: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.ui(12.5)).foregroundStyle(Ink.secondary)
            TextField("", text: text, prompt: Text(hint).foregroundStyle(Color(hex: 0xA3A7A4)), axis: .vertical)
                .studioDictatable(text)
                .lineLimit(1...3)
                .textFieldStyle(.plain).font(.ui(14.5))
                .padding(.horizontal, 14).padding(.vertical, 10.5) // 39 pt tall, as drawn
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Ink.bubble))
                .probeField(id, text: text)
        }
        .padding(.top, 10)
    }

    private func shapeButton(_ s: Look.Shape) -> some View {
        let on = draft.shape == s
        return Button { draft.shape = s } label: {
            Self.swatch(s).fill(on ? Color(fixed: draft.color) : Color(hex: 0xE9EBE8)).frame(width: 34, height: 34)
                .overlay { if on { Self.swatch(s).stroke(Color(fixed: draft.color), lineWidth: 2).frame(width: 42, height: 42) } }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(s.rawValue) shape").accessibilityAddTraits(on ? .isSelected : [])
        .probe("shape:\(s.rawValue)") { draft.shape = s }
    }

    private func colorButton(_ c: UInt32) -> some View {
        Button { draft.color = c } label: { Circle().fill(Color(hex: c)).frame(width: 22, height: 22) }
            .buttonStyle(.plain)
            .accessibilityLabel(String(format: "colour #%06X", c)).accessibilityAddTraits(draft.color == c ? .isSelected : [])
            .probe(String(format: "color:%06x", c)) { draft.color = c }
    }

    /// The shapes at the renders' radii (points, not a share of the size; at most half of it).
    static func swatch(_ s: Look.Shape, size: CGFloat = 34) -> AnyShape {
        let r = { (v: CGFloat) in min(v, size / 2) }
        switch s {
        case .circle: return AnyShape(Circle())
        case .squircle: return AnyShape(RoundedRectangle(cornerRadius: size > 40 ? 22 : 10, style: .continuous))
        case .leaf: return AnyShape(UnevenRoundedRectangle(topLeadingRadius: r(10), bottomLeadingRadius: r(22), bottomTrailingRadius: r(22), topTrailingRadius: r(22)))
        case .drop: return AnyShape(UnevenRoundedRectangle(topLeadingRadius: r(22), bottomLeadingRadius: r(22), bottomTrailingRadius: r(8), topTrailingRadius: r(22)))
        case .square: return AnyShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
    }

    // MARK: actions

    private func cancel() {
        model.go(.chat(AppModel.chiefID))
    }

    private func create() {
        guard !busy else { return }
        let existing = IntentStore().domainSlugs()
        if let p = draft.problem(existing: existing, names: model.team.map(\.name), chiefName: model.chiefName) { problem = p; return }
        busy = true
        do {
            try draft.create()
        } catch {
            problem = error.localizedDescription
            busy = false
            return
        }
        let slug = draft.slug
        Task {
            await model.refresh()
            busy = false
            model.go(.chat(slug))
        }
    }

    private func interview() {
        ChatHandoff.pending[AppModel.chiefID] = draft.interviewMessage
        model.go(.chat(AppModel.chiefID))
    }
}
