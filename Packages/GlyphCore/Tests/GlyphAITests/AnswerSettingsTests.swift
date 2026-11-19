import Foundation
import Testing
@testable import GlyphAI

private let reply = #"""
{"answers":{"default":["claude","codex"],"apps":{"well":["ollama"],"time":["auto"]},"private":null},
 "private":["well","wealth"],"surfaces":["jot","time","well"],
 "engines":{"claude":{"available":true,"detail":"haiku"},"codex":{"available":false,"detail":"not set up"}},
 "council":{"available":true}}
"""#

@Test func answerSettingsDecodeTheHubReply() throws {
    let s = try #require(AnswerSettings.decode(Data(reply.utf8)))
    #expect(s.choice == ["claude", "codex"] && s.councilAvailable && s.privateApps == ["well", "wealth"])
    #expect(s.engines["claude"] == .init(available: true, detail: "haiku") && s.engines["codex"]?.available == false)
    #expect(s.choice(for: "jot") == ["claude", "codex"], "an app with no entry follows the default")
    #expect(s.choice(for: "well") == ["ollama"] && s.choice(for: "time") == ["auto"], "an entry wins")
    #expect(AnswerSettings.decode(Data(#"{"answers":{"default":[]}}"#.utf8)) == nil && AnswerSettings.decode(Data("nope".utf8)) == nil)
}

@Test func theChatWaitsLongerOnlyForACouncil() {
    #expect(AnswerSettings.timeout(for: ["auto"]) == 20 && AnswerSettings.timeout(for: ["claude"]) == 20)
    #expect(AnswerSettings.timeout(for: ["claude", "codex"]) == 120)
}

@Test func answersAreSaidInWords() {
    #expect(AnswerSettings.words(["auto"]) == "Auto" && AnswerSettings.words(["ollama"]) == "Open model")
    #expect(AnswerSettings.words(["claude", "codex"]) == "Council: Claude, Codex")
    #expect(AnswerSettings.words(by: "claude") == "Claude" && AnswerSettings.words(by: "council(claude,codex)") == "Council: Claude, Codex")
    #expect(AnswerSettings.words(by: "claude (codex unavailable)") == "Claude (Codex was not available)")
    #expect(AnswerSettings.words(by: "codex (council not set up)") == "Codex (no council on the vault computer)")
}

@Test func aChatPlanKeepsWhoAnswered() throws {
    let p = try JSONDecoder().decode(ChatPlan.self, from: Data(#"{"kind":"answer","reply":"Hi.","answered_by":"ollama"}"#.utf8))
    #expect(p.answeredBy == "ollama")
    #expect(try JSONDecoder().decode(ChatPlan.self, from: Data(#"{"kind":"none"}"#.utf8)).answeredBy == "")
}
