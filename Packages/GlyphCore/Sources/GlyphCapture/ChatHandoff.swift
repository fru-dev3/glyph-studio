#if os(iOS)
import GlyphAI
import GlyphVault
import SwiftUI
import UIKit

extension Color {
    /// "007A5E" (a GlyphAgent's colour).
    init(hex: String) {
        let v = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x808080
        self.init(red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

extension ChatModel {
    /// Where Time goes back to once it has armed what an app's chat asked for.
    static let backLinks = ["jot": "jot://chat", "crm": "glyph-crm://", "native": "glyph-native://time", "well": "glyph-well://", "travel": "glyph-travel://"]
    static let timeLink = URL(string: "glyph-time://")!

    /// One turn of Glyph Core Intelligence as chat lines, the same in every app on GlyphChat. An answer, a question
    /// back, or what was done. Another app's job (a handoff) says what it is doing under that app's face, is done by
    /// that app's agent, and for Time waits for Time's own answer: "Waiting for Time", then the confirmed card
    /// ("Alarm set · 3:32 PM · Take a walk", a tap opens Time). Never a done card before the app confirms. The
    /// hub's optional proactive offer follows last.
    public static func lines(for plan: ChatPlan, hub: Hub, app: String) async -> [ChatEntry] {
        let nothing = [ChatEntry(text: plan.reply.isEmpty ? "Nothing to do" : plan.reply)]
        switch plan.kind {
        case "answer": return [.answer(plan.reply)]
        case "ask": return [.ask(plan.question.isEmpty ? plan.reply : plan.question)]
        case "act": break
        default: return nothing
        }
        var out: [ChatEntry] = []
        for job in plan.jobs {
            let name = GlyphAgent.named(job.agent)?.name ?? job.agent.capitalized
            if job.handoff {
                let what = [job.at, job.title.isEmpty ? job.quote : job.title].filter { !$0.isEmpty }.joined(separator: " · ")
                // Wrapped in full (never cut short): what is being done, in which app, the time and the title.
                out.append(ChatEntry(text: job.doing.isEmpty ? "Asking \(name): \(what)" : job.doing, kind: .answer, agent: job.agent))
            }
            for d in await hub.perform(ChatPlan(kind: "act", jobs: [job])).flatMap(\.done) {
                if let id = d.waiting {
                    out.append(waiting(id, job: job, command: d.line, queue: hub.timeQueue, back: backLinks[app].flatMap(URL.init(string:))))
                } else {
                    out.append(ChatEntry(text: d.line, done: d.ok, mood: d.ok ? .happy : .sad,
                                         undo: d.undo.map { u -> @MainActor () -> Void in { Task { _ = await hub.undo(u) } } }, link: d.ok ? d.link : nil,
                                         agent: job.handoff ? job.agent : nil))
                }
            }
        }
        guard !out.isEmpty else { return nothing }
        if !plan.suggest.isEmpty {  // after the last thing is done, or confirmed
            let offer = ChatEntry(text: plan.suggest, kind: .answer)
            if let i = out.lastIndex(where: { $0.then != nil }), let then = out[i].then { out[i].then = { await then() + [offer] } }
            else { out.append(offer) }
        }
        return out
    }

    /// Time's request, left in the shared queue: Time is opened to arm it (and comes back), and the line waits for
    /// Time's answer on the request's id.
    static func waiting(_ id: String, job: ChatPlan.Job, command: String, queue: URL, back: URL?) -> ChatEntry {
        ChatEntry(text: "Waiting for Time", working: true, agent: "time") {
            // The App Group Time reads (or a queue of the caller's own, as in tests, answered there).
            let shared = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: TimeRequest.group) != nil || queue != TimeRequest.queue
            guard shared else {
                // No shared queue in this app: Time hears it in its own Chat, and confirms there.
                var c = URLComponents(string: "glyph-time://talk")!; c.queryItems = [URLQueryItem(name: "text", value: command)]
                let sent = await UIApplication.shared.open(c.url!)
                return [ChatEntry(text: sent ? "Sent to Time's Chat: \(command)" : "Glyph Time isn't on this iPhone", mood: sent ? .rest : .sad,
                                  link: sent ? timeLink : nil, agent: "time")]
            }
            let opened = await UIApplication.shared.open(GlyphAgent.armLink(back: back))
            // Time answers in the queue, then comes back; without Time, a few seconds only (a test may answer for it).
            for _ in 0..<(opened ? 600 : 6) {
                if let a = TimeRequest.answer(id, in: queue) {
                    guard a.event == "armed" else {
                        return [ChatEntry(text: "Time couldn't: \(a.text ?? "no time in that")", mood: .sad, link: timeLink, agent: "time")]
                    }
                    return [ChatEntry(text: ChatPlan.confirmed(a.text ?? "", job: job), detail: a.text, done: true, link: timeLink, agent: "time")]
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            return [ChatEntry(text: opened ? "Time hasn't answered, open it to check" : "Glyph Time isn't on this iPhone",
                              mood: .sad, link: opened ? timeLink : nil, agent: "time")]
        }
    }
}
#endif
