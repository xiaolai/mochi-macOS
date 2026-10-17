import Foundation
import MochiKernel
import Security

/// The learner's ElevenLabs API key, kept in the Keychain beside Mochi's other secrets. It is used only by
/// `PracticeTimbreConverter`, and only when the learner has turned practice timbre on.
public enum ElevenLabsCredential {
    private static let account = "ELEVENLABS_API_KEY"

    public static func read() throws -> String {
        for service in [AppIdentity.bundleIdentifier] + AppIdentity.legacyBundleIdentifiers {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { continue }
            guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8),
                !value.isEmpty
            else {
                throw AppFailure("Could not read the ElevenLabs key from Keychain. Save it again in Settings → Voices.")
            }
            return value
        }
        throw AppFailure("Save your ElevenLabs API key in Settings → Voices.")
    }

    /// Whether a key is saved. A Keychain error reads as "not saved", so the settings offer to save one again.
    public static var isSaved: Bool {
        (try? read()) != nil
    }

    public static func save(_ value: String) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.count < 4096, !key.contains(where: { $0.isNewline }) else {
            throw AppFailure("Enter a valid ElevenLabs API key.")
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppIdentity.bundleIdentifier,
            kSecAttrAccount as String: account,
        ]
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data(key.utf8)] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(key.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AppFailure("Could not save the ElevenLabs key in Keychain.") }
    }

    public static func delete() throws {
        let status = SecItemDelete(
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: AppIdentity.bundleIdentifier,
                kSecAttrAccount as String: account,
            ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppFailure("Could not remove the ElevenLabs key from Keychain.")
        }
    }
}
