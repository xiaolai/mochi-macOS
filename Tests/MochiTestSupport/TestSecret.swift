import Foundation
import RealtimeConnection

/// A minted client secret for a fake connection. Every secret is registered with the process's scrubber, so a test
/// bearer must never be a word that also appears in a message under test; the default cannot be.
public func testSecret(_ bearer: String = "ek_test-secret") -> ClientSecret {
    ClientSecret(bearer: bearer, expiresAt: Date(timeIntervalSinceNow: 600))
}
