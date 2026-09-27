import Foundation
import XCTest
@testable import VisionStack

private actor UpgradeProviderStub: ModelHubServicing {
    var imageResponse: ParsedGenerationResponse?
    var imageError: URLError?
    private(set) var receivedContexts: [BillableRequestContext] = []
    private(set) var receivedImagePrompts: [String] = []
    private(set) var receivedImageReferences: [String?] = []
    private(set) var receivedImageReferenceGroups: [[String]] = []
    private(set) var receivedVideoPrompts: [String] = []
    var imageDelay: Duration?
    var videoDelay: Duration?
    var cancelError: URLError?
    var videoTaskError: URLError?
    var reconciliationResponse: ParsedGenerationResponse?
    var reconciliationError: VisionStackError?
    var catalogValue: ModelCatalog?
    private(set) var imageWasCancelled = false
    private(set) var videoWasCancelled = false

    init(imageResponse: ParsedGenerationResponse? = nil, imageError: URLError? = nil, catalog: ModelCatalog? = nil) {
        self.imageResponse = imageResponse
        self.imageError = imageError
        self.catalogValue = catalog
    }

    func health() async throws -> ModelHubRuntimeStatus { .init(service: "fake", providerCount: 1, routeCount: 1) }
    func catalog() async throws -> ModelCatalog { catalogValue ?? .init(models: [], embeddedCapabilities: []) }
    func capabilities(for modelID: String) async throws -> CapabilityProfile {
        .init(modelID: modelID, operations: [.chat, .image, .video], source: .modelHub)
    }
    func chat(model: String, messages: [[String: String]], requestContext: BillableRequestContext) async throws -> String { "fake" }
    func generateImage(model: String, prompt: String, size: String, quality: String, referenceImage: String?, requestContext: BillableRequestContext) async throws -> ParsedGenerationResponse {
        receivedContexts.append(requestContext)
        receivedImagePrompts.append(prompt)
        receivedImageReferences.append(referenceImage)
        if let imageDelay {
            do { try await Task.sleep(for: imageDelay) }
            catch { imageWasCancelled = true; throw error }
        }
        if let imageError { throw imageError }
        return imageResponse ?? .init(raw: "{}", taskID: nil, mediaURLs: [], state: nil, errorMessage: nil)
    }
    func generateImage(model: String, prompt: String, size: String, quality: String, referenceImages: [String], requestContext: BillableRequestContext) async throws -> ParsedGenerationResponse {
        receivedImageReferenceGroups.append(referenceImages)
        return try await generateImage(
            model: model,
            prompt: prompt,
            size: size,
            quality: quality,
            referenceImage: referenceImages.first,
            requestContext: requestContext
        )
    }
    func generateVideo(model: String, prompt: String, size: String, ratio: String, duration: Int, referenceImage: String?, requestContext: BillableRequestContext) async throws -> ParsedGenerationResponse {
        receivedVideoPrompts.append(prompt)
        if let videoDelay {
            do { try await Task.sleep(for: videoDelay) }
            catch { videoWasCancelled = true; throw error }
        }
        return .init(raw: "{}", taskID: "fake-video", mediaURLs: [], state: .queued, errorMessage: nil)
    }
    func videoTask(model: String, taskID: String) async throws -> ParsedGenerationResponse {
        if let videoTaskError { throw videoTaskError }
        return .init(raw: "{}", taskID: taskID, mediaURLs: [], state: .running, errorMessage: nil)
    }
    func requestStatus(model: String, clientRequestID: UUID) async throws -> ParsedGenerationResponse {
        if let reconciliationError { throw reconciliationError }
        return reconciliationResponse ?? .init(raw: "{}", taskID: nil, mediaURLs: [], state: .running, errorMessage: nil)
    }
    func cancelVideoTask(model: String, taskID: String) async throws {
        if let cancelError { throw cancelError }
    }
}


private actor UpgradeCredentials: ProviderCredentialStoring {
    var secrets: [UUID: String] = [:]
    var blockedID: UUID?
    var pending: CheckedContinuation<String, Never>?
    func block(_ id: UUID) { blockedID = id }
    func isWaiting() -> Bool { pending != nil }
    func resume() { pending?.resume(returning: "A-test-key"); pending = nil }
    func readSecret(for providerID: UUID) async -> String {
        if blockedID == providerID { return await withCheckedContinuation { pending = $0 } }
        return secrets[providerID] ?? "fixture-key"
    }
    func saveSecret(_ secret: String, for providerID: UUID) async throws { secrets[providerID] = secret }
    func deleteSecret(for providerID: UUID) async throws { secrets[providerID] = nil }
}

final class ConnectionAndDraftUpgradeTests: XCTestCase {
    @MainActor func testLastProviderSelectionWinsWhenCredentialReadsCompleteOutOfOrder() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "vs-upgrade-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = UpgradeCredentials(), stub = UpgradeProviderStub()
        let a = AIProviderConfiguration(displayName: "A", kind: .openAICompatible, baseURL: "https://a.example/v1")
        let b = AIProviderConfiguration(displayName: "B", kind: .openAICompatible, baseURL: "https://b.example/v1")
        let store = AppStore(persistence: PersistenceService(root: root), providerFactory: { _, _ in stub }, providerCredentialStore: credentials)
        store.providerConnections = [a,b]
        await credentials.block(a.id)
        let first = Task { await store.selectProvider(a.id) }
        for _ in 0..<10000 { if await credentials.isWaiting() { break }; await Task.yield() }
        let waiting = await credentials.isWaiting(); XCTAssertTrue(waiting)
        await store.selectProvider(b.id)
        await credentials.resume(); await first.value
        XCTAssertEqual(store.selectedProviderID,b.id); XCTAssertEqual(store.baseURL,b.baseURL)
        XCTAssertEqual(store.token,"fixture-key")
        await store.flushPersistence()
    }

    @MainActor func testJobClientUsesOriginalConnectionAfterSwitchAndLegacyRequiresBinding() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "vs-upgrade-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = UpgradeCredentials(), aStub = UpgradeProviderStub(), bStub = UpgradeProviderStub()
        let a = AIProviderConfiguration(displayName: "A", kind: .openAICompatible, baseURL: "https://a.example/v1")
        let b = AIProviderConfiguration(displayName: "B", kind: .openAICompatible, baseURL: "https://b.example/v1")
        let store = AppStore(persistence: PersistenceService(root: root), providerFactory: { p, _ in p.id == a.id ? aStub : bStub }, providerCredentialStore: credentials)
        store.providerConnections = [a,b]
        await store.selectProvider(b.id)
        var job = GenerationJob(kind:.video,prompt:"p",model:"m",parameters:[:],state:.running,taskID:"a-task")
        do { _ = try await store.providerClient(for:job); XCTFail("legacy job must not guess") } catch {}
        job.connectionID = a.id; job.connectionSnapshot = a
        store.videoJobs = [job]
        let client = try await store.providerClient(for:job)
        _ = try await client.generateVideo(model:"m",prompt:"original",size:"720p",ratio:"16:9",duration:5,referenceImage:nil,requestContext:.new(confirmBillable:true))
        let ap = await aStub.receivedVideoPrompts, bp = await bStub.receivedVideoPrompts
        XCTAssertEqual(ap,["original"]); XCTAssertTrue(bp.isEmpty)
        let removed = await store.removeProviderConnection(a.id); XCTAssertFalse(removed)
        await store.flushPersistence()
    }

    @MainActor func testDraftsAndUndoPersistWithoutCrossingProjectOrConversation() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "vs-upgrade-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = PersistenceService(root:root), stub = UpgradeProviderStub(), credentials = UpgradeCredentials()
        let store = AppStore(persistence:persistence,providerFactory:{ _,_ in stub },providerCredentialStore:credentials)
        let a = CreativeProject(name:"A"), b = CreativeProject(name:"B")
        store.projects = [a,b]; store.selectedProjectID = a.id; store.createConversation()
        let ca = try XCTUnwrap(store.selectedConversationID)
        store.chatDraft = "A chat"; store.imageDraft.size = "1536x1024"; store.imagePromptDraft = "A image"
        store.selectedProjectID = b.id; store.createConversation(); store.chatDraft = "B chat"; store.videoDraft.duration = 10
        store.selectedProjectID = a.id; store.selectConversation(ca)
        XCTAssertEqual(store.chatDraft,"A chat"); XCTAssertEqual(store.imagePromptDraft,"A image"); XCTAssertEqual(store.imageDraft.size,"1536x1024")
        store.deleteConversation(ca); XCTAssertFalse(store.conversations.contains { $0.id == ca })
        await store.flushPersistence()
        let loaded = try await persistence.load()
        let snapshot = try XCTUnwrap(loaded.snapshot)
        XCTAssertEqual(snapshot.deletedConversations?.last?.id,ca)
        XCTAssertEqual(snapshot.imageDrafts?[a.id.uuidString]?.prompt,"A image")
        XCTAssertEqual(snapshot.videoDrafts?[b.id.uuidString]?.duration,10)
        XCTAssertTrue(store.undoDeleteConversation()); XCTAssertEqual(store.chatDraft,"A chat")
        await store.flushPersistence()
        let restarted = AppStore(persistence: persistence, providerFactory: { _, _ in stub }, providerCredentialStore: credentials,
                                 localMediaSkillLoader: { throw VisionStackError.server("offline fixture") }, distributionProfile: .personal)
        await restarted.bootstrap()
        restarted.selectProject(a.id); restarted.selectConversation(ca)
        XCTAssertEqual(restarted.chatDraft, "A chat")
        XCTAssertEqual(restarted.imageDraft.size, "1536x1024")
        XCTAssertEqual(restarted.imagePromptDraft, "A image")
        XCTAssertNotNil(restarted.imageDraft.updatedAt)
        restarted.selectProject(b.id)
        XCTAssertEqual(restarted.chatDraft, "B chat")
        XCTAssertEqual(restarted.videoDraft.duration, 10)
        await restarted.flushPersistence()
    }
}
