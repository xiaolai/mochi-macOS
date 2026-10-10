import XCTest
@testable import MochiCore
final class BrandingTests: XCTestCase {
    func testPreviousMochiPreferencesSurviveIdentityChangeWithoutOverwritingNewValues() {
        let name = "mochi-identity-test-\(UUID())"
        let defaults = UserDefaults(suiteName:name)!
        defer { defaults.removePersistentDomain(forName:name) }
        defaults.set("cedar",forKey:"conversationVoice")
        let profile = Data("saved-profile".utf8)
        AppIdentity.migratePreferences(into:defaults,legacy:[
            "conversationVoice":"marin", "practiceVoiceMode":"personal",
            "voiceProfiles":profile, "personalVoiceOptions":Data([1,2]),
            "voiceGreetingHistory":["Hello", "Hi"], "unknown":"ignore"
        ])
        AppIdentity.migratePreferences(into:defaults,legacy:["practiceVoiceMode":"builtIn"])
        XCTAssertEqual(defaults.string(forKey:"conversationVoice"),"cedar")
        XCTAssertEqual(defaults.string(forKey:"practiceVoiceMode"),"personal")
        XCTAssertEqual(defaults.data(forKey:"voiceProfiles"),profile)
        XCTAssertEqual(defaults.data(forKey:"personalVoiceOptions"),Data([1,2]))
        XCTAssertEqual(defaults.stringArray(forKey:"voiceGreetingHistory"),["Hello", "Hi"])
        XCTAssertNil(defaults.object(forKey:"unknown"))
    }

    func testLibraryCopyPreservesOriginalAndDoesNotOverwriteMochi() throws {
        let parent = temporary(); defer { try? FileManager.default.removeItem(at:parent) }
        let legacy = parent.appendingPathComponent(AppIdentity.legacyDataDirectory)
        let store = LibraryStore(root:legacy)
        var library = Library(); library.conversations = [Conversation(title:"Existing chat")]
        try store.save(library)
        let original = try Data(contentsOf:store.file)
        try Data([1,2]).write(to:legacy.appendingPathComponent("recording.wav"))
        let migrated = try AppIdentity.prepareDataDirectory(in:parent)
        XCTAssertEqual(migrated.lastPathComponent,"Mochi")
        XCTAssertEqual(try Data(contentsOf:migrated.appendingPathComponent("library.json")),original)
        XCTAssertEqual(try Data(contentsOf:migrated.appendingPathComponent("recording.wav")),Data([1,2]))
        XCTAssertEqual(try Data(contentsOf:store.file),original)
        var changed = try LibraryStore(root:migrated).load(); changed.conversations[0].title = "New local title"
        try LibraryStore(root:migrated).save(changed)
        _ = try AppIdentity.prepareDataDirectory(in:parent)
        XCTAssertEqual(try LibraryStore(root:migrated).load().conversations[0].title,"New local title")
    }
    func testPreferencesOnlyCopyKnownMissingValues() {
        let name = "mochi-test-\(UUID())"
        let defaults = UserDefaults(suiteName:name)!
        defer { defaults.removePersistentDomain(forName:name) }
        defaults.set("new-model",forKey:"model")
        AppIdentity.migratePreferences(into:defaults,legacy:["model":"old-model","clone":"test-clone","auth":"api","unknown":"do not copy"])
        XCTAssertEqual(defaults.string(forKey:"model"),"new-model")
        XCTAssertEqual(defaults.string(forKey:"clone"),"test-clone")
        XCTAssertNil(defaults.object(forKey:"unknown"))
    }
    func testNewInstallAndUnsafeLegacyRoot() throws {
        let parent = temporary(), other = temporary()
        defer { for p in [parent,other] { try? FileManager.default.removeItem(at:p) } }
        let fresh = try AppIdentity.prepareDataDirectory(in:parent)
        XCTAssertEqual(fresh.lastPathComponent,"Mochi")
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:other,withIntermediateDirectories:true)
        try FileManager.default.createSymbolicLink(at:parent.appendingPathComponent(AppIdentity.legacyDataDirectory),withDestinationURL:other)
        XCTAssertThrowsError(try AppIdentity.prepareDataDirectory(in:parent))
        XCTAssertFalse(FileManager.default.fileExists(atPath:fresh.path))
    }
    func testCorruptAndFutureLegacyDataAreNotMigratedOrChanged() throws {
        for future in [false,true] {
            let parent = temporary(); defer { try? FileManager.default.removeItem(at:parent) }
            let legacy = parent.appendingPathComponent(AppIdentity.legacyDataDirectory)
            let store = LibraryStore(root:legacy); try store.prepare()
            if future { var library = Library(); library.version = 4; try JSONEncoder().encode(library).write(to:store.file) }
            else { try Data("broken".utf8).write(to:store.file) }
            let before = try Data(contentsOf:store.file)
            XCTAssertThrowsError(try AppIdentity.prepareDataDirectory(in:parent))
            XCTAssertEqual(try Data(contentsOf:store.file),before)
            XCTAssertFalse(FileManager.default.fileExists(atPath:parent.appendingPathComponent("Mochi").path))
        }
    }
    func testEmptyDestinationMigratesButUnrelatedContentsArePreserved() throws {
        let parent = temporary(); defer { try? FileManager.default.removeItem(at:parent) }
        let store = LibraryStore(root:parent.appendingPathComponent(AppIdentity.legacyDataDirectory))
        var library = Library(); library.conversations = [Conversation(title:"Existing")]; try store.save(library)
        let new = parent.appendingPathComponent("Mochi")
        try FileManager.default.createDirectory(at:new,withIntermediateDirectories:true)
        let migrated = try AppIdentity.prepareDataDirectory(in:parent)
        XCTAssertEqual(try LibraryStore(root:migrated).load().conversations[0].title,"Existing")
        try FileManager.default.removeItem(at:new.appendingPathComponent("library.json"))
        try Data([1]).write(to:new.appendingPathComponent("other-data"))
        XCTAssertThrowsError(try AppIdentity.prepareDataDirectory(in:parent))
        XCTAssertTrue(FileManager.default.fileExists(atPath:new.appendingPathComponent("other-data").path))
    }
    private func temporary() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
}
