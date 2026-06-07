import Foundation
import Testing

/// The app is bundled-only and auto-updates via Sparkle, so the source Info.plist MUST
/// carry a valid feed URL and EdDSA public key. build-app.sh copies this plist into the
/// bundle; if these keys are absent the shipped app would either not update or fail to
/// verify updates. Guard the contract at the source.
@Suite("Sparkle Info.plist contract")
struct InfoPlistSparkleTests {
    static func repoInfoPlist() throws -> [String: Any] {
        // Tests/<thisFile>.swift → repo root is one directory up from Tests/.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // repo root
        let data = try Data(contentsOf: root.appendingPathComponent("Info.plist"))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return plist as? [String: Any] ?? [:]
    }

    @Test func feedURLIsHTTPS() throws {
        let feed = try Self.repoInfoPlist()["SUFeedURL"] as? String
        #expect(feed?.hasPrefix("https://") == true)
        #expect(feed?.hasSuffix("appcast.xml") == true)
    }

    @Test func publicEDKeyPresentAndBase64() throws {
        let key = try Self.repoInfoPlist()["SUPublicEDKey"] as? String ?? ""
        #expect(!key.isEmpty)
        #expect(Data(base64Encoded: key) != nil)   // valid EdDSA public key encoding
    }
}
