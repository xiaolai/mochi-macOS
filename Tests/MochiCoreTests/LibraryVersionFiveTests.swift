import MochiKernel
import MochiTestSupport
import XCTest

@testable import MochiCore

/// Version 5 adds review state, recording metadata and transcript evidence (plan W4). Older Mochi refuses it, so the
/// bytes of a version-4 library are kept, once, before its first version-5 save.
final class LibraryVersionFiveTests: XCTestCase {
    private func folder() -> URL { TestScratch.folder() }
    private let v5 = LibraryStore.reviewLibraryBackupPrefix
    /// A library as Mochi 0.8 wrote it: version 4, none of the version-5 keys.
    private func versionFour(title: String = "Old", audio: String? = nil) -> Data {
        let message =
            audio.map { #"{"id":"\#(UUID())","role":"user","text":"Hello","audio":"\#($0)","date":0}"# } ?? ""
        return Data(
            #"{"version":4,"conversations":[{"id":"\#(UUID())","title":"\#(title)","messages":[\#(message)],"date":0}],"expressions":[{"id":"\#(UUID())","conversationID":"\#(UUID())","meaning":"m","english":"Hello.","referenceKind":"Your voice","attempts":[],"date":0}],"conversationTemplates":[],"characters":[]}"#
                .utf8)
    }
    private func backups(_ root: URL, _ prefix: String) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
    }
    private func evidence(_ text: String) -> TranscriptEvidence {
        TranscriptEvidence(text: text, raw: text, tokens: [(Array(text.utf8), -0.1)])!
    }

    func testVersionFourKeepsItsBytesOnceBeforeItsFirstVersionFiveSave() throws {
        let root = folder()
        let store = LibraryStore(root: root)
        try store.prepare()
        let original = versionFour()
        try original.write(to: store.file)
        let loaded = try store.load()
        XCTAssertNil(loaded.expressions[0].review, "Older formats decode the new fields as nil")
        try store.save(loaded)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("\(v5).json")), original)
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("\(v5).json").path)[
                .posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try JSONDecoder().decode(Library.self, from: Data(contentsOf: store.file)).version, 5)
        try store.save(try store.load())
        XCTAssertEqual(try backups(root, v5).count, 1, "Later saves add no copies")
        XCTAssertEqual(try backups(root, LibraryStore.characterLibraryBackupPrefix), [])
    }
    func testOlderVersionsKeepOnlyTheirOwnUpgradeCopy() throws {
        let root = folder()
        let store = LibraryStore(root: root)
        try store.prepare()
        let three = Data(
            #"{"version":3,"conversations":[],"expressions":[],"conversationTemplates":[]}"#.utf8)
        try three.write(to: store.file)
        try store.save(try store.load())
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent("\(LibraryStore.characterLibraryBackupPrefix).json")),
            three)
        XCTAssertEqual(try backups(root, v5), [], "The version-5 threshold is version 4 only")
    }
    func testADifferentVersionFourCopyGetsItsOwnBackup() throws {
        let root = folder()
        let store = LibraryStore(root: root)
        try store.prepare()
        let first = versionFour(title: "First")
        try first.write(to: store.file)
        try store.save(try store.load())
        let second = versionFour(title: "Second")
        try second.write(to: store.file)
        try store.save(try store.load())
        let kept = try backups(root, v5)
        XCTAssertEqual(kept.count, 2)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("\(v5).json")), first)
        XCTAssertTrue(try kept.contains { try Data(contentsOf: $0) == second })
    }
    func testAFailedBackupBlocksTheSave() throws {
        let root = folder()
        let store = LibraryStore(root: root)
        try store.prepare()
        let original = versionFour()
        try original.write(to: store.file)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("\(v5).json"), withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.save(try store.load()))
        XCTAssertEqual(try Data(contentsOf: store.file), original)
    }
    func testRestoringAVersionFourEarlierCopyKeepsItsOriginalBytes() throws {
        let root = folder()
        let store = LibraryStore(root: root)
        try store.prepare()
        try Data("not a library".utf8).write(to: store.file)
        let original = versionFour()
        try original.write(to: store.previousFile)
        let restored = try store.restorePrevious()
        try store.save(restored)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("\(v5).json")), original)
    }
    func testOnlyNamesLikeTheBackupsThemselvesAreRefused() throws {
        let root = folder()
        let store = LibraryStore(root: root)
        try store.prepare()
        let name = "\(v5)-example.wav"
        try Data([1, 2, 3]).write(to: root.appendingPathComponent(name))
        try versionFour(audio: name).write(to: store.file)
        XCTAssertEqual(try store.load().referencedAudio, [name])
        for unsafe in ["\(v5).json", "\(v5)-1-\(UUID().uuidString).json"] {
            var library = Library()
            var chat = Conversation()
            chat.messages = [Message(role: "user", text: "", audio: unsafe)]
            library.conversations = [chat]
            XCTAssertThrowsError(try library.validate(), unsafe)
        }
    }

    func testEveryNewFieldSurvivesTheFileABackupAndAnImport() throws {
        let root = folder()
        let store = LibraryStore(root: root)
        try store.prepare()
        var library = Library()
        var chat = Conversation()
        var voice = Message(role: "user", text: "I go home.", audio: "recording-\(UUID().uuidString).wav")
        voice.recording = RecordingMetadata(model: "gpt-4o-mini-transcribe", language: "en")
        voice.transcriptEvidence = evidence("I go home.")
        chat.messages = [voice]
        library.conversations = [chat]
        var item = PracticeExpression(conversationID: chat.id, meaning: "m", english: "Hello.", language: .english)
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        item.review = ReviewState(
            box: 2, due: day.addingTimeInterval(86400 * 4), enrolled: day,
            grades: [.init(date: day, grade: .good)])
        library.expressions = [item]
        try Data([1]).write(to: root.appendingPathComponent(voice.audio!))
        try store.save(library)
        let loaded = try store.load()
        XCTAssertEqual(loaded.conversations[0].messages[0].recording, voice.recording)
        XCTAssertEqual(loaded.conversations[0].messages[0].transcriptEvidence, voice.transcriptEvidence)
        XCTAssertEqual(loaded.expressions[0].review, item.review)

        let package = folder().appendingPathComponent("backup.mochilibrary")
        try LibraryBackup.write(loaded, from: root, to: package)
        let read = try LibraryBackup.read(package)
        XCTAssertEqual(read.expressions[0].review, item.review)
        var local = Library()
        XCTAssertEqual(try LibraryBackup.merge(read, from: package, into: &local, root: folder()), 1)
        XCTAssertEqual(local.conversations[0].messages[0].transcriptEvidence, voice.transcriptEvidence)
        XCTAssertEqual(local.conversations[0].messages[0].recording, voice.recording)
        XCTAssertEqual(local.expressions[0].review, item.review)
    }

    func testInvalidNewFieldsAreRefused() {
        func refused(_ change: (inout Library) -> Void, _ label: String) {
            var library = Library()
            var chat = Conversation()
            chat.messages = [Message(role: "user", text: "I go home.", audio: "a.wav")]
            library.conversations = [chat]
            library.expressions = [
                PracticeExpression(conversationID: chat.id, meaning: "", english: "Hi.", language: .english)
            ]
            XCTAssertNoThrow(try library.validate(), label)
            change(&library)
            XCTAssertThrowsError(try library.validate(), label)
        }
        let now = Date()
        refused({ $0.expressions[0].review = ReviewState(box: 6, due: now, enrolled: now) }, "box above 5")
        refused({ $0.expressions[0].review = ReviewState(box: -1, due: now, enrolled: now) }, "negative box")
        refused(
            { $0.expressions[0].review = ReviewState(due: now, enrolled: now.addingTimeInterval(1)) },
            "due before enrolment")
        refused(
            {
                $0.expressions[0].review = ReviewState(
                    due: now, enrolled: now, grades: Array(repeating: .init(date: now, grade: .good), count: 101))
            }, "too many grades")
        refused({ $0.conversations[0].messages[0].recording = RecordingMetadata(model: "") }, "empty model")
        refused(
            { $0.conversations[0].messages[0].recording = RecordingMetadata(model: "m", language: "match") },
            "Match Me is not a language hint")
        refused(
            { $0.conversations[0].messages[0].recording = RecordingMetadata(model: "m", language: "xx") },
            "unknown language")
        refused(
            { $0.conversations[0].messages[0].transcriptEvidence = self.evidence("I went home.") },
            "evidence for other text")
        refused(
            {
                $0.conversations[0].messages[0].transcriptEvidence?.pieces[0].logprob = 0
                var bad = self.evidence("I go home.")
                bad.pieces = [.init(end: 4, logprob: -0.1)]
                $0.conversations[0].messages[0].transcriptEvidence = bad
            }, "evidence that stops short of the end")
        refused(
            {
                var bad = self.evidence("I go home.")
                bad.pieces = [.init(end: 10, logprob: .nan)]
                $0.conversations[0].messages[0].transcriptEvidence = bad
            }, "non-finite log probability")
        refused(
            {
                var bad = self.evidence("I go home.")
                bad.pieces = [.init(end: 10, logprob: 0.5)]
                $0.conversations[0].messages[0].transcriptEvidence = bad
            }, "positive log probability")
    }
}

/// Transcript evidence is built from the transcriber's tokens only when they cover the transcript exactly.
final class TranscriptEvidenceTests: XCTestCase {
    private func tokens(_ parts: [String], _ logprob: Double = -0.2) -> [(bytes: [UInt8], logprob: Double)] {
        parts.map { (Array($0.utf8), logprob) }
    }

    func testTokensCoveringTheTextGiveOnePiecePerToken() throws {
        let evidence = try XCTUnwrap(
            TranscriptEvidence(text: "I go home.", raw: "I go home.", tokens: tokens(["I", " go", " home", "."])))
        XCTAssertEqual(evidence.pieces.map(\.end), [1, 4, 9, 10])
        XCTAssertTrue(evidence.isValid)
    }
    func testSurroundingWhitespaceTrimmedFromTheTextIsClippedAway() throws {
        let evidence = try XCTUnwrap(
            TranscriptEvidence(text: "Hi there", raw: " Hi there\n", tokens: tokens([" Hi", " there", "\n"])))
        XCTAssertEqual(evidence.pieces.map(\.end), [2, 8])
    }
    func testACharacterSplitAcrossTokensStillAligns() throws {
        // "é" is two UTF-8 bytes; the transcriber may send them in two tokens.
        let bytes = Array("Café".utf8)
        let split: [(bytes: [UInt8], logprob: Double)] = [(Array(bytes[0..<4]), -0.1), (Array(bytes[4...]), -0.9)]
        let evidence = try XCTUnwrap(TranscriptEvidence(text: "Café", raw: "Café", tokens: split))
        XCTAssertEqual(evidence.pieces.map(\.end), [4, 5])
        XCTAssertEqual(evidence.pieces.last?.logprob, -0.9)
    }
    func testTokensThatDoNotSpellTheTranscriptGiveNoEvidence() {
        XCTAssertNil(TranscriptEvidence(text: "I go home.", raw: "I go home.", tokens: tokens(["I", " go"])))
        XCTAssertNil(TranscriptEvidence(text: "I go home.", raw: "I go home.", tokens: []))
        XCTAssertNil(TranscriptEvidence(text: "I went.", raw: "I go home.", tokens: tokens(["I go home."])))
        XCTAssertNil(TranscriptEvidence(text: "", raw: "", tokens: []))
    }
    func testImpossibleProbabilitiesOrTooManyTokensGiveNoEvidence() {
        XCTAssertNil(TranscriptEvidence(text: "Hi", raw: "Hi", tokens: tokens(["Hi"], .infinity)))
        XCTAssertNil(TranscriptEvidence(text: "Hi", raw: "Hi", tokens: tokens(["Hi"], 0.3)))
        let many = String(repeating: "a", count: TranscriptEvidence.maximumPieces + 1)
        XCTAssertNil(TranscriptEvidence(text: many, raw: many, tokens: tokens(many.map(String.init))))
    }
}
