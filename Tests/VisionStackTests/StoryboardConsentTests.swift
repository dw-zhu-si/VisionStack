import Foundation
import XCTest
@testable import VisionStack

private actor StoryboardSubmissionStub: ModelHubServicing {
    private(set) var requests: [BillableRequestContext] = []
    private var submissionHook: (@Sendable () async -> Void)?

    func setSubmissionHook(_ hook: @escaping @Sendable () async -> Void) {
        submissionHook = hook
    }

    func health() async throws -> ModelHubRuntimeStatus {
        throw VisionStackError.server("此测试不连接 ModelHub。")
    }

    func catalog() async throws -> ModelCatalog {
        throw VisionStackError.server("此测试不读取外部模型目录。")
    }

    func capabilities(for modelID: String) async throws -> CapabilityProfile {
        throw VisionStackError.server("此测试只使用本地能力夹具。")
    }

    func chat(model: String, messages: [[String: String]], requestContext: BillableRequestContext) async throws -> String {
        throw VisionStackError.server("此测试不执行对话。")
    }

    func generateImage(model: String, prompt: String, size: String, quality: String, referenceImage: String?, requestContext: BillableRequestContext) async throws -> ParsedGenerationResponse {
        throw VisionStackError.server("此测试不生成图片。")
    }

    func generateVideo(model: String, prompt: String, size: String, ratio: String, duration: Int, referenceImage: String?, requestContext: BillableRequestContext) async throws -> ParsedGenerationResponse {
        requests.append(requestContext)
        let hook = submissionHook
        submissionHook = nil
        await hook?()
        // 仅模拟“是否受理未知”，不创建轮询、网络请求或媒体文件。
        throw URLError(.timedOut)
    }

    func videoTask(model: String, taskID: String) async throws -> ParsedGenerationResponse {
        throw VisionStackError.server("此测试不轮询外部任务。")
    }

    func requestStatus(model: String, clientRequestID: UUID) async throws -> ParsedGenerationResponse {
        throw VisionStackError.server("此测试不查询外部请求。")
    }

    func cancelVideoTask(model: String, taskID: String) async throws {
        throw VisionStackError.server("此测试不取消外部任务。")
    }
}

final class StoryboardConsentTests: XCTestCase {
    @MainActor
    private func makeStore(root: URL, service: StoryboardSubmissionStub, shotCount: Int = 2) -> AppStore {
        let store = AppStore(
            persistence: PersistenceService(root: root),
            modelHubFactory: { _, _ in service },
            distributionProfile: .publicRelease
        )
        let project = CreativeProject(name: "分镜授权回归")
        let model = ModelDescriptor(id: "fixture/video", owner: "fixture", availability: "available")
        store.projects = [project]
        store.selectedProjectID = project.id
        store.connection = .connected(1)
        store.models = [model]
        store.preferredVideoModel = model.id
        store.capabilities[model.id] = CapabilityProfile(modelID: model.id, operations: [.video], source: .modelHub)
        store.storyboardShots = (0..<shotCount).map { index in
            StoryboardShot(order: index, title: "镜头 \(index + 1)", prompt: "镜头 \(index + 1) 向前推进", durationSeconds: 5, projectID: project.id)
        }
        return store
    }

    @MainActor func testUnacceptedConsentKeepsEveryShotPendingAndPersistsPausedQueue() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "visionstack-storyboard-consent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = StoryboardSubmissionStub()
        let store = makeStore(root: root, service: service)
        let expectedIDs = store.storyboardShots.map(\.id)

        await store.generateStoryboardBatch(size: "720p", ratio: "16:9")

        let queue = try XCTUnwrap(store.currentStoryboardBatchQueue)
        XCTAssertEqual(queue.pendingShotIDs, expectedIDs)
        XCTAssertTrue(queue.submittedShotIDs.isEmpty)
        XCTAssertTrue(queue.isPaused)
        XCTAssertTrue(store.videoJobs.isEmpty)
        XCTAssertTrue(store.showingThirdPartyAIConsent)
        XCTAssertFalse(store.notice?.contains("全部提交") == true)
        let requests = await service.requests
        XCTAssertTrue(requests.isEmpty)
        await store.flushPersistence()
        let saved = try await PersistenceService(root: root).load()
        XCTAssertEqual(saved.snapshot?.storyboardBatchQueues?.first?.pendingShotIDs, expectedIDs)
        XCTAssertEqual(saved.snapshot?.storyboardBatchQueues?.first?.isPaused, true)
    }

    @MainActor func testRevocationDuringFirstSubmissionPausesRemainingShotsWithoutLosingTheRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "visionstack-storyboard-revoke-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = StoryboardSubmissionStub()
        let store = makeStore(root: root, service: service)
        let shotIDs = store.storyboardShots.map(\.id)
        store.acceptThirdPartyAIConsent()
        await service.setSubmissionHook { @MainActor [weak store] in
            store?.revokeThirdPartyAIConsent()
        }

        await store.generateStoryboardBatch(size: "720p", ratio: "16:9")

        let queue = try XCTUnwrap(store.currentStoryboardBatchQueue)
        XCTAssertEqual(queue.submittedShotIDs, [shotIDs[0]])
        XCTAssertEqual(queue.pendingShotIDs, [shotIDs[1]])
        XCTAssertTrue(queue.isPaused)
        XCTAssertEqual(store.videoJobs.count, 1)
        XCTAssertEqual(store.videoJobs.first?.storyboardShotID, shotIDs[0])
        XCTAssertEqual(store.videoJobs.first?.submissionState, .unknown)
        XCTAssertNotNil(store.videoJobs.first?.idempotencyKey)
        XCTAssertFalse(store.notice?.contains("全部提交") == true)
        let requests = await service.requests
        XCTAssertEqual(requests.count, 1)
        await store.flushPersistence()
    }

    @MainActor func testGrantingConsentAndResumingSubmitsEachPendingShotExactlyOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "visionstack-storyboard-resume-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = StoryboardSubmissionStub()
        let store = makeStore(root: root, service: service)
        let expectedIDs = store.storyboardShots.map(\.id)
        await store.generateStoryboardBatch(size: "720p", ratio: "16:9")

        store.acceptThirdPartyAIConsent()
        await store.resumeStoryboardBatch()
        await store.resumeStoryboardBatch()

        let queue = try XCTUnwrap(store.currentStoryboardBatchQueue)
        XCTAssertTrue(queue.pendingShotIDs.isEmpty)
        XCTAssertEqual(queue.submittedShotIDs, expectedIDs)
        XCTAssertEqual(store.videoJobs.count, expectedIDs.count)
        XCTAssertEqual(Set(store.videoJobs.compactMap(\.storyboardShotID)), Set(expectedIDs))
        let requests = await service.requests
        XCTAssertEqual(requests.count, expectedIDs.count)
        XCTAssertEqual(Set(requests.map(\.idempotencyKey)).count, expectedIDs.count)
        await store.flushPersistence()
    }

    @MainActor func testUnavailableModelPausesQueueAndCanResumeAfterModelIsRestored() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "visionstack-storyboard-model-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = StoryboardSubmissionStub()
        let store = makeStore(root: root, service: service, shotCount: 1)
        let expectedIDs = store.storyboardShots.map(\.id)
        store.acceptThirdPartyAIConsent()
        store.preferredVideoModel = "fixture/unavailable"

        await store.generateStoryboardBatch(size: "720p", ratio: "16:9")

        XCTAssertEqual(store.currentStoryboardBatchQueue?.pendingShotIDs, expectedIDs)
        XCTAssertEqual(store.currentStoryboardBatchQueue?.submittedShotIDs, [])
        XCTAssertEqual(store.currentStoryboardBatchQueue?.isPaused, true)
        XCTAssertTrue(store.videoJobs.isEmpty)

        store.preferredVideoModel = "fixture/video"
        await store.resumeStoryboardBatch()
        XCTAssertEqual(store.currentStoryboardBatchQueue?.pendingShotIDs, [])
        XCTAssertEqual(store.currentStoryboardBatchQueue?.submittedShotIDs, expectedIDs)
        XCTAssertEqual(store.videoJobs.count, 1)
        await store.flushPersistence()
    }

    @MainActor func testInvalidPromptRemainsPendingInsteadOfCountingAsSubmitted() async throws {
        for prompt in [" \n ", String(repeating: "镜", count: MediaPromptComposer.maximumUserPromptCharacters + 1)] {
            let root = FileManager.default.temporaryDirectory.appending(path: "visionstack-storyboard-prompt-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let service = StoryboardSubmissionStub()
            let store = makeStore(root: root, service: service, shotCount: 1)
            store.acceptThirdPartyAIConsent()
            store.storyboardShots[0].prompt = prompt
            let expectedID = store.storyboardShots[0].id

            await store.generateStoryboardBatch(size: "720p", ratio: "16:9")

            XCTAssertEqual(store.currentStoryboardBatchQueue?.pendingShotIDs, [expectedID])
            XCTAssertEqual(store.currentStoryboardBatchQueue?.submittedShotIDs, [])
            XCTAssertEqual(store.currentStoryboardBatchQueue?.isPaused, true)
            XCTAssertTrue(store.videoJobs.isEmpty)
            await store.flushPersistence()
        }
    }

    @MainActor func testUnavailableReferenceRemainsPendingInsteadOfCountingAsSubmitted() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "visionstack-storyboard-reference-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = StoryboardSubmissionStub()
        let store = makeStore(root: root, service: service, shotCount: 1)
        store.acceptThirdPartyAIConsent()
        store.storyboardShots[0].referenceAssetID = UUID()
        let expectedID = store.storyboardShots[0].id

        await store.generateStoryboardBatch(size: "720p", ratio: "16:9")

        XCTAssertEqual(store.currentStoryboardBatchQueue?.pendingShotIDs, [expectedID])
        XCTAssertEqual(store.currentStoryboardBatchQueue?.submittedShotIDs, [])
        XCTAssertEqual(store.currentStoryboardBatchQueue?.isPaused, true)
        XCTAssertTrue(store.videoJobs.isEmpty)
        await store.flushPersistence()
    }

    @MainActor func testMissingQueuedShotIsPausedWithoutInventingASubmittedTask() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "visionstack-storyboard-missing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = StoryboardSubmissionStub()
        let store = makeStore(root: root, service: service, shotCount: 0)
        let missingID = UUID()
        let projectID = try XCTUnwrap(store.selectedProjectID)
        store.acceptThirdPartyAIConsent()
        store.storyboardBatchQueues = [StoryboardBatchQueue(projectID: projectID, pendingShotIDs: [missingID], resolution: "720p", aspectRatio: "16:9")]

        await store.resumeStoryboardBatch()

        XCTAssertEqual(store.currentStoryboardBatchQueue?.pendingShotIDs, [missingID])
        XCTAssertEqual(store.currentStoryboardBatchQueue?.submittedShotIDs, [])
        XCTAssertEqual(store.currentStoryboardBatchQueue?.isPaused, true)
        XCTAssertTrue(store.videoJobs.isEmpty)
        await store.flushPersistence()
    }

    @MainActor func testResumingWhileSubmissionIsInFlightDoesNotCreateASecondBillableRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "visionstack-storyboard-reentrant-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = StoryboardSubmissionStub()
        let store = makeStore(root: root, service: service, shotCount: 1)
        let expectedID = store.storyboardShots[0].id
        store.acceptThirdPartyAIConsent()
        await service.setSubmissionHook { @MainActor [weak store] in
            await store?.resumeStoryboardBatch()
        }

        await store.generateStoryboardBatch(size: "720p", ratio: "16:9")

        XCTAssertEqual(store.currentStoryboardBatchQueue?.submittedShotIDs, [expectedID])
        XCTAssertEqual(store.currentStoryboardBatchQueue?.pendingShotIDs, [])
        XCTAssertEqual(store.videoJobs.count, 1)
        let requests = await service.requests
        XCTAssertEqual(requests.count, 1)
        await store.flushPersistence()
    }
}
