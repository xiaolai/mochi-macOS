import AVFoundation
import Foundation
import MochiCore
import MochiKernel
import Speech

/// Apple's on-device speech recognition (SpeechTranscriber, macOS 26 and later), used to check which words of a
/// practice sentence were caught. Only English is offered: the confidence cutoff in `AttemptCheck` was measured on
/// en-US recognition of learners reading English, and no other language has been measured.
public enum WordRecognition {
    public enum Availability: Equatable, Sendable {
        case ready
        /// Apple's speech model for the language is not on this Mac; it downloads only when the learner agrees.
        case needsDownload
        case unavailable(Reason)
    }
    public enum Reason: Equatable, Sendable {
        case olderMacOS
        case language
        case recognizer
    }
    /// The locale measured in plan E5.
    static let localeIdentifier = "en-US"

    public static func availability(for language: ConversationLanguage) async -> Availability {
        guard language == .english else { return .unavailable(.language) }
        guard #available(macOS 26, *) else { return .unavailable(.olderMacOS) }
        return await AppleRecognizer.availability()
    }
    /// Downloads and installs Apple's speech model for the language. Call only after the learner agreed.
    public static func download(for language: ConversationLanguage) async throws {
        guard language == .english, #available(macOS 26, *) else { throw unavailable }
        try await AppleRecognizer.download()
    }
    /// The words recognized in a recording, without any hint of what was meant to be said.
    public static func recognize(_ url: URL, language: ConversationLanguage) async throws -> [RecognizedWord] {
        guard language == .english, #available(macOS 26, *) else { throw unavailable }
        return try await AppleRecognizer.recognize(url)
    }
    private static var unavailable: AppFailure { AppFailure("Speech recognition is not available for this sentence.") }
}

@available(macOS 26, *)
private enum AppleRecognizer {
    /// Exactly the configuration measured in E5.
    static func transcriber() -> SpeechTranscriber {
        SpeechTranscriber(
            locale: Locale(identifier: WordRecognition.localeIdentifier), transcriptionOptions: [],
            reportingOptions: [], attributeOptions: [.audioTimeRange, .transcriptionConfidence])
    }
    /// Whether the model still has to be downloaded. `AssetInventory.status` is not used: until an installation
    /// request has been made in the process, it reports an installed model as merely supported.
    static func needsDownload() async throws -> Bool {
        try await AssetInventory.assetInstallationRequest(supporting: [transcriber()]) != nil
    }
    /// Without its model the recognizer returns no words rather than an error, which would read as silence.
    static func requireInstalled() async throws {
        if try await needsDownload() { throw AppFailure("Apple’s speech model is not installed on this Mac.") }
    }
    static func availability() async -> WordRecognition.Availability {
        guard SpeechTranscriber.isAvailable else { return .unavailable(.recognizer) }
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier(.bcp47) == WordRecognition.localeIdentifier }) else {
            return .unavailable(.language)
        }
        do {
            return try await needsDownload() ? .needsDownload : .ready
        } catch {
            MochiLog.failure(MochiLog.audio, "Check the speech model", error)
            return .unavailable(.recognizer)
        }
    }
    static func download() async throws {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber()]) {
            try await request.downloadAndInstall()
        }
        try await requireInstalled()
    }
    static func recognize(_ url: URL) async throws -> [RecognizedWord] {
        try await requireInstalled()
        let transcriber = transcriber()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: url)
        return try await withTaskCancellationHandler {
            async let words = collect(transcriber)
            do {
                try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
            } catch {
                await analyzer.cancelAndFinishNow()
                throw error
            }
            return try await words
        } onCancel: {
            Task { await analyzer.cancelAndFinishNow() }
        }
    }
    /// One word per whitespace-separated piece of each final result. A piece without a confidence counts as 0, as it
    /// did in the measurement, so it shows as uncertain rather than as heard.
    private static func collect(_ transcriber: SpeechTranscriber) async throws -> [RecognizedWord] {
        var words: [RecognizedWord] = []
        for try await result in transcriber.results where result.isFinal {
            for run in result.text.runs {
                let piece = String(result.text[run.range].characters)
                let confidence = run.transcriptionConfidence ?? 0
                words += piece.split(whereSeparator: \.isWhitespace).map {
                    RecognizedWord(text: String($0), confidence: confidence)
                }
            }
        }
        return words
    }
}
