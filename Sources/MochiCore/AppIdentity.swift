import Foundation
import Darwin

public enum AppIdentity {
    public static let name = "Mochi"
    public static let bundleIdentifier = "com.xiaolai.mochi-macos"
    public static let legacyBundleIdentifier = "com.xiaolai.enjoy-myself"
    public static let legacyDataDirectory = "Enjoy Myself"
    public static let backupType = "com.xiaolai.mochi-macos.library"

    /// Copy first, then atomically install the directory; leave original data intact.
    public static func prepareDataDirectory(in support: URL) throws -> URL {
        let destination = support.appendingPathComponent(name)
        let legacy = support.appendingPathComponent(legacyDataDirectory)
        let fm = FileManager.default
        if fm.fileExists(atPath:destination.path) {
            try validateDirectory(destination)
            if fm.fileExists(atPath:destination.appendingPathComponent("library.json").path) { return destination }
            guard try fm.contentsOfDirectory(atPath:destination.path).isEmpty else { throw AppFailure("The Mochi folder contains other data; it has not been changed.") }
        }
        guard fm.fileExists(atPath:legacy.path) else { return destination }
        try validateDirectory(legacy)
        _ = try LibraryStore(root:legacy).load() // Corrupt/future data stays untouched.
        let staging = support.appendingPathComponent(".mochi-migration-\(UUID().uuidString)")
        defer { try? fm.removeItem(at:staging) }
        try fm.copyItem(at:legacy,to:staging)
        try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:staging.path)
        if fm.fileExists(atPath:destination.path) {
            // rmdir only succeeds for an empty directory; never recursively erase a destination.
            guard Darwin.rmdir(destination.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
        }
        try fm.moveItem(at:staging,to:destination)
        return destination
    }
    public static func migratePreferences(into defaults: UserDefaults, legacy: [String:Any]) {
        for key in ["auth","model","clone","performer"] where defaults.object(forKey:key) == nil {
            if let value = legacy[key] as? String { defaults.set(value,forKey:key) }
        }
    }
    private static func validateDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw AppFailure("The saved library folder is not a regular directory.") }
    }
}
