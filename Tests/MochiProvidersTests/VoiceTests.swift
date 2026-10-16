import MochiKernel
import MochiTestSupport
import SaidGuard
import XCTest

@testable import MochiCore
@testable import MochiProviders

final class VoiceTests: XCTestCase {
    func testCatalogAndExactSentence() {
        XCTAssertEqual(RealtimeVoice.allCases.count, 10)
        XCTAssertTrue(ReferenceSpeech.matches("I'm ready to start.", "I’m ready to start!", language: "en"))
        XCTAssertFalse(ReferenceSpeech.matches("I worked slowly.", "My progress was slow.", language: "en"))
        XCTAssertFalse(ReferenceSpeech.matches("one thing", "one thing. Let us begin.", language: "en"))
        XCTAssertFalse(ReferenceSpeech.matches("We'll start.", "Well start.", language: "en"))
    }
    /// The said guard reads a script with its own language's rules: in French `3` is `trois`, so a reading of it as
    /// `three` is another sentence, and `1/2` is not `1 2` in any language.
    func testReadingsAreCheckedWithTheTextsOwnLanguage() {
        XCTAssertTrue(ReferenceSpeech.matches("J'ai 3 chats.", "J'ai trois chats.", language: "fr"))
        XCTAssertFalse(ReferenceSpeech.matches("J'ai 3 chats.", "J'ai three chats.", language: "fr"))
        XCTAssertTrue(ReferenceSpeech.matches("I have 3 cats.", "I have three cats.", language: "en"))
        XCTAssertFalse(ReferenceSpeech.matches("Take 1/2 a cup.", "Take 1 2 a cup.", language: "en"))
        XCTAssertFalse(ReferenceSpeech.matches("We'll start.", "Well start.", language: "fr"))
    }
    /// A cache hit plays without a check, so audio accepted under one language's rules is never reused for another,
    /// and the said guard's version is part of the key.
    func testReferenceCacheSeparatesLanguagesAndKeysOnTheSaidGuard() {
        let english = ReferenceSpeech.cacheName(text: "J'ai 3 chats.", language: "en", model: "m", voice: "marin")
        XCTAssertNotEqual(
            english, ReferenceSpeech.cacheName(text: "J'ai 3 chats.", language: "fr", model: "m", voice: "marin"))
        XCTAssertNotEqual(
            ReferenceSpeech.cacheName(text: "Hello", language: "en", model: "m", voice: "marin"),
            ReferenceSpeech.cacheName(
                text: "Hello", language: "en", model: "m", voice: "marin", saidGuard: saidGuardVersion - 1))
    }
    func testReferenceCacheSeparatesModelAndVoice() {
        let a = ReferenceSpeech.cacheName(text: "Hello", language: "en", model: "gpt-realtime", voice: "marin")
        XCTAssertNotEqual(
            a, ReferenceSpeech.cacheName(text: "Hello", language: "en", model: "gpt-realtime", voice: "cedar"))
        XCTAssertNotEqual(
            a, ReferenceSpeech.cacheName(text: "Hello", language: "en", model: "other-model", voice: "marin"))
        XCTAssertFalse(ReferenceSpeech.matches("   ", "", language: "en"))
    }
}

extension VoiceTests {
    func testReferenceCacheSeparatesVoiceAndSpeed() {
        let a = ReferenceSpeech.cacheName(text: "Hello", language: "en", model: "gpt-realtime", voice: "marin")
        let b = ReferenceSpeech.cacheName(text: "Hello", language: "en", model: "gpt-realtime", voice: "cedar")
        XCTAssertNotEqual(a, b)
        var options = OpenAIVoiceOptions()
        options.speed = 0.8
        XCTAssertNotEqual(
            a,
            ReferenceSpeech.cacheName(
                text: "Hello", language: "en", model: "gpt-realtime", voice: "marin", options: options))
    }

    func testCanonicallyEquivalentTextMatches() {
        XCTAssertTrue(
            ReferenceSpeech.matches(
                "Un café, s'il vous plaît.", "Un cafe\u{0301}, s'il vous plai\u{0302}t!", language: "fr"))
        XCTAssertFalse(ReferenceSpeech.matches("café", "cafe", language: "fr"))
    }

    func testNonFiniteSpeedStillNamesTheCacheWithoutCrashing() {
        var nan = OpenAIVoiceOptions()
        nan.speed = .nan
        var infinite = OpenAIVoiceOptions()
        infinite.speed = .infinity
        let a = ReferenceSpeech.cacheName(text: "Hi", language: "en", model: "m", voice: "marin", options: nan)
        let b = ReferenceSpeech.cacheName(text: "Hi", language: "en", model: "m", voice: "marin", options: infinite)
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, ReferenceSpeech.cacheName(text: "Hi", language: "en", model: "m", voice: "marin"))
    }

    func testTruncatedReferenceAudioIsNotCached() async throws {
        let root = TestScratch.folder("g2-reference")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var result = RealtimeAccumulator()
        result.text = "Hello there."
        result.audio = Data(repeating: 1, count: 4800)
        result.truncated = true
        let cut = result
        do {
            _ = try await RealtimeService().referenceAudio(
                text: "Hello there.", language: "en", root: root, force: true
            ) { _ in cut }
            XCTFail("A truncated example was accepted")
        } catch {
            XCTAssertTrue(error is AppFailure)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testCachedExampleIsReusedWithoutAReply() async throws {
        let root = TestScratch.folder("mochi-cache")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = RealtimeService()
        let cached = root.appendingPathComponent(
            ReferenceSpeech.cacheName(text: "Hello.", language: "en", model: service.model, voice: service.voice))
        try Data([1]).write(to: cached)
        let url = try await service.referenceAudio(text: "Hello.", language: "en", root: root, force: false) { _ in
            XCTFail("A cached example must not be regenerated")
            throw AppFailure("no")
        }
        XCTAssertEqual(url, cached)
        var replied = false
        _ = try? await service.referenceAudio(text: "Hello.", language: "en", root: root, force: true) { _ in
            replied = true
            throw AppFailure("offline")
        }
        XCTAssertTrue(replied)
    }

    func testUsingACachedExampleKeepsItFromCleanup() async throws {
        let root = try folder()
        let service = RealtimeService()
        let cached = root.appendingPathComponent(
            ReferenceSpeech.cacheName(text: "Hi.", language: "en", model: service.model, voice: service.voice))
        try Data([1]).write(to: cached)
        try age(cached, days: 8)
        _ = try await service.referenceAudio(text: "Hi.", language: "en", root: root, force: false) { _ in
            throw AppFailure("must not regenerate")
        }
        try LibraryStore(root: root).cleanupOrphanedAudio(Library())
        XCTAssertTrue(FileManager.default.fileExists(atPath: cached.path))
    }

    private func write(_ text: String, to home: URL) throws {
        try Data(text.utf8).write(to: home.appendingPathComponent(".codex/auth.json"))
    }

    private func home() throws -> URL {
        let url = TestScratch.folder("mochi-home")
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func folder() throws -> URL {
        let url = TestScratch.folder("mochi-files")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func age(_ url: URL, days: Double) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -days * 86400)], ofItemAtPath: url.path)
    }
}
