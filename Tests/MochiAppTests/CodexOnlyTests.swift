import XCTest
import MochiCore
@testable import MochiApp
final class CodexOnlyTests: XCTestCase {
    @MainActor func testLegacyProviderPreferencesCannotSelectPaidProviders() throws {
        let suite = "mochi-codex-only-\(UUID())", prefs = UserDefaults(suiteName:suite)!
        let root = URL(fileURLWithPath:"/tmp/mochi-codex-only-\(UUID())")
        defer { prefs.removePersistentDomain(forName:suite); try? FileManager.default.removeItem(at:root) }
        prefs.set("api",forKey:"auth"); prefs.set("personal",forKey:"practiceVoiceMode"); prefs.set("old-clone",forKey:"clone")
        let legacyProfiles = Data("legacy profile bytes".utf8); prefs.set(legacyProfiles,forKey:"voiceProfiles")
        let app = AppModel(libraryRoot:root,preferences:prefs)
        XCTAssertEqual(app.auth,"codex"); XCTAssertEqual(app.builtInPracticeVoice,"marin")
        XCTAssertEqual(prefs.data(forKey:"voiceProfiles"),legacyProfiles); XCTAssertEqual(prefs.string(forKey:"clone"),"old-clone")
        XCTAssertFalse(app.busy); XCTAssertNil(app.error)
    }
    @MainActor func testLegacyReferenceAudioAndLabelSurviveVoiceChangeAndRelaunch() throws {
        let suite = "mochi-retained-voice-\(UUID())", prefs = UserDefaults(suiteName:suite)!
        let root = URL(fileURLWithPath:"/tmp/mochi-retained-\(UUID())")
        defer { prefs.removePersistentDomain(forName:suite); try? FileManager.default.removeItem(at:root) }
        let app = AppModel(libraryRoot:root,preferences:prefs)
        var item = PracticeExpression(conversationID:app.selectedID!,meaning:"",english:"Hello")
        item.reference = "reference-old.mp3"; item.referenceKind = "My Voice · Legacy"
        app.library.expressions = [item]; try Data([1,2,3]).write(to:root.appendingPathComponent(item.reference!)); try app.store.save(app.library)
        app.builtInPracticeVoice = "cedar"
        let loaded = AppModel(libraryRoot:root,preferences:prefs)
        XCTAssertEqual(loaded.library.expressions[0].referenceKind,item.referenceKind)
        XCTAssertEqual(loaded.library.expressions[0].reference,item.reference)
        XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent(item.reference!).path))
        XCTAssertEqual(loaded.builtInPracticeVoice,"cedar")
    }
}
