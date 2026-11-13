import Foundation
import Testing
@testable import GlyphAI
import GlyphVault

@Test func chatPlanDecodesToolJobsAndAnswers() throws {
    let act = try JSONDecoder().decode(ChatPlan.self, from: Data(#"{"kind":"act","reply":"Saved","jobs":[{"agent":"jot","tool":"save_note","arguments":{"text":"Call Ken Lee","n":2},"quote":"note to call Ken Lee","handoff":true}]}"#.utf8))
    #expect(act.kind == "act" && act.jobs.count == 1 && act.jobs[0].handoff && act.jobs[0].tool == "save_note")
    let args = try JSONSerialization.jsonObject(with: Data(act.jobs[0].arguments.utf8)) as? [String: Any]
    #expect(args?["text"] as? String == "Call Ken Lee" && args?["n"] as? Int == 2)
    let ask = try JSONDecoder().decode(ChatPlan.self, from: Data(#"{"kind":"ask","question":"Which Ken?"}"#.utf8))
    #expect(ask.question == "Which Ken?" && ask.jobs.isEmpty && ask.reply.isEmpty)
}

@Test func timeAgentHasTimerCommands() async throws {
    let queue = FileManager.default.temporaryDirectory.appending(path: "chatplan-\(UUID().uuidString).jsonl")
    let hub = Hub(base: nil, model: "iPhone", timeQueue: queue)
    let done = try await GlyphAgent.time.call("stop_timer", json: "{}", hub: hub)
    #expect(done.count == 1 && done[0].line == "stop the timer")
}

/// Fru, 2026-10-30: "alarm in five minutes to remind me to take a walk" came back as "wake me up in 5 minutes for
/// Take a..." (a title from Time's data, a done card before Time said anything). The handoff carries their words.
@Test func handoffCarriesTheirWordsAndConfirmsFromTime() async throws {
    let plan = try JSONDecoder().decode(ChatPlan.self, from: Data(#"""
    {"kind":"act","suggest":"Want me to log the walk in Well when you're back?","jobs":[{"agent":"time","tool":"request_alarm",
     "arguments":{"when":"in 5 minutes","label":"Take a walk"},"quote":"alarm in five minutes to remind me to take a walk","handoff":true,
     "title":"Take a walk","at":"3:32 PM","doing":"Asking Time to set an alarm for 3:32 PM: Take a walk"}]}
    """#.utf8))
    let j = plan.jobs[0]
    #expect(j.title == "Take a walk" && j.at == "3:32 PM" && j.doing.hasPrefix("Asking Time") && plan.suggest.contains("Well"))
    let queue = FileManager.default.temporaryDirectory.appending(path: "walk-\(UUID().uuidString).jsonl")
    let done = try await GlyphAgent.time.call(j.tool, json: j.arguments, hub: Hub(base: nil, model: "iPhone", timeQueue: queue))
    #expect(done.count == 1 && done[0].waiting != nil, "nothing shows as set until Time answers")
    #expect(TimeRequest.pending(in: queue).first?.command == "wake me up in 5 minutes for Take a walk")
    #expect(ChatPlan.confirmed("Alarm: Take a walk, today at 3:32 PM", job: j) == "Alarm set · 3:32 PM · Take a walk")
    #expect(ChatPlan.confirmed("Alarm: Take a walk, tomorrow at 7:00 AM", job: j) == "Alarm set · tomorrow 7:00 AM · Take a walk")
    #expect(ChatPlan.confirmed("Alarm", job: ChatPlan.Job(agent: "time", tool: "request_alarm", at: "3:32 PM")) == "Alarm set · 3:32 PM")
    #expect(GlyphAgent.armLink(back: URL(string: "jot://chat")).absoluteString == "glyph-time://arm?return=jot://chat")
}
