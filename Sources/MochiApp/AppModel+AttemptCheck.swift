import Foundation
import MochiCore
import MochiKernel
import MochiProviders

/// Which words of the practice sentence the latest attempt got across, from on-device recognition.
extension AppModel {
    /// Checks a recorded attempt against the sentence. It never throws: a failed check leaves the attempt saved and
    /// says so in the word check instead.
    func checkAttempt(_ file: String, of item: PracticeExpression, job: ExclusiveJob) async {
        let language = item.language ?? .english
        let availability = await recognition.availability(language)
        guard job.isCurrent() else { return }
        switch availability {
        case .needsDownload:
            help.attemptCheck = .needsDownload
            return
        case .unavailable(let reason):
            help.attemptCheck = .unavailable(reason)
            return
        case .ready: break
        }
        do {
            let words = try await recognition.recognize(store.root.appendingPathComponent(file), language)
            guard job.isCurrent() else { return }
            help.attemptCheck = .checked(AttemptCheck(target: item.english, recognized: words))
        } catch {
            guard job.isCurrent() else { return }
            MochiLog.failure(MochiLog.audio, "Check practice attempt", error)
            help.attemptCheck = .failed
        }
    }
    /// Downloads Apple's speech model after the learner chose to, then checks the latest attempt.
    func downloadSpeechModel() {
        guard let item = help.expression, let file = item.attempts.last?.file else { return }
        runExclusive("Download speech model", progress: "Downloading Apple’s speech model…") { [weak self] job in
            guard let self else { return }
            try await recognition.download(item.language ?? .english)
            guard job.isCurrent() else { return }
            await checkAttempt(file, of: item, job: job)
        }
    }
}
