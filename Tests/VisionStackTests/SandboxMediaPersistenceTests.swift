import CryptoKit
import Foundation
import XCTest
@testable import VisionStack

final class SandboxMediaPersistenceTests: XCTestCase {
    func testProjectBackupSucceedsWithOnlyItsSelectedDestinationWritable() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appending(path: "用户选择的备份.visionstackproject")
        let fileManager = SelectedDestinationFileManager(destination: destination)
        let project = CreativeProject(name: "只授权目标包")

        let health = try ProjectBackupService.write(
            ProjectBackupPayload(project: project),
            to: destination,
            fileManager: fileManager
        )

        XCTAssertTrue(health.isHealthy)
        XCTAssertEqual(try ProjectBackupService.load(destination).project.id, project.id)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [destination.lastPathComponent])
    }

    @MainActor func testSingleMediaDownloadCreatesOnlyTheUserSelectedFile() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "managed-result.png")
        let destinationDirectory = root.appending(path: "用户选择目录")
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let destination = destinationDirectory.appending(path: "作品.png")
        let bytes = Data([0x89, 0x50, 0x4e, 0x47, 1, 2, 3, 4])
        try bytes.write(to: source)
        let job = GenerationJob(
            kind: .image,
            prompt: "合成下载测试",
            model: "fixture/image",
            parameters: [:],
            state: .succeeded,
            resultURLs: [source.absoluteString]
        )

        try MediaFileActions.exportSingleFile(job, to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destinationDirectory.path), ["作品.png"])
    }

    func testProjectBackupIncludesBackgroundAudioAndRemainsPortableWithoutItsSource() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "原始背景音频.wav")
        let bytes = fixtureWAV()
        try bytes.write(to: source)
        let project = CreativeProject(name: "带音频的草剪")
        let cut = RoughCutProject(projectID: project.id, name: "测试草剪", backgroundAudioURL: source.absoluteString)
        let destination = root.appending(path: "可移植备份.visionstackproject")

        let health = try ProjectBackupService.write(
            ProjectBackupPayload(project: project, roughCuts: [cut]),
            to: destination
        )
        let restoredPayload = try ProjectBackupService.load(destination)
        let relativeAudio = try XCTUnwrap(restoredPayload.roughCuts.first?.backgroundAudioURL)

        XCTAssertTrue(health.isHealthy)
        XCTAssertTrue(relativeAudio.hasPrefix("Audio/"), "备份必须携带音频，不能继续引用原机绝对路径。")
        guard relativeAudio.hasPrefix("Audio/") else { return }
        try FileManager.default.removeItem(at: source)
        let packagedAudio = try ProjectBackupService.resolvedFileURL(relativeAudio, in: destination)
        XCTAssertEqual(try Data(contentsOf: packagedAudio), bytes)
        let manifest = try JSONDecoder.visionStack.decode(
            ProjectBackupManifest.self,
            from: Data(contentsOf: destination.appending(path: ProjectBackupService.manifestName))
        )
        XCTAssertEqual(manifest.files[relativeAudio], digest(bytes))
        XCTAssertTrue(try ProjectBackupService.inspect(destination).isHealthy)
    }

    func testMissingBackgroundAudioIsReportedAndItsExternalPathIsNotExported() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let missingAudio = root.appending(path: "已丢失音频.wav")
        let project = CreativeProject(name: "缺失音频")
        let cut = RoughCutProject(projectID: project.id, name: "测试草剪", backgroundAudioURL: missingAudio.absoluteString)
        let destination = root.appending(path: "缺失音频备份.visionstackproject")

        let health = try ProjectBackupService.write(
            ProjectBackupPayload(project: project, roughCuts: [cut]),
            to: destination
        )
        let payload = try JSONDecoder.visionStack.decode(
            ProjectBackupPayload.self,
            from: Data(contentsOf: destination.appending(path: ProjectBackupService.payloadName))
        )

        XCTAssertEqual(health.missingFiles, [missingAudio.lastPathComponent])
        XCTAssertFalse(health.isHealthy)
        XCTAssertNil(payload.roughCuts.first?.backgroundAudioURL)
    }

    @MainActor func testRestoredBackgroundAudioSurvivesPackageRemovalAndPersistenceReload() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = fixtureWAV()
        let package = root.appending(path: "输入备份.visionstackproject")
        try writePortableAudioPackage(to: package, audio: bytes)
        let storeRoot = root.appending(path: "隔离存储")
        let store = AppStore(
            persistence: PersistenceService(root: storeRoot),
            modelHubFactory: { _, _ in throw VisionStackError.server("测试禁止联网") }
        )

        await store.restoreProjectBackup(from: package)
        await store.flushPersistence()

        let audioValue = try XCTUnwrap(store.currentProjectRoughCut?.backgroundAudioURL)
        let ownedAudio = try XCTUnwrap(URL(string: audioValue))
        XCTAssertTrue(ownedAudio.isFileURL, "恢复后的路径应指向本机受控音频文件。")
        XCTAssertTrue(ownedAudio.path.hasPrefix(storeRoot.appending(path: "Audio").path + "/"))
        guard ownedAudio.isFileURL else { return }
        try FileManager.default.removeItem(at: package)
        XCTAssertEqual(try Data(contentsOf: ownedAudio), bytes)
        let reloaded = try await PersistenceService(root: storeRoot).load()
        XCTAssertEqual(reloaded.snapshot?.roughCuts?.first?.backgroundAudioURL, ownedAudio.absoluteString)
        XCTAssertEqual(try Data(contentsOf: ownedAudio), bytes)
    }

    func testBackupLoadingRejectsBackgroundAudioMissingFromIntegrityManifest() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appending(path: "未校验音频.visionstackproject")
        try writePortableAudioPackage(to: package, audio: fixtureWAV(), includeAudioHash: false)

        XCTAssertThrowsError(try ProjectBackupService.load(package))
    }

    func testImportedBackgroundAudioIsOwnedAndSurvivesRemovalOfTheSelectedSource() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "选择的音频.wav")
        let bytes = fixtureWAV()
        try bytes.write(to: source)
        let storeRoot = root.appending(path: "隔离存储")
        let persistence = PersistenceService(root: storeRoot)

        let importedValue = try await persistence.importBackgroundAudio(from: source)
        let imported = try XCTUnwrap(URL(string: importedValue))
        try FileManager.default.removeItem(at: source)

        XCTAssertTrue(imported.path.hasPrefix(storeRoot.appending(path: "Audio").path + "/"))
        XCTAssertEqual(try Data(contentsOf: imported), bytes)
        let attributes = try FileManager.default.attributesOfItem(atPath: imported.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try await PersistenceService(root: storeRoot).deleteBackgroundAudio(importedValue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: imported.path))
    }

    func testBackgroundAudioImportRejectsSymbolicLinksAndNonAudioContent() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "原始音频.wav")
        let symlink = root.appending(path: "链接音频.wav")
        let invalid = root.appending(path: "伪装音频.wav")
        let bytes = fixtureWAV()
        try bytes.write(to: source)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
        try Data("not an audio file".utf8).write(to: invalid)
        let storeRoot = root.appending(path: "隔离存储")
        let persistence = PersistenceService(root: storeRoot)

        for candidate in [symlink, invalid] {
            do {
                _ = try await persistence.importBackgroundAudio(from: candidate)
                XCTFail("不安全或无法解码的音频不应进入受控存储。")
            } catch {}
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: storeRoot.appending(path: "Audio").path))
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    @MainActor func testDiscardingUnsavedAudioPreservesReferencedAndExternalFiles() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "外部音频.wav")
        let bytes = fixtureWAV()
        try bytes.write(to: source)
        let persistence = PersistenceService(root: root.appending(path: "隔离存储"))
        let retained = try await persistence.importBackgroundAudio(from: source)
        let discarded = try await persistence.importBackgroundAudio(from: source)
        let store = AppStore(
            persistence: persistence,
            modelHubFactory: { _, _ in throw VisionStackError.server("测试禁止联网") }
        )
        let project = CreativeProject(name: "已保存草剪")
        store.projects = [project]
        store.selectedProjectID = project.id
        store.saveRoughCut(RoughCutProject(projectID: project.id, name: "保留引用", backgroundAudioURL: retained))
        await store.flushPersistence()

        await store.discardUnreferencedBackgroundAudio([retained, discarded, source.absoluteString])

        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(URL(string: retained))), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(URL(string: discarded)).path))
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(store.currentProjectRoughCut?.backgroundAudioURL, retained)
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "visionstack-sandbox-media-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writePortableAudioPackage(to package: URL, audio: Data, includeAudioHash: Bool = true) throws {
        let audioDirectory = package.appending(path: "Audio")
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        let relativeAudio = "Audio/background.wav"
        try audio.write(to: package.appending(path: relativeAudio))
        let project = CreativeProject(name: "音频恢复夹具")
        let cut = RoughCutProject(projectID: project.id, name: "可移植草剪", backgroundAudioURL: relativeAudio)
        let payload = ProjectBackupPayload(project: project, roughCuts: [cut])
        let payloadData = try JSONEncoder.visionStack.encode(payload)
        try payloadData.write(to: package.appending(path: ProjectBackupService.payloadName))
        var hashes = [ProjectBackupService.payloadName: digest(payloadData)]
        if includeAudioHash { hashes[relativeAudio] = digest(audio) }
        let manifest = ProjectBackupManifest(
            schemaVersion: ProjectBackupPayload.currentSchemaVersion,
            projectName: project.name,
            exportedAt: Date(),
            files: hashes
        )
        try JSONEncoder.visionStack.encode(manifest).write(to: package.appending(path: ProjectBackupService.manifestName))
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func fixtureWAV() -> Data {
        let sampleBytes = Data(repeating: 0, count: 320)
        var data = Data("RIFF".utf8)
        appendLE(UInt32(36 + sampleBytes.count), to: &data)
        data.append(Data("WAVEfmt ".utf8))
        appendLE(UInt32(16), to: &data)
        appendLE(UInt16(1), to: &data)
        appendLE(UInt16(1), to: &data)
        appendLE(UInt32(8_000), to: &data)
        appendLE(UInt32(16_000), to: &data)
        appendLE(UInt16(2), to: &data)
        appendLE(UInt16(16), to: &data)
        data.append(Data("data".utf8))
        appendLE(UInt32(sampleBytes.count), to: &data)
        data.append(sampleBytes)
        return data
    }

    private func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}

private final class SelectedDestinationFileManager: FileManager, @unchecked Sendable {
    private let selectedDestination: URL
    private let protectedParent: URL

    init(destination: URL) {
        selectedDestination = destination.resolvingSymlinksInPath().standardizedFileURL
        protectedParent = destination.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        super.init()
    }

    override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool, attributes: [FileAttributeKey: Any]? = nil) throws {
        try requireSelectedWrite(url)
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        try requireSelectedWrite(dstURL)
        try super.copyItem(at: srcURL, to: dstURL)
    }

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        try requireSelectedWrite(dstURL)
        try super.moveItem(at: srcURL, to: dstURL)
    }

    override func removeItem(at url: URL) throws {
        try requireSelectedWrite(url)
        try super.removeItem(at: url)
    }

    private func requireSelectedWrite(_ url: URL) throws {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard path.hasPrefix(protectedParent.path + "/") else { return }
        guard path == selectedDestination.path || path.hasPrefix(selectedDestination.path + "/") else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: path])
        }
    }
}
