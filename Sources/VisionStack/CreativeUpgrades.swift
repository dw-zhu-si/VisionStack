import CryptoKit
import Foundation

struct VersionReview: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var jobID: UUID
    var projectID: UUID
    var score: Int
    var notes: String = ""
    var isFinal = false
    var updatedAt = Date()
}

struct ProjectCostSummary: Equatable, Sendable {
    var currency: String
    var knownTotal: Decimal
    var knownCount: Int
    var unknownCount: Int
    var providerReportedCount: Int
}

enum ProjectCostLedger {
    static func summary(for jobs: [GenerationJob]) -> ProjectCostSummary {
        var total = Decimal.zero
        var knownCount = 0
        var unknownCount = 0
        var providerReportedCount = 0
        var currency = "CNY"

        for job in jobs {
            guard let cost = job.cost,
                  let amount = cost.actualAmount ?? cost.estimatedAmount else {
                unknownCount += 1
                continue
            }
            total += amount
            knownCount += 1
            currency = cost.currency
            if cost.providerReported { providerReportedCount += 1 }
        }

        return ProjectCostSummary(
            currency: currency,
            knownTotal: total,
            knownCount: knownCount,
            unknownCount: unknownCount,
            providerReportedCount: providerReportedCount
        )
    }
}

struct StoryboardBatchPreview: Equatable, Sendable {
    var requestCount: Int
    var acceptedShotIDs: [UUID]
    var deferredShotIDs: [UUID]
    var estimatedKnownCost: Decimal?
}

enum StoryboardBatchPlanner {
    static func preview(
        shots: [StoryboardShot],
        availableSlots: Int,
        knownCostPerRequest: Decimal?
    ) -> StoryboardBatchPreview {
        let ordered = shots.sorted { $0.order < $1.order }
        let acceptedCount = min(max(availableSlots, 0), ordered.count)
        return StoryboardBatchPreview(
            requestCount: ordered.count,
            acceptedShotIDs: Array(ordered.prefix(acceptedCount).map(\.id)),
            deferredShotIDs: Array(ordered.dropFirst(acceptedCount).map(\.id)),
            estimatedKnownCost: knownCostPerRequest.map { $0 * Decimal(ordered.count) }
        )
    }
}

struct StoryboardBatchQueue: Codable, Hashable, Sendable {
    var projectID: UUID
    var pendingShotIDs: [UUID]
    var submittedShotIDs: [UUID] = []
    var batchID = UUID()
    var isPaused = false
    var resolution: String
    var aspectRatio: String
    var createdAt = Date()
    var updatedAt = Date()
}

struct CreativePreset: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var operation: CreativeOperation
    var promptPrefix: String = ""
    var brandStyle: String = ""
    var parameters: [String: String] = [:]
    var projectID: UUID? = nil
    var createdAt = Date()
    var updatedAt = Date()
}

struct AppliedCreativePreset: Equatable, Sendable {
    var prompt: String
    var parameters: [String: String]
}

enum CreativePresetResolver {
    static func apply(
        _ preset: CreativePreset,
        to prompt: String,
        parameters: [String: String]
    ) -> AppliedCreativePreset {
        var sections: [String] = []
        let prefix = preset.promptPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let brand = preset.brandStyle.trimmingCharacters(in: .whitespacesAndNewlines)
        let userPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prefix.isEmpty { sections.append(prefix) }
        if !brand.isEmpty { sections.append("品牌风格：\(brand)") }
        if !userPrompt.isEmpty { sections.append(userPrompt) }
        var merged = parameters
        for (key, value) in preset.parameters { merged[key] = value }
        return AppliedCreativePreset(prompt: sections.joined(separator: "\n"), parameters: merged)
    }
}

enum VideoTransitionStyle: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case none
    case crossDissolve
    case fadeThroughBlack

    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "无转场"
        case .crossDissolve: "叠化"
        case .fadeThroughBlack: "黑场淡化"
        }
    }
}

struct RoughCutClip: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var jobID: UUID
    var durationSeconds: Double
    var transition: VideoTransitionStyle = .none
    var transitionDuration: Double = 0
    var caption: String = ""
}

struct RoughCutProject: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var projectID: UUID
    var name: String
    var clips: [RoughCutClip] = []
    var backgroundAudioURL: String? = nil
    var createdAt = Date()
    var updatedAt = Date()
}

struct RoughCutTimelineSegment: Equatable, Sendable {
    var clipID: UUID
    var jobID: UUID
    var startSeconds: Double
    var durationSeconds: Double
    var transition: VideoTransitionStyle
    var transitionDuration: Double
    var caption: String
}

enum RoughCutTimeline {
    static func segments(for clips: [RoughCutClip]) -> [RoughCutTimelineSegment] {
        var cursor = 0.0
        return clips.map { clip in
            let duration = max(0.1, clip.durationSeconds)
            let overlap: Double
            if clip.transition == .none {
                overlap = 0
            } else {
                overlap = min(min(max(clip.transitionDuration, 0), duration / 2), cursor)
            }
            let start = max(0, cursor - overlap)
            let segment = RoughCutTimelineSegment(
                clipID: clip.id,
                jobID: clip.jobID,
                startSeconds: start,
                durationSeconds: duration,
                transition: clip.transition,
                transitionDuration: overlap,
                caption: clip.caption
            )
            cursor = start + duration
            return segment
        }
    }

    static func totalDuration(for segments: [RoughCutTimelineSegment]) -> Double {
        segments.map { $0.startSeconds + $0.durationSeconds }.max() ?? 0
    }
}

struct ProjectBackupPayload: Codable, Sendable {
    static let currentSchemaVersion = 2
    var schemaVersion = currentSchemaVersion
    var exportedAt = Date()
    var project: CreativeProject
    var conversations: [Conversation] = []
    var imageJobs: [GenerationJob] = []
    var videoJobs: [GenerationJob] = []
    var referenceAssets: [ReferenceAsset] = []
    var storyboardShots: [StoryboardShot] = []
    var versionReviews: [VersionReview] = []
    var creativePresets: [CreativePreset] = []
    var roughCuts: [RoughCutProject] = []

    init(
        project: CreativeProject,
        conversations: [Conversation] = [],
        imageJobs: [GenerationJob] = [],
        videoJobs: [GenerationJob] = [],
        referenceAssets: [ReferenceAsset] = [],
        storyboardShots: [StoryboardShot] = [],
        versionReviews: [VersionReview] = [],
        creativePresets: [CreativePreset] = [],
        roughCuts: [RoughCutProject] = []
    ) {
        self.project = project
        self.conversations = conversations
        self.imageJobs = imageJobs
        self.videoJobs = videoJobs
        self.referenceAssets = referenceAssets
        self.storyboardShots = storyboardShots
        self.versionReviews = versionReviews
        self.creativePresets = creativePresets
        self.roughCuts = roughCuts
    }
}

struct ProjectBackupManifest: Codable, Sendable {
    var schemaVersion: Int
    var projectName: String
    var exportedAt: Date
    var files: [String: String]
}

struct ProjectBackupHealth: Codable, Equatable, Sendable {
    var checkedAt = Date()
    var mediaFileCount: Int
    var referenceFileCount: Int
    var missingFiles: [String]
    var hashMismatches: [String]
    var unsafePaths: [String]

    var isHealthy: Bool {
        missingFiles.isEmpty && hashMismatches.isEmpty && unsafePaths.isEmpty
    }
}

enum ProjectBackupService {
    static let payloadName = "project.json"
    static let manifestName = "manifest.json"

    static func write(
        _ original: ProjectBackupPayload,
        to destination: URL,
        fileManager: FileManager = .default
    ) throws -> ProjectBackupHealth {
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw VisionStackError.mediaArchiveFailed("备份目标已存在；映栈不会覆盖旧备份。")
        }
        let temporary = fileManager.temporaryDirectory.appending(path: "visionstack-backup-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: temporary) }
        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let mediaDirectory = temporary.appending(path: "Media", directoryHint: .isDirectory)
        let referenceDirectory = temporary.appending(path: "References", directoryHint: .isDirectory)
        let audioDirectory = temporary.appending(path: ManagedAudioStore.directoryName, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: mediaDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.createDirectory(at: referenceDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.createDirectory(at: audioDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        var payload = original
        payload.schemaVersion = ProjectBackupPayload.currentSchemaVersion
        var missingFiles: [String] = []
        var mediaFileCount = 0
        var referenceFileCount = 0

        func copiedRelativePath(_ value: String, folder: String, prefix: String) throws -> String? {
            guard let source = URL(string: value), source.isFileURL else { return nil }
            let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard fileManager.fileExists(atPath: source.path), values?.isRegularFile == true, values?.isSymbolicLink != true else {
                missingFiles.append(source.lastPathComponent)
                return nil
            }
            if folder == ManagedAudioStore.directoryName { try ManagedAudioStore.validateFile(source) }
            let ext = source.pathExtension.isEmpty ? "bin" : source.pathExtension.lowercased()
            let relative = "\(folder)/\(prefix)-\(UUID().uuidString).\(ext)"
            let target = temporary.appending(path: relative)
            try fileManager.copyItem(at: source, to: target)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            return relative
        }

        func portableJob(_ originalJob: GenerationJob) throws -> GenerationJob {
            var job = originalJob
            job.resultURLs = try originalJob.resultURLs.compactMap { try copiedRelativePath($0, folder: "Media", prefix: originalJob.kind.rawValue) }
            mediaFileCount += job.resultURLs.count
            job.remoteResultURLs = nil
            job.rawResponse = ""
            job.clientRequestID = nil
            job.idempotencyKey = nil
            return job
        }

        payload.imageJobs = try original.imageJobs.map(portableJob)
        payload.videoJobs = try original.videoJobs.map(portableJob)
        payload.referenceAssets = try original.referenceAssets.compactMap { originalAsset in
            guard let relative = try copiedRelativePath(originalAsset.localURL, folder: "References", prefix: "reference") else { return nil }
            var asset = originalAsset
            asset.localURL = relative
            referenceFileCount += 1
            return asset
        }
        payload.roughCuts = try original.roughCuts.map { originalCut in
            var cut = originalCut
            if let value = originalCut.backgroundAudioURL {
                cut.backgroundAudioURL = try copiedRelativePath(value, folder: ManagedAudioStore.directoryName, prefix: "background")
                if cut.backgroundAudioURL != nil { mediaFileCount += 1 }
            }
            return cut
        }

        let payloadURL = temporary.appending(path: payloadName)
        try secureWrite(JSONEncoder.visionStack.encode(payload), to: payloadURL, fileManager: fileManager)
        var hashes = [payloadName: try hash(payloadURL)]
        for (directory, folder) in [(mediaDirectory, "Media"), (referenceDirectory, "References"), (audioDirectory, ManagedAudioStore.directoryName)] {
            for file in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                let relative = "\(folder)/\(file.lastPathComponent)"
                hashes[relative] = try hash(file)
            }
        }
        let manifest = ProjectBackupManifest(
            schemaVersion: ProjectBackupPayload.currentSchemaVersion,
            projectName: payload.project.name,
            exportedAt: payload.exportedAt,
            files: hashes
        )
        try secureWrite(JSONEncoder.visionStack.encode(manifest), to: temporary.appending(path: manifestName), fileManager: fileManager)
        try fileManager.moveItem(at: temporary, to: destination)
        return ProjectBackupHealth(
            mediaFileCount: mediaFileCount,
            referenceFileCount: referenceFileCount,
            missingFiles: missingFiles.sorted(),
            hashMismatches: [],
            unsafePaths: []
        )
    }

    static func inspect(_ package: URL, fileManager: FileManager = .default) throws -> ProjectBackupHealth {
        let packageValues = try package.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard packageValues.isDirectory == true, packageValues.isSymbolicLink != true else {
            throw VisionStackError.mediaArchiveFailed("项目备份必须是普通目录，不能是符号链接。")
        }
        let manifestURL = try resolvedFileURL(manifestName, in: package)
        let manifestValues = try manifestURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard manifestValues.isRegularFile == true, manifestValues.isSymbolicLink != true,
              let manifestSize = manifestValues.fileSize, manifestSize > 0, manifestSize <= 10_000_000 else {
            throw VisionStackError.mediaArchiveFailed("项目备份清单不是安全的普通文件或体积异常。")
        }
        let manifest = try JSONDecoder.visionStack.decode(ProjectBackupManifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.schemaVersion <= ProjectBackupPayload.currentSchemaVersion else {
            throw VisionStackError.unsupportedSchema(manifest.schemaVersion)
        }
        guard manifest.files.count <= 5_000 else {
            throw VisionStackError.mediaArchiveFailed("项目备份文件数量超过安全上限。")
        }
        var missing: [String] = []
        var mismatches: [String] = []
        var unsafe: [String] = []
        var mediaCount = 0
        var referenceCount = 0
        for (relative, expectedHash) in manifest.files {
            guard isSafeRelativePath(relative) else { unsafe.append(relative); continue }
            if relative.hasPrefix("Media/") || relative.hasPrefix("Audio/") { mediaCount += 1 }
            if relative.hasPrefix("References/") { referenceCount += 1 }
            let file: URL
            do { file = try resolvedFileURL(relative, in: package) }
            catch { unsafe.append(relative); continue }
            guard fileManager.fileExists(atPath: file.path) else { missing.append(relative); continue }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            let maximumBytes: Int64 = relative.hasPrefix("References/") ? 10_000_000
                : relative.hasPrefix("Audio/") ? Int64(ManagedAudioStore.maximumBytes)
                : relative == payloadName ? 50_000_000
                : MediaArchivePolicy.maximumRemoteBytes(for: .video)
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let fileSize = values.fileSize, fileSize > 0, Int64(fileSize) <= maximumBytes else {
                unsafe.append(relative)
                continue
            }
            if try hash(file) != expectedHash { mismatches.append(relative) }
        }
        if manifest.files[payloadName] == nil {
            unsafe.append(payloadName)
        } else if !missing.contains(payloadName), !mismatches.contains(payloadName), !unsafe.contains(payloadName) {
            let payload = try JSONDecoder.visionStack.decode(
                ProjectBackupPayload.self,
                from: Data(contentsOf: try resolvedFileURL(payloadName, in: package))
            )
            guard payload.schemaVersion <= ProjectBackupPayload.currentSchemaVersion else {
                throw VisionStackError.unsupportedSchema(payload.schemaVersion)
            }
            for value in payload.roughCuts.compactMap(\.backgroundAudioURL) {
                if value.hasPrefix("Audio/"), isSafeRelativePath(value) {
                    guard manifest.files[value] != nil else { unsafe.append(value); continue }
                    guard !missing.contains(value), !mismatches.contains(value), !unsafe.contains(value) else { continue }
                    do { try ManagedAudioStore.validateFile(resolvedFileURL(value, in: package)) }
                    catch { unsafe.append(value) }
                } else if payload.schemaVersion >= 2 {
                    unsafe.append("背景音频必须是备份包内的 Audio 相对路径")
                }
            }
        }
        return ProjectBackupHealth(
            mediaFileCount: mediaCount,
            referenceFileCount: referenceCount,
            missingFiles: missing.sorted(),
            hashMismatches: mismatches.sorted(),
            unsafePaths: unsafe.sorted()
        )
    }

    static func load(_ package: URL, fileManager: FileManager = .default) throws -> ProjectBackupPayload {
        let health = try inspect(package, fileManager: fileManager)
        guard health.isHealthy else {
            throw VisionStackError.mediaArchiveFailed(
                "项目备份健康检查未通过，已停止恢复（缺失 \(health.missingFiles.count)、哈希不符 \(health.hashMismatches.count)、不安全路径 \(health.unsafePaths.count)）。"
            )
        }
        return try JSONDecoder.visionStack.decode(
            ProjectBackupPayload.self,
            from: Data(contentsOf: package.appending(path: payloadName))
        )
    }

    static func resolvedFileURL(_ relative: String, in package: URL) throws -> URL {
        guard isSafeRelativePath(relative) else {
            throw VisionStackError.mediaArchiveFailed("备份包包含不安全路径。")
        }
        let resolvedRoot = package.resolvingSymlinksInPath().standardizedFileURL
        let resolved = package.appending(path: relative).resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(resolvedRoot.path + "/") else {
            throw VisionStackError.mediaArchiveFailed("备份包路径越界。")
        }
        return resolved
    }

    private static func isSafeRelativePath(_ value: String) -> Bool {
        !value.isEmpty
            && !value.hasPrefix("/")
            && !value.contains("\\")
            && !value.split(separator: "/").contains("..")
    }

    private static func hash(_ url: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: url, options: [.mappedIfSafe]))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func secureWrite(_ data: Data, to url: URL, fileManager: FileManager) throws {
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
