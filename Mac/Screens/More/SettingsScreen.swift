import SwiftUI

/// Settings, a sheet over the app: which vault and engine, the three privacy switches (they write
/// Studio's Privacy flags, which every engine call reads), the chief of staff's name (`chief set-name`)
/// and the spending line agents ask before crossing (`chief set usd`). Done goes back.
struct SettingsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var engine = ""
    @State private var usd: Double?
    @State private var editing: String?
    @State private var field = ""
    @State private var problem: String?
    @State private var flags = (bunker: Privacy.bunker, lock: Privacy.vaultLock, draft: Privacy.draftOnly)
    @State private var phone = PhoneLink.wanted
    @State private var models = ""

    var body: some View {
        MorePanel(dim: false) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Settings").font(.ui(17, .semibold))
                    Spacer()
                    MoreTextButton(title: "Done") { model.go(model.previous ?? .chat(AppModel.chiefID)) }
                }
                header("Vault")
                linkRow("Vault", value: Vault.isDemo ? "Demo vault" : "Your vault") { model.go(.sources("vault")) }
                row("Engine", value: engine)
                row("Models", value: models)
                row("Glyph Bot", value: Self.appVersion)
                header("Privacy")
                toggle("Local models only", "Nothing leaves this Mac", isOn: Binding(get: { flags.bunker }, set: { Privacy.set(bunker: $0); flags.bunker = Privacy.bunker }))
                toggle("Keep agents inside the vault", "Agents cannot read other folders", isOn: Binding(get: { flags.lock }, set: { Privacy.set(vaultLock: $0); flags.lock = Privacy.vaultLock }))
                toggle("Draft, never send", "Agents draft; you send, and you say Save", isOn: Binding(get: { flags.draft }, set: { Privacy.set(draftOnly: $0); flags.draft = Privacy.draftOnly }))
                header("iPhone")
                if Vault.isDemo {
                    row("Glyph Bot on the iPhone", value: "Works with your vault")
                } else {
                    toggle("Answer the iPhone", PhoneLink.shared.running ? "Over Tailscale only, port \(PhoneLink.shared.port)" : (PhoneLink.shared.problem ?? "Over Tailscale only. macOS asks once: choose Allow"),
                           isOn: Binding(get: { phone }, set: { PhoneLink.set(on: $0); phone = $0 }))
                }
                header("Agents")
                editable("Chief of staff", key: "name", value: model.chiefName, prompt: "A name")
                editable("Ask before spending over", key: "usd", value: usd.map(Self.dollars) ?? "", prompt: "Dollars")
                if let problem { Text(problem).font(.ui(12.5)).foregroundStyle(Ink.warn).padding(.top, 10) }
            }
        }
        .task { await load() }
    }

    private func header(_ t: String) -> some View { MoreLabel(text: t).padding(.top, 18) }

    private func line<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        HStack(spacing: 12) { content() }
            .padding(.vertical, 13)
            .overlay(alignment: .bottom) { Rectangle().fill(Color(hex: 0xF0F1EF)).frame(height: 1) }
    }

    private func row(_ k: String, value: String) -> some View {
        line {
            Text(k).font(.ui(14.5, .medium))
            Spacer()
            Text(value).font(.ui(13.5)).foregroundStyle(Color(hex: 0x6B706C))
        }
    }

    private func linkRow(_ k: String, value: String, action: @escaping () -> Void) -> some View {
        line {
            Text(k).font(.ui(14.5, .medium))
            Spacer()
            Button(action: action) {
                HStack(spacing: 4) {
                    Text(value).font(.ui(13.5))
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(Color(hex: 0x6B706C)).contentShape(Rectangle())
            }
            .buttonStyle(.plain).probe("settings:\(k)", action: action)
        }
    }

    /// "Version 0.1.3 (1)", from the app's own Info.plist.
    static var appVersion: String {
        let i = Bundle.main.infoDictionary ?? [:]
        return "Version \(i["CFBundleShortVersionString"] as? String ?? "?") (\(i["CFBundleVersion"] as? String ?? "?"))"
    }

    /// The model CLIs on this Mac and the provider keys on disk, by name only.
    static func modelsLine() -> String {
        let clis = [("claude", "Claude"), ("codex", "Codex"), ("ollama", "Ollama")]
            .filter { c in Engine.searchPath.contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(c.0)") } }.map(\.1)
        let keys = Vault.isDemo ? [] : Keys.available()
        var parts: [String] = []
        if !clis.isEmpty { parts.append(clis.joined(separator: ", ")) }
        if !keys.isEmpty { parts.append("keys for " + keys.joined(separator: ", ")) }
        return parts.isEmpty ? "None found" : parts.joined(separator: " · ")
    }

    private func toggle(_ k: String, _ sub: String, isOn: Binding<Bool>) -> some View {
        line {
            VStack(alignment: .leading, spacing: 0) {
                Text(k).font(.ui(14.5, .medium))
                Text(sub).font(.ui(12.5)).foregroundStyle(Color(hex: 0x7A7F7B))
            }
            Spacer()
            Toggle38(isOn: isOn, label: k)
        }
    }

    private func editable(_ k: String, key: String, value: String, prompt: String) -> some View {
        line {
            Text(k).font(.ui(14.5, .medium))
            Spacer()
            if editing == key {
                TextField(prompt, text: $field).textFieldStyle(.plain).font(.ui(13.5)).multilineTextAlignment(.trailing).frame(width: 160)
                    .onSubmit { Task { await save(key) } }
                    .probeField("settings:\(key)", text: $field) { Task { await save(key) } }
                MoreTextButton(title: "Save", id: "settings:save:\(key)", color: Ink.green) { Task { await save(key) } }
            } else {
                Button { edit(key, value) } label: { Text(value).font(.ui(13.5)).foregroundStyle(Color(hex: 0x6B706C)).contentShape(Rectangle()) }
                    .buttonStyle(.plain).help("Change").probe("settings:edit:\(key)") { edit(key, value) }
            }
        }
    }

    private func edit(_ key: String, _ value: String) {
        editing = key
        field = key == "usd" ? value.replacingOccurrences(of: "$", with: "") : value
    }

    private func save(_ key: String) async {
        let v = field.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            switch key {
            case "name":
                guard !v.isEmpty else { problem = "The chief of staff needs a name."; return }
                _ = try await Engine.run(["chief", "set-name", v, "--json"])
                await model.refresh()
            default:
                guard let n = Double(v.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "")), n >= 0 else {
                    problem = "Write the limit as dollars, like 25."; return
                }
                let r = try await Engine.json(["chief", "set", "usd", Self.dollars(n).dropFirst().description], as: ChiefLimits.self)
                usd = r.limits?.usd ?? n
            }
            editing = nil; problem = nil
        } catch { problem = error.localizedDescription }
    }

    private func load() async {
        flags = (Privacy.bunker, Privacy.vaultLock, Privacy.draftOnly)
        models = Self.modelsLine()
        async let v = Engine.run(["--version"])
        async let c = Engine.json(["chief", "show"], as: ChiefLimits.self)
        if let out = try? await v { engine = Self.engineName(String(decoding: out, as: UTF8.self)) }
        do { usd = try await c.limits?.usd } catch { problem = error.localizedDescription }
    }

    /// "prevail 1.10.9 (Glyph Engine)" -> "Glyph Engine 1.10.9".
    static func engineName(_ s: String) -> String {
        let line = s.split(separator: "\n").first.map(String.init) ?? ""
        let version = line.split(separator: " ").first { $0.first?.isNumber == true }.map(String.init)
        guard let version else { return line.nonEmpty ?? "Unknown" }
        return "Glyph Engine \(version)"
    }

    /// 25 -> "$25", 2.5 -> "$2.50".
    static func dollars(_ n: Double) -> String {
        n == n.rounded() ? "$\(Int(n))" : String(format: "$%.2f", n)
    }

    /// The vault's own name, from VAULT.md's title ("# VAULT.md - Glyph demo vault"), else its folder.
    static var vaultName: String {
        if let first = Vault.read(Vault.root.appending(path: "VAULT.md"))?.split(separator: "\n").first, first.hasPrefix("# ") {
            let t = first.dropFirst(2)
            let name = t.range(of: " - ").map { String(t[$0.upperBound...]) } ?? String(t)
            if let n = name.nonEmpty { return n.prefix(1).uppercased() + n.dropFirst() }
        }
        return Vault.root.lastPathComponent
    }
}
