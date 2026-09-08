import AppKit
import CryptoKit
import Foundation
import Security
import UniformTypeIdentifiers
import UserNotifications

actor LocalNotificationService {
    func requestAuthorization() async -> Bool {
        do { return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
        catch { return false }
    }

    func deliverCompletion(job: GenerationJob) async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard [.authorized, .provisional].contains(settings.authorizationStatus) else { return }
        let content = UNMutableNotificationContent()
        content.title = "映栈任务已完成"
        content.body = "\(job.kind.rawValue) · \(String(job.prompt.prefix(42)))"
        content.sound = .default
        let request = UNNotificationRequest(identifier: "visionstack-job-\(job.id.uuidString)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

enum KeychainStore {
    private static let service = "app.visionstack.community.studio"
    private static let account = "modelhub.gateway.token"

    static func readToken() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { return "" }
        return value
    }

    static func readTokenAsync(
        using operation: @escaping @Sendable () -> String = { KeychainStore.readToken() }
    ) async -> String {
        await Task.detached(priority: .utility, operation: operation).value
    }

    static func saveToken(_ token: String) throws {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if token.isEmpty { SecItemDelete(identity as CFDictionary); return }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = identity
            insert.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw VisionStackError.server("Keychain 写入失败（\(addStatus)）。") }
        } else if status != errSecSuccess {
            throw VisionStackError.server("Keychain 更新失败（\(status)）。")
        }
    }
}

actor PersistenceService {
    private let root: URL
    private let stateURL: URL
    private let stateBackupURL: URL
    private let resourcesURL: URL
    private let resourcesBackupURL: URL
    private let mediaURL: URL
    private let referencesURL: URL
    private let downloadsURL: URL
    private var latestStateRevision = 0
    private var latestResourceRevision = 0
    private let removesRootOnDeinit: Bool

    init(root customRoot: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        if let customRoot {
            root = customRoot
            removesRootOnDeinit = false
        } else if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
                    || ProcessInfo.processInfo.processName.lowercased().contains("xctest") {
            root = FileManager.default.temporaryDirectory.appending(path: "visionstack-xctest-\(UUID().uuidString)", directoryHint: .isDirectory)
            removesRootOnDeinit = true
        } else {
            root = support.appending(path: "VisionStackCommunity", directoryHint: .isDirectory)
            removesRootOnDeinit = false
        }
        stateURL = root.appending(path: "state.json")
        stateBackupURL = root.appending(path: "state.backup.json")
        resourcesURL = root.appending(path: "resources.json")
        resourcesBackupURL = root.appending(path: "resources.backup.json")
        mediaURL = root.appending(path: "Media", directoryHint: .isDirectory)
        referencesURL = root.appending(path: "References", directoryHint: .isDirectory)
        downloadsURL = root.appending(path: "Downloads", directoryHint: .isDirectory)
    }

    deinit {
        if removesRootOnDeinit { try? FileManager.default.removeItem(at: root) }
    }

    func load() throws -> PersistenceLoad {
        try ensureDirectories()
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            return PersistenceLoad(snapshot: nil, resources: loadResources(), recoveryNotice: nil, migratedLegacyState: false)
        }
        let data = try Data(contentsOf: stateURL)
        if let snapshot = try? JSONDecoder.visionStack.decode(AppSnapshot.self, from: data) {
            guard snapshot.schemaVersion <= AppSnapshot.currentSchemaVersion else { throw VisionStackError.unsupportedSchema(snapshot.schemaVersion) }
            return PersistenceLoad(snapshot: snapshot, resources: loadResources(), recoveryNotice: nil, migratedLegacyState: false)
        }
        if let legacy = try? JSONDecoder.visionStack.decode(LegacyAppSnapshot.self, from: data) {
            let snapshot = AppSnapshot(
                conversations: legacy.conversations, selectedConversationID: legacy.selectedConversationID,
                imageJobs: legacy.imageJobs, videoJobs: legacy.videoJobs, selectedAgentID: nil, selectedSkillIDs: [],
                baseURL: legacy.baseURL, preferredChatModel: legacy.preferredChatModel,
                preferredImageModel: legacy.preferredImageModel, preferredVideoModel: legacy.preferredVideoModel,
                webSearchEnabled: false, cachedModels: [], cachedCapabilities: [], customCapabilities: [],
                contextBudgetTokens: nil, maxConcurrentGenerationTasks: nil,
                referenceAssets: nil, storyboardShots: nil
            )
            return PersistenceLoad(snapshot: snapshot, resources: legacy.resources, recoveryNotice: "已把旧版历史迁移到版本化存储；原文件将在首次保存时备份。", migratedLegacyState: true)
        }
        if let backupData = try? Data(contentsOf: stateBackupURL),
           let backup = try? JSONDecoder.visionStack.decode(AppSnapshot.self, from: backupData) {
            return PersistenceLoad(snapshot: backup, resources: loadResources(), recoveryNotice: "主历史文件无法读取，已从最近备份恢复；损坏文件未被删除。", migratedLegacyState: false)
        }
        throw VisionStackError.server("本地历史无法解码，应用已保留原文件且不会覆盖。")
    }

    func saveState(_ snapshot: AppSnapshot, revision: Int) throws {
        guard revision >= latestStateRevision else { return }
        try ensureDirectories(); try backup(stateURL, to: stateBackupURL)
        try secureWrite(JSONEncoder.visionStack.encode(SnapshotSanitizer.sanitized(snapshot)), to: stateURL)
        latestStateRevision = revision
    }

    func saveResources(_ resources: [ImportedResource], revision: Int) throws {
        guard revision >= latestResourceRevision else { return }
        try ensureDirectories(); try backup(resourcesURL, to: resourcesBackupURL)
        try secureWrite(JSONEncoder.visionStack.encode(resources), to: resourcesURL)
        latestResourceRevision = revision
    }

    func archiveMedia(
        _ values: [String],
        kind: GenerationKind,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [String] {
        try ensureDirectories()
        var archived: [String] = []
        let totalItems = max(values.count, 1)
        do {
            for (index, value) in values.enumerated() {
            if value.hasPrefix("data:") {
                guard let comma = value.firstIndex(of: ",") else {
                    throw VisionStackError.mediaArchiveFailed("生成结果中的 Base64 数据无效。")
                }
                let encoded = value[value.index(after: comma)...]
                guard MediaArchivePolicy.allowsInlineBase64CharacterCount(encoded.utf8.count, kind: kind) else {
                    throw VisionStackError.mediaArchiveFailed("内嵌媒体超过本地安全解码上限。")
                }
                guard let data = Data(base64Encoded: String(encoded)),
                      data.count <= MediaArchivePolicy.maximumInlineDecodedBytes(for: kind) else {
                    throw VisionStackError.mediaArchiveFailed("生成结果中的 Base64 数据无效或超过上限。")
                }
                archived.append(try saveMediaData(data, kind: kind, mimeType: value.components(separatedBy: ";").first?.replacingOccurrences(of: "data:", with: "")))
                progress?(Double(index + 1) / Double(totalItems))
                continue
            }
            guard let url = URL(string: value), MediaURLPolicy.isAllowedRemoteURL(url) else {
                throw VisionStackError.mediaArchiveFailed("模型返回的媒体地址未通过 HTTPS 与私网边界检查。")
            }
            var request = URLRequest(url: url, timeoutInterval: kind == .video ? 600 : 120)
            request.setValue("VisionStack/0.2", forHTTPHeaderField: "User-Agent")
            let checkpointURL = downloadsURL.appending(path: Self.downloadCheckpointName(for: value))
            let resumeData = try? Data(contentsOf: checkpointURL)
            let downloader = ProgressiveMediaDownloader(maximumBytes: MediaArchivePolicy.maximumRemoteBytes(for: kind)) { itemProgress in
                progress?((Double(index) + itemProgress) / Double(totalItems))
            }
            let temporaryURL: URL
            let http: HTTPURLResponse
            do {
                (temporaryURL, http) = try await downloader.download(request, resumeData: resumeData)
                if FileManager.default.fileExists(atPath: checkpointURL.path) { try? FileManager.default.removeItem(at: checkpointURL) }
            } catch let failure as ResumableDownloadFailure {
                try secureWrite(failure.resumeData, to: checkpointURL)
                throw failure.underlying
            } catch {
                if resumeData != nil, FileManager.default.fileExists(atPath: checkpointURL.path) {
                    try? FileManager.default.removeItem(at: checkpointURL)
                }
                throw error
            }
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            guard (200..<300).contains(http.statusCode) else {
                throw VisionStackError.mediaArchiveFailed("生成已完成，但媒体下载失败。")
            }
            let fileValues = try temporaryURL.resourceValues(forKeys: [.fileSizeKey])
            let maximum = MediaArchivePolicy.maximumRemoteBytes(for: kind)
            guard (fileValues.fileSize ?? 0) > 0, (fileValues.fileSize ?? 0) <= maximum else {
                throw VisionStackError.mediaArchiveFailed("媒体文件为空或超过本地归档上限。")
            }
            let mime = http.value(forHTTPHeaderField: "Content-Type")?.components(separatedBy: ";").first
            guard MediaArchivePolicy.allowsContentType(mime, kind: kind) else {
                throw VisionStackError.mediaArchiveFailed("媒体响应类型与任务类型不匹配，已拒绝归档。")
            }
            archived.append(try saveDownloadedFile(at: temporaryURL, kind: kind, mimeType: mime, suggestedExtension: url.pathExtension))
            progress?(Double(index + 1) / Double(totalItems))
            }
        } catch {
            deleteArchivedMedia(archived)
            throw error
        }
        return archived
    }

    func deleteArchivedMedia(_ values: [String]) {
        let mediaRoot = mediaURL.standardizedFileURL.path
        for value in values {
            guard let url = URL(string: value), url.isFileURL else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(mediaRoot + "/") else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    func clearAllMedia() throws {
        if FileManager.default.fileExists(atPath: mediaURL.path) { try FileManager.default.removeItem(at: mediaURL) }
        if FileManager.default.fileExists(atPath: downloadsURL.path) { try FileManager.default.removeItem(at: downloadsURL) }
        try FileManager.default.createDirectory(at: mediaURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: downloadsURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    static func downloadCheckpointName(for remoteValue: String) -> String {
        let digest = SHA256.hash(data: Data(remoteValue.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(digest).resume"
    }

    func auditMedia(jobs: [GenerationJob], references: [ReferenceAsset]) throws -> MediaHealthReport {
        try ensureDirectories()
        let referencedJobPaths = Set(jobs.flatMap(\.resultURLs).compactMap { value -> String? in
            guard let url = URL(string: value), url.isFileURL else { return nil }
            return url.standardizedFileURL.path
        })
        let missingJobFiles = referencedJobPaths.filter { !FileManager.default.fileExists(atPath: $0) }.sorted()
        let missingReferenceFiles = references.compactMap { asset -> String? in
            guard let url = URL(string: asset.localURL), url.isFileURL,
                  !FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url.standardizedFileURL.path
        }.sorted()
        let managedFiles = try FileManager.default.contentsOfDirectory(
            at: mediaURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).filter { url in
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            return values?.isRegularFile == true && values?.isSymbolicLink != true
        }.map { $0.standardizedFileURL.path }
        let orphaned = managedFiles.filter { !referencedJobPaths.contains($0) }.sorted()
        return MediaHealthReport(
            checkedAt: Date(),
            missingJobFiles: missingJobFiles,
            missingReferenceFiles: missingReferenceFiles,
            orphanedManagedFiles: orphaned
        )
    }

    func deleteOrphanedManagedFiles(_ paths: [String]) throws {
        let rootPath = mediaURL.standardizedFileURL.path + "/"
        for path in paths {
            let target = URL(fileURLWithPath: path).standardizedFileURL
            guard target.path.hasPrefix(rootPath) else { continue }
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        }
    }

    func importReference(from source: URL, sourceJobID: UUID? = nil) throws -> ReferenceAsset {
        try ensureDirectories()
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw VisionStackError.mediaArchiveFailed("参考图必须是普通图片文件，不能是符号链接。")
        }
        guard let size = values.fileSize, size > 0, size <= 10_000_000 else {
            throw VisionStackError.mediaArchiveFailed("参考图必须小于 10 MB。")
        }
        let ext = source.pathExtension.lowercased()
        guard ["png", "jpg", "jpeg", "webp", "heic"].contains(ext) else {
            throw VisionStackError.mediaArchiveFailed("参考图仅支持 PNG、JPEG、WebP 或 HEIC。")
        }
        guard NSImage(contentsOf: source) != nil else {
            throw VisionStackError.mediaArchiveFailed("参考图内容无法解码，可能不是有效图片。")
        }
        let destination = referencesURL.appending(path: "\(UUID().uuidString).\(ext)")
        try FileManager.default.copyItem(at: source, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return ReferenceAsset(name: source.deletingPathExtension().lastPathComponent, localURL: destination.absoluteString, sourceJobID: sourceJobID)
    }

    func importArchivedMedia(from source: URL, kind: GenerationKind) throws -> String {
        try ensureDirectories()
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let byteCount = values.fileSize, byteCount > 0,
              byteCount <= MediaArchivePolicy.maximumRemoteBytes(for: kind) else {
            throw VisionStackError.mediaArchiveFailed("备份媒体不是安全的普通文件，或超过本地归档上限。")
        }
        let ext = source.pathExtension.lowercased()
        let allowed = kind == .video ? ["mp4", "mov", "webm", "m4v"] : ["png", "jpg", "jpeg", "webp", "heic"]
        guard allowed.contains(ext) else {
            throw VisionStackError.mediaArchiveFailed("备份媒体扩展名与任务类型不匹配。")
        }
        if kind == .image, NSImage(contentsOf: source) == nil {
            throw VisionStackError.mediaArchiveFailed("备份中的图片无法解码。")
        }
        return try saveDownloadedFile(at: source, kind: kind, mimeType: nil, suggestedExtension: ext)
    }

    func importBackgroundAudio(from source: URL) throws -> String {
        try ensureDirectories()
        return try ManagedAudioStore.importFile(
            from: source,
            into: root.appending(path: ManagedAudioStore.directoryName, directoryHint: .isDirectory)
        )
    }

    func deleteBackgroundAudio(_ localURL: String) throws {
        try ManagedAudioStore.deleteFile(
            localURL,
            from: root.appending(path: ManagedAudioStore.directoryName, directoryHint: .isDirectory)
        )
    }

    func deleteReference(_ asset: ReferenceAsset) throws {
        let url = try validatedReferenceURL(asset, requireExistingFile: false)
        let path = url.path
        if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(at: url) }
    }

    func referenceDataURL(_ asset: ReferenceAsset) throws -> String {
        let url = try validatedReferenceURL(asset)
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard !data.isEmpty, data.count <= 10_000_000 else {
            throw VisionStackError.mediaArchiveFailed("参考图为空或超过 10 MB 请求上限。")
        }
        let mime = switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "webp": "image/webp"
        case "heic": "image/heic"
        default: "image/png"
        }
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }

    private func validatedReferenceURL(_ asset: ReferenceAsset, requireExistingFile: Bool = true) throws -> URL {
        guard let url = URL(string: asset.localURL), url.isFileURL else {
            throw VisionStackError.mediaArchiveFailed("参考图地址无效。")
        }
        let resolvedRoot = referencesURL.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedURL.path.hasPrefix(resolvedRoot + "/") else {
            throw VisionStackError.mediaArchiveFailed("参考图不在映栈受控目录中或已变为链接文件。")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            if requireExistingFile { throw VisionStackError.mediaArchiveFailed("参考图文件已不存在。") }
            return resolvedURL
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw VisionStackError.mediaArchiveFailed("参考图不在映栈受控目录中或已变为链接文件。")
        }
        return resolvedURL
    }

    private func loadResources() -> [ImportedResource] {
        guard let data = try? Data(contentsOf: resourcesURL) else { return [] }
        if let resources = try? JSONDecoder.visionStack.decode([ImportedResource].self, from: data) { return resources }
        guard let backup = try? Data(contentsOf: resourcesBackupURL) else { return [] }
        return (try? JSONDecoder.visionStack.decode([ImportedResource].self, from: backup)) ?? []
    }

    private func saveMediaData(_ data: Data, kind: GenerationKind, mimeType: String?, suggestedExtension: String = "") throws -> String {
        let ext = mediaExtension(kind: kind, mimeType: mimeType, suggestedExtension: suggestedExtension)
        let url = mediaURL.appending(path: "\(kind.rawValue)-\(UUID().uuidString).\(ext)")
        try secureWrite(data, to: url)
        return url.absoluteString
    }

    private func saveDownloadedFile(at source: URL, kind: GenerationKind, mimeType: String?, suggestedExtension: String) throws -> String {
        let ext = mediaExtension(kind: kind, mimeType: mimeType, suggestedExtension: suggestedExtension)
        let destination = mediaURL.appending(path: "\(kind.rawValue)-\(UUID().uuidString).\(ext)")
        try FileManager.default.copyItem(at: source, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return destination.absoluteString
    }

    private func mediaExtension(kind: GenerationKind, mimeType: String?, suggestedExtension: String) -> String {
        switch mimeType?.lowercased() {
        case "image/jpeg": return "jpg"
        case "image/webp": return "webp"
        case "image/heic": return "heic"
        case "video/quicktime": return "mov"
        case "video/webm": return "webm"
        case "video/mp4": return "mp4"
        case "image/png": return "png"
        default:
            let safe = suggestedExtension.lowercased()
            let allowed = kind == .video ? ["mp4", "mov", "webm", "m4v"] : ["png", "jpg", "jpeg", "webp", "heic"]
            return allowed.contains(safe) ? safe : (kind == .video ? "mp4" : "png")
        }
    }

    private func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: mediaURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: referencesURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: downloadsURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    private func backup(_ source: URL, to destination: URL) throws {
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private func secureWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

enum ReferenceFilePicker {
    @MainActor static func chooseImages() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "导入参考图"
        panel.message = "图片会复制到映栈的本地受控目录；单张不超过 10 MB。"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.png, .jpeg, .webP, .heic]
        return panel.runModal() == .OK ? panel.urls : []
    }
}

private struct LegacyAppSnapshot: Codable {
    var conversations: [Conversation]
    var selectedConversationID: UUID?
    var imageJobs: [GenerationJob]
    var videoJobs: [GenerationJob]
    var resources: [ImportedResource]
    var baseURL: String
    var preferredChatModel: String
    var preferredImageModel: String
    var preferredVideoModel: String
}

extension JSONEncoder {
    static var visionStack: JSONEncoder {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]; return encoder
    }
}
extension JSONDecoder {
    static var visionStack: JSONDecoder {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder
    }
}

protocol ModelHubServicing: Sendable {
    func health() async throws -> ModelHubRuntimeStatus
    func catalog() async throws -> ModelCatalog
    func capabilities(for modelID: String) async throws -> CapabilityProfile
    func chat(model: String, messages: [[String: String]], requestContext: BillableRequestContext) async throws -> String
    func generateImage(model: String, prompt: String, size: String, quality: String, referenceImage: String?, requestContext: BillableRequestContext) async throws -> ParsedGenerationResponse
    func generateImage(model: String, prompt: String, size: String, quality: String, referenceImages: [String], requestContext: BillableRequestContext) async throws -> ParsedGenerationResponse
    func generateVideo(model: String, prompt: String, size: String, ratio: String, duration: Int, referenceImage: String?, requestContext: BillableRequestContext) async throws -> ParsedGenerationResponse
    func videoTask(model: String, taskID: String) async throws -> ParsedGenerationResponse
    func requestStatus(model: String, clientRequestID: UUID) async throws -> ParsedGenerationResponse
    func cancelVideoTask(model: String, taskID: String) async throws
}

extension ModelHubServicing {
    func generateImage(model: String, prompt: String, size: String, quality: String, referenceImages: [String], requestContext: BillableRequestContext) async throws -> ParsedGenerationResponse {
        try await generateImage(
            model: model,
            prompt: prompt,
            size: size,
            quality: quality,
            referenceImage: referenceImages.first,
            requestContext: requestContext
        )
    }
}

actor ModelHubClient: ModelHubServicing {
    private let baseURL: URL
    private let token: String

    init(baseURL: String, token: String) throws {
        guard let url = URL(string: baseURL), let host = url.host?.lowercased(),
              ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              ["", "/", "/v1", "/v1/"].contains(url.path) else { throw VisionStackError.invalidLoopbackURL }
        self.baseURL = url; self.token = token
    }

    func health() async throws -> ModelHubRuntimeStatus {
        let json = try await request(path: "/health", authorized: false)
        guard let object = json as? [String: Any],
              (object["status"] as? String)?.lowercased() == "ok" else {
            throw VisionStackError.invalidResponse("ModelHub 健康接口没有返回可用状态。")
        }
        return ModelHubRuntimeStatus(
            service: object["service"] as? String ?? "ModelHub",
            providerCount: object["providers"] as? Int ?? 0,
            routeCount: object["routes"] as? Int ?? 0
        )
    }

    func catalog() async throws -> ModelCatalog {
        let json = try await request(path: "/v1/models/available")
        guard let object = json as? [String: Any], let data = object["data"] as? [Any] else {
            throw VisionStackError.invalidResponse("ModelHub 模型列表缺少 data 数组。")
        }
        return ModelHubProtocolParser.catalog(from: data)
    }

    func capabilities(for modelID: String) async throws -> CapabilityProfile {
        let segment = ModelHubProtocolParser.encodedPathSegment(modelID)
        let json = try await request(path: "/v1/models/\(segment)/capabilities", pathIsPercentEncoded: true)
        guard let row = json as? [String: Any],
              let profile = ModelHubProtocolParser.capability(from: row) else {
            throw VisionStackError.invalidResponse("ModelHub 没有返回可识别的模型能力声明。")
        }
        return profile
    }

    func chat(model: String, messages: [[String: String]], confirmBillable: Bool) async throws -> String {
        try await chat(model: model, messages: messages, requestContext: .new(confirmBillable: confirmBillable))
    }

    func chat(model: String, messages: [[String: String]], requestContext: BillableRequestContext) async throws -> String {
        let json = try await request(
            path: "/v1/chat/completions",
            method: "POST",
            body: ModelHubProtocolParser.chatBody(model: model, messages: messages, requestContext: requestContext),
            requestContext: requestContext
        )
        guard let object = json as? [String: Any], let choices = object["choices"] as? [[String: Any]],
              let first = choices.first, let message = first["message"] as? [String: Any], let content = message["content"] as? String else {
            throw VisionStackError.invalidResponse("聊天响应缺少 choices[0].message.content。")
        }
        return content
    }

    func generateImage(model: String, prompt: String, size: String, quality: String, referenceImage: String?, confirmBillable: Bool) async throws -> ParsedGenerationResponse {
        try await generateImage(model: model, prompt: prompt, size: size, quality: quality, referenceImage: referenceImage, requestContext: .new(confirmBillable: confirmBillable))
    }

    func generateImage(model: String, prompt: String, size: String, quality: String, referenceImage: String?, requestContext: BillableRequestContext) async throws -> ParsedGenerationResponse {
        try await generateImage(
            model: model,
            prompt: prompt,
            size: size,
            quality: quality,
            referenceImages: referenceImage.map { [$0] } ?? [],
            requestContext: requestContext
        )
    }

    func generateImage(model: String, prompt: String, size: String, quality: String, referenceImages: [String], requestContext: BillableRequestContext) async throws -> ParsedGenerationResponse {
        let body = ModelHubProtocolParser.imageBody(model: model, prompt: prompt, size: size, quality: quality, referenceImages: referenceImages, requestContext: requestContext)
        return ModelHubResponseParser.parse(try await request(path: "/v1/images/generations", method: "POST", body: body, requestContext: requestContext))
    }

    func generateVideo(model: String, prompt: String, size: String, ratio: String, duration: Int, referenceImage: String?, confirmBillable: Bool) async throws -> ParsedGenerationResponse {
        try await generateVideo(model: model, prompt: prompt, size: size, ratio: ratio, duration: duration, referenceImage: referenceImage, requestContext: .new(confirmBillable: confirmBillable))
    }

    func generateVideo(model: String, prompt: String, size: String, ratio: String, duration: Int, referenceImage: String?, requestContext: BillableRequestContext) async throws -> ParsedGenerationResponse {
        let body = ModelHubProtocolParser.videoBody(model: model, prompt: prompt, size: size, ratio: ratio, duration: duration, referenceImage: referenceImage, requestContext: requestContext)
        return ModelHubResponseParser.parse(try await request(path: "/v1/videos/generations", method: "POST", body: body, requestContext: requestContext))
    }

    func videoTask(model: String, taskID: String) async throws -> ParsedGenerationResponse {
        let task = taskID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? taskID
        let modelValue = model.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? model
        return ModelHubResponseParser.parse(try await request(path: "/v1/tasks/\(task)?model=\(modelValue)"))
    }

    func requestStatus(model: String, clientRequestID: UUID) async throws -> ParsedGenerationResponse {
        let requestID = ModelHubProtocolParser.encodedPathSegment(clientRequestID.uuidString)
        let modelValue = model.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? model
        return ModelHubResponseParser.parse(try await request(path: "/v1/requests/\(requestID)?model=\(modelValue)"))
    }

    func cancelVideoTask(model: String, taskID: String) async throws {
        let task = taskID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? taskID
        let modelValue = model.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? model
        _ = try await request(path: "/v1/tasks/\(task)?model=\(modelValue)", method: "DELETE")
    }

    private func request(path: String, method: String = "GET", body: [String: Any]? = nil, authorized: Bool = true, pathIsPercentEncoded: Bool = false, requestContext: BillableRequestContext? = nil) async throws -> Any {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { throw VisionStackError.invalidLoopbackURL }
        let split = path.split(separator: "?", maxSplits: 1).map(String.init)
        if pathIsPercentEncoded { components.percentEncodedPath = split[0] } else { components.path = split[0] }
        components.percentEncodedQuery = split.count == 2 ? split[1] : nil
        guard let url = components.url else { throw VisionStackError.invalidResponse() }
        var request = URLRequest(url: url, timeoutInterval: method == "GET" ? 20 : 120)
        request.httpMethod = method; request.setValue("application/json", forHTTPHeaderField: "Accept")
        if authorized && !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let requestContext {
            request.setValue(requestContext.idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
            request.setValue(requestContext.clientRequestID.uuidString, forHTTPHeaderField: "X-Client-Request-ID")
        }
        if let body { request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw VisionStackError.invalidResponse() }
        let json = (try? JSONSerialization.jsonObject(with: data)) ?? ["raw": String(data: data, encoding: .utf8) ?? ""]
        guard (200..<300).contains(http.statusCode) else {
            let message = ModelHubResponseParser.errorMessage(in: json) ?? "ModelHub 返回 HTTP \(http.statusCode)。"
            if ModelHubProtocolParser.isBillingBlocked(statusCode: http.statusCode, response: json) {
                throw VisionStackError.billingBlocked(message)
            }
            throw VisionStackError.httpStatus(http.statusCode, message)
        }
        return json
    }
}

enum ModelHubProtocolParser {
    static func catalog(from data: [Any]) -> ModelCatalog {
        var models: [ModelDescriptor] = []
        var profiles: [CapabilityProfile] = []
        for item in data {
            if let id = item as? String {
                models.append(ModelDescriptor(id: id, owner: id.split(separator: "/").first.map(String.init) ?? "ModelHub", availability: "available"))
                continue
            }
            guard let row = item as? [String: Any], let id = row["id"] as? String else { continue }
            models.append(ModelDescriptor(
                id: id,
                owner: row["owned_by"] as? String ?? "ModelHub",
                availability: row["availability"] as? String ?? "available",
                source: row["source"] as? String,
                constraintScope: row["constraint_scope"] as? String
            ))
            if let profile = capability(from: row), profile.isConfigured { profiles.append(profile) }
        }
        return ModelCatalog(models: models, embeddedCapabilities: profiles)
    }

    static func capability(from row: [String: Any]) -> CapabilityProfile? {
        guard let id = (row["id"] ?? row["model"]) as? String else { return nil }
        let constraints = row["constraints"] as? [String: Any] ?? [:]
        let outputs = stringList(constraints["output_modalities"] ?? row["output_modalities"] ?? row["outputs"] ?? row["modalities"])
        let declared = stringList(row["capabilities"]).map { $0.lowercased() }
        let image = constraints["image"] as? [String: Any] ?? row["image"] as? [String: Any]
        let video = constraints["video"] as? [String: Any] ?? row["video"] as? [String: Any]
        let widthPixels = image?["width_pixels"] as? [String: Any]
        let heightPixels = image?["height_pixels"] as? [String: Any]
        var operations: Set<CreativeOperation> = []
        if outputs.contains(where: { ["text", "chat"].contains($0.lowercased()) }) || declared.contains(where: { $0.contains("text") || $0.contains("chat") }) { operations.insert(.chat) }
        if outputs.contains(where: { $0.lowercased() == "image" }) || declared.contains(where: { $0.contains("imagegeneration") }) { operations.insert(.image) }
        if outputs.contains(where: { $0.lowercased() == "video" }) || declared.contains(where: { $0.contains("videogeneration") }) { operations.insert(.video) }
        return CapabilityProfile(
            modelID: id,
            operations: operations,
            imageSizes: stringList(image?["sizes"] ?? constraints["sizes"] ?? row["sizes"]),
            aspectRatios: stringList((video?["aspect_ratios"] ?? image?["aspect_ratios"]) ?? constraints["aspect_ratios"] ?? row["aspect_ratios"]),
            qualities: stringList(image?["qualities"] ?? constraints["qualities"] ?? row["qualities"]),
            videoResolutions: stringList(video?["resolutions"] ?? constraints["resolutions"] ?? row["resolutions"]),
            durations: intList(video?["durations_seconds"] ?? constraints["durations_seconds"] ?? row["durations_seconds"]),
            source: .modelHub,
            verifiedAt: Date(),
            inputModalities: stringList(constraints["input_modalities"] ?? row["input_modalities"]),
            imageMinimumWidth: integer(widthPixels?["minimum"]),
            imageMaximumWidth: integer(widthPixels?["maximum"]),
            imageMinimumHeight: integer(heightPixels?["minimum"]),
            imageMaximumHeight: integer(heightPixels?["maximum"])
        )
    }

    static func encodedPathSegment(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func chatBody(model: String, messages: [[String: String]], confirmBillable: Bool) -> [String: Any] {
        chatBody(model: model, messages: messages, requestContext: .new(confirmBillable: confirmBillable))
    }

    static func chatBody(model: String, messages: [[String: String]], requestContext: BillableRequestContext) -> [String: Any] {
        [
            "model": model,
            "messages": messages,
            "stream": false,
            "temperature": 0.6,
            "confirm_billable": requestContext.confirmBillable,
            "client_request_id": requestContext.clientRequestID.uuidString,
            "idempotency_key": requestContext.idempotencyKey
        ]
    }

    static func imageBody(model: String, prompt: String, size: String, quality: String, referenceImage: String? = nil, confirmBillable: Bool) -> [String: Any] {
        imageBody(model: model, prompt: prompt, size: size, quality: quality, referenceImages: referenceImage.map { [$0] } ?? [], requestContext: .new(confirmBillable: confirmBillable))
    }

    static func imageBody(model: String, prompt: String, size: String, quality: String, referenceImage: String? = nil, requestContext: BillableRequestContext) -> [String: Any] {
        imageBody(model: model, prompt: prompt, size: size, quality: quality, referenceImages: referenceImage.map { [$0] } ?? [], requestContext: requestContext)
    }

    static func imageBody(model: String, prompt: String, size: String, quality: String, referenceImages: [String], confirmBillable: Bool) -> [String: Any] {
        imageBody(model: model, prompt: prompt, size: size, quality: quality, referenceImages: referenceImages, requestContext: .new(confirmBillable: confirmBillable))
    }

    static func imageBody(model: String, prompt: String, size: String, quality: String, referenceImages: [String], requestContext: BillableRequestContext) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "confirm_billable": requestContext.confirmBillable,
            "client_request_id": requestContext.clientRequestID.uuidString,
            "idempotency_key": requestContext.idempotencyKey
        ]
        if !size.isEmpty { body["size"] = normalizedImageSize(size, for: model) }
        if !quality.isEmpty { body["quality"] = quality }
        let cleanReferences = referenceImages.filter { !$0.isEmpty }
        if let firstReference = cleanReferences.first {
            body["image_url"] = firstReference
            if model.lowercased().contains("qwen-image") {
                body["input"] = [
                    "messages": [[
                        "role": "user",
                        "content": cleanReferences.map { ["image": $0] } + [["text": prompt]]
                    ]]
                ]
            }
        }
        return body
    }

    static func normalizedImageSize(_ size: String, for model: String) -> String {
        guard model.lowercased().contains("qwen-image") else { return size }
        let normalized = size
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "x", with: "*")
            .replacingOccurrences(of: "X", with: "*")
        let dimensions = normalized.split(separator: "*", omittingEmptySubsequences: false)
        guard dimensions.count == 2,
              dimensions.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return size }
        return normalized
    }

    static func videoBody(model: String, prompt: String, size: String, ratio: String, duration: Int, referenceImage: String? = nil, confirmBillable: Bool) -> [String: Any] {
        videoBody(model: model, prompt: prompt, size: size, ratio: ratio, duration: duration, referenceImage: referenceImage, requestContext: .new(confirmBillable: confirmBillable))
    }

    static func videoBody(model: String, prompt: String, size: String, ratio: String, duration: Int, referenceImage: String? = nil, requestContext: BillableRequestContext) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "duration_seconds": duration,
            "confirm_billable": requestContext.confirmBillable,
            "client_request_id": requestContext.clientRequestID.uuidString,
            "idempotency_key": requestContext.idempotencyKey
        ]
        if !size.isEmpty { body["size"] = size }
        if !ratio.isEmpty { body["aspect_ratio"] = ratio }
        if let referenceImage, !referenceImage.isEmpty { body["image_url"] = referenceImage }
        return body
    }

    static func isBillingBlocked(statusCode: Int, response: Any) -> Bool {
        if statusCode == 402 { return true }
        let object = response as? [String: Any]
        let error = object?["error"] as? [String: Any]
        let code = ((error?["code"] ?? object?["code"]) as? String ?? "").lowercased()
        let message = (ModelHubResponseParser.errorMessage(in: response) ?? "").lowercased()
        let markers = ["balance", "credit", "quota", "payment", "billing", "余额", "额度", "欠费"]
        return markers.contains(where: { code.contains($0) || message.contains($0) })
    }

    private static func stringList(_ value: Any?) -> [String] {
        if let values = value as? [String] { return values }
        if let value = value as? String { return [value] }
        return []
    }

    private static func intList(_ value: Any?) -> [Int] {
        if let values = value as? [Int] { return values }
        if let values = value as? [NSNumber] { return values.map(\.intValue) }
        return []
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }
}

enum ContextBudget {
    static let allowedRange = 4_096...65_536
    static let defaultTokens = 16_384

    static func prepare(
        systemPrompt: String,
        evidence: String?,
        conversation: [StudioMessage],
        maxInputTokens: Int
    ) -> PreparedChatContext {
        let budget = min(max(maxInputTokens, allowedRange.lowerBound), allowedRange.upperBound)
        let systemLimit = max(1_024, budget / 3)
        let trimmedSystem = truncate(systemPrompt, toTokens: systemLimit)
        var messages: [[String: String]] = [["role": "system", "content": trimmedSystem]]
        var used = estimateTokens(trimmedSystem) + 4

        if let evidence, !evidence.isEmpty {
            let evidenceLimit = max(0, min(budget / 4, budget - used - 4))
            if evidenceLimit > 0 {
                let value = truncate(evidence, toTokens: evidenceLimit)
                messages.append(["role": "user", "content": value])
                used += estimateTokens(value) + 4
            }
        }

        var selected: [StudioMessage] = []
        for message in conversation.reversed() {
            let tokens = estimateTokens(message.content) + 4
            if used + tokens > budget {
                if selected.isEmpty {
                    let remaining = max(256, budget - used - 4)
                    selected.append(StudioMessage(role: message.role, content: truncate(message.content, toTokens: remaining)))
                }
                break
            }
            selected.append(message)
            used += tokens
        }
        selected.reverse()
        messages += selected.map { ["role": $0.role.rawValue, "content": $0.content] }
        let estimate = messages.reduce(0) { $0 + estimateTokens($1["content"] ?? "") + 4 }
        return PreparedChatContext(
            messages: messages,
            report: ContextBudgetReport(
                estimatedTokens: estimate,
                includedMessageCount: selected.count,
                droppedMessageCount: max(0, conversation.count - selected.count),
                truncatedSystemPrompt: trimmedSystem != systemPrompt
            )
        )
    }

    static func estimateTokens(_ value: String) -> Int {
        var ascii = 0
        var nonASCII = 0
        for scalar in value.unicodeScalars {
            if scalar.isASCII { ascii += 1 } else { nonASCII += 1 }
        }
        return nonASCII + ((ascii + 3) / 4)
    }

    static func truncate(_ value: String, toTokens limit: Int) -> String {
        guard estimateTokens(value) > limit else { return value }
        let suffix = "\n…[已按上下文预算截断]"
        let contentLimit = max(1, limit - estimateTokens(suffix))
        var output = String.UnicodeScalarView()
        var ascii = 0
        var nonASCII = 0
        for scalar in value.unicodeScalars {
            let nextASCII = ascii + (scalar.isASCII ? 1 : 0)
            let nextNonASCII = nonASCII + (scalar.isASCII ? 0 : 1)
            if nextNonASCII + ((nextASCII + 3) / 4) > contentLimit { break }
            output.append(scalar)
            ascii = nextASCII
            nonASCII = nextNonASCII
        }
        return String(output) + suffix
    }
}

private struct ResumableDownloadFailure: Error, @unchecked Sendable {
    let resumeData: Data
    let underlying: Error
}

private final class ProgressiveMediaDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Double) -> Void
    private let maximumBytes: Int64
    private var continuation: CheckedContinuation<(URL, HTTPURLResponse), Error>?
    private var downloadedURL: URL?
    private var response: HTTPURLResponse?
    private var session: URLSession?
    private var policyError: Error?

    init(maximumBytes: Int64, progress: @escaping @Sendable (Double) -> Void) {
        self.maximumBytes = maximumBytes
        self.progress = progress
    }

    func download(_ request: URLRequest, resumeData: Data?) async throws -> (URL, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: queue)
            self.session = session
            if let resumeData, !resumeData.isEmpty { session.downloadTask(withResumeData: resumeData).resume() }
            else { session.downloadTask(with: request).resume() }
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesWritten > maximumBytes || totalBytesExpectedToWrite > maximumBytes {
            policyError = VisionStackError.mediaArchiveFailed("媒体下载超过本地归档上限，已提前停止。")
            downloadTask.cancel()
            return
        }
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, MediaURLPolicy.isAllowedRemoteURL(url) else {
            policyError = VisionStackError.mediaArchiveFailed("媒体重定向目标未通过 HTTPS 与私网边界检查。")
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            let owned = FileManager.default.temporaryDirectory.appending(path: "visionstack-download-\(UUID().uuidString)")
            try FileManager.default.copyItem(at: location, to: owned)
            downloadedURL = owned
            response = downloadTask.response as? HTTPURLResponse
        } catch {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { self.session?.finishTasksAndInvalidate(); self.session = nil }
        guard let continuation else { return }
        self.continuation = nil
        if let policyError {
            continuation.resume(throwing: policyError)
        } else if let error {
            let nsError = error as NSError
            if let resumeData = nsError.userInfo["NSURLSessionDownloadTaskResumeData"] as? Data, !resumeData.isEmpty {
                continuation.resume(throwing: ResumableDownloadFailure(resumeData: resumeData, underlying: error))
            } else {
                continuation.resume(throwing: error)
            }
        } else if let downloadedURL, let response {
            continuation.resume(returning: (downloadedURL, response))
        } else {
            continuation.resume(throwing: VisionStackError.mediaArchiveFailed("下载完成但临时文件不可用。"))
        }
    }
}

actor WebSearchService {
    func search(_ query: String) async throws -> SearchOutcome {
        guard var components = URLComponents(string: "https://html.duckduckgo.com/html/") else { throw VisionStackError.searchFailed("无法构造搜索地址。") }
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else { throw VisionStackError.searchFailed("搜索地址无效。") }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Mozilla/5.0 (Macintosh; VisionStack/0.2)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let html = String(data: data, encoding: .utf8) else {
            throw VisionStackError.searchFailed("联网检索失败，请检查网络后重试。")
        }
        let sources = parse(html: html)
        if sources.isEmpty, html.localizedCaseInsensitiveContains("result__") { throw VisionStackError.searchFailed("搜索页面结构发生变化，当前结果无法可靠解析。") }
        return SearchOutcome(sources: sources, warning: sources.isEmpty ? "联网检索没有返回可引用资料，本轮未按实时资料回答。" : nil)
    }

    static func resolveDuckDuckGoURL(_ raw: String) -> String {
        let normalized = raw.hasPrefix("//") ? "https:" + raw : raw
        guard let components = URLComponents(string: normalized), components.host?.contains("duckduckgo.com") == true,
              let destination = components.queryItems?.first(where: { $0.name == "uddg" })?.value,
              let url = URL(string: destination), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return normalized }
        return url.absoluteString
    }

    private func parse(html: String) -> [ResearchSource] {
        let pattern = #"<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>[\s\S]*?<a[^>]*class="result__snippet"[^>]*>(.*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).prefix(6).compactMap { match in
            guard let u = Range(match.range(at: 1), in: html), let t = Range(match.range(at: 2), in: html), let s = Range(match.range(at: 3), in: html) else { return nil }
            let resolved = Self.resolveDuckDuckGoURL(decodeHTML(String(html[u])))
            guard let url = URL(string: resolved), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            return ResearchSource(title: clean(String(html[t])), url: resolved, snippet: clean(String(html[s])))
        }
    }

    private func clean(_ value: String) -> String {
        decodeHTML(value.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func decodeHTML(_ value: String) -> String {
        value.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
    }
}

enum LibraryImporter {
    @MainActor static func chooseDirectory() -> URL? {
        let panel = NSOpenPanel(); panel.title = "选择灵栈导出的 Agent / Skill 目录"
        panel.message = "映栈只读取定义与说明，不执行 scripts、hooks、MCP 或二进制文件。"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func scan(_ root: URL) throws -> [ImportedResource] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            throw VisionStackError.importFailed("无法读取所选目录。")
        }
        var resources: [ImportedResource] = []; var inspected = 0
        for case let url as URL in enumerator {
            inspected += 1
            if inspected > 2_000 { throw VisionStackError.importFailed("目录文件过多，已在 2,000 项安全上限停止。") }
            let values = try url.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            guard values.isRegularFile == true, (values.fileSize ?? 0) <= 2_000_000 else { continue }
            let lowerPath = url.path.lowercased(); let isSkill = url.lastPathComponent.lowercased() == "skill.md"
            let isAgent = !isSkill && lowerPath.contains("/agent") && ["md", "json", "yaml", "yml"].contains(url.pathExtension.lowercased())
            guard isSkill || isAgent else { continue }
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { continue }
            let metadata = frontmatter(text)
            let fallbackName = isSkill ? url.deletingLastPathComponent().lastPathComponent : url.deletingPathExtension().lastPathComponent
            let name = metadata["name"] ?? fallbackName
            let summary = metadata["description"] ?? firstContentLine(text) ?? "从灵栈目录导入"
            let folder = url.deletingLastPathComponent()
            let risk = FileManager.default.fileExists(atPath: folder.appending(path: "scripts").path) ||
                text.localizedCaseInsensitiveContains("allowed-tools") || text.localizedCaseInsensitiveContains("hook") || text.localizedCaseInsensitiveContains("mcp")
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            resources.append(ImportedResource(kind: isSkill ? .skill : .agent, name: name, summary: summary,
                instructions: String(text.prefix(60_000)), sourcePath: url.path, contentHash: hash, executableRisk: risk, enabled: !risk))
        }
        return resources.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func frontmatter(_ text: String) -> [String: String] {
        guard text.hasPrefix("---"), let end = text.dropFirst(3).range(of: "\n---") else { return [:] }
        let block = text[text.index(text.startIndex, offsetBy: 3)..<end.lowerBound]
        return block.split(separator: "\n").reduce(into: [:]) { output, line in
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 { output[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
        }
    }
    private static func firstContentLine(_ text: String) -> String? {
        text.split(separator: "\n").map(String.init).first {
            let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return !value.isEmpty && value != "---" && !value.hasPrefix("#") && !value.contains(":")
        }
    }
}
