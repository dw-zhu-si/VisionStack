import Foundation
import XCTest
@testable import VisionStack

private actor ArchiveProbe {
    var calls = 0
    var cancelled = false
    func download() async throws -> (URL, HTTPURLResponse) {
        calls += 1
        do { try await Task.sleep(for: .seconds(30)) }
        catch { cancelled = true; throw error }
        throw URLError(.timedOut)
    }
}

final class ArchiveCancellationUpgradeTests: XCTestCase {
    @MainActor func testStoppingArchiveCancelsTransportAndPreservesProviderResultWithoutDuplicateDownload() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "vs-archive-cancel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = ArchiveProbe()
        let persistence = PersistenceService(root: root, mediaDownloader: { _, _, _ in try await probe.download() })
        let store = AppStore(persistence: persistence)
        let remote = "https://offline-fixture.invalid/generated.png"
        let job = GenerationJob(kind: .image, prompt: "fixture", model: "fake/image", parameters: [:], state: .needsArchive,
                                remoteResultURLs: [remote], submissionState: .submitted, providerState: .succeeded, archiveState: .pending)
        store.imageJobs = [job]
        let first = Task { await store.archiveRemoteResults(for: job) }
        for _ in 0..<10000 { if await probe.calls == 1 { break }; await Task.yield() }
        let began = await probe.calls; XCTAssertEqual(began, 1)
        await store.archiveRemoteResults(for: job)
        let before = ContinuousClock.now
        await store.cancelArchiveJob(job.id)
        await first.value
        XCTAssertLessThan(before.duration(to: .now), .seconds(1))
        let count = await probe.calls, cancelled = await probe.cancelled
        XCTAssertEqual(count, 1); XCTAssertTrue(cancelled)
        let result = try XCTUnwrap(store.imageJobs.first)
        XCTAssertEqual(result.state, .needsArchive)
        XCTAssertEqual(result.providerState, .succeeded)
        XCTAssertEqual(result.archiveState, .pending)
        XCTAssertEqual(result.remoteResultURLs, [remote]); XCTAssertTrue(result.resultURLs.isEmpty)
        await store.flushPersistence()
        let files = try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "Media").path)
        XCTAssertTrue(files.isEmpty)
    }
}
