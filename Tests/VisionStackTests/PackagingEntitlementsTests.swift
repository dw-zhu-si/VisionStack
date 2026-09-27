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

    func testCommunityPackagingRejectsOfficialChannelsAndDelegatesLocalBuild() throws {
        let fixture = FileManager.default.temporaryDirectory
            .appending(path: "visionstack-packaging-test-\(UUID().uuidString)")
        let scripts = fixture.appending(path: "scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let wrapper = scripts.appending(path: "package_macos_app.sh")
        try FileManager.default.copyItem(
            at: packageRoot.appending(path: "scripts/package_macos_app.sh"), to: wrapper
        )
        let stub = scripts.appending(path: "build_macos.sh")
        try "#!/bin/sh\nprintf 'community-build-delegated'\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        for mode in ["github", "developer-id", "distribution", "app-store", "unknown", "local"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [wrapper.path]
            var environment = ProcessInfo.processInfo.environment
            environment["RELEASE_MODE"] = mode
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTAssertEqual(process.terminationStatus, mode == "local" ? 0 : 64, mode)
            XCTAssertEqual(text, mode == "local" ? "community-build-delegated" : "", mode)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.path), ["scripts"], mode)
        }
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
