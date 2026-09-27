#if DEBUG
import Foundation

private actor UIAuditCredentialStore: ProviderCredentialStoring {
    private var values: [UUID: String] = [:]
    func readSecret(for providerID: UUID) async -> String { values[providerID] ?? "" }
    func saveSecret(_ secret: String, for providerID: UUID) async throws { values[providerID] = secret }
    func deleteSecret(for providerID: UUID) async throws { values.removeValue(forKey: providerID) }
}

/// Synthetic fixtures exercise the real UI and persistence. They never establish a model connection.
@MainActor
enum UIAuditHarness {
    static var isEnabled: Bool {
        CommandLine.arguments.contains("--ui-audit") ||
        (Bundle.main.bundleIdentifier?.hasSuffix(".ui-audit") == true && Bundle.main.object(forInfoDictionaryKey: "VisionStackUIAuditMode") as? Bool == true)
    }
    static func makeStore() -> AppStore {
        precondition(Bundle.main.bundleIdentifier?.hasSuffix(".ui-audit") == true,
                     "UI audit requires its own .ui-audit bundle identifier")
        let root = FileManager.default.temporaryDirectory.appending(path: "visionstack-ui-audit-\(UUID().uuidString)", directoryHint: .isDirectory)
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        catch { fatalError("Cannot create isolated UI audit directory") }
        print("VISIONSTACK_UI_AUDIT_STATE=\(root.appending(path: "state.json").path)")
        let store = AppStore(
            persistence: PersistenceService(root: root),
            modelHubFactory: { _, _ in throw VisionStackError.invalidResponse("隔离 UI 验收禁止网络请求") },
            providerFactory: { _, _ in throw VisionStackError.invalidResponse("隔离 UI 验收禁止网络请求") },
            providerCredentialStore: UIAuditCredentialStore(),
            automaticallyImportsLocalMediaSkills: false,
            localMediaSkillLoader: { throw VisionStackError.invalidResponse("隔离 UI 验收禁止读取本机能力资源") },
            distributionProfile: .personal
        )
        let first = CreativeProject(name: "验收项目 A", summary: "合成测试数据；无真实生成")
        let second = CreativeProject(name: "验收项目 B", summary: "项目切换与草稿隔离")
        store.projects = [first, second]
        let conversationA = Conversation(title: "验收对话 A", messages: [StudioMessage(role: .assistant, content: "这是隔离界面的合成测试内容。")], projectID: first.id)
        let conversationB = Conversation(title: "验收对话 B", messages: [], projectID: second.id)
        store.conversations = [conversationA, conversationB]
        store.selectedProjectID = first.id
        store.selectedConversationID = conversationA.id
        let provider = AIProviderConfiguration(id: UUID(), displayName: "离线验收连接", kind: .openAICompatible, baseURL: "https://ui-audit.invalid/v1", manualModelIDs: [])
        store.providerConnections = [provider]
        store.selectedProviderID = provider.id
        store.baseURL = provider.baseURL
        store.models = [ModelDescriptor(id: "audit/chat", owner: "离线样例", availability: "available"), ModelDescriptor(id: "audit/image", owner: "离线样例", availability: "available"), ModelDescriptor(id: "audit/video", owner: "离线样例", availability: "available")]
        store.preferredChatModel = "audit/chat"
        store.preferredImageModel = "audit/image"
        store.preferredVideoModel = "audit/video"
        // Use production configuration entry points so capability caches and defaults are consistent.
        store.saveCustomCapability(modelID: "audit/chat", operations: [.chat], imageSizes: [], qualities: [], videoResolutions: [], aspectRatios: [], durations: [])
        store.saveCustomCapability(modelID: "audit/image", operations: [.image], imageSizes: ["1024x1024", "1536x1024"], qualities: ["auto", "high"], videoResolutions: [], aspectRatios: [], durations: [])
        store.saveCustomCapability(modelID: "audit/video", operations: [.video], imageSizes: [], qualities: [], videoResolutions: ["720p", "1080p"], aspectRatios: ["16:9", "9:16"], durations: [5, 10])
        store.preferredChatModel = "audit/chat"
        store.preferredImageModel = "audit/image"
        store.preferredVideoModel = "audit/video"
        let mediaRoot = root.appending(path: "Media", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: mediaRoot, withIntermediateDirectories: true)
            // A fixed one-pixel PNG is deliberately a fixture, not a generated artwork.
            let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
            for index in 1...56 {
                let url = mediaRoot.appending(path: "fixture-\(index).png")
                try png.write(to: url)
                store.imageJobs.append(GenerationJob(kind: .image, prompt: "验收素材 \(String(format: "%02d", index))", model: "audit/image", parameters: [:], state: .succeeded, resultURLs: [url.absoluteString], cost: JobCostRecord(currency: index.isMultiple(of: 2) ? "CNY" : "USD", estimatedAmount: nil, actualAmount: 0), projectID: first.id, connectionID: provider.id, connectionSnapshot: provider))
            }
        } catch { fatalError("Cannot create isolated UI audit fixture media") }
        store.imageJobs.append(GenerationJob(kind: .image, prompt: "验收旧任务：等待绑定原连接", model: "audit/image", parameters: [:], state: .failed, projectID: first.id))
        store.selectProject(second.id)
        store.chatDraft = "项目 B 的对话草稿"
        store.imagePromptDraft = "项目 B 的图片草稿"
        store.selectProject(first.id)
        store.chatDraft = "项目 A 的对话草稿"
        store.imagePromptDraft = "项目 A 的图片草稿"
        store.notice = "隔离 UI 验收：全部为合成数据，所有模型请求均被拒绝。"
        return store
    }
}
#endif
