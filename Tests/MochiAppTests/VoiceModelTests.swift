import XCTest
import MochiCore
@testable import MochiApp
final class VoiceModelTests: XCTestCase {
    @MainActor func testNewUserAndLegacyModes() throws {
        let suite = "mochi-voice-test-\(UUID())"
        let prefs = UserDefaults(suiteName:suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root); prefs.removePersistentDomain(forName:suite) }
        let fresh = AppModel(libraryRoot:root,preferences:prefs)
        XCTAssertEqual(fresh.practiceVoiceMode,.builtIn)
        XCTAssertEqual(fresh.conversationVoice,"marin")
        prefs.set("legacy-clone",forKey:"clone")
        let migrated = AppModel(libraryRoot:root,preferences:prefs)
        XCTAssertEqual(migrated.practiceVoiceMode,.personal)
        XCTAssertEqual(migrated.voiceProfiles.count,1)
        XCTAssertFalse(migrated.voiceProfiles[0].createdByApp)
        XCTAssertEqual(migrated.clone,"legacy-clone")
    }
    @MainActor func testSelectingVoiceDoesNotRelabelSavedReference() {
        let app = AppModel(demo:true)
        app.startHelp(); app.editEnglish("A sentence")
        app.ensureExpression(); app.expression?.referenceKind = "Marin · Built-in voice"
        app.builtInPracticeVoice = "cedar"
        XCTAssertEqual(app.expression?.referenceKind,"Marin · Built-in voice")
        let profile = VoiceProfile(name:"My Voice",providerID:"test-clone",createdByApp:true)
        app.acceptVoiceProfile(profile)
        XCTAssertEqual(app.practiceVoiceMode,.personal)
        XCTAssertEqual(app.clone,"test-clone")
        app.removeVoiceProfile(profile)
        XCTAssertEqual(app.practiceVoiceMode,.builtIn)
        XCTAssertEqual(app.expression?.referenceKind,"Marin · Built-in voice")
    }
}

private struct VerificationAPI: VoiceAccountAPI {
    func list() async throws -> [AccountVoice] { [AccountVoice(id:"created-test",name:"Test",requiresVerification:true)] }
    func create(name: String, samples: [VoiceUpload]) async throws -> CreatedVoice { CreatedVoice(id:"created-test",requiresVerification:true) }
    func delete(id: String) async throws { throw AppFailure("Not used") }
}
final class VoiceSetupTests: XCTestCase {
    @MainActor func testConsentAndVerificationGate() async throws {
        let suite = "mochi-setup-test-\(UUID())", prefs = UserDefaults(suiteName:suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root); prefs.removePersistentDomain(forName:suite) }
        let app = AppModel(libraryRoot:root,preferences:prefs)
        let setup = VoiceSetupModel(app:app,api:VerificationAPI())
        let file = root.appendingPathComponent("input.wav")
        var pcm = Data()
        for i in 0..<1_440_000 {
            var value = Int16(sin(Double(i) * 0.05) * 12000).littleEndian
            withUnsafeBytes(of:&value) { pcm.append(contentsOf:$0) }
        }
        try PCM.wav(pcm).write(to:file)
        try setup.addSample(file)
        XCTAssertEqual(Int(setup.totalDuration),60)
        XCTAssertFalse(setup.canCreate)
        setup.consent = true
        XCTAssertTrue(setup.canCreate)
        setup.createAndCompare()
        for _ in 0..<100 where setup.busy { try await Task.sleep(nanoseconds:10_000_000) }
        XCTAssertFalse(setup.busy)
        XCTAssertTrue(try XCTUnwrap(setup.profile).requiresVerification)
        XCTAssertEqual(app.voiceProfiles.count,1)
        XCTAssertTrue(app.voiceProfiles[0].createdByApp)
        XCTAssertNil(setup.convertedAudio)
        setup.heardConverted = true; setup.accept()
        XCTAssertEqual(app.practiceVoiceMode,.builtIn)
        setup.close()
        XCTAssertTrue(FileManager.default.fileExists(atPath:setup.directory.path))
        let reopened = AppModel(libraryRoot:root,preferences:prefs)
        XCTAssertTrue(reopened.voiceProfiles[0].requiresVerification)
    }
    @MainActor func testCancelledSetupRemovesPrivateCopiesNotOriginal() throws {
        let app = AppModel(demo:true)
        let setup = VoiceSetupModel(app:app,api:VerificationAPI())
        let source = app.store.root.appendingPathComponent("original.wav")
        var pcm = Data()
        for i in 0..<96000 {
            var value = Int16(sin(Double(i) * 0.05) * 12000).littleEndian
            withUnsafeBytes(of:&value) { pcm.append(contentsOf:$0) }
        }
        try PCM.wav(pcm).write(to:source)
        try setup.addSample(source)
        XCTAssertEqual(setup.samples.count,1)
        setup.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath:setup.directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:source.path))
    }
}

extension VoiceSetupTests {
    @MainActor func testExistingVoiceRequiresPreviewAcceptanceAndRenameKeepsOwnership() async throws {
        let suite = "mochi-existing-test-\(UUID())", prefs = UserDefaults(suiteName:suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root); prefs.removePersistentDomain(forName:suite) }
        let app = AppModel(libraryRoot:root,preferences:prefs)
        let setup = VoiceSetupModel(app:app,api:VerificationAPI(),comparisonRenderer:{ identity,root in
            XCTAssertEqual(identity.clone,"existing-test")
            return (root.appendingPathComponent("source.mp3"),root.appendingPathComponent("converted.mp3"))
        })
        let profile = VoiceProfile(name:"Original",providerID:"existing-test",createdByApp:false)
        setup.profile = profile
        setup.name = "Renamed"
        setup.createAndCompare()
        for _ in 0..<100 where setup.busy { try await Task.sleep(nanoseconds:10_000_000) }
        setup.accept()
        XCTAssertEqual(app.practiceVoiceMode,.builtIn)
        setup.heardConverted = true
        setup.accept()
        XCTAssertEqual(app.practiceVoiceMode,.personal)
        XCTAssertEqual(app.selectedVoiceProfile?.name,"Renamed")
        XCTAssertFalse(try XCTUnwrap(app.selectedVoiceProfile).canDeleteRemote)
        setup.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath:setup.directory.path))
    }
    @MainActor func testCorruptProfilesAreNotOverwritten() throws {
        let suite = "mochi-corrupt-voices-\(UUID())", prefs = UserDefaults(suiteName:suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root); prefs.removePersistentDomain(forName:suite) }
        let bytes = Data("corrupt".utf8); prefs.set(bytes,forKey:"voiceProfiles")
        let app = AppModel(libraryRoot:root,preferences:prefs)
        XCTAssertFalse(app.voiceProfilesReadable)
        XCTAssertFalse(app.upsertVoiceProfile(VoiceProfile(name:"New",providerID:"new",createdByApp:false)))
        XCTAssertEqual(prefs.data(forKey:"voiceProfiles"),bytes)
    }
}

extension VoiceSetupTests {
    @MainActor func testReplacementKeepsPreviousProfileAndUsesNewDirectory() {
        let app = AppModel(demo:true)
        let setup = VoiceSetupModel(app:app,api:VerificationAPI())
        let previousID = setup.profileID
        let previous = VoiceProfile(id:previousID,name:"Previous",providerID:"previous-clone",createdByApp:true)
        app.upsertVoiceProfile(previous); setup.profile = previous
        setup.beginReplacement()
        XCTAssertNotEqual(setup.profileID,previousID)
        XCTAssertNil(setup.profile)
        XCTAssertTrue(app.voiceProfiles.contains(where:{$0.id == previousID}))
        setup.close()
    }
}

extension VoiceModelTests {
    @MainActor func testVoiceOptionsPersistAndRejectInvalidPreferences() throws {
        let suite = "mochi-options-test-\(UUID())", root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let prefs = UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite); try? FileManager.default.removeItem(at:root) }
        let app = AppModel(libraryRoot:root,preferences:prefs)
        app.conversationVoiceOptions.speed = 1.2; app.practiceVoiceOptions.speed = 0.8
        app.personalVoiceOptions.pronunciation.style = 0.25; app.personalVoiceOptions.conversion.stability = 0.9
        let loaded = AppModel(libraryRoot:root,preferences:prefs)
        XCTAssertEqual(loaded.conversationVoiceOptions.speed,1.2); XCTAssertEqual(loaded.practiceVoiceOptions.speed,0.8)
        XCTAssertEqual(loaded.personalVoiceOptions,app.personalVoiceOptions)
        let setup = VoiceSetupModel(app:loaded)
        XCTAssertEqual(setup.options,loaded.personalVoiceOptions)
        setup.options.speed = 0.9
        XCTAssertEqual(loaded.personalVoiceOptions.speed,1)
        prefs.set(Data("{\"speed\":9}".utf8),forKey:"practiceVoiceOptions")
        XCTAssertEqual(AppModel(libraryRoot:root,preferences:prefs).practiceVoiceOptions.speed,1)
    }
}
