import Foundation
import XCTest

final class PackagingEntitlementsTests: XCTestCase {
    func testBaseEntitlementsContainOnlyUnrestrictedSandboxCapabilities() throws {
        let entitlementsURL = packageRoot.appending(path: "Packaging/VisionStack.entitlements")
        let data = try Data(contentsOf: entitlementsURL)
        var format = PropertyListSerialization.PropertyListFormat.xml
        let entitlements = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: &format)
                as? [String: Any]
        )
        let expectedKeys: Set<String> = [
            "com.apple.security.app-sandbox",
            "com.apple.security.files.user-selected.read-write",
            "com.apple.security.network.client"
        ]

        XCTAssertEqual(Set(entitlements.keys), expectedKeys)
        for key in expectedKeys {
            XCTAssertEqual(entitlements[key] as? Bool, true, "\(key) 必须明确启用。")
        }
        XCTAssertNil(entitlements["com.apple.application-identifier"])
        XCTAssertNil(entitlements["com.apple.developer.team-identifier"])
    }

    func testAppStoreEntitlementsMatchRegisteredIdentityAndSandboxCapabilities() throws {
        let entitlementsURL = packageRoot.appending(path: "Packaging/VisionStackAppStore.entitlements")
        let data = try Data(contentsOf: entitlementsURL)
        var format = PropertyListSerialization.PropertyListFormat.xml
        let entitlements = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: &format)
                as? [String: Any]
        )

        XCTAssertEqual(entitlements["com.apple.application-identifier"] as? String, "L4G2HAQ5B5.studio.yeluzi.visionstack")
        XCTAssertEqual(entitlements["com.apple.developer.team-identifier"] as? String, "L4G2HAQ5B5")
        XCTAssertEqual(entitlements["com.apple.security.app-sandbox"] as? Bool, true)
        XCTAssertEqual(entitlements["com.apple.security.files.user-selected.read-write"] as? Bool, true)
        XCTAssertEqual(entitlements["com.apple.security.network.client"] as? Bool, true)
    }

    func testPackagingScriptDoesNotInjectRestrictedIdentityEntitlements() throws {
        let scriptURL = packageRoot.appending(path: "scripts/package_macos_app.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertFalse(script.contains("Set :com.apple.application-identifier"))
        XCTAssertFalse(script.contains("Set :com.apple.developer.team-identifier"))
    }

    func testAppStorePackagingRequiresEmbedsAndVerifiesAProvisioningProfile() throws {
        let scriptURL = packageRoot.appending(path: "scripts/package_macos_app.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.contains("APP_STORE_PROVISIONING_PROFILE"))
        XCTAssertTrue(script.contains("Contents/embedded.provisionprofile"))
        XCTAssertTrue(script.contains("verify_app_store_profile"))
        XCTAssertTrue(script.contains("EXPECTED_APP_IDENTIFIER"))
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
