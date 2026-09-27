import Foundation
import XCTest
@testable import VisionStack

private actor LifecycleProviderFixture: ModelHubServicing {
    let label: String
    private var holdCatalog: Bool
    private var pendingCatalog: CheckedContinuation<ModelCatalog, Never>?
    private var calls: [String] = []

    init(_ label: String, holdCatalog: Bool = false) { self.label = label; self.holdCatalog = holdCatalog }
    private var catalogValue: ModelCatalog {
        .init(models: [.init(id: "\(label)-model", owner: label, availability: "available")], embeddedCapabilities: [])
    }
    func recordedCalls() -> [String] { calls }
    func isCatalogWaiting() -> Bool { pendingCatalog != nil }
    func releaseCatalog() { holdCatalog = false; pendingCatalog?.resume(returning: catalogValue); pendingCatalog = nil }
    func health() async throws -> ModelHubRuntimeStatus {
        calls.append("health")
        return .init(service: label, providerCount: 1, routeCount: 1)
    }
    func catalog() async throws -> ModelCatalog {
        calls.append("catalog")
        if holdCatalog { return await withCheckedContinuation { pendingCatalog = $0 } }
        return catalogValue
    }
    func capabilities(for modelID: String) async throws -> CapabilityProfile {
        .init(modelID: modelID, operations: [.chat, .image, .video], source: .modelHub)
    }
    func chat(model: String, messages: [[String: String]], requestContext: BillableRequestContext) async throws -> String {
        calls.append("submit-chat"); return "fixture"
    }
    func generateImage(model: String, prompt: String, size: String, quality: String, referenceImage: String?, requestContext: BillableRequestContext) async throws -> ParsedGenerationResponse {
        calls.append("submit-image")
        return .init(raw: "{}", taskID: nil, mediaURLs: [], state: .failed, errorMessage: "fixture")
    }
    func generateVideo(model: String, prompt: String, size: String, ratio: String, duration: Int, referenceImage: String?, requestContext: BillableRequestContext) async throws -> ParsedGenerationResponse {
        calls.append("submit-video")
        return .init(raw: "{}", taskID: "new-task", mediaURLs: [], state: .queued, errorMessage: nil)
    }
    func videoTask(model: String, taskID: String) async throws -> ParsedGenerationResponse {
        calls.append("query:\(taskID)")
        // Terminal failure exercises routing without creating media downloads or
        // leaving the background poll alive after the test finishes.
        return .init(raw: "{}", taskID: taskID, mediaURLs: [], state: .failed, errorMessage: "fixture-terminal")
    }
    func requestStatus(model: String, clientRequestID: UUID) async throws -> ParsedGenerationResponse {
        calls.append("reconcile:\(clientRequestID.uuidString)")
        return .init(raw: "{}", taskID: nil, mediaURLs: [], state: .failed, errorMessage: "fixture-terminal")
    }
    func cancelVideoTask(model: String, taskID: String) async throws { calls.append("cancel:\(taskID)") }
}

private actor LifecycleCredentialFixture: ProviderCredentialStoring {
    func readSecret(for providerID: UUID) async -> String { "fixture-\(providerID.uuidString)" }
    func saveSecret(_ secret: String, for providerID: UUID) async throws {}
    func deleteSecret(for providerID: UUID) async throws {}
}

final class ProviderLifecycleUpgradeTests: XCTestCase {
    private func root() -> URL { FileManager.default.temporaryDirectory.appending(path: "visionstack-provider-lifecycle-\(UUID())") }
    private func providers() -> (AIProviderConfiguration, AIProviderConfiguration) {
        (.init(displayName: "A", kind: .openAICompatible, baseURL: "https://a.example/v1"),
         .init(displayName: "B", kind: .openAICompatible, baseURL: "https://b.example/v1"))
    }
    private func job(_ provider: AIProviderConfiguration, taskID: String, state: JobState) -> GenerationJob {
        var job = GenerationJob(kind: .video, prompt: "fixture", model: "same-model", parameters: [:], state: state,
                                taskID: taskID, submissionState: .submitted, providerState: .running, archiveState: .pending)
        job.connectionID = provider.id
        job.connectionSnapshot = provider
        return job
    }
    @MainActor private func store(_ root: URL, a: AIProviderConfiguration, aStub: LifecycleProviderFixture, bStub: LifecycleProviderFixture) -> AppStore {
        AppStore(persistence: PersistenceService(root: root), providerFactory: { configuration, secret in
            XCTAssertEqual(secret, "fixture-\(configuration.id.uuidString)", "credentials must match the requested connection")
            return configuration.id == a.id ? aStub : bStub
        }, providerCredentialStore: LifecycleCredentialFixture(), videoPollInterval: .milliseconds(1),
                 automaticallyImportsLocalMediaSkills: false, distributionProfile: .personal)
    }
    @MainActor private func persist(_ jobs: [GenerationJob], root: URL, a: AIProviderConfiguration, b: AIProviderConfiguration,
                                    aStub: LifecycleProviderFixture, bStub: LifecycleProviderFixture) async {
        let writer = store(root, a: a, aStub: aStub, bStub: bStub)
        writer.providerConnections = [a, b]
        writer.selectedProviderID = b.id
        writer.baseURL = b.baseURL
        writer.videoJobs = jobs
        await writer.flushPersistence()
    }

    @MainActor func testPersistedOriginalProviderOwnsReconciliationAndCancellationAfterSwitch() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let (a, b) = providers()
        let aStub = LifecycleProviderFixture("a"), bStub = LifecycleProviderFixture("b")
        let reconcile = job(a, taskID: "original-reconcile", state: .pollingDegraded)
        let cancel = job(a, taskID: "original-cancel", state: .cancelPending)
        await persist([reconcile, cancel], root: root, a: a, b: b, aStub: aStub, bStub: bStub)
        let restored = store(root, a: a, aStub: aStub, bStub: bStub)
        await restored.bootstrap()
        XCTAssertEqual(restored.selectedProviderID, b.id)
        let loaded = try XCTUnwrap(restored.videoJobs.first { $0.id == reconcile.id })
        XCTAssertEqual(loaded.connectionID, a.id)
        await restored.reconcileJob(loaded)
        await restored.cancelVideoJob(cancel.id)
        let aCalls = await aStub.recordedCalls(), bCalls = await bStub.recordedCalls()
        XCTAssertEqual(aCalls, ["query:original-reconcile", "cancel:original-cancel"])
        XCTAssertFalse(bCalls.contains { $0.hasPrefix("query:") || $0.hasPrefix("cancel:") || $0.hasPrefix("submit-") })
        XCTAssertEqual(restored.videoJobs.first { $0.id == reconcile.id }?.state, .failed)
        XCTAssertEqual(restored.videoJobs.first { $0.id == cancel.id }?.state, .cancelled)
        await restored.flushPersistence()
    }

    @MainActor func testBootstrapResumesPersistedVideoPollOnlyAgainstOriginalProvider() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let (a, b) = providers()
        let aStub = LifecycleProviderFixture("a"), bStub = LifecycleProviderFixture("b")
        let pending = job(a, taskID: "resume-after-restart", state: .running)
        await persist([pending], root: root, a: a, b: b, aStub: aStub, bStub: bStub)
        let restored = store(root, a: a, aStub: aStub, bStub: bStub)
        await restored.bootstrap()
        for _ in 0..<500 where restored.videoJobs.first?.state != .failed { try await Task.sleep(for: .milliseconds(1)) }
        let aCalls = await aStub.recordedCalls(), bCalls = await bStub.recordedCalls()
        XCTAssertEqual(aCalls, ["query:resume-after-restart"])
        XCTAssertFalse(bCalls.contains { $0.hasPrefix("query:") || $0.hasPrefix("submit-") })
        XCTAssertEqual(restored.selectedProviderID, b.id)
        XCTAssertEqual(restored.videoJobs.first?.state, .failed)
        if restored.videoJobs.first?.state != .failed { await restored.cancelVideoJob(pending.id) }
        await restored.flushPersistence()
    }

    @MainActor func testChangedOriginalEndpointRejectsRecoveryAndCancellationBeforeProviderCall() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let (a, b) = providers()
        let aStub = LifecycleProviderFixture("a"), bStub = LifecycleProviderFixture("b")
        let original = job(a, taskID: "old-endpoint-task", state: .pollingDegraded)
        await persist([original], root: root, a: a, b: b, aStub: aStub, bStub: bStub)
        let restored = store(root, a: a, aStub: aStub, bStub: bStub)
        await restored.bootstrap()
        let index = try XCTUnwrap(restored.providerConnections.firstIndex { $0.id == a.id })
        restored.providerConnections[index].baseURL = "https://changed.example/v1"
        await restored.reconcileJob(try XCTUnwrap(restored.videoJobs.first))
        XCTAssertTrue(restored.notice?.contains("地址已改变") == true)
        await restored.cancelVideoJob(original.id)
        XCTAssertEqual(restored.videoJobs.first?.state, .cancelPending)
        XCTAssertTrue(restored.videoJobs.first?.errorMessage?.contains("地址已改变") == true)
        let aCalls = await aStub.recordedCalls(), bCalls = await bStub.recordedCalls()
        XCTAssertTrue(aCalls.isEmpty)
        XCTAssertFalse(bCalls.contains { $0.hasPrefix("query:") || $0.hasPrefix("cancel:") || $0.hasPrefix("submit-") })
        await restored.flushPersistence()
    }

    @MainActor func testLegacyBindingOnlyPersistsProvenanceAndNeverSubmitsOrQueries() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let (a, b) = providers()
        let aStub = LifecycleProviderFixture("a"), bStub = LifecycleProviderFixture("b")
        let store = store(root, a: a, aStub: aStub, bStub: bStub)
        store.providerConnections = [a, b]; store.selectedProviderID = b.id
        let legacy = GenerationJob(kind: .video, prompt: "legacy", model: "same-model", parameters: [:], state: .pollingDegraded, taskID: "legacy-task")
        store.videoJobs = [legacy]
        XCTAssertTrue(store.bindLegacyJob(legacy.id, to: a.id))
        XCTAssertFalse(store.bindLegacyJob(legacy.id, to: b.id), "must not silently rebind an established origin")
        await store.flushPersistence()
        let loaded = try await PersistenceService(root: root).load()
        let saved = try XCTUnwrap(loaded.snapshot?.videoJobs.first)
        XCTAssertEqual(saved.connectionID, a.id)
        XCTAssertEqual(saved.connectionSnapshot?.baseURL, a.baseURL)
        XCTAssertEqual(saved.taskID, legacy.taskID)
        XCTAssertEqual(saved.state, legacy.state)
        let aCalls = await aStub.recordedCalls(), bCalls = await bStub.recordedCalls()
        XCTAssertTrue(aCalls.isEmpty); XCTAssertTrue(bCalls.isEmpty)
    }

    @MainActor func testLastSelectionCatalogWinsWhenPreviousCatalogReturnsLate() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let (a, b) = providers()
        let aStub = LifecycleProviderFixture("a", holdCatalog: true), bStub = LifecycleProviderFixture("b")
        let store = store(root, a: a, aStub: aStub, bStub: bStub)
        store.providerConnections = [a, b]
        let first = Task { await store.selectProvider(a.id) }
        for _ in 0..<500 { if await aStub.isCatalogWaiting() { break }; try await Task.sleep(for: .milliseconds(1)) }
        let aWaiting = await aStub.isCatalogWaiting()
        XCTAssertTrue(aWaiting)
        await store.selectProvider(b.id)
        XCTAssertEqual(store.models.map(\.id), ["b-model"])
        await aStub.releaseCatalog()
        await first.value
        XCTAssertEqual(store.selectedProviderID, b.id)
        XCTAssertEqual(store.baseURL, b.baseURL)
        XCTAssertEqual(store.token, "fixture-\(b.id.uuidString)")
        XCTAssertEqual(store.models.map(\.id), ["b-model"])
        XCTAssertEqual(store.modelHubStatus?.service, "b")
        await store.flushPersistence()
    }
}
