import Foundation
import CryptoKit
import XCTest
@testable import VisionStack

private actor FakeModelHubService: ModelHubServicing {
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

private actor InMemoryProviderCredentialStore: ProviderCredentialStoring {
    private var values: [UUID: String] = [:]

    func readSecret(for providerID: UUID) async -> String { values[providerID] ?? "" }
    func saveSecret(_ secret: String, for providerID: UUID) async throws { values[providerID] = secret }
    func deleteSecret(for providerID: UUID) async throws { values.removeValue(forKey: providerID) }
}

private func writeValidReferencePNG(to url: URL) throws {
    let base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    try XCTUnwrap(Data(base64Encoded: base64)).write(to: url, options: .atomic)
}

private final class ThreadObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Bool?

    func record(_ value: Bool) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }

    var value: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }
}

final class VisionStackTests: XCTestCase {
    func testAppResourceSearchSkipsMissingCandidateAndUsesReadableIcon() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "visionstack-resource-test-\(UUID().uuidString)")
        let missing = root.appending(path: "missing.png")
        let readable = root.appending(path: "AppIcon.png")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: readable)

        XCTAssertEqual(AppResources.firstReadableURL([missing, readable]), readable)
    }

    func testAppResourceSearchReturnsNilInsteadOfCrashingWhenAllCandidatesAreMissing() {
        let missing = FileManager.default.temporaryDirectory.appending(path: "visionstack-missing-\(UUID().uuidString).png")
        XCTAssertNil(AppResources.firstReadableURL([missing, nil]))
    }

    func testAppResourceSearchCanResolvePackagedResourceBundleDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "visionstack-bundle-test-\(UUID().uuidString)")
        let missing = root.appending(path: "missing.bundle")
        let bundle = root.appending(path: AppResources.swiftPackageBundleName)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(AppResources.firstReadableDirectoryURL([missing, bundle]), bundle)
    }

    @MainActor func testCorruptStateBlocksBootstrapWithoutOverwritingOriginalHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "visionstack-corrupt-state-\(UUID().uuidString)")
        let stateURL = root.appending(path: "state.json")
        let backupURL = root.appending(path: "state.backup.json")
        let corruptState = Data("{not-valid-json".utf8)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try corruptState.write(to: stateURL)
        let store = AppStore(persistence: PersistenceService(root: root))

        await store.bootstrap()
        store.createConversation()
        try await Task.sleep(for: .milliseconds(350))

        XCTAssertNotNil(store.persistenceBlockReason)
        XCTAssertTrue(store.conversations.isEmpty)
        XCTAssertEqual(try Data(contentsOf: stateURL), corruptState)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path))
    }

    @MainActor func testJobCountersCountWithoutChangingChronologicalJobOrder() {
        let store = AppStore()
        let olderImage = GenerationJob(kind: .image, prompt: "旧", model: "fixture/image", parameters: [:], state: .running, createdAt: Date(timeIntervalSince1970: 1))
        let newerVideo = GenerationJob(kind: .video, prompt: "新", model: "fixture/video", parameters: [:], state: .succeeded, createdAt: Date(timeIntervalSince1970: 2))
        let queuedVideo = GenerationJob(kind: .video, prompt: "排队", model: "fixture/video", parameters: [:], state: .queued, createdAt: Date(timeIntervalSince1970: 3))
        store.imageJobs = [olderImage]
        store.videoJobs = [newerVideo, queuedVideo]

        XCTAssertEqual(store.totalJobCount, 3)
        XCTAssertEqual(store.activeGenerationCount, 2)
        XCTAssertEqual(store.allJobs.map(\.id), [queuedVideo.id, newerVideo.id, olderImage.id])
    }

    @MainActor func testAssetLibraryContainsMediaWhileTaskCenterKeepsAllJobs() {
        let store = AppStore()
        let failed = GenerationJob(kind: .image, prompt: "失败诊断", model: "fixture/image", parameters: [:], state: .failed)
        let remote = GenerationJob(kind: .image, prompt: "远程素材", model: "fixture/image", parameters: [:], state: .needsArchive, remoteResultURLs: ["https://example.com/image.png"])
        store.imageJobs = [failed, remote]

        XCTAssertEqual(store.totalJobCount, 2)
        XCTAssertEqual(store.assetJobs.map(\.id), [remote.id])
    }

    @MainActor func testFailedSettingsValidationDoesNotMutateAnyDraftedSetting() async {
        let store = AppStore(modelHubFactory: { _, _ in throw VisionStackError.server("连接失败") })
        store.baseURL = "http://127.0.0.1:11435/v1"
        store.contextBudgetTokens = 8_192
        store.maxConcurrentGenerationTasks = 2

        let saved = await store.saveSettings(
            baseURL: "http://127.0.0.1:19999/v1",
            token: "draft",
            contextBudgetTokens: 65_536,
            maxConcurrentGenerationTasks: 4
        )

        XCTAssertFalse(saved)
        XCTAssertEqual(store.baseURL, "http://127.0.0.1:11435/v1")
        XCTAssertEqual(store.contextBudgetTokens, 8_192)
        XCTAssertEqual(store.maxConcurrentGenerationTasks, 2)
    }

    func testProviderEndpointPolicySeparatesModelHubLoopbackFromDirectHTTPS() {
        XCTAssertNoThrow(try ProviderEndpointPolicy.validate(
            kind: .modelHub,
            baseURL: "http://127.0.0.1:11435/v1"
        ))
        XCTAssertNoThrow(try ProviderEndpointPolicy.validate(
            kind: .openAICompatible,
            baseURL: "https://api.vendor.example/v1"
        ))
        XCTAssertThrowsError(try ProviderEndpointPolicy.validate(
            kind: .openAICompatible,
            baseURL: "http://api.vendor.example/v1"
        ))
        XCTAssertThrowsError(try ProviderEndpointPolicy.validate(
            kind: .openAICompatible,
            baseURL: "https://127.0.0.1:9443/v1"
        ))
        XCTAssertThrowsError(try ProviderEndpointPolicy.validate(
            kind: .modelHub,
            baseURL: "https://api.vendor.example/v1"
        ))
    }

    @MainActor func testDirectProviderConnectionPersistsMetadataButNeverPersistsItsSecret() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "visionstack-direct-provider-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ModelDescriptor(id: "vendor/vision-v1", owner: "任意厂商", availability: "available")
        let profile = CapabilityProfile(modelID: model.id, operations: [.image], imageSizes: ["1024x1024"], qualities: ["auto"], source: .modelHub)
        let fake = FakeModelHubService(catalog: .init(models: [model], embeddedCapabilities: [profile]))
        let vault = InMemoryProviderCredentialStore()
        let store = AppStore(
            persistence: PersistenceService(root: root),
            modelHubFactory: { _, _ in fake },
            providerFactory: { _, _ in fake },
            providerCredentialStore: vault
        )

        let saved = await store.saveProviderConnection(
            displayName: "任意厂商直连",
            kind: .openAICompatible,
            baseURL: "https://api.vendor.example/v1",
            apiKey: "fixture-provider-secret",
            manualModelIDs: ["vendor/vision-v1"]
        )
        await store.flushPersistence()

        XCTAssertTrue(saved)
        XCTAssertEqual(store.activeProvider?.displayName, "任意厂商直连")
        XCTAssertEqual(store.models.map(\.id), ["vendor/vision-v1"])
        let providerID = try XCTUnwrap(store.activeProvider?.id)
        let storedSecret = await vault.readSecret(for: providerID)
        XCTAssertEqual(storedSecret, "fixture-provider-secret")
        let persistedData = try Data(contentsOf: root.appending(path: "state.json"))
        let persisted = try XCTUnwrap(String(data: persistedData, encoding: .utf8))
        let snapshot = try JSONDecoder.visionStack.decode(AppSnapshot.self, from: persistedData)
        XCTAssertFalse(persisted.contains("fixture-provider-secret"))
        XCTAssertTrue(persisted.contains("任意厂商直连"))
        XCTAssertEqual(snapshot.providerConnections?.first(where: { $0.id == providerID })?.baseURL, "https://api.vendor.example/v1")
    }

    @MainActor func testModelHubRemainsBuiltInAndCanBeRecommendedWithoutBeingMandatory() async {
        let fake = FakeModelHubService()
        let vault = InMemoryProviderCredentialStore()
        let store = AppStore(
            modelHubFactory: { _, _ in fake },
            providerFactory: { _, _ in fake },
            providerCredentialStore: vault
        )

        XCTAssertEqual(store.providerConnections.first?.kind, .modelHub)
        XCTAssertEqual(store.activeProvider?.kind, .modelHub)
        XCTAssertEqual(ProviderRecommendation.modelHubAppStoreURL.absoluteString, "https://apps.apple.com/app/id6797847364")

        let saved = await store.saveProviderConnection(
            displayName: "另一家厂商",
            kind: .openAICompatible,
            baseURL: "https://api.other.example/v1",
            apiKey: "",
            manualModelIDs: ["other/chat-v1"]
        )

        XCTAssertTrue(saved)
        XCTAssertEqual(store.activeProvider?.kind, .openAICompatible)
        XCTAssertTrue(store.providerConnections.contains(where: { $0.kind == .modelHub }))
    }

    @MainActor func testManualModelRegistrationAcceptsAnyProviderWithoutStoringProviderCredentials() {
        let store = AppStore()

        let registered = store.registerManualModel(
            providerName: "任意厂商实验室",
            modelID: "custom-provider/vision-model-v1",
            operations: [.image],
            imageSizes: ["1024x1024"],
            qualities: ["auto"],
            videoResolutions: [],
            aspectRatios: [],
            durations: [],
            supportsReferenceImage: true
        )

        XCTAssertTrue(registered)
        XCTAssertEqual(store.manualModels.map(\.owner), ["任意厂商实验室"])
        XCTAssertEqual(store.models.filter(\.isManual).map(\.id), ["custom-provider/vision-model-v1"])
        XCTAssertEqual(store.imageModels.map(\.id), ["custom-provider/vision-model-v1"])
        XCTAssertTrue(store.profile(for: "custom-provider/vision-model-v1")?.supportsReferenceImage == true)
        XCTAssertEqual(store.baseURL, "http://127.0.0.1:11435/v1")
        XCTAssertTrue(store.token.isEmpty)
    }

    @MainActor func testManualModelRegistrationRejectsIncompleteOrWhitespaceModelIdentifiers() {
        let store = AppStore()

        XCTAssertFalse(store.registerManualModel(
            providerName: "",
            modelID: "provider/model",
            operations: [.chat]
        ))
        XCTAssertFalse(store.registerManualModel(
            providerName: "任意厂商",
            modelID: "provider/model with space",
            operations: [.chat]
        ))
        XCTAssertFalse(store.registerManualModel(
            providerName: "任意厂商",
            modelID: "provider/model",
            operations: []
        ))
        XCTAssertTrue(store.manualModels.isEmpty)
        XCTAssertTrue(store.models.isEmpty)
    }

    @MainActor func testManualModelPersistsAndCanBeRemovedWithoutAffectingModelHubSettings() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "visionstack-manual-model-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let offlineFactory: AppStore.ModelHubFactory = { _, _ in throw VisionStackError.server("离线") }
        let store = AppStore(persistence: PersistenceService(root: root), modelHubFactory: offlineFactory)
        store.baseURL = "http://127.0.0.1:11435/v1"
        XCTAssertTrue(store.registerManualModel(
            providerName: "自定义视频厂商",
            modelID: "video-lab/cinema-v2",
            operations: [.video],
            videoResolutions: ["1080p"],
            aspectRatios: ["16:9"],
            durations: [5, 10]
        ))
        await store.flushPersistence()

        let reloaded = AppStore(persistence: PersistenceService(root: root), modelHubFactory: offlineFactory)
        await reloaded.bootstrap()

        XCTAssertEqual(reloaded.manualModels.map(\.id), ["video-lab/cinema-v2"])
        XCTAssertEqual(reloaded.videoModels.map(\.id), ["video-lab/cinema-v2"])
        XCTAssertTrue(reloaded.removeManualModel(modelID: "video-lab/cinema-v2"))
        XCTAssertTrue(reloaded.manualModels.isEmpty)
        XCTAssertTrue(reloaded.videoModels.isEmpty)
        XCTAssertEqual(reloaded.baseURL, "http://127.0.0.1:11435/v1")
    }

    @MainActor func testModelHubRefreshKeepsManualModelsFromUnlistedProviders() async {
        let official = ModelDescriptor(id: "official/chat", owner: "官方厂商", availability: "available")
        let officialProfile = CapabilityProfile(modelID: official.id, operations: [.chat], source: .modelHub)
        let fake = FakeModelHubService(catalog: .init(models: [official], embeddedCapabilities: [officialProfile]))
        let store = AppStore(modelHubFactory: { _, _ in fake })
        XCTAssertTrue(store.registerManualModel(
            providerName: "目录外厂商",
            modelID: "outside/image-v1",
            operations: [.image],
            imageSizes: ["1024x1024"],
            qualities: ["auto"]
        ))

        await store.refreshModelHub()

        XCTAssertEqual(Set(store.models.map(\.id)), Set(["official/chat", "outside/image-v1"]))
        XCTAssertEqual(store.manualModels.map(\.id), ["outside/image-v1"])
        XCTAssertEqual(store.chatModels.map(\.id), ["official/chat"])
        XCTAssertEqual(store.imageModels.map(\.id), ["outside/image-v1"])
    }

    @MainActor func testBootstrapCreatesDefaultProjectAndConversationOwnership() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "visionstack-project-bootstrap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(persistence: PersistenceService(root: root), modelHubFactory: { _, _ in throw VisionStackError.server("离线") })

        await store.bootstrap()

        let project = try XCTUnwrap(store.selectedProject)
        XCTAssertEqual(project.name, "默认项目")
        XCTAssertEqual(store.conversations.first?.projectID, project.id)
    }

    func testKeychainReadNeverRunsOnMainThread() async {
        let observation = ThreadObservation()

        let token = await KeychainStore.readTokenAsync(using: {
            observation.record(Thread.isMainThread)
            return "fixture-token"
        })

        XCTAssertEqual(token, "fixture-token")
        XCTAssertEqual(observation.value, false)
    }

    @MainActor func testConversationArchiveAndCrossModeTransferPreserveContent() {
        let root = FileManager.default.temporaryDirectory.appending(path: "visionstack-conversation-transfer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(persistence: PersistenceService(root: root))
        store.projects = [CreativeProject(name: "测试项目")]
        store.selectedProjectID = store.projects[0].id
        store.createConversation()
        let conversationID = store.selectedConversationID

        store.transferText("一座雨夜车站", to: .image)
        XCTAssertEqual(store.mode, .image)
        XCTAssertEqual(store.imagePromptDraft, "一座雨夜车站")

        if let conversationID { store.archiveConversation(conversationID) }
        XCTAssertNotNil(store.conversations.first?.archivedAt)
        if let conversationID { store.restoreConversation(conversationID) }
        XCTAssertNil(store.conversations.first?.archivedAt)
    }

    @MainActor func testDefaultTestStoreNeverWritesRealApplicationSupportState() async throws {
        let realState = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "VisionStack/state.json")
        let before = try? Data(contentsOf: realState)
        let store = AppStore()
        store.projects = [CreativeProject(name: "隔离门禁")]
        store.selectedProjectID = store.projects[0].id
        store.createConversation()
        await store.flushPersistence()
        let after = try? Data(contentsOf: realState)
        XCTAssertEqual(after, before)
    }

    func testMediaHealthAuditFindsMissingReferencesAndManagedOrphans() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "visionstack-media-health-\(UUID().uuidString)")
        let media = root.appending(path: "Media", directoryHint: .isDirectory)
        let orphan = media.appending(path: "orphan.png")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: orphan)
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = media.appending(path: "missing.png")
        let job = GenerationJob(kind: .image, prompt: "缺失", model: "fixture/image", parameters: [:], state: .succeeded, resultURLs: [missing.absoluteString])

        let report = try await PersistenceService(root: root).auditMedia(jobs: [job], references: [])

        XCTAssertEqual(report.missingJobFiles, [missing.path])
        XCTAssertEqual(report.orphanedManagedFiles, [orphan.path])
        XCTAssertEqual(report.issueCount, 2)
    }

    @MainActor func testReferenceLibraryPersistsListsReusesAndDeletesWithinCurrentProject() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "visionstack-reference-library-\(UUID().uuidString)")
        let source = root.appending(path: "source.png")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try writeValidReferencePNG(to: source)

        let project = CreativeProject(name: "当前项目")
        let otherProject = CreativeProject(name: "其他项目")
        let persistence = PersistenceService(root: root)
        var imported = try await persistence.importReference(from: source)
        imported.projectID = project.id
        let fake = FakeModelHubService()
        let model = ModelDescriptor(id: "qwen-image-3.0-pro", owner: "provider", availability: "available")
        let store = AppStore(persistence: persistence, modelHubFactory: { _, _ in fake })
        store.projects = [project, otherProject]
        store.selectedProjectID = project.id
        store.referenceAssets = [imported]
        // This fixture explicitly consents before exercising only its injected fake provider.
        store.acceptThirdPartyAIConsent()
        store.connection = .connected(1)
        store.models = [model]
        store.capabilities[model.id] = CapabilityProfile(
            modelID: model.id,
            operations: [.image],
            source: .modelHub,
            inputModalities: ["text", "image"]
        )
        await store.flushPersistence()

        let reloaded = AppStore(persistence: PersistenceService(root: root), modelHubFactory: { _, _ in fake })
        await reloaded.bootstrap()
        reloaded.connection = .connected(1)
        reloaded.models = [model]
        reloaded.capabilities[model.id] = store.capabilities[model.id]

        XCTAssertEqual(reloaded.currentProjectReferenceAssets.map(\.id), [imported.id])
        XCTAssertTrue(URL(string: imported.localURL).map { FileManager.default.fileExists(atPath: $0.path) } == true)

        await reloaded.generateImage(
            prompt: "保留参考图中的主体",
            size: "1024x1024",
            quality: "auto",
            model: model.id,
            referenceAssetID: imported.id,
            confirmBillable: true
        )

        let submittedReferences = await fake.receivedImageReferences
        let submitted = try XCTUnwrap(submittedReferences.first ?? nil)
        XCTAssertTrue(submitted.hasPrefix("data:image/png;base64,"))
        XCTAssertFalse(submitted.contains(imported.localURL))
        XCTAssertFalse(submitted.hasPrefix("file:"))
        XCTAssertEqual(reloaded.imageJobs.first?.referenceAssetID, imported.id)

        reloaded.imageJobs.removeAll()
        await reloaded.deleteReference(imported)

        XCTAssertTrue(reloaded.currentProjectReferenceAssets.isEmpty)
        XCTAssertTrue(URL(string: imported.localURL).map { !FileManager.default.fileExists(atPath: $0.path) } == true)
    }

    @MainActor func testImageGenerationRejectsReferenceOwnedByAnotherProjectBeforeSubmitting() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "visionstack-reference-project-isolation-\(UUID().uuidString)")
        let references = root.appending(path: "References", directoryHint: .isDirectory)
        let managedFile = references.appending(path: "other-project.png")
        try FileManager.default.createDirectory(at: references, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try writeValidReferencePNG(to: managedFile)

        let currentProject = CreativeProject(name: "当前项目")
        let otherProject = CreativeProject(name: "其他项目")
        let foreignReference = ReferenceAsset(
            name: "其他项目参考图",
            localURL: managedFile.absoluteString,
            projectID: otherProject.id
        )
        let fake = FakeModelHubService()
        let model = ModelDescriptor(id: "qwen-image-3.0-pro", owner: "provider", availability: "available")
        let store = AppStore(persistence: PersistenceService(root: root), modelHubFactory: { _, _ in fake })
        store.projects = [currentProject, otherProject]
        store.selectedProjectID = currentProject.id
        store.referenceAssets = [foreignReference]
        // This fixture explicitly consents before exercising only its injected fake provider.
        store.acceptThirdPartyAIConsent()
        store.connection = .connected(1)
        store.models = [model]
        store.capabilities[model.id] = CapabilityProfile(
            modelID: model.id,
            operations: [.image],
            source: .modelHub,
            inputModalities: ["text", "image"]
        )

        await store.generateImage(
            prompt: "不应跨项目使用",
            size: "1024x1024",
            quality: "auto",
            model: model.id,
            referenceAssetID: foreignReference.id,
            confirmBillable: true
        )

        let submittedReferences = await fake.receivedImageReferences
        XCTAssertTrue(submittedReferences.isEmpty)
        XCTAssertTrue(store.imageJobs.isEmpty)
        XCTAssertTrue(store.notice?.contains("不属于当前项目") == true)
    }

    @MainActor func testUsedOrArchivedProjectReferenceCannotBePermanentlyDeleted() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "visionstack-reference-delete-lifecycle-\(UUID().uuidString)")
        let references = root.appending(path: "References", directoryHint: .isDirectory)
        let managedFile = references.appending(path: "protected.png")
        try FileManager.default.createDirectory(at: references, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try writeValidReferencePNG(to: managedFile)

        var archivedProject = CreativeProject(name: "已归档项目")
        archivedProject.archivedAt = Date()
        let asset = ReferenceAsset(name: "受保护参考图", localURL: managedFile.absoluteString, projectID: archivedProject.id)
        let referencingJob = GenerationJob(
            kind: .image,
            prompt: "已使用参考图",
            model: "qwen-image-3.0-pro",
            parameters: [:],
            state: .succeeded,
            referenceAssetID: asset.id,
            projectID: archivedProject.id
        )
        let store = AppStore(persistence: PersistenceService(root: root))
        store.projects = [archivedProject]
        store.referenceAssets = [asset]
        store.imageJobs = [referencingJob]

        await store.deleteReference(asset)

        XCTAssertEqual(store.referenceAssets.map(\.id), [asset.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: managedFile.path))
        XCTAssertTrue(store.notice?.contains("仍被 1 个任务或分镜引用") == true)

        store.imageJobs.removeAll()
        await store.deleteReference(asset)

        XCTAssertEqual(store.referenceAssets.map(\.id), [asset.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: managedFile.path))
        XCTAssertTrue(store.notice?.contains("已归档项目") == true)
    }

    func testMediaConfirmationStatePresentsDeleteAndDismissesCleanly() {
        var state = MediaConfirmationState()

        state.request(.delete)

        XCTAssertTrue(state.isPresented)
        XCTAssertEqual(state.pending, .delete)

        state.dismiss()

        XCTAssertFalse(state.isPresented)
        XCTAssertNil(state.pending)
    }

    func testDeleteConfirmationUsesExplicitDestructiveCopy() {
        let content = MediaPendingConfirmation.delete.content(for: .image)

        XCTAssertEqual(content.title, "删除这项图片任务？")
        XCTAssertEqual(content.primaryButtonTitle, "删除任务和全部本地文件")
        XCTAssertTrue(content.isDestructive)
        XCTAssertTrue(content.message.contains("无法撤销"))
    }

    @MainActor func testDeleteImageJobRemovesRecordAndManagedMedia() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "visionstack-delete-job-\(UUID().uuidString)")
        let mediaDirectory = root.appending(path: "Media", directoryHint: .isDirectory)
        let mediaURL = mediaDirectory.appending(path: "failed-image.png")
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: mediaURL)
        let job = GenerationJob(
            kind: .image,
            prompt: "待删除失败任务",
            model: "fixture/image",
            parameters: [:],
            state: .failed,
            resultURLs: [mediaURL.absoluteString]
        )
        let store = AppStore(persistence: PersistenceService(root: root))
        store.imageJobs = [job]

        await store.deleteImageJob(job)

        XCTAssertFalse(store.imageJobs.contains(where: { $0.id == job.id }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mediaURL.path))
    }

    @MainActor func testExplicitDeleteRemovesFailedLegacyJobEvenWhenItContainsRemoteResultHint() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "visionstack-delete-failed-remote-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let job = GenerationJob(
            kind: .image,
            prompt: "尺寸报错",
            model: "qwen-image-3.0-pro",
            parameters: ["size": "1024x1024"],
            state: .failed,
            remoteResultURLs: ["https://example.com/request-diagnostic"],
            providerState: .failed,
            archiveState: .notRequired
        )
        let store = AppStore(persistence: PersistenceService(root: root))
        store.imageJobs = [job]

        await store.deleteImageJob(job)

        XCTAssertTrue(store.imageJobs.isEmpty)
    }

    func testMultimodalRegistryKeepsBothImageAndVideo() {
        let p = CapabilityRegistry.profile(for: "vendor/grok-imagine")
        XCTAssertTrue(p.operations.contains(.image)); XCTAssertTrue(p.operations.contains(.video))
    }
    func testUnknownModelRequiresConfiguration() {
        let p = CapabilityRegistry.profile(for: "vendor/new-model-without-metadata")
        XCTAssertTrue(p.operations.isEmpty); XCTAssertEqual(p.source, .unknown)
    }
    func testProviderPrefixDoesNotMisclassifyChatModelAsVideo() {
        let p = CapabilityRegistry.profile(for: "seedance/gpt-5.6-terra")
        XCTAssertTrue(p.operations.contains(.chat))
        XCTAssertFalse(p.operations.contains(.video))
        XCTAssertTrue(p.isConfigured)
        XCTAssertEqual(p.source, .bundledProfile)
    }

    @MainActor func testBundledHighConfidenceProfileEntersOnlyMatchingModelRouting() {
        let store = AppStore()
        let model = ModelDescriptor(id: "seedance/gpt-5.6-terra", owner: "seedance", availability: "available")
        store.models = [model]
        store.capabilities[model.id] = CapabilityRegistry.profile(for: model.id)
        XCTAssertEqual(store.chatModels.map(\.id), [model.id])
        XCTAssertTrue(store.imageModels.isEmpty)
        XCTAssertTrue(store.videoModels.isEmpty)
    }

    @MainActor func testModelSelectionDirectoryIncludesEveryAvailableModel() {
        let store = AppStore()
        let declared = ModelDescriptor(id: "provider/declared-video", owner: "provider", availability: "available")
        let candidate = ModelDescriptor(id: "seedance/doubao-seedance-2.0-fast", owner: "seedance", availability: "available")
        let unclassified = ModelDescriptor(id: "provider/special-motion", owner: "provider", availability: "available")
        let offline = ModelDescriptor(id: "provider/offline-video", owner: "provider", availability: "offline")
        store.models = [unclassified, offline, candidate, declared]
        store.capabilities[declared.id] = CapabilityProfile(modelID: declared.id, operations: [.video], source: .modelHub)
        store.capabilities[candidate.id] = CapabilityRegistry.profile(for: candidate.id)

        XCTAssertEqual(
            store.selectableModels(for: .video).map(\.id),
            [declared.id, candidate.id, unclassified.id]
        )
    }

    @MainActor func testSelectingUnclassifiedModelRequiresExplicitCapabilityEditing() {
        let store = AppStore()
        let model = ModelDescriptor(id: "provider/special-motion", owner: "provider", availability: "available")
        store.models = [model]
        store.capabilities[model.id] = CapabilityRegistry.profile(for: model.id)

        XCTAssertFalse(store.selectModel(model.id, for: .video))
        XCTAssertEqual(store.preferredVideoModel, "")
        XCTAssertEqual(store.profile(for: model.id)?.source, .unknown)
        XCTAssertNil(store.customCapabilities[model.id])
        XCTAssertTrue(store.videoModels.isEmpty)
    }
    @MainActor func testUnavailableConfiguredModelDoesNotEnterExecutableRouting() {
        let store = AppStore()
        let model = ModelDescriptor(id: "provider/image", owner: "provider", availability: "offline")
        store.models = [model]
        store.capabilities[model.id] = CapabilityProfile(modelID: model.id, operations: [.image], source: .modelHub)
        XCTAssertTrue(store.imageModels.isEmpty)
    }

    @MainActor func testCapabilityWizardOnlyAdoptsExplicitlySelectedCandidates() {
        let store = AppStore()
        let image = ModelDescriptor(id: "provider/qwen-image-3.0-pro", owner: "provider", availability: "available")
        let video = ModelDescriptor(id: "provider/wan2-video", owner: "provider", availability: "available")
        store.models = [image, video]

        store.adoptCapabilityCandidates([image.id])

        XCTAssertTrue(store.profile(for: image.id)?.isConfigured == true)
        XCTAssertFalse(store.profile(for: video.id)?.isConfigured == true)
    }
    func testEmptyVideoResponseIsNotSuccess() {
        let p = ModelHubResponseParser.parse(["status": "accepted"])
        XCTAssertNil(p.taskID); XCTAssertTrue(p.mediaURLs.isEmpty); XCTAssertNil(p.state)
    }
    func testSemanticTaskParsing() {
        let p = ModelHubResponseParser.parse(["data": [["id": "asset", "url": "https://example.com/v.mp4"]], "task_id": "task-1"])
        XCTAssertEqual(p.taskID, "task-1"); XCTAssertEqual(p.mediaURLs, ["https://example.com/v.mp4"])
    }
    func testTopLevelFailedStateWins() {
        XCTAssertEqual(ModelHubResponseParser.jobState(in: ["status": "failed", "data": ["status": "completed"]]), .failed)
    }
    func testLoopbackValidation() {
        XCTAssertThrowsError(try ModelHubClient(baseURL: "https://example.com/v1", token: "x"))
        XCTAssertNoThrow(try ModelHubClient(baseURL: "http://127.0.0.1:11435/v1", token: ""))
    }
    func testQwenImageRequestNormalizesDimensionsToProviderFormat() {
        let body = ModelHubProtocolParser.imageBody(
            model: "qwen-image-3.0-pro",
            prompt: "测试",
            size: "1024x1024",
            quality: "auto",
            confirmBillable: true
        )
        XCTAssertEqual(body["size"] as? String, "1024*1024")
    }
    func testCurrentModelHubCapabilityProtocolShape() {
        let profile = ModelHubProtocolParser.capability(from: [
            "id": "provider/wan2.7-image",
            "capabilities": ["imageGeneration"],
            "constraints": [
                "input_modalities": ["text", "image"],
                "output_modalities": ["image"],
                "image": ["sizes": ["1K", "2K"], "aspect_ratios": ["1:1", "16:9"]]
            ]
        ])
        XCTAssertEqual(profile?.operations, [.image])
        XCTAssertEqual(profile?.imageSizes, ["1K", "2K"])
        XCTAssertEqual(profile?.aspectRatios, ["1:1", "16:9"])
        XCTAssertEqual(profile?.source, .modelHub)
        XCTAssertTrue(profile?.supportsReferenceImage == true)
    }

    func testImageCapabilityParsesCustomPixelBounds() {
        let profile = ModelHubProtocolParser.capability(from: [
            "id": "provider/qwen-image",
            "capabilities": ["imageGeneration"],
            "constraints": [
                "output_modalities": ["image"],
                "image": [
                    "width_pixels": ["minimum": 512, "maximum": 2048],
                    "height_pixels": ["minimum": 512, "maximum": 2048]
                ]
            ]
        ])

        XCTAssertEqual(profile?.imageMinimumWidth, 512)
        XCTAssertEqual(profile?.imageMaximumWidth, 2048)
        XCTAssertEqual(profile?.imageMinimumHeight, 512)
        XCTAssertEqual(profile?.imageMaximumHeight, 2048)
    }

    func testCustomImageDimensionsAreValidatedBeforeBuildingRequestValue() {
        let profile = CapabilityProfile(
            modelID: "provider/qwen-image",
            operations: [.image],
            source: .modelHub,
            imageMinimumWidth: 512,
            imageMaximumWidth: 2048,
            imageMinimumHeight: 512,
            imageMaximumHeight: 2048
        )

        XCTAssertEqual(ImageDimensionPolicy.validation(width: 1024, height: 1536, profile: profile), .valid)
        XCTAssertEqual(ImageDimensionPolicy.validation(width: 256, height: 1024, profile: profile), .invalid("宽度需在 512–2048 像素之间"))
        XCTAssertEqual(ImageDimensionPolicy.requestValue(width: 1024, height: 1536), "1024x1536")
    }

    func testCatalogPreservesRouteMetadata() {
        let catalog = ModelHubProtocolParser.catalog(from: [[
            "id": "inkos", "owned_by": "modelhub-route", "availability": "available",
            "source": "route", "constraint_scope": "provider_specific", "capabilities": []
        ]])
        XCTAssertEqual(catalog.models.count, 1)
        XCTAssertTrue(catalog.models[0].isRoute)
        XCTAssertEqual(catalog.models[0].constraintScope, "provider_specific")
    }

    func testModelIDIsEncodedAsOnePathSegment() {
        XCTAssertEqual(ModelHubProtocolParser.encodedPathSegment("供应商 A/model name"), "%E4%BE%9B%E5%BA%94%E5%95%86%20A%2Fmodel%20name")
    }

    func testBillableConfirmationIsIncludedInGenerationContracts() {
        let image = ModelHubProtocolParser.imageBody(model: "p/image", prompt: "x", size: "1K", quality: "", confirmBillable: true)
        let video = ModelHubProtocolParser.videoBody(model: "p/video", prompt: "x", size: "720p", ratio: "16:9", duration: 5, confirmBillable: true)
        XCTAssertEqual(image["confirm_billable"] as? Bool, true)
        XCTAssertEqual(video["confirm_billable"] as? Bool, true)
    }

    func testConversationSendIsImmediateWhileGeneratedMediaKeepsConfirmation() {
        XCTAssertFalse(BillingConfirmationPresentation.requiresModal(for: .chat))
        XCTAssertTrue(BillingConfirmationPresentation.requiresModal(for: .image))
        XCTAssertTrue(BillingConfirmationPresentation.requiresModal(for: .video))
    }

    func testProviderUsageAndCostAreParsedWithoutTreatingUnknownAsZero() {
        let priced = ModelHubResponseParser.parse([
            "status": "completed",
            "usage": ["input_tokens": 120, "output_tokens": 30, "total_cost": "1.25", "currency": "CNY"]
        ])
        let unknown = ModelHubResponseParser.parse(["status": "completed"])

        XCTAssertEqual(priced.cost?.actualAmount, Decimal(string: "1.25"))
        XCTAssertEqual(priced.cost?.inputTokens, 120)
        XCTAssertTrue(priced.cost?.providerReported == true)
        XCTAssertNil(unknown.cost)
    }

    func testResumeCheckpointNameIsStableAndDoesNotExposeSignedURL() {
        let remote = "https://provider.example/video.mp4?token=private"
        let first = PersistenceService.downloadCheckpointName(for: remote)
        let second = PersistenceService.downloadCheckpointName(for: remote)
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.hasSuffix(".resume"))
        XCTAssertFalse(first.contains("private"))
        XCTAssertFalse(first.contains("provider.example"))
    }

    func testBillingErrorsCloseTheGate() {
        XCTAssertTrue(ModelHubProtocolParser.isBillingBlocked(statusCode: 402, response: [:]))
        XCTAssertTrue(ModelHubProtocolParser.isBillingBlocked(statusCode: 429, response: ["error": ["code": "insufficient_balance", "message": "余额不足"]]))
        XCTAssertFalse(ModelHubProtocolParser.isBillingBlocked(statusCode: 429, response: ["error": ["code": "rate_limit", "message": "too many requests"]]))
    }

    func testContextBudgetKeepsNewestMessagesWithinLimit() {
        let messages = (0..<30).map { index in
            StudioMessage(role: index.isMultiple(of: 2) ? .user : .assistant, content: "第\(index)条" + String(repeating: "内容", count: 500))
        }
        let prepared = ContextBudget.prepare(
            systemPrompt: String(repeating: "系统规则", count: 2_000),
            evidence: String(repeating: "外部证据", count: 1_000),
            conversation: messages,
            maxInputTokens: 4_096
        )
        XCTAssertLessThanOrEqual(prepared.report.estimatedTokens, 4_096)
        XCTAssertGreaterThan(prepared.report.droppedMessageCount, 0)
        XCTAssertTrue(prepared.report.truncatedSystemPrompt)
        XCTAssertTrue(prepared.messages.last?["content"]?.contains("第29条") == true)
    }

    func testContextEstimateIsConservativeForChineseAndASCII() {
        XCTAssertEqual(ContextBudget.estimateTokens("中文测试"), 4)
        XCTAssertEqual(ContextBudget.estimateTokens("abcdefgh"), 2)
    }

    func testQwenReferenceImageUsesModelConsumableMultimodalContent() throws {
        let dataURL = "data:image/png;base64,AAAA"
        let image = ModelHubProtocolParser.imageBody(model: "qwen-image-3.0-pro", prompt: "按照参考图生成", size: "1024x1024", quality: "", referenceImage: dataURL, confirmBillable: true)
        let input = try XCTUnwrap(image["input"] as? [String: Any])
        let messages = try XCTUnwrap(input["messages"] as? [[String: Any]])
        let firstMessage = try XCTUnwrap(messages.first)
        let content = try XCTUnwrap(firstMessage["content"] as? [[String: String]])

        XCTAssertEqual(firstMessage["role"] as? String, "user")
        XCTAssertEqual(content.compactMap { $0["image"] }, [dataURL])
        XCTAssertEqual(content.compactMap { $0["text"] }, ["按照参考图生成"])
        XCTAssertFalse(content.compactMap { $0["image"] }.contains { $0.hasPrefix("file:") })
    }

    func testQwenReferenceImagesPreserveIdentityThenPhotographyOrder() throws {
        let identity = "data:image/png;base64,aWRlbnRpdHk="
        let photography = "data:image/png;base64,cGhvdG9ncmFwaHk="
        let image = ModelHubProtocolParser.imageBody(
            model: "qwen-image-3.0-pro",
            prompt: "按角色使用两张参考图",
            size: "1024x1024",
            quality: "auto",
            referenceImages: [identity, photography],
            confirmBillable: true
        )
        XCTAssertEqual(image["image_url"] as? String, identity)
        let input = try XCTUnwrap(image["input"] as? [String: Any])
        let messages = try XCTUnwrap(input["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.first?["content"] as? [[String: String]])
        XCTAssertEqual(content.compactMap { $0["image"] }, [identity, photography])
        XCTAssertEqual(content.compactMap { $0["text"] }, ["按角色使用两张参考图"])
    }

    func testVideoReferenceImageKeepsGatewayImageURLField() {
        let dataURL = "data:image/png;base64,AAAA"
        let video = ModelHubProtocolParser.videoBody(model: "p/video", prompt: "x", size: "720p", ratio: "16:9", duration: 5, referenceImage: dataURL, confirmBillable: true)
        XCTAssertEqual(video["image_url"] as? String, dataURL)
    }

    func testStoryboardTimelineUsesShotOrderAndDuration() {
        let second = StoryboardShot(order: 1, title: "二", prompt: "B", durationSeconds: 5)
        let first = StoryboardShot(order: 0, title: "一", prompt: "A", durationSeconds: 3)
        let segments = StoryboardTimelineLayout.segments(for: [second, first])
        XCTAssertEqual(segments.map(\.shotID), [first.id, second.id])
        XCTAssertEqual(segments.map(\.startSeconds), [0, 3])
        XCTAssertEqual(segments.map(\.durationSeconds), [3, 5])
    }

    @MainActor func testVersionReviewScoresAndKeepsOneFinalVersionPerProject() {
        let store = AppStore()
        let project = CreativeProject(name: "版本评审")
        let first = GenerationJob(kind: .image, prompt: "A", model: "fixture/image", parameters: [:], state: .succeeded, projectID: project.id)
        let second = GenerationJob(kind: .image, prompt: "B", model: "fixture/image", parameters: [:], state: .succeeded, projectID: project.id)
        store.projects = [project]
        store.selectedProjectID = project.id
        store.imageJobs = [first, second]

        store.updateVersionReview(jobID: first.id, score: 7, notes: "构图更好")
        store.markFinalVersion(jobID: first.id)
        store.markFinalVersion(jobID: second.id)

        XCTAssertEqual(store.versionReview(for: first.id)?.score, 5)
        XCTAssertEqual(store.versionReview(for: first.id)?.notes, "构图更好")
        XCTAssertFalse(store.versionReview(for: first.id)?.isFinal == true)
        XCTAssertTrue(store.versionReview(for: second.id)?.isFinal == true)
    }

    @MainActor func testChatResultCanBecomeStoryboardGroupWithoutEmptyLines() {
        let store = AppStore()
        let project = CreativeProject(name: "对话转分镜")
        store.projects = [project]
        store.selectedProjectID = project.id

        store.transferToStoryboardGroup("1. 远景：城市天际线\n\n- 中景：人物走入车站\n3、特写：手握车票")

        XCTAssertEqual(store.storyboardShots.map(\.title), ["镜头 1", "镜头 2", "镜头 3"])
        XCTAssertEqual(store.storyboardShots.map(\.prompt), ["远景：城市天际线", "中景：人物走入车站", "特写：手握车票"])
        XCTAssertEqual(store.mode, .video)
    }

    func testProjectCostLedgerSeparatesKnownUnknownAndProviderReportedCosts() {
        let known = GenerationJob(
            kind: .image,
            prompt: "已知",
            model: "fixture/image",
            parameters: [:],
            state: .succeeded,
            cost: JobCostRecord(currency: "CNY", estimatedAmount: nil, actualAmount: Decimal(string: "1.25"), inputTokens: nil, outputTokens: nil, providerReported: true)
        )
        let estimated = GenerationJob(
            kind: .video,
            prompt: "估算",
            model: "fixture/video",
            parameters: [:],
            state: .running,
            cost: JobCostRecord(currency: "CNY", estimatedAmount: Decimal(string: "2.50"), actualAmount: nil, inputTokens: nil, outputTokens: nil, providerReported: false)
        )
        let unknown = GenerationJob(kind: .video, prompt: "未知", model: "fixture/video", parameters: [:], state: .failed)

        let summary = ProjectCostLedger.summary(for: [known, estimated, unknown])

        XCTAssertEqual(summary.knownTotal, Decimal(string: "3.75"))
        XCTAssertEqual(summary.knownCount, 2)
        XCTAssertEqual(summary.unknownCount, 1)
        XCTAssertEqual(summary.providerReportedCount, 1)
    }

    func testStoryboardBatchPreviewRespectsConcurrencyAndShowsKnownBudget() {
        let shots = (0..<4).map { StoryboardShot(order: $0, title: "镜头 \($0 + 1)", prompt: "P\($0)", durationSeconds: 5) }

        let preview = StoryboardBatchPlanner.preview(
            shots: shots,
            availableSlots: 2,
            knownCostPerRequest: Decimal(string: "1.50")
        )

        XCTAssertEqual(preview.acceptedShotIDs, Array(shots.prefix(2).map(\.id)))
        XCTAssertEqual(preview.deferredShotIDs, Array(shots.suffix(2).map(\.id)))
        XCTAssertEqual(preview.estimatedKnownCost, Decimal(string: "6.00"))
        XCTAssertEqual(preview.requestCount, 4)
    }

    func testCreativePresetMergesPromptBrandAndParametersWithoutDroppingUserText() {
        let preset = CreativePreset(
            name: "品牌新品",
            operation: .image,
            promptPrefix: "高级编辑摄影",
            brandStyle: "暖金、米白、克制留白",
            parameters: ["size": "1536x1024", "quality": "high"]
        )

        let applied = CreativePresetResolver.apply(
            preset,
            to: "拍摄一只手表",
            parameters: ["quality": "auto"]
        )

        XCTAssertTrue(applied.prompt.contains("拍摄一只手表"))
        XCTAssertTrue(applied.prompt.contains("高级编辑摄影"))
        XCTAssertTrue(applied.prompt.contains("暖金、米白、克制留白"))
        XCTAssertEqual(applied.parameters["size"], "1536x1024")
        XCTAssertEqual(applied.parameters["quality"], "high")
    }

    func testRoughCutTimelineOverlapsCrossDissolvesAndKeepsCaptions() {
        let first = RoughCutClip(jobID: UUID(), durationSeconds: 5, transition: .none, transitionDuration: 0, caption: "开场")
        let second = RoughCutClip(jobID: UUID(), durationSeconds: 4, transition: .crossDissolve, transitionDuration: 1, caption: "第二镜")

        let segments = RoughCutTimeline.segments(for: [first, second])

        XCTAssertEqual(segments.map(\.startSeconds), [0, 4])
        XCTAssertEqual(segments.map(\.durationSeconds), [5, 4])
        XCTAssertEqual(segments.map(\.caption), ["开场", "第二镜"])
        XCTAssertEqual(RoughCutTimeline.totalDuration(for: segments), 8)
    }

    @MainActor func testRoughCutExporterCreatesPlayableLocalMP4() async throws {
        let ffmpeg = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        let ffprobe = URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe")
        guard FileManager.default.isExecutableFile(atPath: ffmpeg.path),
              FileManager.default.isExecutableFile(atPath: ffprobe.path) else {
            throw XCTSkip("本机没有 ffmpeg/ffprobe，跳过本地草剪集成探针。")
        }
        let root = FileManager.default.temporaryDirectory.appending(path: "visionstack-rough-cut-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstURL = root.appending(path: "first.mp4")
        let secondURL = root.appending(path: "second.mp4")
        let audioURL = root.appending(path: "music.wav")
        let destination = root.appending(path: "rough-cut.mp4")

        try runProcess(ffmpeg, ["-y", "-f", "lavfi", "-i", "color=c=red:s=320x240:d=2", "-f", "lavfi", "-i", "sine=frequency=440:duration=2", "-c:v", "mpeg4", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", firstURL.path])
        try runProcess(ffmpeg, ["-y", "-f", "lavfi", "-i", "color=c=blue:s=320x240:d=2", "-f", "lavfi", "-i", "sine=frequency=660:duration=2", "-c:v", "mpeg4", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", secondURL.path])
        try runProcess(ffmpeg, ["-y", "-f", "lavfi", "-i", "sine=frequency=220:duration=3", audioURL.path])

        let projectID = UUID()
        let first = GenerationJob(kind: .video, prompt: "红色开场", model: "fixture/video", parameters: [:], state: .succeeded, resultURLs: [firstURL.absoluteString], projectID: projectID)
        let second = GenerationJob(kind: .video, prompt: "蓝色结尾", model: "fixture/video", parameters: [:], state: .succeeded, resultURLs: [secondURL.absoluteString], projectID: projectID)
        let cut = RoughCutProject(
            projectID: projectID,
            name: "集成探针",
            clips: [
                RoughCutClip(jobID: first.id, durationSeconds: 1.5, caption: "开场"),
                RoughCutClip(jobID: second.id, durationSeconds: 1.5, transition: .crossDissolve, transitionDuration: 0.5, caption: "结尾")
            ],
            backgroundAudioURL: audioURL.absoluteString
        )

        try await RoughCutExporter.export(cut, jobs: [first, second], to: destination)

        let values = try destination.resourceValues(forKeys: [.fileSizeKey])
        XCTAssertGreaterThan(values.fileSize ?? 0, 1_000)
        let probe = try runProcess(ffprobe, ["-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", destination.path])
        XCTAssertGreaterThan(Double(probe.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0, 2.0)
    }

    func testProjectBackupPackageCopiesMediaAndPassesHealthInspection() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "visionstack-project-package-\(UUID().uuidString)")
        let source = root.appending(path: "source.png")
        let package = root.appending(path: "测试项目.visionstackproject", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeValidReferencePNG(to: source)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = CreativeProject(name: "可恢复项目")
        let job = GenerationJob(kind: .image, prompt: "已完成", model: "fixture/image", parameters: [:], state: .succeeded, resultURLs: [source.absoluteString], projectID: project.id)
        let payload = ProjectBackupPayload(project: project, imageJobs: [job])

        let written = try ProjectBackupService.write(payload, to: package)
        let inspected = try ProjectBackupService.inspect(package)
        let loaded = try ProjectBackupService.load(package)

        XCTAssertTrue(written.isHealthy)
        XCTAssertTrue(inspected.isHealthy)
        XCTAssertEqual(inspected.mediaFileCount, 1)
        XCTAssertEqual(loaded.project.name, "可恢复项目")
        XCTAssertEqual(loaded.imageJobs.count, 1)
        XCTAssertFalse(loaded.imageJobs[0].resultURLs[0].hasPrefix("file:///Users/"))
    }

    @MainActor func testProjectBackupRestoresAsNewProjectWithManagedMedia() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "visionstack-project-restore-\(UUID().uuidString)")
        let persistenceRoot = root.appending(path: "ApplicationSupport")
        let source = root.appending(path: "source.png")
        let package = root.appending(path: "恢复探针.visionstackproject", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeValidReferencePNG(to: source)
        defer { try? FileManager.default.removeItem(at: root) }
        let archivedProject = CreativeProject(name: "待恢复项目")
        let archivedJob = GenerationJob(kind: .image, prompt: "恢复素材", model: "fixture/image", parameters: [:], state: .succeeded, resultURLs: [source.absoluteString], projectID: archivedProject.id)
        _ = try ProjectBackupService.write(ProjectBackupPayload(project: archivedProject, imageJobs: [archivedJob]), to: package)
        let existing = CreativeProject(name: "现有项目")
        let store = AppStore(persistence: PersistenceService(root: persistenceRoot))
        store.projects = [existing]
        store.selectedProjectID = existing.id

        await store.restoreProjectBackup(from: package)

        XCTAssertEqual(store.projects.count, 2)
        XCTAssertEqual(store.selectedProject?.name, "待恢复项目（恢复）")
        let restored = try XCTUnwrap(store.currentProjectImageJobs.first)
        let media = try XCTUnwrap(MediaFileActions.localURLs(for: restored).first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: media.path))
        XCTAssertTrue(media.path.hasPrefix(persistenceRoot.appending(path: "Media").path + "/"))
    }

    func testProjectBackupRejectsSymlinkThatEscapesPackage() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "visionstack-project-symlink-\(UUID().uuidString)")
        let source = root.appending(path: "source.png")
        let outside = root.appending(path: "outside.png")
        let package = root.appending(path: "逃逸.visionstackproject", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeValidReferencePNG(to: source)
        try writeValidReferencePNG(to: outside)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = CreativeProject(name: "路径防护")
        let job = GenerationJob(kind: .image, prompt: "图片", model: "fixture/image", parameters: [:], state: .succeeded, resultURLs: [source.absoluteString], projectID: project.id)
        _ = try ProjectBackupService.write(ProjectBackupPayload(project: project, imageJobs: [job]), to: package)
        let media = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: package.appending(path: "Media"), includingPropertiesForKeys: nil).first)
        try FileManager.default.removeItem(at: media)
        try FileManager.default.createSymbolicLink(at: media, withDestinationURL: outside)

        let health = try ProjectBackupService.inspect(package)

        XCTAssertFalse(health.isHealthy)
        XCTAssertEqual(health.unsafePaths.count, 1)
        XCTAssertThrowsError(try ProjectBackupService.load(package))
    }

    func testEightFeatureUpgradeEntrypointsAreVisibleInNativeUI() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = try ["ChatView.swift", "AssetLibraryView.swift", "ProjectWorkspaceView.swift", "TaskCenterView.swift", "CreativeWorkflowView.swift", "VideoStudioView.swift", "CreativeToolsView.swift"]
            .map { try String(contentsOf: root.appending(path: "Sources/VisionStack/\($0)"), encoding: .utf8) }
            .joined(separator: "\n")

        for requiredCopy in ["转生图", "版本评审", "项目工作区", "费用台账", "暂停批量", "备份与健康包", "创作预设", "视频草剪台"] {
            XCTAssertTrue(sources.contains(requiredCopy), "缺少界面入口：\(requiredCopy)")
        }
    }

    func testBatchAndStoryboardMetadataRoundTrip() throws {
        let referenceID = UUID()
        let shotID = UUID()
        let batchID = UUID()
        let job = GenerationJob(kind: .video, prompt: "镜头", model: "fixture/video", parameters: [:], state: .queued, batchID: batchID, versionIndex: 2, referenceAssetID: referenceID, storyboardShotID: shotID)
        let decoded = try JSONDecoder.visionStack.decode(GenerationJob.self, from: JSONEncoder.visionStack.encode(job))
        XCTAssertEqual(decoded.batchID, batchID)
        XCTAssertEqual(decoded.versionIndex, 2)
        XCTAssertEqual(decoded.referenceAssetID, referenceID)
        XCTAssertEqual(decoded.storyboardShotID, shotID)
    }
    func testSearchRedirectResolution() {
        XCTAssertEqual(WebSearchService.resolveDuckDuckGoURL("//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fa"), "https://example.com/a")
    }

    func testMultipleMediaResultsArePreserved() {
        let parsed = ModelHubResponseParser.parse([
            "data": [
                ["url": "https://example.com/1.png"],
                ["url": "https://example.com/2.png"]
            ]
        ])
        XCTAssertEqual(parsed.mediaURLs.count, 2)
    }

    func testAssetMetadataRoundTrip() throws {
        let job = GenerationJob(
            kind: .image,
            prompt: "测试提示词",
            model: "fixture/image",
            parameters: ["size": "1024x1024"],
            state: .succeeded,
            favorite: true,
            tags: ["终稿", "角色"],
            collection: "品牌片",
            parentJobID: UUID()
        )
        let data = try JSONEncoder.visionStack.encode(job)
        let decoded = try JSONDecoder.visionStack.decode(GenerationJob.self, from: data)
        XCTAssertEqual(decoded.tags, ["终稿", "角色"])
        XCTAssertEqual(decoded.collection, "品牌片")
        XCTAssertEqual(decoded.favorite, true)
        XCTAssertNotNil(decoded.parentJobID)
    }

    func testExportMetadataOmitsRawProviderPayloadAndPrivateRequestIdentity() throws {
        let secretURL = "https://provider.example/result.png?token=secret"
        let job = GenerationJob(
            kind: .image,
            prompt: "可交付提示词",
            model: "provider/image",
            parameters: ["size": "1K"],
            state: .succeeded,
            remoteResultURLs: [secretURL],
            rawResponse: "{\"secret\":\"provider-token\"}",
            clientRequestID: UUID(),
            idempotencyKey: "private-idempotency-key"
        )
        let data = try JSONEncoder.visionStack.encode(SafeJobExportMetadata(job: job))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(text.contains("可交付提示词"))
        XCTAssertFalse(text.contains("provider-token"))
        XCTAssertFalse(text.contains("private-idempotency-key"))
        XCTAssertFalse(text.contains("token=secret"))
    }

    func testGenerationRetryPlanPreservesOriginalJobInputsAndLinksToParent() throws {
        let referenceID = UUID()
        let shotID = UUID()
        let source = GenerationJob(
            kind: .video,
            prompt: "保留原始镜头描述",
            model: "provider/original-video",
            parameters: ["size": "1080p", "aspect_ratio": "16:9", "duration_seconds": "8"],
            state: .timedOut,
            remoteResultURLs: ["https://example.com/partial.mp4"],
            referenceAssetID: referenceID,
            storyboardShotID: shotID
        )

        let plan = try XCTUnwrap(GenerationRetryPlan(job: source))

        XCTAssertEqual(plan.kind.rawValue, GenerationKind.video.rawValue)
        XCTAssertEqual(plan.model, "provider/original-video")
        XCTAssertEqual(plan.prompt, "保留原始镜头描述")
        XCTAssertEqual(plan.parameters, ["size": "1080p", "aspect_ratio": "16:9", "duration_seconds": "8"])
        XCTAssertEqual(plan.referenceAssetID, referenceID)
        XCTAssertEqual(plan.storyboardShotID, shotID)
        XCTAssertEqual(plan.parentJobID, source.id)
        XCTAssertTrue(plan.hasRemoteResultURLs)
    }

    @MainActor func testRetryPlanKeepsOriginalModelWhenPreferredModelChanges() throws {
        let source = GenerationJob(
            kind: .image,
            prompt: "原图",
            model: "provider/original-image",
            parameters: ["size": "1K", "quality": "auto"],
            state: .failed
        )
        let store = AppStore()
        store.preferredImageModel = "provider/new-preferred-image"

        let plan = try XCTUnwrap(GenerationRetryPlan(job: source))

        XCTAssertEqual(plan.model, "provider/original-image")
        XCTAssertNotEqual(plan.model, store.preferredImageModel)
    }

    @MainActor func testRetryIsUnavailableWhenOriginalModelIsNoLongerConfigured() {
        let source = GenerationJob(
            kind: .image,
            prompt: "原图",
            model: "provider/removed-image",
            parameters: ["size": "1K", "quality": "auto"],
            state: .failed
        )
        let currentModel = ModelDescriptor(id: "provider/current-image", owner: "provider", availability: "available")
        let store = AppStore()
        store.connection = .connected(1)
        store.models = [currentModel]
        store.capabilities[currentModel.id] = CapabilityProfile(modelID: currentModel.id, operations: [.image], source: .modelHub)
        store.preferredImageModel = currentModel.id

        let availability = store.retryAvailability(for: source)

        XCTAssertFalse(availability.isAvailable)
        XCTAssertTrue(availability.reason?.contains("原模型") == true)
    }

    @MainActor func testRetryIsUnavailableWhenGenerationConcurrencyIsFull() {
        let model = ModelDescriptor(id: "provider/image", owner: "provider", availability: "available")
        let source = GenerationJob(
            kind: .image,
            prompt: "失败任务",
            model: model.id,
            parameters: ["size": "1K", "quality": "auto"],
            state: .failed
        )
        let active = GenerationJob(
            kind: .image,
            prompt: "活动任务",
            model: model.id,
            parameters: ["size": "1K", "quality": "auto"],
            state: .running
        )
        let store = AppStore()
        store.connection = .connected(1)
        store.models = [model]
        store.capabilities[model.id] = CapabilityProfile(modelID: model.id, operations: [.image], source: .modelHub)
        store.maxConcurrentGenerationTasks = 1
        store.imageJobs = [source, active]

        let availability = store.retryAvailability(for: source)

        XCTAssertFalse(availability.isAvailable)
        XCTAssertTrue(availability.reason?.contains("并发") == true)
    }

    @MainActor func testRetryIsUnavailableWhenSameParentHasActiveChildRetry() {
        let model = ModelDescriptor(id: "provider/video", owner: "provider", availability: "available")
        let source = GenerationJob(
            kind: .video,
            prompt: "失败镜头",
            model: model.id,
            parameters: ["size": "720p", "aspect_ratio": "16:9", "duration_seconds": "5"],
            state: .failed
        )
        let activeRetry = GenerationJob(
            kind: .video,
            prompt: source.prompt,
            model: source.model,
            parameters: source.parameters,
            state: .queued,
            parentJobID: source.id
        )
        let store = AppStore()
        store.connection = .connected(1)
        store.models = [model]
        store.capabilities[model.id] = CapabilityProfile(modelID: model.id, operations: [.video], source: .modelHub)
        store.videoJobs = [source, activeRetry]

        let availability = store.retryAvailability(for: source)

        XCTAssertFalse(availability.isAvailable)
        XCTAssertTrue(availability.reason?.contains("已有") == true)
    }

    @MainActor func testRemoteResultsRequireArchiveRecoveryInsteadOfBillableRetry() {
        let model = ModelDescriptor(id: "provider/image", owner: "provider", availability: "available")
        let source = GenerationJob(
            kind: .image,
            prompt: "归档失败仍可重试",
            model: model.id,
            parameters: ["size": "1K", "quality": "auto"],
            state: .failed,
            remoteResultURLs: ["https://example.com/result.png"]
        )
        let store = AppStore()
        store.connection = .connected(1)
        store.models = [model]
        store.capabilities[model.id] = CapabilityProfile(modelID: model.id, operations: [.image], source: .modelHub)

        let availability = store.retryAvailability(for: source)

        XCTAssertFalse(availability.isAvailable)
        XCTAssertTrue(availability.reason?.contains("存到本机") == true)
    }

    @MainActor func testRetryIsUnavailableForNonterminalOrBillingBlockedJob() {
        let model = ModelDescriptor(id: "provider/image", owner: "provider", availability: "available")
        var source = GenerationJob(
            kind: .image,
            prompt: "任务",
            model: model.id,
            parameters: ["size": "1K", "quality": "auto"],
            state: .running
        )
        let store = AppStore()
        store.connection = .connected(1)
        store.models = [model]
        store.capabilities[model.id] = CapabilityProfile(modelID: model.id, operations: [.image], source: .modelHub)

        XCTAssertFalse(store.retryAvailability(for: source).isAvailable)

        source.state = .failed
        store.billingGate = .blocked("余额不足")
        let availability = store.retryAvailability(for: source)
        XCTAssertFalse(availability.isAvailable)
        XCTAssertTrue(availability.reason?.contains("余额不足") == true)
    }

    func testMediaTerminalActionDistinguishesRetryFromNewVersion() {
        XCTAssertEqual(MediaTerminalAction(state: .failed), .retry)
        XCTAssertEqual(MediaTerminalAction(state: .timedOut), .retry)
        XCTAssertEqual(MediaTerminalAction(state: .succeeded), .newVersion)
        XCTAssertEqual(MediaTerminalAction(state: .cancelled), .newVersion)
    }

    func testGenerationJobTracksProviderAndArchiveLifecycleSeparately() {
        let requestID = UUID()
        let retryGroupID = UUID()
        let job = GenerationJob(
            kind: .image,
            prompt: "任务状态分离",
            model: "provider/image",
            parameters: ["size": "1K"],
            state: .needsArchive,
            remoteResultURLs: ["https://example.com/result.png"],
            submissionState: .submitted,
            providerState: .succeeded,
            archiveState: .failed,
            clientRequestID: requestID,
            idempotencyKey: "visionstack-\(requestID.uuidString)",
            retryGroupID: retryGroupID
        )

        XCTAssertEqual(job.submissionState, .submitted)
        XCTAssertEqual(job.providerState, .succeeded)
        XCTAssertEqual(job.archiveState, .failed)
        XCTAssertEqual(job.effectiveRetryGroupID, retryGroupID)
        XCTAssertTrue(job.requiresArchiveRecovery)
        XCTAssertFalse(job.canCreateBillableRetry)
    }

    func testRetryFamilyKeepsOneRootAcrossMultipleGenerations() {
        let rootID = UUID()
        let root = GenerationJob(
            id: rootID,
            kind: .video,
            prompt: "A",
            model: "provider/video",
            parameters: [:],
            state: .failed,
            retryGroupID: rootID
        )
        let child = GenerationJob(
            kind: .video,
            prompt: "B",
            model: root.model,
            parameters: [:],
            state: .failed,
            parentJobID: root.id,
            retryGroupID: root.effectiveRetryGroupID
        )
        let activeGrandchild = GenerationJob(
            kind: .video,
            prompt: "C",
            model: root.model,
            parameters: [:],
            state: .running,
            parentJobID: child.id,
            retryGroupID: root.effectiveRetryGroupID
        )

        XCTAssertEqual(child.effectiveRetryGroupID, rootID)
        XCTAssertEqual(activeGrandchild.effectiveRetryGroupID, rootID)
        XCTAssertTrue(GenerationRetryPolicy.hasActiveJob(in: rootID, jobs: [root, child, activeGrandchild]))
    }

    func testBillableGenerationContractCarriesStableIdempotencyIdentity() {
        let requestID = UUID()
        let context = BillableRequestContext(
            clientRequestID: requestID,
            idempotencyKey: "visionstack-\(requestID.uuidString)",
            confirmBillable: true
        )

        let image = ModelHubProtocolParser.imageBody(
            model: "p/image",
            prompt: "x",
            size: "1K",
            quality: "auto",
            requestContext: context
        )

        XCTAssertEqual(image["client_request_id"] as? String, requestID.uuidString)
        XCTAssertEqual(image["idempotency_key"] as? String, context.idempotencyKey)
        XCTAssertEqual(image["confirm_billable"] as? Bool, true)
    }

    @MainActor func testAmbiguousImageSubmissionIsReconciledInsteadOfMarkedRetryableFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "visionstack-ambiguous-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeModelHubService(imageError: URLError(.timedOut))
        let model = ModelDescriptor(id: "provider/image", owner: "provider", availability: "available")
        let store = AppStore(
            persistence: PersistenceService(root: root),
            modelHubFactory: { _, _ in fake }
        )
        // This fixture explicitly consents before exercising only its injected fake provider.
        store.acceptThirdPartyAIConsent()
        store.connection = .connected(1)
        store.models = [model]
        store.capabilities[model.id] = CapabilityProfile(modelID: model.id, operations: [.image], source: .modelHub)

        await store.generateImage(prompt: "不重复计费", size: "1K", quality: "auto", model: model.id, confirmBillable: true)

        let job = try XCTUnwrap(store.imageJobs.first)
        XCTAssertEqual(job.state, .submissionUnknown)
        XCTAssertEqual(job.submissionState, .unknown)
        XCTAssertEqual(job.providerState, .unknown)
        XCTAssertNotNil(job.clientRequestID)
        XCTAssertNotNil(job.idempotencyKey)
        XCTAssertFalse(store.retryAvailability(for: job).isAvailable)
        let contexts = await fake.receivedContexts
        XCTAssertEqual(contexts.first?.idempotencyKey, job.idempotencyKey)
    }

    @MainActor func testProviderSuccessWithArchiveFailureBecomesNeedsArchive() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "visionstack-archive-failure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = "data:image/png;base64,not-valid-base64"
        let fake = FakeModelHubService(imageResponse: .init(raw: "{}", taskID: "provider-result", mediaURLs: [remote], state: .succeeded, errorMessage: nil))
        let model = ModelDescriptor(id: "provider/image", owner: "provider", availability: "available")
        let store = AppStore(
            persistence: PersistenceService(root: root),
            modelHubFactory: { _, _ in fake }
        )
        // This fixture explicitly consents before exercising only its injected fake provider.
        store.acceptThirdPartyAIConsent()
        store.connection = .connected(1)
        store.models = [model]
        store.capabilities[model.id] = CapabilityProfile(modelID: model.id, operations: [.image], source: .modelHub)

        await store.generateImage(prompt: "先恢复归档", size: "1K", quality: "auto", model: model.id, confirmBillable: true)

        let job = try XCTUnwrap(store.imageJobs.first)
        XCTAssertEqual(job.state, .needsArchive)
        XCTAssertEqual(job.submissionState, .submitted)
        XCTAssertEqual(job.providerState, .succeeded)
        XCTAssertEqual(job.archiveState, .failed)
        XCTAssertEqual(job.remoteResultURLs, [remote])
        XCTAssertFalse(store.retryAvailability(for: job).isAvailable)
    }

    @MainActor func testRunningImageCannotBeDeletedAndCanBeStoppedWithoutLosingReconciliationRecord() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "visionstack-running-image-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeModelHubService()
        await fake.setImageDelayForTesting(.seconds(30))
        let model = ModelDescriptor(id: "provider/image", owner: "provider", availability: "available")
        let store = AppStore(persistence: PersistenceService(root: root), modelHubFactory: { _, _ in fake })
        // This fixture explicitly consents before exercising only its injected fake provider.
        store.acceptThirdPartyAIConsent()
        store.connection = .connected(1)
        store.models = [model]
        store.capabilities[model.id] = CapabilityProfile(modelID: model.id, operations: [.image], source: .modelHub)

        let generation = Task { await store.generateImage(prompt: "停止但不丢记录", size: "1K", quality: "auto", model: model.id, confirmBillable: true) }
        for _ in 0..<50 where store.imageJobs.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let running = try XCTUnwrap(store.imageJobs.first)

        await store.deleteImageJob(running)
        XCTAssertEqual(store.imageJobs.count, 1)
        XCTAssertTrue(store.notice?.contains("先停止") == true)

        await store.cancelImageJob(running.id)
        await generation.value

        let stopped = try XCTUnwrap(store.imageJobs.first)
        XCTAssertEqual(stopped.state, .cancelPending)
        XCTAssertEqual(stopped.providerState, .cancelPending)
        XCTAssertNotNil(stopped.clientRequestID)
        let wasCancelled = await fake.imageWasCancelledForTesting()
        XCTAssertTrue(wasCancelled)
    }

    @MainActor func testClearHistoryRefusesWhileAnyTaskNeedsReconciliation() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "visionstack-clear-active-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(persistence: PersistenceService(root: root))
        store.imageJobs = [GenerationJob(
            kind: .image,
            prompt: "未知提交",
            model: "provider/image",
            parameters: [:],
            state: .submissionUnknown,
            submissionState: .unknown,
            providerState: .unknown
        )]

        await store.clearGenerationHistory()

        XCTAssertEqual(store.imageJobs.count, 1)
        XCTAssertTrue(store.notice?.contains("不能清空") == true)
    }

    @MainActor func testVideoCancellationFailureKeepsTaskForLaterReconciliation() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "visionstack-cancel-failure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeModelHubService()
        await fake.setCancelErrorForTesting(URLError(.cannotConnectToHost))
        let store = AppStore(persistence: PersistenceService(root: root), modelHubFactory: { _, _ in fake })
        let job = GenerationJob(
            kind: .video,
            prompt: "取消待确认",
            model: "provider/video",
            parameters: [:],
            state: .running,
            taskID: "upstream-task",
            submissionState: .submitted,
            providerState: .running,
            archiveState: .pending
        )
        store.videoJobs = [job]

        await store.cancelVideoJob(job.id)

        let retained = try XCTUnwrap(store.videoJobs.first)
        XCTAssertEqual(retained.state, .cancelPending)
        XCTAssertEqual(retained.providerState, .cancelPending)
        XCTAssertEqual(retained.taskID, "upstream-task")
    }

    @MainActor func testVideoInitialSubmissionTaskIsOwnedAndCancellable() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "visionstack-running-video-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeModelHubService()
        await fake.setVideoDelayForTesting(.seconds(3))
        let model = ModelDescriptor(id: "provider/video", owner: "provider", availability: "available")
        let store = AppStore(persistence: PersistenceService(root: root), modelHubFactory: { _, _ in fake })
        // This fixture explicitly consents before exercising only its injected fake provider.
        store.acceptThirdPartyAIConsent()
        store.connection = .connected(1)
        store.models = [model]
        store.capabilities[model.id] = CapabilityProfile(modelID: model.id, operations: [.video], source: .modelHub)

        let generation = Task { await store.generateVideo(prompt: "停止视频提交", size: "720p", ratio: "16:9", duration: 5, model: model.id, confirmBillable: true) }
        for _ in 0..<50 where store.videoJobs.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let running = try XCTUnwrap(store.videoJobs.first)

        await store.cancelVideoJob(running.id)
        _ = await generation.value

        let retained = try XCTUnwrap(store.videoJobs.first)
        XCTAssertEqual(retained.state, .cancelPending)
        XCTAssertNotNil(retained.idempotencyKey)
        let cancelled = await fake.videoWasCancelledForTesting()
        XCTAssertTrue(cancelled)
    }

    @MainActor func testRepeatedVideoPollingErrorsBecomeReconciliationStateInsteadOfBillableFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "visionstack-video-poll-degraded-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeModelHubService()
        await fake.setVideoTaskErrorForTesting(URLError(.networkConnectionLost))
        let model = ModelDescriptor(id: "provider/video", owner: "provider", availability: "available")
        let store = AppStore(
            persistence: PersistenceService(root: root),
            modelHubFactory: { _, _ in fake },
            videoPollInterval: .milliseconds(1)
        )
        // This fixture explicitly consents before exercising only its injected fake provider.
        store.acceptThirdPartyAIConsent()
        store.connection = .connected(1)
        store.models = [model]
        store.capabilities[model.id] = CapabilityProfile(modelID: model.id, operations: [.video], source: .modelHub)

        await store.generateVideo(prompt: "轮询断线", size: "720p", ratio: "16:9", duration: 5, model: model.id, confirmBillable: true)
        for _ in 0..<100 where store.videoJobs.first?.state != .pollingDegraded {
            try await Task.sleep(for: .milliseconds(2))
        }

        let retained = try XCTUnwrap(store.videoJobs.first)
        XCTAssertEqual(retained.state, .pollingDegraded)
        XCTAssertEqual(retained.providerState, .unknown)
        XCTAssertFalse(store.retryAvailability(for: retained).isAvailable)
        XCTAssertNotNil(retained.taskID)
    }

    func testMultiResultArchiveRollsBackFilesWhenLaterItemFails() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "visionstack-archive-transaction-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = PersistenceService(root: root)

        do {
            _ = try await persistence.archiveMedia(
                ["data:image/png;base64,aGVsbG8=", "data:image/png;base64,not-valid-base64"],
                kind: .image
            )
            XCTFail("第二项无效时应回滚整个归档批次")
        } catch {
            let media = root.appending(path: "Media", directoryHint: .isDirectory)
            let files = (try? FileManager.default.contentsOfDirectory(at: media, includingPropertiesForKeys: nil)) ?? []
            XCTAssertTrue(files.isEmpty)
        }
    }

    @MainActor func testReconciliationArchivesProviderResultWithoutCreatingSecondRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "visionstack-reconcile-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeModelHubService()
        await fake.setReconciliationResponseForTesting(.init(
            raw: "{\"state\":\"succeeded\"}",
            taskID: "provider-task",
            mediaURLs: ["data:image/png;base64,aGVsbG8="],
            state: .succeeded,
            errorMessage: nil
        ))
        let requestID = UUID()
        let job = GenerationJob(
            kind: .image,
            prompt: "只对账不重提",
            model: "provider/image",
            parameters: [:],
            state: .submissionUnknown,
            submissionState: .unknown,
            providerState: .unknown,
            clientRequestID: requestID,
            idempotencyKey: "visionstack-\(requestID.uuidString)"
        )
        let store = AppStore(persistence: PersistenceService(root: root), modelHubFactory: { _, _ in fake })
        store.imageJobs = [job]

        await store.reconcileJob(job)

        let reconciled = try XCTUnwrap(store.imageJobs.first)
        XCTAssertEqual(reconciled.state, .succeeded)
        XCTAssertEqual(reconciled.providerState, .succeeded)
        XCTAssertEqual(reconciled.archiveState, .succeeded)
        XCTAssertEqual(reconciled.resultURLs.count, 1)
        XCTAssertNotNil(reconciled.lastReconciledAt)
        let submittedContexts = await fake.receivedContexts
        XCTAssertEqual(submittedContexts.count, 0)
    }

    @MainActor func testUnsupportedRequestReconciliationEndsUnknownSubmissionWithoutEnablingRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "visionstack-reconcile-unsupported-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeModelHubService()
        await fake.setReconciliationErrorForTesting(.httpStatus(404, "接口不存在"))
        let requestID = UUID()
        let job = GenerationJob(
            kind: .image,
            prompt: "超时后无法自动确认",
            model: "provider/image",
            parameters: [:],
            state: .submissionUnknown,
            submissionState: .unknown,
            providerState: .unknown,
            clientRequestID: requestID,
            idempotencyKey: "visionstack-\(requestID.uuidString)"
        )
        let store = AppStore(persistence: PersistenceService(root: root), modelHubFactory: { _, _ in fake })
        store.imageJobs = [job]

        await store.reconcileJob(job)

        let reconciled = try XCTUnwrap(store.imageJobs.first)
        XCTAssertEqual(reconciled.state, .timedOut)
        XCTAssertEqual(reconciled.submissionState, .unknown)
        XCTAssertEqual(reconciled.providerState, .unknown)
        XCTAssertNotNil(reconciled.lastReconciledAt)
        XCTAssertTrue(store.canDeleteJob(reconciled))
        XCTAssertFalse(store.retryAvailability(for: reconciled).isAvailable)
        XCTAssertTrue(reconciled.errorMessage?.contains("无法自动确认") == true)
    }

    @MainActor func testUnknownSubmissionCanBeExplicitlyDeletedWhileRunningJobRemainsProtected() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "visionstack-delete-unknown-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let unknown = GenerationJob(
            kind: .image,
            prompt: "请求已经超时但提交结果未知",
            model: "provider/image",
            parameters: [:],
            state: .submissionUnknown,
            submissionState: .unknown,
            providerState: .unknown,
            clientRequestID: UUID()
        )
        let running = GenerationJob(
            kind: .image,
            prompt: "本机请求仍在运行",
            model: "provider/image",
            parameters: [:],
            state: .running,
            submissionState: .submitting,
            providerState: .notStarted,
            clientRequestID: UUID()
        )
        let store = AppStore(persistence: PersistenceService(root: root))
        store.imageJobs = [unknown, running]

        XCTAssertTrue(store.canDeleteJob(unknown))
        XCTAssertFalse(store.canDeleteJob(running))

        await store.deleteImageJob(unknown)

        XCTAssertEqual(store.imageJobs.map(\.id), [running.id])
        XCTAssertTrue(store.notice?.contains("不会取消可能存在的供应商任务") == true)
    }

    func testDeleteConfirmationWarnsWhenSubmissionWasNeverConfirmed() {
        let content = MediaPendingConfirmation.delete.content(for: .image, hasUnconfirmedSubmission: true)

        XCTAssertEqual(content.title, "放弃对账并删除本地记录？")
        XCTAssertEqual(content.primaryButtonTitle, "仍然删除本地记录")
        XCTAssertTrue(content.message.contains("不会取消可能存在的供应商任务"))
        XCTAssertTrue(content.message.contains("仍可能计费"))
    }

    @MainActor func testManualArchiveRecoveryCompletesAllLifecycleStages() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "visionstack-manual-archive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = "data:image/png;base64,aGVsbG8="
        let job = GenerationJob(
            kind: .image,
            prompt: "恢复本地归档",
            model: "provider/image",
            parameters: [:],
            state: .needsArchive,
            remoteResultURLs: [remote],
            submissionState: .submitted,
            providerState: .succeeded,
            archiveState: .failed
        )
        let store = AppStore(persistence: PersistenceService(root: root))
        store.imageJobs = [job]

        await store.archiveRemoteResults(for: job)

        let recovered = try XCTUnwrap(store.imageJobs.first)
        XCTAssertEqual(recovered.state, .succeeded)
        XCTAssertEqual(recovered.submissionState, .submitted)
        XCTAssertEqual(recovered.providerState, .succeeded)
        XCTAssertEqual(recovered.archiveState, .succeeded)
        XCTAssertEqual(recovered.resultURLs.count, 1)
        XCTAssertTrue(URL(string: recovered.resultURLs[0]).map { FileManager.default.fileExists(atPath: $0.path) } == true)
    }

    func testQwenNestedMessageImageIsParsedAsMediaResult() {
        let parsed = ModelHubResponseParser.parse([
            "output": [
                "choices": [[
                    "message": [
                        "content": [["type": "image", "image": "https://media.example/result.png?signature=private"]]
                    ]
                ]]
            ]
        ])

        XCTAssertEqual(parsed.mediaURLs, ["https://media.example/result.png?signature=private"])
    }

    func testGeminiInlineImageIsParsedAsMediaResult() {
        let parsed = ModelHubResponseParser.parse([
            "candidates": [[
                "content": [
                    "parts": [[
                        "inlineData": [
                            "mimeType": "image/png",
                            "data": "aGVsbG8="
                        ]
                    ]]
                ]
            ]]
        ])

        XCTAssertEqual(parsed.mediaURLs, ["data:image/png;base64,aGVsbG8="])
    }

    func testBundledCapabilityMatchingUsesExclusiveGenerationFamilies() {
        let qwenImage = CapabilityRegistry.profile(for: "千问AI平台（按量付费）/qwen-image-3.0-pro")
        let seedanceVideo = CapabilityRegistry.profile(for: "seedance/doubao-seedance-2.0-mini")
        let chat = CapabilityRegistry.profile(for: "千问AI平台（按量付费）/qwen3.8-max")

        XCTAssertEqual(qwenImage.operations, [.image])
        XCTAssertEqual(seedanceVideo.operations, [.video])
        XCTAssertEqual(chat.operations, [.chat])
    }

    func testEveryKnownModelFamilyGetsResolvedWithoutPretendingUnsupportedModelsAreChat() {
        let representativeIDs = [
            "Agnes AI/agnes-2.5-pro",
            "云雾 API/SparkDesk-v3.5",
            "云雾 API/qwq-72b-preview",
            "千问AI平台（业务空间/按量付费）/happyhorse-1.1-t2v",
            "seedance/ltx-2.3-text-image",
            "MiniMax 中国站/MiniMax Music 3.0",
            "云雾 API/gemini-embedding-001"
        ]
        let profiles = representativeIDs.map(CapabilityRegistry.profile(for:))

        XCTAssertTrue(profiles.allSatisfy { $0.source != .unknown })
        XCTAssertEqual(profiles[0].operations, [.chat])
        XCTAssertEqual(profiles[3].operations, [.video])
        XCTAssertEqual(profiles[4].operations, [.image])
        XCTAssertTrue(profiles[5].operations.isEmpty)
        XCTAssertTrue(profiles[6].operations.isEmpty)
    }

    @MainActor func testModelSelectionRejectsKnownIncompatibleOperationWithoutCreatingProfile() {
        let store = AppStore()
        let model = ModelDescriptor(id: "seedance/qwen-image-3.0-pro", owner: "seedance", availability: "available")
        store.models = [model]
        store.capabilities[model.id] = CapabilityRegistry.profile(for: model.id)

        XCTAssertFalse(store.selectModel(model.id, for: .chat))
        XCTAssertEqual(store.preferredChatModel, "")
        XCTAssertNil(store.customCapabilities[model.id])
    }

    @MainActor func testDeletingLastConversationInProjectDoesNotSelectAnotherProjectsConversation() {
        let store = AppStore()
        let current = CreativeProject(name: "当前项目")
        let other = CreativeProject(name: "其他项目")
        let currentConversation = Conversation(title: "当前对话", messages: [], projectID: current.id)
        let otherConversation = Conversation(title: "其他对话", messages: [], projectID: other.id)
        store.projects = [current, other]
        store.selectedProjectID = current.id
        store.conversations = [otherConversation, currentConversation]
        store.selectedConversationID = currentConversation.id

        store.deleteConversation(currentConversation.id)

        XCTAssertNotEqual(store.selectedConversationID, otherConversation.id)
        XCTAssertEqual(store.selectedConversation?.projectID, current.id)
    }

    @MainActor func testAuthoritativeCapabilityRefreshClearsStaleLocalOverride() async {
        let fake = FakeModelHubService()
        let store = AppStore(modelHubFactory: { _, _ in fake })
        let model = ModelDescriptor(id: "provider/declared", owner: "provider", availability: "available")
        store.connection = .connected(1)
        store.models = [model]
        store.saveCustomCapability(modelID: model.id, operations: [.chat], imageSizes: [], qualities: [], videoResolutions: [], aspectRatios: [], durations: [])

        await store.refreshCapability(for: model.id)

        XCTAssertNil(store.customCapabilities[model.id])
        XCTAssertEqual(store.profile(for: model.id)?.source, .modelHub)
    }

    @MainActor func testBootstrapRecoversProviderSuccessFromNestedHistoricalImageResponse() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "visionstack-nested-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let remote = "https://media.example/recover.png?signature=private"
        let raw = "{\"output\":{\"choices\":[{\"message\":{\"content\":[{\"type\":\"image\",\"image\":\"\(remote)\"}]}}]}}"
        let failed = GenerationJob(
            kind: .image,
            prompt: "历史成功结果",
            model: "provider/qwen-image",
            parameters: ["size": "1024x1024"],
            state: .failed,
            rawResponse: raw,
            submissionState: .rejected,
            providerState: .failed,
            archiveState: .notRequired
        )
        let snapshot = AppSnapshot(
            conversations: [], selectedConversationID: nil, imageJobs: [failed], videoJobs: [],
            selectedAgentID: nil, selectedSkillIDs: [], baseURL: "http://127.0.0.1:11435/v1",
            preferredChatModel: "", preferredImageModel: "", preferredVideoModel: "", webSearchEnabled: false,
            cachedModels: [], cachedCapabilities: [], customCapabilities: []
        )
        try JSONEncoder.visionStack.encode(snapshot).write(to: root.appending(path: "state.json"), options: .atomic)
        let store = AppStore(persistence: PersistenceService(root: root), modelHubFactory: { _, _ in throw VisionStackError.server("离线") })

        await store.bootstrap()

        let recovered = try XCTUnwrap(store.imageJobs.first)
        XCTAssertEqual(recovered.state, .needsArchive)
        XCTAssertEqual(recovered.submissionState, .submitted)
        XCTAssertEqual(recovered.providerState, .succeeded)
        XCTAssertEqual(recovered.archiveState, .failed)
        XCTAssertEqual(recovered.remoteResultURLs, [remote])
        XCTAssertFalse(recovered.canCreateBillableRetry)
    }

    func testSnapshotSanitizerRemovesEmbeddedMediaAndSignedURLAfterLocalArchive() {
        let payload = String(repeating: "a", count: 1_000_000)
        let job = GenerationJob(
            kind: .image,
            prompt: "已归档",
            model: "provider/image",
            parameters: [:],
            state: .succeeded,
            resultURLs: ["file:///tmp/local.png"],
            remoteResultURLs: ["https://media.example/result.png?signature=private"],
            rawResponse: "{\"data\":[{\"b64_json\":\"\(payload)\"}]}",
            providerState: .succeeded,
            archiveState: .succeeded
        )
        let snapshot = AppSnapshot(
            conversations: [], selectedConversationID: nil, imageJobs: [job], videoJobs: [],
            selectedAgentID: nil, selectedSkillIDs: [], baseURL: "http://127.0.0.1:11435/v1",
            preferredChatModel: "", preferredImageModel: "", preferredVideoModel: "", webSearchEnabled: false,
            cachedModels: [], cachedCapabilities: [], customCapabilities: []
        )

        let sanitized = SnapshotSanitizer.sanitized(snapshot)
        let saved = sanitized.imageJobs[0]

        XCTAssertLessThan(saved.rawResponse.utf8.count, 2_000)
        XCTAssertTrue(saved.rawResponse.contains("payload_sha256"))
        XCTAssertFalse(saved.rawResponse.contains(payload))
        XCTAssertNil(saved.remoteResultURLs)
    }

    func testMediaURLPolicyRejectsLoopbackPrivateAndNonHTTPSTargets() throws {
        XCTAssertTrue(MediaURLPolicy.isAllowedRemoteURL(try XCTUnwrap(URL(string: "https://cdn.example.com/result.png"))))
        XCTAssertFalse(MediaURLPolicy.isAllowedRemoteURL(try XCTUnwrap(URL(string: "http://cdn.example.com/result.png"))))
        XCTAssertFalse(MediaURLPolicy.isAllowedRemoteURL(try XCTUnwrap(URL(string: "https://127.0.0.1/result.png"))))
        XCTAssertFalse(MediaURLPolicy.isAllowedRemoteURL(try XCTUnwrap(URL(string: "https://10.0.0.8/result.png"))))
        XCTAssertFalse(MediaURLPolicy.isAllowedRemoteURL(try XCTUnwrap(URL(string: "https://192.168.1.8/result.png"))))
        XCTAssertFalse(MediaURLPolicy.isAllowedRemoteURL(try XCTUnwrap(URL(string: "https://169.254.169.254/latest/meta-data"))))
        XCTAssertFalse(MediaURLPolicy.isAllowedRemoteURL(try XCTUnwrap(URL(string: "file:///tmp/result.png"))))
    }

    func testInlineMediaLimitIsCheckedBeforeBase64Decode() {
        XCTAssertTrue(MediaArchivePolicy.allowsInlineBase64CharacterCount(1024, kind: .image))
        XCTAssertFalse(MediaArchivePolicy.allowsInlineBase64CharacterCount(MediaArchivePolicy.maximumInlineEncodedBytes(for: .image) + 1, kind: .image))
        XCTAssertFalse(MediaArchivePolicy.allowsInlineBase64CharacterCount(MediaArchivePolicy.maximumInlineEncodedBytes(for: .video) + 1, kind: .video))
    }

    func testParameterSelectionPreservesSupportedCurrentValueAndFallsBackOnlyWhenNeeded() {
        XCTAssertEqual(ParameterSelectionPolicy.preserving("1080p", allowed: ["720p", "1080p"], fallback: "720p"), "1080p")
        XCTAssertEqual(ParameterSelectionPolicy.preserving("4K", allowed: ["720p", "1080p"], fallback: "720p"), "720p")
        XCTAssertEqual(ParameterSelectionPolicy.preserving(8, allowed: [4, 8, 10], fallback: 5), 8)
    }

    @MainActor func testCurrentProjectCollectionsAndCountersExcludeOtherProjects() {
        let store = AppStore()
        let current = CreativeProject(name: "当前")
        let other = CreativeProject(name: "其他")
        store.projects = [current, other]
        store.selectedProjectID = current.id
        store.imageJobs = [
            GenerationJob(kind: .image, prompt: "当前图", model: "p/image", parameters: [:], state: .succeeded, projectID: current.id),
            GenerationJob(kind: .image, prompt: "其他图", model: "p/image", parameters: [:], state: .succeeded, projectID: other.id)
        ]
        store.videoJobs = [GenerationJob(kind: .video, prompt: "当前视频", model: "p/video", parameters: [:], state: .running, projectID: current.id)]

        XCTAssertEqual(store.currentProjectImageJobs.map(\.prompt), ["当前图"])
        XCTAssertEqual(store.currentProjectVideoJobs.map(\.prompt), ["当前视频"])
        XCTAssertEqual(store.currentProjectTaskCount, 2)
    }

    @MainActor func testArchivedProjectCanBeRestoredAndSelected() {
        let store = AppStore()
        var archived = CreativeProject(name: "已归档", archivedAt: Date())
        let active = CreativeProject(name: "活动")
        store.projects = [active, archived]
        store.selectedProjectID = active.id

        store.restoreProject(archived.id)

        archived = store.projects.first(where: { $0.id == archived.id })!
        XCTAssertNil(archived.archivedAt)
        XCTAssertEqual(store.selectedProjectID, archived.id)
        XCTAssertEqual(store.selectedConversation?.projectID, archived.id)
    }

    func testLocalMediaSkillCatalogCoversEveryCurrentImageAndVideoSkillWithChineseMetadata() {
        let descriptors = LocalMediaSkillCatalog.descriptors

        XCTAssertEqual(descriptors.count, 7)
        XCTAssertEqual(Set(descriptors.map(\.stableID)).count, descriptors.count)
        XCTAssertTrue(descriptors.allSatisfy { $0.localizedName.range(of: "\\p{Han}", options: .regularExpression) != nil })
        XCTAssertTrue(descriptors.allSatisfy { $0.localizedSummary.range(of: "\\p{Han}", options: .regularExpression) != nil })
        XCTAssertTrue(descriptors.allSatisfy { !$0.mediaDomains.isEmpty })
        XCTAssertEqual(descriptors.filter { $0.mediaDomains == [.image] }.count, 6)
        XCTAssertEqual(descriptors.filter { $0.mediaDomains == [.video] }.count, 1)
        XCTAssertEqual(descriptors.filter { $0.mediaDomains == [.shared] }.count, 0)
        XCTAssertEqual(descriptors.filter { $0.mediaDomains == [.utility] }.count, 0)
    }

    func testBundledMediaAgentsAreChineseClassifiedAndHaveStableIDs() {
        let agents = LocalMediaAgentCatalog.resources
        let installedSkillStableIDs = Set(LocalMediaSkillCatalog.descriptors.map(\.stableID))
        let assignedSkillStableIDs = Set(agents.flatMap(\.assignedSkillIDs))
        let sharedAssignments = Dictionary(grouping: agents.flatMap(\.assignedSkillIDs), by: { $0 })

        XCTAssertEqual(agents.count, 6)
        XCTAssertEqual(Set(agents.compactMap(\.stableID)).count, 6)
        XCTAssertTrue(agents.allSatisfy { $0.kind == .agent && !$0.classifiedMediaDomains.isEmpty && !$0.executableRisk && $0.enabled })
        XCTAssertTrue(agents.allSatisfy { $0.name.range(of: "\\p{Han}", options: .regularExpression) != nil })
        XCTAssertTrue(agents.allSatisfy { !$0.assignedSkillIDs.isEmpty && $0.assignedSkillIDs.count <= MediaPromptComposer.maximumSkillCount })
        XCTAssertEqual(assignedSkillStableIDs, installedSkillStableIDs)
        XCTAssertTrue(sharedAssignments.values.contains { $0.count > 1 })
        XCTAssertEqual(agents.first(where: { $0.stableID == LocalMediaAgentCatalog.imageAgentStableID })?.classifiedMediaDomains, [.image])
        XCTAssertEqual(agents.first(where: { $0.stableID == LocalMediaAgentCatalog.videoAgentStableID })?.classifiedMediaDomains, [.video])
        XCTAssertTrue(LocalMediaAgentCatalog.personalOnlyAgentStableIDs.isEmpty)
    }

    func testNewEditorialAndPortraitSkillsAreBundledAndAgentManaged() throws {
        let stableIDs = [
            "visionstack.skill.gc-minimal-zine-poster",
            "visionstack.skill.portrait-reshoot-direction",
            "visionstack.skill.photo-relic-editorial"
        ]
        let descriptors = LocalMediaSkillCatalog.descriptors.filter { stableIDs.contains($0.stableID) }
        XCTAssertEqual(Set(descriptors.map(\.stableID)), Set(stableIDs))
        XCTAssertTrue(descriptors.allSatisfy { $0.sourceKind == .bundle && $0.mediaDomains == [.image] })

        let scan = try LocalMediaSkillCatalog.scan(
            descriptors: descriptors,
            homeDirectory: FileManager.default.temporaryDirectory,
            includeBundledAgents: false
        )
        XCTAssertEqual(scan.missingStableIDs, [])
        XCTAssertEqual(Set(scan.resources.compactMap(\.stableID)), Set(stableIDs))
        XCTAssertTrue(scan.resources.allSatisfy { !$0.executableRisk && $0.enabled })

        let expectedAgents: [String: String] = [
            LocalMediaAgentCatalog.minimalZineAgentStableID: "映栈极简 Zine 海报总监",
            LocalMediaAgentCatalog.portraitReshootAgentStableID: "映栈写真复拍导演",
            LocalMediaAgentCatalog.photoRelicAgentStableID: "映栈照片遗迹编辑总监"
        ]
        for (stableID, name) in expectedAgents {
            let agent = try XCTUnwrap(LocalMediaAgentCatalog.resources.first { $0.stableID == stableID })
            XCTAssertEqual(agent.name, name)
            XCTAssertTrue(agent.assignedSkillIDs.contains(where: stableIDs.contains))
        }
        XCTAssertTrue(LocalMediaAgentCatalog.personalOnlyAgentStableIDs.isEmpty)
    }

    func testPortraitReferencePromptSeparatesIdentityAndPhotographyResponsibilities() throws {
        let agent = try XCTUnwrap(LocalMediaAgentCatalog.resources.first {
            $0.stableID == LocalMediaAgentCatalog.portraitReshootAgentStableID
        })
        let plan = MediaPromptComposer.compose(
            operation: .image,
            userPrompt: "在海边回头微笑",
            agent: agent,
            skills: [],
            referenceRoles: [.identity, .photographyPlan]
        )
        XCTAssertTrue(plan.providerPrompt.contains("第 1 张：身份参考"))
        XCTAssertTrue(plan.providerPrompt.contains("第 2 张：摄影方案参考"))
        XCTAssertTrue(plan.providerPrompt.contains("世界空间"))
        XCTAssertTrue(plan.providerPrompt.contains("具体场景事件"))
        XCTAssertTrue(plan.providerPrompt.contains("不得把上一轮生成图自动当作新参考"))
    }

    func testTasteAndImpeccableImageAdaptationsAreBundledAndAgentManaged() throws {
        let stableIDs = [
            "visionstack.skill.taste-image-direction",
            "visionstack.skill.impeccable-image-quality"
        ]
        let descriptors = LocalMediaSkillCatalog.descriptors.filter { stableIDs.contains($0.stableID) }

        XCTAssertEqual(Set(descriptors.map(\.stableID)), Set(stableIDs))
        XCTAssertTrue(descriptors.allSatisfy { $0.mediaDomains == [.image] })
        XCTAssertTrue(descriptors.allSatisfy { $0.homeRelativePath.hasPrefix("ManagedSkills/") })
        XCTAssertTrue(descriptors.contains { $0.localizedName == "Taste 图片审美定向" })
        XCTAssertTrue(descriptors.contains { $0.localizedName == "Impeccable 图片品质审校" })

        let scan = try LocalMediaSkillCatalog.scan(
            descriptors: descriptors,
            homeDirectory: FileManager.default.temporaryDirectory,
            includeBundledAgents: false
        )
        XCTAssertEqual(Set(scan.resources.compactMap(\.stableID)), Set(stableIDs))
        XCTAssertEqual(scan.missingStableIDs, [])
        XCTAssertTrue(scan.resources.allSatisfy { !$0.executableRisk && $0.enabled })
        XCTAssertTrue(scan.resources.contains { $0.instructions.contains("参考图锚点") })
        XCTAssertTrue(scan.resources.contains { $0.instructions.contains("终稿审校") })

        let agent = try XCTUnwrap(LocalMediaAgentCatalog.resources.first {
            $0.stableID == "visionstack.agent.image-aesthetic-quality-director"
        })
        XCTAssertEqual(agent.name, "映栈图片审美品控总监")
        XCTAssertEqual(
            Set(agent.assignedSkillIDs),
            Set(stableIDs + [MediaPromptComposer.mandatoryImageSkillStableID])
        )
        XCTAssertEqual(agent.classifiedMediaDomains, [.image])

        let plan = MediaPromptComposer.compose(
            operation: .image,
            userPrompt: "根据参考图生成一张克制而有辨识度的产品照片",
            agent: agent,
            skills: scan.resources
        )
        XCTAssertEqual(Set(plan.skillStableIDs), Set(stableIDs + [MediaPromptComposer.mandatoryImageSkillStableID]))
        XCTAssertTrue(plan.providerPrompt.contains("Taste"))
        XCTAssertTrue(plan.providerPrompt.contains("Impeccable"))
        XCTAssertTrue(plan.providerPrompt.contains("参考图锚点"))
        XCTAssertTrue(plan.providerPrompt.contains("终稿审校"))
    }

    func testPromptAestheticDefinitionIsBundledAndMandatoryForEveryImageAgent() throws {
        let stableID = MediaPromptComposer.mandatoryImageSkillStableID
        let descriptor = try XCTUnwrap(LocalMediaSkillCatalog.descriptors.first { $0.stableID == stableID })

        XCTAssertEqual(stableID, "visionstack.skill.image-aesthetic-foundation")
        XCTAssertEqual(descriptor.sourceKind, .bundle)
        XCTAssertEqual(descriptor.homeRelativePath, "ManagedSkills/VisionStackImageFoundation/SKILL.md")

        for agent in LocalMediaAgentCatalog.resources where agent.applies(to: .image) {
            let plan = MediaPromptComposer.compose(
                operation: .image,
                userPrompt: "一张有明确视觉目标的图片",
                agent: agent,
                skills: []
            )
            XCTAssertEqual(plan.skillStableIDs.first, stableID, "\(agent.name) 没有优先调用默认审美 Skill")
            XCTAssertTrue(plan.providerPrompt.contains("先明确用途、主体和叙事瞬间"))
            XCTAssertTrue(plan.providerPrompt.contains("负向边界"))
        }

        let videoPlan = MediaPromptComposer.compose(
            operation: .video,
            userPrompt: "镜头向前推进",
            agent: LocalMediaAgentCatalog.resources.first { $0.applies(to: .video) },
            skills: []
        )
        XCTAssertFalse(videoPlan.skillStableIDs.contains(stableID))
    }

    func testBundledImageFoundationIsProjectOwnedAndLicensed() throws {
        let projectRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let managedRoot = projectRoot.appending(path: "Sources/VisionStack/Resources/ManagedSkills/VisionStackImageFoundation")
        let skill = try String(contentsOf: managedRoot.appending(path: "SKILL.md"), encoding: .utf8)

        XCTAssertTrue(skill.contains("映栈图片审美基础"))
        XCTAssertTrue(skill.contains("参考图合同"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: managedRoot.appending(path: "LICENSE").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: managedRoot.appending(path: "SOURCE.md").path))
    }

    func testAgentOnlyUIHidesSkillInventoryAndManualSelectionControls() throws {
        let projectRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcePaths = [
            "Sources/VisionStack/ChatView.swift",
            "Sources/VisionStack/MediaAgentSkillRouting.swift",
            "Sources/VisionStack/RootView.swift",
            "Sources/VisionStack/SettingsView.swift"
        ]
        let visibleViewSource = try sourcePaths.map {
            try String(contentsOf: projectRoot.appending(path: $0), encoding: .utf8)
        }.joined(separator: "\n")
        let appStoreSource = try String(
            contentsOf: projectRoot.appending(path: "Sources/VisionStack/AppStore.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(visibleViewSource.contains("加载 Skills"))
        XCTAssertFalse(visibleViewSource.contains("Agent 与 Skills"))
        XCTAssertFalse(visibleViewSource.contains("ForEach(store.enabledSkills"))
        XCTAssertFalse(visibleViewSource.contains("setMediaSkill"))
        XCTAssertFalse(appStoreSource.contains("func setSkill("))
        XCTAssertFalse(appStoreSource.contains("func setMediaSkill("))
    }

    func testPaperInterfaceUsesReadableLightAppearanceAndPrimaryTextColors() throws {
        let projectRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSource = try String(
            contentsOf: projectRoot.appending(path: "Sources/VisionStack/VisionStackApp.swift"),
            encoding: .utf8
        )
        let rootSource = try String(
            contentsOf: projectRoot.appending(path: "Sources/VisionStack/RootView.swift"),
            encoding: .utf8
        )
        let designSource = try String(
            contentsOf: projectRoot.appending(path: "Sources/VisionStack/DesignSystem.swift"),
            encoding: .utf8
        )
        let modelSource = try String(
            contentsOf: projectRoot.appending(path: "Sources/VisionStack/ModelSelectionView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(appSource.contains(".preferredColorScheme(.light)"))
        XCTAssertTrue(rootSource.contains(".foregroundStyle(VSColor.ink)"))
        XCTAssertTrue(designSource.contains("StatusPill") && designSource.contains(".foregroundStyle(VSColor.ink)"))
        XCTAssertTrue(modelSource.contains(".foregroundStyle(VSColor.ink)"))
    }

    func testImageStudioExposesReferenceLibraryManagementEntry() throws {
        let projectRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let imageStudioSource = try String(
            contentsOf: projectRoot.appending(path: "Sources/VisionStack/ImageStudioView.swift"),
            encoding: .utf8
        )
        let assetLibrarySource = try String(
            contentsOf: projectRoot.appending(path: "Sources/VisionStack/AssetLibraryView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(imageStudioSource.contains("管理参考图"))
        XCTAssertTrue(assetLibrarySource.contains("导入参考图"))
        XCTAssertTrue(assetLibrarySource.contains("删除参考图"))
    }

    func testLocalMediaSkillScanReadsOnlyDeclaredSkillAndDefaultsExecutableDefinitionsToDisabled() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "visionstack-local-media-skill-\(UUID().uuidString)")
        let skillDirectory = root.appending(path: ".codex/skills/fixture-media")
        try FileManager.default.createDirectory(at: skillDirectory.appending(path: "scripts"), withIntermediateDirectories: true)
        try Data("---\nname: fixture\ndescription: fixture\n---\n# Fixture\nallowed-tools: Bash\n".utf8)
            .write(to: skillDirectory.appending(path: "SKILL.md"))
        defer { try? FileManager.default.removeItem(at: root) }
        let descriptor = LocalMediaSkillDescriptor(
            stableID: "codex.fixture-media",
            localizedName: "测试媒体技能",
            localizedSummary: "用于验证本机图片与视频技能的安全导入。",
            homeRelativePath: ".codex/skills/fixture-media/SKILL.md",
            mediaDomains: [.shared]
        )

        let result = try LocalMediaSkillCatalog.scan(descriptors: [descriptor], homeDirectory: root, includeBundledAgents: false)
        let resource = try XCTUnwrap(result.resources.first)

        XCTAssertEqual(result.missingStableIDs, [])
        XCTAssertEqual(resource.stableID, descriptor.stableID)
        XCTAssertEqual(resource.name, descriptor.localizedName)
        XCTAssertEqual(resource.summary, descriptor.localizedSummary)
        XCTAssertTrue(resource.executableRisk)
        XCTAssertFalse(resource.enabled)
        XCTAssertTrue(resource.instructions.contains("allowed-tools"))
        XCTAssertEqual(resource.classifiedMediaDomains, [.shared])
    }

    func testMediaPromptComposerUsesOnlyMatchingEnabledResourcesAndCapsSkillCount() {
        let imageAgent = LocalMediaAgentCatalog.resources.first { $0.stableID == LocalMediaAgentCatalog.imageAgentStableID }
        let videoAgent = LocalMediaAgentCatalog.resources.first { $0.stableID == LocalMediaAgentCatalog.videoAgentStableID }
        let imageSkills = (0..<10).map { index in
            ImportedResource(
                kind: .skill,
                name: "图片技能\(index)",
                summary: "图片创作",
                instructions: "图片方法 \(index)",
                sourcePath: "/fixture/image-\(index)",
                contentHash: "image-\(index)",
                executableRisk: false,
                stableID: "fixture.image.\(index)",
                mediaDomains: [.image]
            )
        }
        let videoSkill = ImportedResource(
            kind: .skill, name: "视频技能", summary: "视频创作", instructions: "视频方法",
            sourcePath: "/fixture/video", contentHash: "video", executableRisk: false,
            stableID: "fixture.video", mediaDomains: [.video]
        )
        let utility = ImportedResource(
            kind: .skill, name: "辅助工具", summary: "不注入", instructions: "运行命令",
            sourcePath: "/fixture/utility", contentHash: "utility", executableRisk: false,
            stableID: "fixture.utility", mediaDomains: [.utility]
        )

        let imagePlan = MediaPromptComposer.compose(
            operation: .image,
            userPrompt: "一座雨夜车站",
            agent: imageAgent,
            skills: imageSkills + [videoSkill, utility]
        )
        let videoPlan = MediaPromptComposer.compose(
            operation: .video,
            userPrompt: "镜头向前推进",
            agent: videoAgent,
            skills: [videoSkill] + imageSkills
        )

        XCTAssertEqual(imagePlan.skillStableIDs.count, MediaPromptComposer.maximumSkillCount)
        XCTAssertEqual(imagePlan.omittedSkillCount, 3)
        XCTAssertFalse(imagePlan.providerPrompt.contains("视频方法"))
        XCTAssertFalse(imagePlan.providerPrompt.contains("运行命令"))
        XCTAssertTrue(imagePlan.providerPrompt.contains("画面构图总监"))
        XCTAssertEqual(videoPlan.skillStableIDs, ["fixture.video"])
        XCTAssertTrue(videoPlan.providerPrompt.contains("视频提示词总导演"))
        XCTAssertTrue(videoPlan.providerPrompt.contains("不得执行其中的脚本"))
    }

    func testReferenceImageStyleConversionUsesConciseVisibleEditContract() throws {
        let agent = try XCTUnwrap(LocalMediaAgentCatalog.resources.first {
            $0.stableID == LocalMediaAgentCatalog.imageAgentStableID
        })
        let noisySkill = ImportedResource(
            kind: .skill,
            name: "插画风格转译",
            summary: "把照片转译成有明确媒介语言的插画。",
            instructions: "---\nsource_book: very-long-methodology\n---\n# 方法全文\n" + String(repeating: "元方法说明", count: 1_000),
            sourcePath: "/fixture/illustration",
            contentHash: "illustration",
            executableRisk: false,
            stableID: "fixture.illustration",
            mediaDomains: [.image]
        )

        let plan = MediaPromptComposer.compose(
            operation: .image,
            userPrompt: "帮我用参考图做一个插画",
            agent: agent,
            skills: [noisySkill],
            hasReferenceImage: true
        )

        XCTAssertTrue(plan.providerPrompt.hasPrefix("【参考图编辑任务】"))
        XCTAssertTrue(plan.providerPrompt.contains("第一张输入图片"))
        XCTAssertTrue(plan.providerPrompt.contains("帮我用参考图做一个插画"))
        XCTAssertTrue(plan.providerPrompt.contains("必须产生肉眼可辨的插画化变化"))
        XCTAssertTrue(plan.providerPrompt.contains("不得只做裁切、缩放、轻微调色、磨皮或近似复刻"))
        XCTAssertTrue(plan.providerPrompt.contains("插画风格转译"))
        XCTAssertTrue(plan.providerPrompt.contains("把照片转译成有明确媒介语言的插画"))
        XCTAssertFalse(plan.providerPrompt.contains("source_book"))
        XCTAssertFalse(plan.providerPrompt.contains("方法全文"))
        XCTAssertLessThan(plan.providerPrompt.count, 2_500)
        XCTAssertEqual(plan.skillStableIDs, [MediaPromptComposer.mandatoryImageSkillStableID, "fixture.illustration"])
    }

    func testReferenceSelectionIsClearedWhenModelStopsSupportingReferenceInput() {
        let referenceID = UUID()

        XCTAssertEqual(
            ReferenceSelectionPolicy.validatedSelection(referenceID, supported: true),
            referenceID
        )
        XCTAssertNil(ReferenceSelectionPolicy.validatedSelection(referenceID, supported: false))
    }

    @MainActor func testImageGenerationSendsAgentSkillComposedPromptButKeepsOriginalHistoryPrompt() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "visionstack-media-routing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeModelHubService()
        let model = ModelDescriptor(id: "provider/image", owner: "provider", availability: "available")
        var agent = try XCTUnwrap(LocalMediaAgentCatalog.resources.first { $0.stableID == LocalMediaAgentCatalog.imageAgentStableID })
        agent.assignedSkillStableIDs = ["fixture.composition"]
        let skill = ImportedResource(
            kind: .skill, name: "构图技能", summary: "优化构图", instructions: "使用清晰的前中后景层次。",
            sourcePath: "/fixture/composition", contentHash: "composition", executableRisk: false,
            stableID: "fixture.composition", mediaDomains: [.image]
        )
        let store = AppStore(persistence: PersistenceService(root: root), modelHubFactory: { _, _ in fake })
        // This fixture explicitly consents before exercising only its injected fake provider.
        store.acceptThirdPartyAIConsent()
        store.connection = .connected(1)
        store.models = [model]
        store.capabilities[model.id] = CapabilityProfile(modelID: model.id, operations: [.image], source: .modelHub)
        store.resources = [agent, skill]
        store.selectedImageAgentID = agent.id
        store.selectedImageSkillIDs = []

        await store.generateImage(prompt: "一棵古树", size: "1024x1024", quality: "auto", model: model.id, confirmBillable: true)

        let receivedPrompts = await fake.receivedImagePrompts
        let received = try XCTUnwrap(receivedPrompts.first)
        let job = try XCTUnwrap(store.imageJobs.first)
        XCTAssertEqual(job.prompt, "一棵古树")
        XCTAssertEqual(job.agentStableID, agent.stableID)
        XCTAssertEqual(job.skillStableIDs, [MediaPromptComposer.mandatoryImageSkillStableID, "fixture.composition"])
        XCTAssertTrue(received.contains("一棵古树"))
        XCTAssertTrue(received.contains("使用清晰的前中后景层次"))
        XCTAssertNotEqual(received, job.prompt)
    }

    @MainActor func testReferenceImageGenerationSendsVisibleEditPromptAndRecordsRequestEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "visionstack-reference-edit-prompt-\(UUID().uuidString)")
        let source = root.appending(path: "reference.png")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try writeValidReferencePNG(to: source)

        let project = CreativeProject(name: "参考图编辑")
        let persistence = PersistenceService(root: root)
        var reference = try await persistence.importReference(from: source)
        reference.projectID = project.id
        let fake = FakeModelHubService()
        let model = ModelDescriptor(id: "qwen-image-3.0-pro", owner: "provider", availability: "available")
        let store = AppStore(persistence: persistence, modelHubFactory: { _, _ in fake })
        store.projects = [project]
        store.selectedProjectID = project.id
        store.referenceAssets = [reference]
        // This fixture explicitly consents before exercising only its injected fake provider.
        store.acceptThirdPartyAIConsent()
        store.connection = .connected(1)
        store.models = [model]
        store.capabilities[model.id] = CapabilityProfile(
            modelID: model.id,
            operations: [.image],
            source: .modelHub,
            inputModalities: ["text", "image"]
        )

        await store.generateImage(
            prompt: "帮我用参考图做一个插画",
            size: "1024x1024",
            quality: "auto",
            model: model.id,
            referenceAssetID: reference.id,
            confirmBillable: true
        )

        let receivedPrompts = await fake.receivedImagePrompts
        let prompt = try XCTUnwrap(receivedPrompts.first)
        let job = try XCTUnwrap(store.imageJobs.first)
        XCTAssertTrue(prompt.contains("【参考图编辑任务】"))
        XCTAssertTrue(prompt.contains("必须产生肉眼可辨的插画化变化"))
        XCTAssertEqual(job.prompt, "帮我用参考图做一个插画")
        XCTAssertEqual(job.parameters["reference_mode"], "visible-edit")
        XCTAssertEqual(job.parameters["reference_request"], "included")
    }

    @MainActor func testPortraitGenerationSendsBothOriginalReferenceRolesAndPersistsBindings() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "visionstack-dual-reference-\(UUID().uuidString)")
        let identitySource = root.appending(path: "identity.png")
        let photographySource = root.appending(path: "photography.png")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try writeValidReferencePNG(to: identitySource)
        try writeValidReferencePNG(to: photographySource)

        let project = CreativeProject(name: "写真复拍")
        let persistence = PersistenceService(root: root)
        var identity = try await persistence.importReference(from: identitySource)
        var photography = try await persistence.importReference(from: photographySource)
        identity.projectID = project.id
        photography.projectID = project.id
        let fake = FakeModelHubService()
        let model = ModelDescriptor(id: "qwen-image-3.0-pro", owner: "provider", availability: "available")
        let agent = try XCTUnwrap(LocalMediaAgentCatalog.resources.first {
            $0.stableID == LocalMediaAgentCatalog.portraitReshootAgentStableID
        })
        let store = AppStore(persistence: persistence, modelHubFactory: { _, _ in fake })
        store.projects = [project]
        store.selectedProjectID = project.id
        store.referenceAssets = [identity, photography]
        // This fixture explicitly consents before exercising only its injected fake provider.
        store.acceptThirdPartyAIConsent()
        store.connection = .connected(1)
        store.models = [model]
        store.capabilities[model.id] = CapabilityProfile(
            modelID: model.id,
            operations: [.image],
            source: .modelHub,
            inputModalities: ["text", "image"]
        )
        store.resources = [agent]
        store.selectedImageAgentID = agent.id

        let bindings = [
            ImageReferenceBinding(assetID: identity.id, role: .identity),
            ImageReferenceBinding(assetID: photography.id, role: .photographyPlan)
        ]
        await store.generateImage(
            prompt: "在海边回头微笑",
            size: "1024x1024",
            quality: "auto",
            model: model.id,
            imageReferences: bindings,
            confirmBillable: true
        )

        let groups = await fake.receivedImageReferenceGroups
        XCTAssertEqual(groups.first?.count, 2)
        let job = try XCTUnwrap(store.imageJobs.first)
        XCTAssertEqual(job.effectiveImageReferences, bindings)
        XCTAssertEqual(job.parameters["reference_roles"], "identity,photographyPlan")
        let prompts = await fake.receivedImagePrompts
        let prompt = try XCTUnwrap(prompts.first)
        XCTAssertTrue(prompt.contains("第 1 张：身份参考"))
        XCTAssertTrue(prompt.contains("第 2 张：摄影方案参考"))
    }

    @MainActor func testVideoGenerationSendsVideoAgentSkillPromptAndRecordsRouting() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "visionstack-video-routing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeModelHubService()
        let model = ModelDescriptor(id: "provider/video", owner: "provider", availability: "available")
        var agent = try XCTUnwrap(LocalMediaAgentCatalog.resources.first { $0.stableID == LocalMediaAgentCatalog.videoAgentStableID })
        agent.assignedSkillStableIDs = ["fixture.camera"]
        let skill = ImportedResource(
            kind: .skill, name: "运镜技能", summary: "优化运镜", instructions: "镜头缓慢向主体推进并保持焦点稳定。",
            sourcePath: "/fixture/camera", contentHash: "camera", executableRisk: false,
            stableID: "fixture.camera", mediaDomains: [.video]
        )
        let store = AppStore(
            persistence: PersistenceService(root: root),
            modelHubFactory: { _, _ in fake },
            videoPollInterval: .seconds(30)
        )
        // This fixture explicitly consents before exercising only its injected fake provider.
        store.acceptThirdPartyAIConsent()
        store.connection = .connected(1)
        store.models = [model]
        store.capabilities[model.id] = CapabilityProfile(modelID: model.id, operations: [.video], source: .modelHub)
        store.resources = [agent, skill]
        store.selectedVideoAgentID = agent.id
        store.selectedVideoSkillIDs = []

        await store.generateVideo(prompt: "少女走过雨夜车站", size: "720p", ratio: "16:9", duration: 5, model: model.id, confirmBillable: true)

        let receivedPrompts = await fake.receivedVideoPrompts
        let received = try XCTUnwrap(receivedPrompts.first)
        let job = try XCTUnwrap(store.videoJobs.first)
        XCTAssertEqual(job.prompt, "少女走过雨夜车站")
        XCTAssertEqual(job.agentStableID, agent.stableID)
        XCTAssertEqual(job.skillStableIDs, ["fixture.camera"])
        XCTAssertTrue(received.contains("视频提示词总导演"))
        XCTAssertTrue(received.contains("镜头缓慢向主体推进"))
        await store.cancelVideoJob(job.id)
    }

    func testResourceMergeIsIdempotentAndPreservesExplicitEnableChoice() throws {
        let stableID = "codex.imagegen"
        let existingID = UUID()
        let existing = ImportedResource(
            id: existingID, kind: .skill, name: "旧名称", summary: "旧说明", instructions: "旧内容",
            sourcePath: "/old/SKILL.md", contentHash: "old", executableRisk: true,
            stableID: stableID, enabled: true
        )
        let incoming = ImportedResource(
            kind: .skill, name: "图像生成与编辑", summary: "生成和编辑图片。", instructions: "新内容",
            sourcePath: "/new/SKILL.md", contentHash: "new", executableRisk: true,
            stableID: stableID, enabled: false
        )

        let first = ResourceLibraryMerger.merge(existing: [existing], incoming: [incoming])
        let second = ResourceLibraryMerger.merge(existing: first.resources, incoming: [incoming])

        XCTAssertEqual(first.report.added, 0)
        XCTAssertEqual(first.report.updated, 1)
        XCTAssertEqual(first.resources.count, 1)
        XCTAssertEqual(first.resources[0].id, existingID)
        XCTAssertTrue(first.resources[0].enabled)
        XCTAssertEqual(first.resources[0].name, "图像生成与编辑")
        XCTAssertEqual(second.report.unchanged, 1)
        XCTAssertEqual(second.resources, first.resources)
    }

    func testImportedResourceDecodesLegacyRecordWithoutStableID() throws {
        let id = UUID()
        let json = """
        [{"id":"\(id.uuidString)","kind":"Skill","name":"旧资源","summary":"旧说明","instructions":"内容","sourcePath":"/legacy/SKILL.md","contentHash":"legacy","executableRisk":false,"enabled":true,"importedAt":"1970-01-01T00:00:00Z"}]
        """

        let decoded = try JSONDecoder.visionStack.decode([ImportedResource].self, from: Data(json.utf8))

        XCTAssertEqual(decoded.first?.id, id)
        XCTAssertNil(decoded.first?.stableID)
        XCTAssertNil(decoded.first?.mediaDomains)
        XCTAssertNil(decoded.first?.assignedSkillStableIDs)
    }

    @MainActor func testDefaultDistributionRejectsUnconsentedImageAndVideoWithoutCallingProvider() async {
        let root = FileManager.default.temporaryDirectory.appending(path: "visionstack-default-consent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeModelHubService()
        // Deliberately omit distributionProfile: an ordinary source build must remain public-safe.
        let store = AppStore(persistence: PersistenceService(root: root), modelHubFactory: { _, _ in fake })
        let model = ModelDescriptor(id: "fixture/multimodal", owner: "fixture", availability: "available")
        store.connection = .connected(1)
        store.models = [model]
        store.capabilities[model.id] = CapabilityProfile(modelID: model.id, operations: [.image, .video], source: .modelHub)
        XCTAssertTrue(store.requiresThirdPartyAIConsent)

        await store.generateImage(prompt: "本地模拟", size: "1024x1024", quality: "auto", model: model.id, confirmBillable: true)
        await store.generateVideo(prompt: "本地模拟", size: "720p", ratio: "16:9", duration: 5, model: model.id, confirmBillable: true)

        XCTAssertTrue(store.showingThirdPartyAIConsent)
        XCTAssertTrue(store.imageJobs.isEmpty)
        XCTAssertTrue(store.videoJobs.isEmpty)
        let requests = await fake.receivedContexts
        let videoPrompts = await fake.receivedVideoPrompts
        XCTAssertTrue(requests.isEmpty)
        XCTAssertTrue(videoPrompts.isEmpty)
        await store.flushPersistence()
    }

    @MainActor func testPublicReleaseRequiresExplicitThirdPartyAIConsentAndSupportsRevocation() async {
        let root = FileManager.default.temporaryDirectory.appending(path: "visionstack-public-consent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(
            persistence: PersistenceService(root: root),
            modelHubFactory: { _, _ in throw VisionStackError.server("离线") },
            distributionProfile: .publicRelease
        )

        XCTAssertTrue(store.requiresThirdPartyAIConsent)
        store.acceptThirdPartyAIConsent()
        XCTAssertFalse(store.requiresThirdPartyAIConsent)
        XCTAssertEqual(store.thirdPartyAIConsentVersion, ThirdPartyAIConsentPolicy.currentVersion)
        store.revokeThirdPartyAIConsent()
        XCTAssertTrue(store.requiresThirdPartyAIConsent)
        XCTAssertNil(store.thirdPartyAIConsentVersion)
        await store.flushPersistence()
    }

    func testPublicSafeResourceFilterRemovesPersonalAndUnknownResources() throws {
        let scan = try LocalMediaSkillCatalog.scan(
            homeDirectory: FileManager.default.temporaryDirectory,
            includeBundledAgents: true
        )
        let restricted = ImportedResource(
            kind: .skill,
            name: "个人资源",
            summary: "不得进入公开包",
            instructions: "仅限本机",
            sourcePath: "/fixture/personal",
            contentHash: "personal",
            executableRisk: false,
            stableID: "codex.personal-only",
            mediaDomains: [.image]
        )

        let filtered = LocalMediaSkillCatalog.publicSafeResources(from: scan.resources + [restricted])
        XCTAssertEqual(filtered.count, LocalMediaSkillCatalog.descriptors.count + LocalMediaAgentCatalog.resources.count)
        XCTAssertFalse(filtered.contains { $0.stableID == restricted.stableID })
        XCTAssertTrue(filtered.allSatisfy { $0.sourcePath.hasPrefix("visionstack://") || $0.sourcePath.contains("ManagedSkills/") })
    }

    @MainActor func testBootstrapCanInstallLocalMediaSkillsOnceWhenExplicitlyRequested() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "visionstack-bootstrap-media-skills-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let resource = ImportedResource(
            kind: .skill, name: "图像生成与编辑", summary: "生成和编辑图片。", instructions: "说明",
            sourcePath: "/fixture/SKILL.md", contentHash: "fixture", executableRisk: false,
            stableID: "codex.imagegen"
        )
        let store = AppStore(
            persistence: PersistenceService(root: root),
            modelHubFactory: { _, _ in throw VisionStackError.server("离线") },
            automaticallyImportsLocalMediaSkills: true,
            localMediaSkillLoader: { LocalMediaSkillScanResult(resources: [resource], missingStableIDs: []) }
        )

        await store.bootstrap()
        await store.flushPersistence()

        XCTAssertEqual(store.resources.map(\.stableID), ["codex.imagegen"])
        let savedData = try Data(contentsOf: root.appending(path: "resources.json"))
        let saved = try JSONDecoder.visionStack.decode([ImportedResource].self, from: savedData)
        XCTAssertEqual(saved.map(\.stableID), ["codex.imagegen"])
    }

    @discardableResult
    private func runProcess(_ executable: URL, _ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = error.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw VisionStackError.server(
                String(data: stderr, encoding: .utf8) ?? "本机媒体探针失败（\(process.terminationStatus)）。"
            )
        }
        return String(data: stdout, encoding: .utf8) ?? ""
    }
}

private extension FakeModelHubService {
    func setImageDelayForTesting(_ value: Duration) { imageDelay = value }
    func setCancelErrorForTesting(_ value: URLError) { cancelError = value }
    func setVideoDelayForTesting(_ value: Duration) { videoDelay = value }
    func setVideoTaskErrorForTesting(_ value: URLError) { videoTaskError = value }
    func imageWasCancelledForTesting() -> Bool { imageWasCancelled }
    func videoWasCancelledForTesting() -> Bool { videoWasCancelled }
    func setReconciliationResponseForTesting(_ value: ParsedGenerationResponse) { reconciliationResponse = value }
    func setReconciliationErrorForTesting(_ value: VisionStackError) { reconciliationError = value }
}
