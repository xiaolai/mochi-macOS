import Darwin
import Foundation
import MochiKernel

/// Marks a library that failed validation while still in memory: a programming error, never user data.
public struct LibraryInvariantViolation: Error { public let reason: String }
public final class LibraryStore {
    public let root: URL
    public var file: URL { root.appendingPathComponent("library.json") }
    /// The last library this store replaced, kept as a hard link so it costs no copy.
    public var previousFile: URL { root.appendingPathComponent("library.previous.json") }
    public static let reservedNames: Set<String> = [
        "library.json", "library.previous.json", "library-v1-backup.json", "library-before-help-transcription.json",
        "library-before-conversation-instructions.json",
    ]
    /// Names the copies of a version-3 library kept before its first version-4 save.
    public static let characterLibraryBackupPrefix = "library-before-character-library-v4"
    /// Names the copies of a version-4 library kept before its first version-5 save.
    public static let reviewLibraryBackupPrefix = "library-before-review-v5"
    private struct FileIdentity: Equatable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modified: timespec
        static func == (a: Self, b: Self) -> Bool {
            a.device == b.device && a.inode == b.inode && a.size == b.size && a.modified.tv_sec == b.modified.tv_sec
                && a.modified.tv_nsec == b.modified.tv_nsec
        }
    }
    /// State of the file this store last read or wrote. While the file on disk still matches it,
    /// saving needs no re-read: migration backups were settled when it was first written.
    private struct Known {
        let identity: FileIdentity
        let version: Int
        var instructionsBackup: Bool
        var featureBackup: Bool
    }
    private var known: Known?
    /// The recordings the earlier copy names, read once per version of that file.
    private var previousAudio: (identity: FileIdentity, names: Set<String>)?
    public init(root: URL) { self.root = root }
    public func prepare() throws {
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    private func identity(_ url: URL) -> FileIdentity? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return FileIdentity(device: info.st_dev, inode: info.st_ino, size: info.st_size, modified: info.st_mtimespec)
    }
    private func remember(_ identity: FileIdentity?, version: Int) {
        guard let identity else {
            known = nil
            return
        }
        known = Known(
            identity: identity, version: version,
            instructionsBackup: FileManager.default.fileExists(
                atPath: root.appendingPathComponent("library-before-conversation-instructions.json").path),
            featureBackup: FileManager.default.fileExists(
                atPath: root.appendingPathComponent("library-before-help-transcription.json").path))
    }
    public func load() throws -> Library {
        guard FileManager.default.fileExists(atPath: file.path) else {
            known = nil
            return Library()
        }
        let before = identity(file)
        let data = try Data(contentsOf: file)
        var library = try JSONDecoder().decode(Library.self, from: data)
        guard (1...Library.currentVersion).contains(library.version) else {
            throw AppFailure(
                "This library was created by a newer version of Mochi. Update Mochi to open it; your data has not been changed."
            )
        }
        try library.validate()
        remember(before == identity(file) ? before : nil, version: library.version)
        library.interruptPendingTranscriptions()
        library.version = Library.currentVersion
        return library
    }
    /// Loads the copy kept before the most recent save, for recovery when `library.json` is unreadable.
    public func loadPrevious() throws -> Library { try readPrevious().library }
    /// The earlier copy as it is stored, and as Mochi opens it.
    private func readPrevious() throws -> (original: Data, storedVersion: Int, library: Library) {
        guard identity(previousFile) != nil else { throw AppFailure("No earlier copy of the library is available.") }
        let original = try Data(contentsOf: previousFile)
        var library = try JSONDecoder().decode(Library.self, from: original)
        guard (1...Library.currentVersion).contains(library.version) else {
            throw AppFailure("The earlier copy was created by a newer version of Mochi.")
        }
        try library.validate()
        let storedVersion = library.version
        library.interruptPendingTranscriptions()
        library.version = Library.currentVersion
        return (original, storedVersion, library)
    }
    /// Recordings the earlier copy names. Restore Earlier Copy can reinstate them, so none may be removed while named here.
    /// An unreadable earlier copy cannot be restored and protects nothing.
    public func previousReferencedAudio() -> Set<String> {
        guard let current = identity(previousFile) else {
            previousAudio = nil
            return []
        }
        if let previousAudio, previousAudio.identity == current { return previousAudio.names }
        let names = (try? loadPrevious())?.referencedAudio ?? []
        previousAudio = (current, names)
        return names
    }
    /// Keeps an unreadable library under a second name (never deleting it) and atomically reinstates the earlier copy,
    /// so `library.json` always names one of the two.
    public func restorePrevious() throws -> Library {
        let (original, storedVersion, library) = try readPrevious()
        // The earlier copy is about to become the library, so its own bytes get the backups any upgrade keeps.
        // Without them, the next save would replace `library.previous.json` and lose an older format's bytes.
        try keepMigrationBackups(
            of: original, version: storedVersion, usesHelpOrTranscription: library.usesHelpOrTranscription)
        var aside: URL?
        if FileManager.default.fileExists(atPath: file.path) {
            let url = root.appendingPathComponent(
                "library-unreadable-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString).json")
            guard Darwin.link(file.path, url.path) == 0 else {
                throw AppFailure(
                    "The unreadable library could not be set aside, so nothing was restored.",
                    underlying: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
            }
            aside = url
        }
        known = nil
        do { try write(library, replacingUnreadable: true) } catch {
            // `library.json` still names the unreadable file, so the extra name is not needed.
            if let aside { unlink(aside.path) }
            throw error
        }
        return library
    }
    /// Folders of hard links that keep an export's recordings; one left by a force quit is removed at cleanup.
    public static let exportStagingPrefix = ".export-"
    /// How long an unreferenced generated example or preview stays cached after its last use.
    public static let cacheLifetime: TimeInterval = 7 * 24 * 3600
    /// Removes audio Mochi created that nothing references: abandoned recordings and replies at once,
    /// generated examples, previews and replaced imports once unused for `cacheLifetime`. Other files are never touched.
    public func cleanupOrphanedAudio(_ library: Library, now: Date = Date()) throws {
        try library.validate()
        let referenced = library.referencedAudio.union(previousReferencedAudio())
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .contentModificationDateKey,
        ]
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys)) {
            let name = url.lastPathComponent
            if name.hasPrefix(Self.exportStagingPrefix) {
                let values = try url.resourceValues(forKeys: keys)
                if values.isDirectory == true, values.isSymbolicLink != true {
                    try FileManager.default.removeItem(at: url)
                }
                continue
            }
            guard !referenced.contains(name), let kind = Self.generatedAudio(name) else { continue }
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            if kind == .cache, now.timeIntervalSince(values.contentModificationDate ?? now) < Self.cacheLifetime {
                continue
            }
            try FileManager.default.removeItem(at: url)
        }
    }
    enum GeneratedAudio { case session, cache }
    /// Classifies names Mochi itself generates; anything else is not Mochi's to delete.
    static func generatedAudio(_ name: String) -> GeneratedAudio? {
        let url = URL(fileURLWithPath: name)
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        func suffix(after prefix: String) -> String? {
            stem.hasPrefix(prefix) ? String(stem.dropFirst(prefix.count)) : nil
        }
        if ext == "wav", let id = suffix(after: "recording-") ?? suffix(after: "reply-"), UUID(uuidString: id) != nil {
            return .session
        }
        if let id = suffix(after: "import-"), UUID(uuidString: id) != nil, !ext.isEmpty { return .cache }
        for (prefix, expected) in [("builtin-", "wav"), ("elevenlabs-", "mp3")] {
            if ext == expected, let hash = suffix(after: prefix), hash.count == 64, hash.allSatisfy(\.isHexDigit) {
                return .cache
            }
        }
        return nil
    }
    public func save(_ library: Library) throws { try write(library, replacingUnreadable: false) }
    /// `replacingUnreadable` installs over a file already kept elsewhere: it is neither read nor kept as the earlier copy.
    private func write(_ library: Library, replacingUnreadable: Bool) throws {
        try prepare()
        guard (1...Library.currentVersion).contains(library.version) else {
            throw AppFailure("Unsupported library version.")
        }
        do { try library.validate() } catch {
            throw AppFailure(
                "Mochi found an inconsistency in your library and did not save it. Your saved library is unchanged.",
                underlying: LibraryInvariantViolation(
                    reason: (error as? AppFailure)?.message ?? String(describing: error)))
        }
        var library = library
        library.version = Library.currentVersion
        let usesHelpOrTranscription = library.usesHelpOrTranscription
        let current = replacingUnreadable ? nil : identity(file)
        let settled =
            known.map {
                $0.identity == current && $0.version == Library.currentVersion && $0.instructionsBackup
                    && ($0.featureBackup || !usesHelpOrTranscription)
            } ?? false
        if current != nil && !settled { try settleMigrationBackups(usesHelpOrTranscription: usesHelpOrTranscription) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(library)
        let staging = root.appendingPathComponent(".library-write-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: staging) }
        try writeDurably(data, to: staging)
        if current != nil { keepPrevious() }
        guard Darwin.rename(staging.path, file.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        remember(identity(file), version: Library.currentVersion)
    }
    /// Re-reads a library that Mochi has not written itself and preserves pre-upgrade copies before replacing it.
    private func settleMigrationBackups(usesHelpOrTranscription: Bool) throws {
        let original = try Data(contentsOf: file)
        let existing: Library
        do { existing = try JSONDecoder().decode(Library.self, from: original) } catch {
            throw AppFailure(
                "The library file was changed outside Mochi and cannot be read, so Mochi did not overwrite it.",
                underlying: error)
        }
        guard (1...Library.currentVersion).contains(existing.version) else {
            throw AppFailure(
                "The library file on disk was written by a newer version of Mochi, so Mochi did not overwrite it.")
        }
        try keepMigrationBackups(
            of: original, version: existing.version, usesHelpOrTranscription: usesHelpOrTranscription)
    }
    /// Keeps the bytes of a library written in `version` before Mochi replaces it. Each format upgrade keeps the
    /// bytes from just before it under its own name, so its thresholds are historical and never move.
    private func keepMigrationBackups(of original: Data, version: Int, usesHelpOrTranscription: Bool) throws {
        if version < 3 { try keepUpgradeBackup(original, named: "library-before-character-templates-v3") }
        if version == 3 { try keepUpgradeBackup(original, named: Self.characterLibraryBackupPrefix) }
        if version == 4 { try keepUpgradeBackup(original, named: Self.reviewLibraryBackupPrefix) }
        let instructionsBackup = root.appendingPathComponent("library-before-conversation-instructions.json")
        if !FileManager.default.fileExists(atPath: instructionsBackup.path) {
            try writeNewPrivateFile(original, to: instructionsBackup)
        }
        let featureBackup = root.appendingPathComponent("library-before-help-transcription.json")
        if usesHelpOrTranscription, !FileManager.default.fileExists(atPath: featureBackup.path) {
            try writeNewPrivateFile(original, to: featureBackup)
        }
        let backup = root.appendingPathComponent("library-v1-backup.json")
        if version == 1 && !FileManager.default.fileExists(atPath: backup.path) {
            try writeNewPrivateFile(original, to: backup)
        }
    }
    /// `name.json` holds the first such copy; a later, different one gets a unique sibling, so none is replaced.
    private func keepUpgradeBackup(_ original: Data, named name: String) throws {
        let base = root.appendingPathComponent("\(name).json")
        let backupExists = FileManager.default.fileExists(atPath: base.path)
        if backupExists, try Data(contentsOf: base) == original { return }
        let destination =
            backupExists
            ? root.appendingPathComponent("\(name)-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString).json")
            : base
        try writeNewPrivateFile(original, to: destination)
    }
    /// Keeps the file about to be replaced as `library.previous.json`. Losing this copy never blocks a save.
    private func keepPrevious() {
        let staging = root.appendingPathComponent(".library-previous-\(UUID().uuidString).json")
        guard Darwin.link(file.path, staging.path) == 0 else {
            MochiLog.failure(
                MochiLog.library, "Keep previous library", POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO),
                level: .info)
            return
        }
        if Darwin.rename(staging.path, previousFile.path) != 0 {
            MochiLog.failure(
                MochiLog.library, "Replace previous library", POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO),
                level: .info)
            unlink(staging.path)
        }
    }
    /// The data reaches stable storage before the rename, so `library.json` is never a name for incomplete bytes.
    private func writeDurably(_ data: Data, to destination: URL) throws {
        let descriptor = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        if fcntl(descriptor, F_FULLFSYNC) != 0 { try handle.synchronize() }
        try handle.close()
    }
    /// Creates a complete 0600 copy that never replaces an existing file, so a failed write cannot leave a partial or briefly readable backup under the final name.
    private func writeNewPrivateFile(_ data: Data, to destination: URL) throws {
        let staging = root.appendingPathComponent(".backup-write-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: staging) }
        try writeDurably(data, to: staging)
        guard renamex_np(staging.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
