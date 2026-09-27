import Foundation
import XCTest
@testable import VisionStack

final class PersistenceRecoveryTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "visionstack-recovery-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func snapshot(_ marker: String) -> AppSnapshot {
        AppSnapshot(conversations: [], selectedConversationID: nil, imageJobs: [], videoJobs: [], selectedAgentID: nil,
                    selectedSkillIDs: [], baseURL: "http://127.0.0.1:65535", preferredChatModel: marker,
                    preferredImageModel: "", preferredVideoModel: "", webSearchEnabled: false, cachedModels: [],
                    cachedCapabilities: [], customCapabilities: [], contextBudgetTokens: nil, maxConcurrentGenerationTasks: nil,
                    referenceAssets: nil, storyboardShots: nil)
    }

    func testMissingPrimaryUsesValidBackup() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = PersistenceService(root: root)
        try await service.saveState(snapshot("backup"), revision: 1)
        try await service.saveState(snapshot("latest"), revision: 2)
        try FileManager.default.removeItem(at: root.appending(path: "state.json"))
        let loaded = try await service.load()
        XCTAssertEqual(loaded.snapshot?.preferredChatModel, "backup")
        XCTAssertNotNil(loaded.recoveryNotice)
    }

    func testUnreadablePrimaryUsesBackupAndFailedSaveKeepsBackup() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = PersistenceService(root: root)
        try await service.saveState(snapshot("backup"), revision: 1)
        try await service.saveState(snapshot("latest"), revision: 2)
        let primary = root.appending(path: "state.json")
        try FileManager.default.removeItem(at: primary)
        // A directory deterministically cannot be read as a state file, including
        // when the test process has privileges that bypass POSIX read bits.
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: false)
        let loaded = try await service.load()
        XCTAssertEqual(loaded.snapshot?.preferredChatModel, "backup")
        let backup = root.appending(path: "state.backup.json")
        let before = try Data(contentsOf: backup)
        do { try await service.saveState(snapshot("new"), revision: 3); XCTFail("directory target must reject save") } catch {}
        XCTAssertEqual(try Data(contentsOf: backup), before)
    }

    func testSavingAfterCorruptionDoesNotReplaceLastValidBackupWithCorruptPrimary() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = PersistenceService(root: root)
        try await service.saveState(snapshot("backup"), revision: 1)
        try await service.saveState(snapshot("latest"), revision: 2)
        let backup = root.appending(path: "state.backup.json")
        let before = try Data(contentsOf: backup)
        try Data("{broken".utf8).write(to: root.appending(path: "state.json"))
        let loaded = try await service.load()
        XCTAssertEqual(loaded.snapshot?.preferredChatModel, "backup")
        try await service.saveState(snapshot("restored"), revision: 3)
        XCTAssertEqual(try Data(contentsOf: backup), before)
        let restored = try await service.load()
        XCTAssertEqual(restored.snapshot?.preferredChatModel, "restored")
    }

    func testUnsupportedBackupSchemaIsNotSilentlyLoaded() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        var future = snapshot("future")
        future.schemaVersion = AppSnapshot.currentSchemaVersion + 1
        try JSONEncoder.visionStack.encode(future).write(to: root.appending(path: "state.backup.json"))
        do { _ = try await PersistenceService(root: root).load(); XCTFail("future schema must fail closed") }
        catch { XCTAssertTrue(error.localizedDescription.contains("版本") || error is VisionStackError) }
    }

    func testMissingResourcePrimaryUsesBackupAndCorruptionBlocksEmptyOverwrite() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = PersistenceService(root: root)
        let resource = ImportedResource(kind: .skill, name: "恢复", summary: "fixture", instructions: "fixture", sourcePath: "fixture", contentHash: "fixture", executableRisk: false)
        try await service.saveResources([resource], revision: 1)
        try await service.saveResources([], revision: 2)
        try FileManager.default.removeItem(at: root.appending(path: "resources.json"))
        let loaded = try await service.load()
        XCTAssertEqual(loaded.resources.first?.name, "恢复")
        try Data("{broken".utf8).write(to: root.appending(path: "resources.backup.json"))
        do { _ = try await service.load(); XCTFail("unrecoverable resources must fail closed") } catch {}
    }
}
