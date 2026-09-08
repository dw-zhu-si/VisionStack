import Foundation

enum StudioMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case chat, image, video
    var id: String { rawValue }
    var title: String { switch self { case .chat: "对话"; case .image: "生图"; case .video: "视频" } }
    var subtitle: String {
        switch self { case .chat: "研究、策划与调度"; case .image: "构图、生成与迭代"; case .video: "分镜、生成与交付" }
    }
    var symbol: String { switch self { case .chat: "text.bubble"; case .image: "photo.on.rectangle.angled"; case .video: "film.stack" } }
    var shortcut: Character { switch self { case .chat: "1"; case .image: "2"; case .video: "3" } }
}

enum CreativeOperation: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case chat, image, video
    var id: String { rawValue }
    var title: String { switch self { case .chat: "对话"; case .image: "图片"; case .video: "视频" } }
}

enum CapabilitySource: String, Codable, Hashable, Sendable {
    case modelHub = "ModelHub 声明"
    case localProfile = "本地兼容档案"
    case bundledProfile = "内置匹配档案"
    case unsupported = "已识别·当前不支持"
    case nameCandidate = "旧版名称候选"
    case unknown = "尚未配置"
}

struct ModelDescriptor: Identifiable, Codable, Hashable, Sendable {
    static let manualSource = "visionstack-manual"
    let id: String
    var owner: String
    var availability: String
    var source: String? = nil
    var constraintScope: String? = nil
    var connectionID: UUID? = nil

    var isRoute: Bool { source == "route" }
    var isManual: Bool { source == Self.manualSource }
    var isAvailable: Bool {
        let value = availability.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.isEmpty || ["available", "ready", "online", "enabled", "active"].contains(value)
    }
}

struct CapabilityProfile: Identifiable, Codable, Hashable, Sendable {
    var id: String { modelID }
    let modelID: String
    var operations: Set<CreativeOperation>
    var imageSizes: [String] = []
    var aspectRatios: [String] = []
    var qualities: [String] = []
    var videoResolutions: [String] = []
    var durations: [Int] = []
    var source: CapabilitySource
    var verifiedAt: Date?
    var inputModalities: [String]? = nil
    var imageMinimumWidth: Int? = nil
    var imageMaximumWidth: Int? = nil
    var imageMinimumHeight: Int? = nil
    var imageMaximumHeight: Int? = nil
    var isResolved: Bool { ![.nameCandidate, .unknown].contains(source) }
    var isConfigured: Bool { !operations.isEmpty && [.modelHub, .localProfile, .bundledProfile].contains(source) }
    var supportsReferenceImage: Bool { inputModalities?.contains(where: { $0.lowercased() == "image" }) == true }
}

struct ModelCatalog: Sendable {
    let models: [ModelDescriptor]
    let embeddedCapabilities: [CapabilityProfile]
}

struct ModelHubRuntimeStatus: Equatable, Sendable {
    let service: String
    let providerCount: Int
    let routeCount: Int
}

enum BillingGateStatus: Equatable, Sendable {
    case confirmationRequired
    case blocked(String)

    var allowsRequest: Bool {
        if case .blocked = self { return false }
        return true
    }

    var title: String {
        switch self {
        case .confirmationRequired: "调用携带计费授权"
        case .blocked: "余额或计费状态受限"
        }
    }

    var detail: String? {
        if case .blocked(let message) = self { return message }
        return nil
    }
}

enum ChatRole: String, Codable, Sendable { case system, user, assistant }

struct ResearchSource: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    let title: String
    let url: String
    let snippet: String
}

struct SearchOutcome: Sendable {
    let sources: [ResearchSource]
    let warning: String?
}

struct StudioMessage: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    let role: ChatRole
    let content: String
    var sources: [ResearchSource] = []
    var createdAt = Date()
}

struct Conversation: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var title: String
    var messages: [StudioMessage]
    var createdAt = Date()
    var updatedAt = Date()
    var projectID: UUID? = nil
    var archivedAt: Date? = nil
}

struct CreativeProject: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var summary: String = ""
    var createdAt = Date()
    var updatedAt = Date()
    var archivedAt: Date? = nil
}

enum ResourceKind: String, Codable, Sendable { case agent = "Agent"; case skill = "Skill" }

enum MediaResourceDomain: String, Codable, CaseIterable, Hashable, Sendable {
    case image
    case video
    case shared
    case utility

    var title: String {
        switch self {
        case .image: "生图"
        case .video: "视频"
        case .shared: "生图与视频"
        case .utility: "辅助工具"
        }
    }

    func applies(to operation: CreativeOperation) -> Bool {
        switch (self, operation) {
        case (.image, .image), (.video, .video), (.shared, .image), (.shared, .video): true
        default: false
        }
    }
}

struct ImportedResource: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    let kind: ResourceKind
    let name: String
    let summary: String
    let instructions: String
    let sourcePath: String
    let contentHash: String
    let executableRisk: Bool
    var stableID: String? = nil
    var mediaDomains: Set<MediaResourceDomain>? = nil
    var assignedSkillStableIDs: [String]? = nil
    var enabled = true
    var importedAt = Date()

    var classifiedMediaDomains: Set<MediaResourceDomain> { mediaDomains ?? [] }
    var assignedSkillIDs: [String] { assignedSkillStableIDs ?? [] }

    func applies(to operation: CreativeOperation) -> Bool {
        classifiedMediaDomains.contains { $0.applies(to: operation) }
    }
}

enum GenerationKind: String, Codable, Sendable { case image = "图片"; case video = "视频" }

struct ReferenceAsset: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var localURL: String
    var createdAt = Date()
    var sourceJobID: UUID? = nil
    var projectID: UUID? = nil
}

enum ImageReferenceRole: String, Codable, Hashable, Sendable, CaseIterable {
    case general
    case identity
    case photographyPlan

    var title: String {
        switch self {
        case .general: "通用参考"
        case .identity: "身份参考"
        case .photographyPlan: "摄影方案参考"
        }
    }
}

struct ImageReferenceBinding: Codable, Hashable, Sendable {
    let assetID: UUID
    let role: ImageReferenceRole
}

struct StoryboardShot: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var order: Int
    var title: String
    var prompt: String
    var durationSeconds: Int
    var referenceAssetID: UUID? = nil
    var createdAt = Date()
    var updatedAt = Date()
    var projectID: UUID? = nil
}

struct TimelineSegment: Equatable, Sendable {
    let shotID: UUID
    let startSeconds: Int
    let durationSeconds: Int
}

enum StoryboardTimelineLayout {
    static func segments(for shots: [StoryboardShot]) -> [TimelineSegment] {
        var cursor = 0
        return shots.sorted { $0.order < $1.order }.map { shot in
            defer { cursor += max(1, shot.durationSeconds) }
            return TimelineSegment(shotID: shot.id, startSeconds: cursor, durationSeconds: max(1, shot.durationSeconds))
        }
    }
}

enum JobState: String, Codable, Sendable {
    case queued = "排队中"
    case running = "生成中"
    case succeeded = "已完成"
    case failed = "失败"
    case timedOut = "已超时"
    case cancelled = "已取消"
    case submissionUnknown = "提交待确认"
    case pollingDegraded = "查询中断"
    case cancelPending = "取消待确认"
    case needsArchive = "待存本机"

    var isTerminal: Bool { [.succeeded, .failed, .timedOut, .cancelled, .needsArchive].contains(self) }
    var requiresReconciliation: Bool { [.submissionUnknown, .pollingDegraded, .cancelPending].contains(self) }
    var isActivelyExecuting: Bool { [.queued, .running].contains(self) }
}

enum SubmissionState: String, Codable, Hashable, Sendable {
    case notSubmitted, submitting, submitted, unknown, rejected
}

enum ProviderState: String, Codable, Hashable, Sendable {
    case notStarted, queued, running, succeeded, failed, cancelPending, cancelled, unknown
}

enum ArchiveState: String, Codable, Hashable, Sendable {
    case notRequired, pending, downloading, succeeded, failed, missing
}

struct BillableRequestContext: Codable, Hashable, Sendable {
    let clientRequestID: UUID
    let idempotencyKey: String
    let confirmBillable: Bool

    static func new(confirmBillable: Bool) -> BillableRequestContext {
        let requestID = UUID()
        return BillableRequestContext(
            clientRequestID: requestID,
            idempotencyKey: "visionstack-\(requestID.uuidString.lowercased())",
            confirmBillable: confirmBillable
        )
    }
}

struct JobCostRecord: Codable, Hashable, Sendable {
    var currency: String = "CNY"
    var estimatedAmount: Decimal?
    var actualAmount: Decimal?
    var inputTokens: Int?
    var outputTokens: Int?
    var providerReported = false
}

struct MediaHealthReport: Equatable, Sendable {
    var checkedAt = Date()
    var missingJobFiles: [String] = []
    var missingReferenceFiles: [String] = []
    var orphanedManagedFiles: [String] = []

    var issueCount: Int { missingJobFiles.count + missingReferenceFiles.count + orphanedManagedFiles.count }
    var isHealthy: Bool { issueCount == 0 }
}

struct GenerationJob: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    let kind: GenerationKind
    let prompt: String
    let model: String
    var parameters: [String: String]
    var state: JobState
    var taskID: String?
    var resultURLs: [String] = []
    var remoteResultURLs: [String]?
    var progress: Double? = nil
    var favorite: Bool? = nil
    var tags: [String]? = nil
    var collection: String? = nil
    var parentJobID: UUID? = nil
    var batchID: UUID? = nil
    var versionIndex: Int? = nil
    var referenceAssetID: UUID? = nil
    var imageReferences: [ImageReferenceBinding]? = nil
    var storyboardShotID: UUID? = nil
    var rawResponse: String = ""
    var errorMessage: String?
    var createdAt = Date()
    var updatedAt = Date()
    var submissionState: SubmissionState? = nil
    var providerState: ProviderState? = nil
    var archiveState: ArchiveState? = nil
    var clientRequestID: UUID? = nil
    var idempotencyKey: String? = nil
    var retryGroupID: UUID? = nil
    var lastReconciledAt: Date? = nil
    var cost: JobCostRecord? = nil
    var projectID: UUID? = nil
    var agentStableID: String? = nil
    var skillStableIDs: [String]? = nil

    var effectiveImageReferences: [ImageReferenceBinding] {
        if let imageReferences, !imageReferences.isEmpty { return imageReferences }
        return referenceAssetID.map { [ImageReferenceBinding(assetID: $0, role: .general)] } ?? []
    }

    var effectiveRetryGroupID: UUID { retryGroupID ?? parentJobID ?? id }
    var requiresArchiveRecovery: Bool {
        if providerState == .succeeded, archiveState != .succeeded { return true }
        return !(remoteResultURLs ?? []).isEmpty && resultURLs.isEmpty
    }
    var canCreateBillableRetry: Bool {
        guard state.isTerminal else { return false }
        guard !requiresArchiveRecovery, providerState != .succeeded else { return false }
        guard submissionState != .unknown, providerState != .cancelPending else { return false }
        return [.failed, .timedOut, .cancelled].contains(state)
    }
}

enum GenerationRetryPolicy {
    static func hasActiveJob(in retryGroupID: UUID, jobs: [GenerationJob]) -> Bool {
        jobs.contains { job in
            guard job.effectiveRetryGroupID == retryGroupID else { return false }
            return job.state.isActivelyExecuting || job.state.requiresReconciliation
        }
    }
}

struct ParsedGenerationResponse: Sendable {
    let raw: String
    let taskID: String?
    let mediaURLs: [String]
    let state: JobState?
    let errorMessage: String?
    let cost: JobCostRecord?

    init(raw: String, taskID: String?, mediaURLs: [String], state: JobState?, errorMessage: String?, cost: JobCostRecord? = nil) {
        self.raw = raw
        self.taskID = taskID
        self.mediaURLs = mediaURLs
        self.state = state
        self.errorMessage = errorMessage
        self.cost = cost
    }
}

struct AppSnapshot: Codable, Sendable {
    static let currentSchemaVersion = 11
    var schemaVersion = currentSchemaVersion
    var conversations: [Conversation]
    var selectedConversationID: UUID?
    var imageJobs: [GenerationJob]
    var videoJobs: [GenerationJob]
    var selectedAgentID: UUID?
    var selectedSkillIDs: Set<UUID>
    var selectedImageAgentID: UUID? = nil
    var selectedImageSkillIDs: Set<UUID>? = nil
    var selectedVideoAgentID: UUID? = nil
    var selectedVideoSkillIDs: Set<UUID>? = nil
    var baseURL: String
    var preferredChatModel: String
    var preferredImageModel: String
    var preferredVideoModel: String
    var webSearchEnabled: Bool
    var cachedModels: [ModelDescriptor]
    var cachedCapabilities: [CapabilityProfile]
    var customCapabilities: [CapabilityProfile]
    var providerConnections: [AIProviderConfiguration]? = nil
    var selectedProviderID: UUID? = nil
    var manualModels: [ModelDescriptor]? = nil
    var contextBudgetTokens: Int?
    var maxConcurrentGenerationTasks: Int?
    var referenceAssets: [ReferenceAsset]?
    var storyboardShots: [StoryboardShot]?
    var projects: [CreativeProject]? = nil
    var selectedProjectID: UUID? = nil
    var completionNotificationsEnabled: Bool? = nil
    var versionReviews: [VersionReview]? = nil
    var creativePresets: [CreativePreset]? = nil
    var storyboardBatchQueues: [StoryboardBatchQueue]? = nil
    var roughCuts: [RoughCutProject]? = nil
    var thirdPartyAIConsentVersion: Int? = nil
}

struct ContextBudgetReport: Equatable, Sendable {
    let estimatedTokens: Int
    let includedMessageCount: Int
    let droppedMessageCount: Int
    let truncatedSystemPrompt: Bool
}

struct PreparedChatContext: Sendable {
    let messages: [[String: String]]
    let report: ContextBudgetReport
}

struct PersistenceLoad: Sendable {
    let snapshot: AppSnapshot?
    let resources: [ImportedResource]
    let recoveryNotice: String?
    let migratedLegacyState: Bool
}

enum ConnectionStatus: Equatable, Sendable {
    case offline, connecting, connected(Int), failed(String)
    var title: String {
        switch self {
        case .offline: "模型服务离线"
        case .connecting: "正在连接"
        case .connected(let count): "\(count) 个模型可用"
        case .failed: "连接需要处理"
        }
    }
    var isConnected: Bool { if case .connected = self { return true }; return false }
    var detail: String? { if case .failed(let message) = self { return message }; return nil }
}

enum VisionStackError: LocalizedError, Sendable {
    case invalidLoopbackURL
    case invalidResponse(String = "服务返回了无法识别的数据。")
    case server(String)
    case httpStatus(Int, String)
    case noModel(String)
    case importFailed(String)
    case searchFailed(String)
    case mediaArchiveFailed(String)
    case billingBlocked(String)
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case .invalidLoopbackURL: "ModelHub 地址必须是 localhost、127.0.0.1 或 ::1，并且不能包含账号、查询参数或未知路径。"
        case .invalidResponse(let message): message
        case .server(let message): message
        case .httpStatus(_, let message): message
        case .noModel(let mode): "请先为\(mode)选择并配置一个当前可用模型。"
        case .importFailed(let message): message
        case .searchFailed(let message): message
        case .mediaArchiveFailed(let message): message
        case .billingBlocked(let message): message
        case .unsupportedSchema(let version): "本地数据版本 \(version) 高于当前应用支持的版本，已停止覆盖原文件。"
        }
    }
}
