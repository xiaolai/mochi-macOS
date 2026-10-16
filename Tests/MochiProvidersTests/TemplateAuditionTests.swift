import MochiCore
import MochiKernel
import PCM16
import XCTest

@testable import MochiProviders

/// Plays scripted conversations through the general built-in templates against the live service, using the
/// Codex sign-in on this Mac, and writes the transcripts and the spoken audio for a person to read and hear.
/// It uses the network and the user's subscription, so it runs only with MOCHI_LIVE_AUDITION=1.
/// A few dozen turns cannot prove how the model behaves in general; they catch instructions that plainly fail.
final class TemplateAuditionTests: XCTestCase {
    private struct Scenario {
        let title: String
        /// The user's turns; the last asks for the finish and is answered in speech.
        let turns: [String]
        /// Whether a reply is in the language the user wrote in.
        let inUserLanguage: (String) -> Bool
    }
    private static func hasCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }
    private static func hasKana(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) }
    }
    private static func hasHangul(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0xAC00...0xD7AF).contains($0.value) }
    }
    private static func latin(_ text: String) -> Bool { !hasCJK(text) && !hasKana(text) && !hasHangul(text) }
    private static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    private static func evidenceFolder(_ name: String) throws -> (folder: URL, stamp: String) {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let folder = repository.appendingPathComponent("build/evidence/\(name)/\(stamp)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (folder, stamp)
    }
    private static func requireLive() throws {
        guard ProcessInfo.processInfo.environment["MOCHI_LIVE_AUDITION"] == "1" else {
            throw XCTSkip("Live audition uses the network and your subscription; set MOCHI_LIVE_AUDITION=1 to run it.")
        }
    }
    private static let scenarios = [
        Scenario(
            title: "Brainstorm with me",
            turns: [
                "Hi! Can we brainstorm?",
                "Names for a small neighbourhood bakery that also sells second-hand books.",
                "I like the bookish ones. More like those, please.",
                "Let's wrap up.",
            ], inUserLanguage: latin),
        Scenario(
            title: "Think out loud",
            turns: [
                "你好", "我最近一直在想要不要换工作，但说不清楚为什么。", "主要是觉得每天做的事情没什么意义，但收入还不错。", "帮我总结一下吧。",
            ], inUserLanguage: hasCJK),
        Scenario(
            title: "Rehearse a conversation",
            turns: [
                "I need to ask my manager for a raise next week.",
                "Her name is Sarah. She's fair but always busy, and the budget is tight this year. I've led two big projects.",
                "Hi Sarah, do you have a minute? I'd like to talk about my salary.",
                "I understand the budget is tight, but I took on a lot more responsibility this year.",
                "Let's stop there. How did I do?",
            ], inUserLanguage: latin),
        Scenario(
            title: "Make a story with me",
            turns: [
                "Let's start.", "A lighthouse keeper finds a letter addressed to her, dated tomorrow.",
                "She opens it, and it's in her own handwriting.", "Give it an ending.",
            ], inUserLanguage: latin),
        Scenario(
            title: "Interview my character",
            turns: [
                "I want to work on a character for my novel.",
                "Her name is Mara, and she wants to find her missing brother.",
                "I last saw him at the harbour ten years ago. I still blame myself for letting him go.",
                "Let's finish the interview.",
            ], inUserLanguage: latin),
        Scenario(
            title: "Learn by teaching",
            turns: ["こんにちは。", "光合成について説明したいです。", "植物は日光を使って、二酸化炭素と水から糖と酸素を作ります。", "まとめてください。"],
            inUserLanguage: hasKana),
        Scenario(
            title: "Remember a moment",
            turns: [
                "I'd like to remember my grandmother's kitchen.",
                "It always smelled of ginger, and she hummed while she cooked. The window looked out on a lemon tree.",
                "I think I felt safe there, like nothing could go wrong.", "Let's keep it.",
            ], inUserLanguage: latin),
    ]

    func testGeneralTemplatesLive() async throws {
        try Self.requireLive()
        XCTAssertEqual(
            Set(Self.scenarios.map(\.title)),
            Set(ConversationTemplate.builtins.filter { $0.category == .general }.map(\.title)),
            "Every general template needs a scenario")
        let (folder, stamp) = try Self.evidenceFolder("template-audition")
        let service = RealtimeService()
        var summary = ["# Template audition \(stamp)", ""]
        for (number, scenario) in Self.scenarios.enumerated() {
            let template = try XCTUnwrap(ConversationTemplate.builtins.first { $0.title == scenario.title })
            var history: [Message] = []
            var transcript = ["# \(template.title)", ""]
            for (index, turn) in scenario.turns.enumerated() {
                let spoken = index == scenario.turns.count - 1
                let reply = try await service.reply(
                    ConversationRequest(
                        history: history, text: turn, spoken: spoken, instructions: template.instructions,
                        characterName: template.characterName, preferences: template.preferences))
                let text = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
                history += [Message(role: "user", text: turn), Message(role: "assistant", text: text)]
                transcript += ["**User:** \(turn)", "", "**Mochi\(spoken ? " (spoken)" : ""):** \(text)", ""]
                XCTAssertFalse(text.isEmpty, "\(template.title), turn \(index + 1): empty reply")
                XCTAssertTrue(
                    scenario.inUserLanguage(text), "\(template.title), turn \(index + 1): not in the user's language")
                if spoken {
                    let seconds = Double(reply.audio.count) / 48000
                    // Words for spaced scripts; characters for Chinese and Japanese, which have no spaces.
                    let length =
                        Self.latin(text)
                        ? "\(text.split(whereSeparator: \.isWhitespace).count) words" : "\(text.count) characters"
                    transcript.append(
                        "_Spoken finish: \(String(format: "%.1f", seconds)) s, \(length), truncated: \(reply.truncated)._"
                    )
                    summary.append(
                        "- \(template.title): finish \(String(format: "%.1f", seconds)) s, truncated \(reply.truncated)"
                    )
                    XCTAssertFalse(reply.truncated, "\(template.title): the spoken finish hit the output cap")
                    try PCM.wav(reply.audio, rate: PCM.sampleRate).write(
                        to: folder.appendingPathComponent(String(format: "%02d-finish.wav", number + 1)))
                }
            }
            try transcript.joined(separator: "\n").write(
                to: folder.appendingPathComponent(String(format: "%02d.md", number + 1)), atomically: true,
                encoding: .utf8)
        }
        try summary.joined(separator: "\n").write(
            to: folder.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        print("Template audition written to \(folder.path)")
    }
    // MARK: Greetings, phrases and characters

    /// The shipped translations, read from the catalog the app is built with; the test bundle has none of its own.
    private static func translations() throws -> [String: [String: String]] {
        let data = try Data(contentsOf: repository.appendingPathComponent("Localization/Localizable.xcstrings"))
        let strings = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["strings"] as? [String: Any]
        return (strings ?? [:]).compactMapValues { entry in
            ((entry as? [String: Any])?["localizations"] as? [String: Any])?.compactMapValues {
                (($0 as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
            }
        }
    }
    /// A built-in text as a person using Mochi in `language` sees it.
    private static func text(_ english: String, in language: String, _ table: [String: [String: String]]) throws
        -> String
    {
        language == "en" ? english : try XCTUnwrap(table[english]?[language], "No \(language) text for \(english)")
    }
    private enum Turn {
        case typed(String)
        /// The template's phrase at this index, sent as its chip would send it; the last turn is spoken.
        case phrase(Int)
    }
    private struct CompanionScenario {
        let template: String
        let character: String
        let language: String
        let turns: [Turn]
        let inUserLanguage: (String) -> Bool
    }
    private static let companionScenarios = [
        CompanionScenario(
            template: "Make a story with me", character: "Pip", language: "en",
            turns: [.typed("A dragon who is afraid of heights."), .phrase(0), .phrase(2)], inUserLanguage: latin),
        CompanionScenario(
            template: "Rehearse a conversation", character: "Alex", language: "en",
            turns: [
                .typed("My landlord. The heating has been broken for two weeks and I need it fixed."),
                .typed("Hi, the heating is still broken and I need someone to fix it this week."), .phrase(0),
                .typed("I understand, but the contract says you maintain it, and it's freezing at night."),
                .phrase(2),
            ], inUserLanguage: latin),
        CompanionScenario(
            template: "Think out loud", character: "Mochi", language: "zh-Hans",
            turns: [
                .typed("我在想要不要学钢琴，但我已经三十五岁了。"), .phrase(0), .typed("其实我是怕自己坚持不下来。"), .phrase(2),
            ], inUserLanguage: hasCJK),
        CompanionScenario(
            template: "Learn by teaching", character: "Alex", language: "ja",
            turns: [
                .typed("地球の季節について教えたいです。"), .typed("地軸が傾いているので、場所によって太陽の光の当たり方が一年の中で変わります。"),
                .phrase(0), .phrase(2),
            ], inUserLanguage: hasKana),
        CompanionScenario(
            template: "Remember a moment", character: "Pip", language: "ko",
            turns: [
                .typed("할머니 댁 마당이 생각나요."), .phrase(1), .typed("사촌들이랑 평상에 앉아서 수박을 먹었어요."), .phrase(2),
            ], inUserLanguage: hasHangul),
    ]

    /// Every built-in greeting, in every interface language, read back word for word across all of Mochi's voices;
    /// then conversations that open with the greeting, use a character, and are steered by phrases. Every result is
    /// recorded before the test fails, so one failure never hides the rest of the evidence.
    func testGreetingsPhrasesAndCharactersLive() async throws {
        try Self.requireLive()
        let table = try Self.translations()
        let (folder, stamp) = try Self.evidenceFolder("companion-audition")
        var summary = ["# Companion audition \(stamp)", "", "## Greetings, read back word for word", ""]
        var failures: [String] = []
        let general = ConversationTemplate.builtins.filter { $0.category == .general }
        let languages = ["en", "zh-Hans", "zh-Hant", "ja", "ko"]
        var spokenCount = 0
        var firstAttempt = 0
        var readBack = 0
        for (number, template) in general.enumerated() {
            for language in languages {
                let text = try Self.text(template.greeting, in: language, table)
                let voice = RealtimeVoice.allCases[spokenCount % RealtimeVoice.allCases.count].rawValue
                spokenCount += 1
                let service = RealtimeService(voice: voice)
                // The app makes one attempt and asks the person to retry; the attempts here measure how often.
                var attempts: [String] = []
                var matched = false
                while !matched && attempts.count < 3 {
                    do {
                        let reply = try await service.reply(
                            ConversationRequest(history: [], text: text, spoken: true, reference: true))
                        matched =
                            !reply.audio.isEmpty && !reply.truncated
                            && ReferenceSpeech.matches(text, reply.text, language: language)
                        attempts.append(reply.text)
                        if matched {
                            try PCM.wav(reply.audio, rate: PCM.sampleRate).write(
                                to: folder.appendingPathComponent(
                                    String(format: "greeting-%02d-%@-%@.wav", number + 1, language, voice)))
                        }
                    } catch {
                        attempts.append("error: \(error)")
                    }
                }
                if matched {
                    readBack += 1
                    if attempts.count == 1 { firstAttempt += 1 }
                } else {
                    failures.append("\(template.title) [\(language), \(voice)] never read back: \(attempts)")
                }
                summary.append(
                    "- \(template.title) [\(language), \(voice)]: \(matched ? "read back" : "FAILED") on attempt "
                        + "\(attempts.count)\(attempts.count > 1 ? "; misreadings: \(attempts.dropLast())" : "")")
            }
        }
        summary += [
            "", "Read back on the first attempt: \(firstAttempt) of \(spokenCount); within three: \(readBack).", "",
            "## Conversations", "",
        ]
        for (number, scenario) in Self.companionScenarios.enumerated() {
            let template = try XCTUnwrap(ConversationTemplate.builtins.first { $0.title == scenario.template })
            let character = try XCTUnwrap(ConversationCharacter.builtins.first { $0.name == scenario.character })
            let service = RealtimeService(voice: character.voice ?? RealtimeService.defaultVoice)
            let greeting = try Self.text(template.greeting, in: scenario.language, table)
            var history = [Message(role: "assistant", text: greeting, speakerName: character.name)]
            var transcript = [
                "# \(template.title) with \(character.name) (\(scenario.language), \(service.voice))", "",
                "**\(character.name) (greeting):** \(greeting)", "",
            ]
            let name = "\(template.title) with \(character.name)"
            do {
                for (index, turn) in scenario.turns.enumerated() {
                    let spoken = index == scenario.turns.count - 1
                    let text: String
                    switch turn {
                    case .typed(let typed): text = typed
                    case .phrase(let phrase):
                        text = try Self.text(template.phrases[phrase], in: scenario.language, table)
                    }
                    let reply = try await service.reply(
                        ConversationRequest(
                            history: history, text: text, spoken: spoken, instructions: template.instructions,
                            characterName: character.name, preferences: template.preferences,
                            personality: character.personality))
                    let answer = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    history += [
                        Message(role: "user", text: text),
                        Message(role: "assistant", text: answer, speakerName: character.name),
                    ]
                    let label = if case .phrase = turn { "User (phrase)" } else { "User" }
                    transcript += [
                        "**\(label):** \(text)", "", "**\(character.name)\(spoken ? " (spoken)" : ""):** \(answer)",
                        "",
                    ]
                    if answer.isEmpty { failures.append("\(name), turn \(index + 1): empty reply") }
                    if !scenario.inUserLanguage(answer) {
                        failures.append("\(name), turn \(index + 1): not in the user's language")
                    }
                    if character.name != "Mochi" && answer.contains("Mochi") {
                        failures.append("\(name), turn \(index + 1): \(character.name) called itself Mochi")
                    }
                    if spoken {
                        if reply.truncated { failures.append("\(name): the spoken finish hit the output cap") }
                        try PCM.wav(reply.audio, rate: PCM.sampleRate).write(
                            to: folder.appendingPathComponent(
                                String(format: "conversation-%02d-finish.wav", number + 1)))
                        summary.append(
                            "- \(name) [\(scenario.language), \(service.voice)]: finish "
                                + "\(String(format: "%.1f", Double(reply.audio.count) / 48000)) s, "
                                + "truncated \(reply.truncated)")
                    }
                }
            } catch {
                failures.append("\(name): \(error)")
                transcript += ["_Stopped: \(error)_", ""]
            }
            try transcript.joined(separator: "\n").write(
                to: folder.appendingPathComponent(String(format: "conversation-%02d.md", number + 1)),
                atomically: true, encoding: .utf8)
        }
        summary += ["", "## Failures", ""] + (failures.isEmpty ? ["None."] : failures.map { "- \($0)" })
        try summary.joined(separator: "\n").write(
            to: folder.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        print("Companion audition written to \(folder.path)")
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }
}
