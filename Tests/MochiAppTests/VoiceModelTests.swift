import XCTest
import MochiCore
@testable import MochiApp
final class VoiceModelTests: XCTestCase {
    @MainActor func testSelectingVoiceDoesNotRelabelSavedReference() {
        let app = AppModel(demo:true)
        app.startHelp(); app.editEnglish("A sentence"); app.ensureExpression()
        app.expression?.referenceKind = "Marin · Saved voice"
        app.builtInPracticeVoice = "cedar"
        XCTAssertEqual(app.expression?.referenceKind,"Marin · Saved voice")
    }
    @MainActor func testVoiceOptionsPersistAndRejectInvalidPreferences() throws {
        let suite = "mochi-options-test-\(UUID())", root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let prefs = UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite); try? FileManager.default.removeItem(at:root) }
        let app = AppModel(libraryRoot:root,preferences:prefs)
        app.conversationVoiceOptions.speed = 1.2; app.practiceVoiceOptions.speed = 0.8
        let loaded = AppModel(libraryRoot:root,preferences:prefs)
        XCTAssertEqual(loaded.conversationVoiceOptions.speed,1.2); XCTAssertEqual(loaded.practiceVoiceOptions.speed,0.8)
        prefs.set(Data("{\"speed\":9}".utf8),forKey:"practiceVoiceOptions")
        XCTAssertEqual(AppModel(libraryRoot:root,preferences:prefs).practiceVoiceOptions.speed,1)
    }
}
