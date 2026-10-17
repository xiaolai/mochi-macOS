import Darwin
import Foundation
import MochiKernel

public enum LibraryBackup {
    /// Writes `library` and its recordings into a new package, and returns the recordings left out, sorted. One
    /// missing from `root`, or not a regular file there, is left out: refusing the whole backup over it would leave
    /// no way to make one. The library still names it, as the library itself does.
    @discardableResult public static func write(_ library: Library, from root: URL, to package: URL) throws
        -> [String]
    {
        try library.validate()
        guard !FileManager.default.fileExists(atPath: package.path) else {
            throw AppFailure("Choose a new backup filename; an existing backup is never overwritten.")
        }
        let omitted = library.referencedAudio.filter { name in
            let values = try? root.appendingPathComponent(name).resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey,
            ])
            return values?.isRegularFile != true || values?.isSymbolicLink == true
        }
        try FileManager.default.createDirectory(
            at: package.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Exclusive: a package that appeared since the check above is neither written into nor removed.
        guard mkdir(package.path, 0o700) == 0 else {
            if errno == EEXIST {
                throw AppFailure("Choose a new backup filename; an existing backup is never overwritten.")
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        do {
            let e = JSONEncoder()
            e.outputFormatting = [.prettyPrinted, .sortedKeys]
            var normalized = library
            normalized.version = Library.currentVersion
            try e.encode(normalized).write(to: package.appendingPathComponent("library.json"), options: .atomic)
            for name in library.referencedAudio.subtracting(omitted) {
                try FileManager.default.copyItem(
                    at: root.appendingPathComponent(name), to: package.appendingPathComponent(name))
            }
        } catch {
            try? FileManager.default.removeItem(at: package)
            throw error
        }
        return omitted.sorted()
    }
    public static func read(_ package: URL) throws -> Library {
        try requireRegularFile(package.appendingPathComponent("library.json")) {
            AppFailure("This backup has no library.json, so it cannot be imported.", underlying: $0)
        }
        var library = try JSONDecoder().decode(
            Library.self, from: Data(contentsOf: package.appendingPathComponent("library.json")))
        guard (1...Library.currentVersion).contains(library.version) else {
            throw AppFailure("This backup requires a newer app.")
        }
        try library.validate()
        for name in library.referencedAudio { _ = try recordingIsPresent(name, in: package) }
        library.version = Library.currentVersion
        return library
    }
    /// Items to import with their audio already copied under fresh names, ready to merge into the library as it is by then.
    public struct PreparedImport {
        public let additions: Library
        public let copied: [URL]
        /// Recordings the additions name that the backup left out, as an export does with one already missing.
        public let missing: Int
    }
    // Only missing IDs are imported; each imported audio name is remapped to avoid collisions.
    public static func merge(_ imported: Library, from package: URL, into local: inout Library, root: URL) throws -> Int
    {
        let prepared = try prepareMerge(imported, from: package, into: local, root: root)
        defer { discard(prepared, keeping: local) }
        return try apply(prepared, to: &local)
    }
    /// Adds the prepared items that are still missing. On a conflict `local` is unchanged.
    public static func apply(_ prepared: PreparedImport, to local: inout Library) throws -> Int {
        let chatIDs = Set(local.conversations.map(\.id))
        let expressionIDs = Set(local.expressions.map(\.id))
        let templateIDs = Set(local.conversationTemplates.map(\.id))
        let characterIDs = Set(local.characters.map(\.id))
        let conversations = prepared.additions.conversations.filter { !chatIDs.contains($0.id) }
        let localMessageIDs = Set(local.conversations.flatMap(\.messages).map(\.id))
        guard !conversations.flatMap(\.messages).contains(where: { localMessageIDs.contains($0.id) }) else {
            throw AppFailure("Imported message IDs conflict with local history.")
        }
        var next = local
        next.conversations += conversations
        next.expressions += prepared.additions.expressions.filter { !expressionIDs.contains($0.id) }
        next.conversationTemplates += prepared.additions.conversationTemplates.filter { !templateIDs.contains($0.id) }
        next.characters += prepared.additions.characters.filter { !characterIDs.contains($0.id) }
        next.version = Library.currentVersion
        try next.validate()
        local = next
        return conversations.count
    }
    /// Removes copied audio that `library` does not reference: all of it after an import was abandoned,
    /// and the audio of items skipped because they were added meanwhile after one was applied.
    public static func discard(_ prepared: PreparedImport, keeping library: Library) {
        let referenced = library.referencedAudio
        for url in prepared.copied where !referenced.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }
    /// Validates a backup against `local` and copies its new audio into `root`. Safe to run off the main thread.
    public static func prepareMerge(_ imported: Library, from package: URL, into local: Library, root: URL) throws
        -> PreparedImport
    {
        try imported.validate()
        for name in imported.referencedAudio { _ = try recordingIsPresent(name, in: package) }
        let chatIDs = Set(local.conversations.map(\.id))
        let expressionIDs = Set(local.expressions.map(\.id))
        var additions = Library()
        additions.conversations = imported.conversations.filter { !chatIDs.contains($0.id) }
        additions.expressions = imported.expressions.filter { !expressionIDs.contains($0.id) }
        let templateIDs = Set(local.conversationTemplates.map(\.id))
        additions.conversationTemplates = imported.conversationTemplates.filter { !templateIDs.contains($0.id) }
        let characterIDs = Set(local.characters.map(\.id))
        additions.characters = imported.characters.filter { !characterIDs.contains($0.id) }
        let localMessageIDs = Set(local.conversations.flatMap(\.messages).map(\.id))
        guard !additions.conversations.flatMap(\.messages).contains(where: { localMessageIDs.contains($0.id) }) else {
            throw AppFailure("Imported message IDs conflict with local history.")
        }
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var mapping: [String: String] = [:]
        var copied: [URL] = []
        var missing = 0
        do {
            for name in additions.referencedAudio {
                try Task.checkCancellation()
                let replacement = LibraryStore.importedAudioName(extension: URL(fileURLWithPath: name).pathExtension)
                // A recording the backup left out keeps a fresh name with no file, as it had none in the library
                // exported: the message is kept, and no local file can ever be named by it.
                if try recordingIsPresent(name, in: package) {
                    let destination = root.appendingPathComponent(replacement)
                    try FileManager.default.copyItem(at: package.appendingPathComponent(name), to: destination)
                    copied.append(destination)
                } else {
                    missing += 1
                }
                mapping[name] = replacement
            }
            try remapAudio(in: &additions) { name in
                guard let replacement = mapping[name] else {
                    throw AppFailure("A backup recording could not be matched to its copy.")
                }
                return replacement
            }
            additions.interruptPendingTranscriptions()
            return PreparedImport(additions: additions, copied: copied, missing: missing)
        } catch {
            for url in copied { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }
    /// Renames every recording `library` references.
    private static func remapAudio(in library: inout Library, _ mapped: (String) throws -> String) rethrows {
        for ci in library.conversations.indices {
            if let name = library.conversations[ci].helpDraft?.recording {
                library.conversations[ci].helpDraft?.recording = try mapped(name)
            }
            for mi in library.conversations[ci].messages.indices {
                if let name = library.conversations[ci].messages[mi].audio {
                    library.conversations[ci].messages[mi].audio = try mapped(name)
                }
            }
        }
        for i in library.expressions.indices {
            if let name = library.expressions[i].reference { library.expressions[i].reference = try mapped(name) }
            for ai in library.expressions[i].attempts.indices {
                library.expressions[i].attempts[ai].file = try mapped(library.expressions[i].attempts[ai].file)
            }
        }
    }
    /// Whether a recording a backup names is in it. It may be absent, as an export leaves out a recording its library
    /// had lost, but anything under its name must be a regular file.
    private static func recordingIsPresent(_ name: String, in folder: URL) throws -> Bool {
        var info = stat()
        if lstat(folder.appendingPathComponent(name).path, &info) != 0, errno == ENOENT { return false }
        try requireRecording(name, in: folder)
        return true
    }
    /// A recording a backup names must be a regular file in `folder`; the failure names it so it can be found.
    private static func requireRecording(_ name: String, in folder: URL) throws {
        try requireRegularFile(folder.appendingPathComponent(name)) {
            AppFailure("The recording “\(name)” is missing or is not a regular file.", underlying: $0)
        }
    }
    /// Throws `failure`, with the file system's reason when there is one, unless `url` is a regular file, not a link.
    private static func requireRegularFile(_ url: URL, _ failure: (Error?) -> AppFailure) throws {
        let values: URLResourceValues
        do { values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) } catch {
            throw failure(error)
        }
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw failure(nil) }
    }
}
