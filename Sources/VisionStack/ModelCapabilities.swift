import CryptoKit
import Foundation

enum ModelHubResponseParser {
    static func parse(_ value: Any) -> ParsedGenerationResponse {
        ParsedGenerationResponse(
            raw: pretty(value),
            taskID: taskID(in: value),
            mediaURLs: mediaValues(in: value),
            state: jobState(in: value),
            errorMessage: errorMessage(in: value),
            cost: costRecord(in: value)
        )
    }

    static func parse(rawJSON: String) -> ParsedGenerationResponse? {
        guard let data = rawJSON.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return parse(value)
    }

    static func diagnosticSummary(from raw: String) -> String {
        let data = Data(raw.utf8)
        if let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           existing["diagnostic_version"] != nil {
            return raw
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        var summary: [String: Any] = [
            "diagnostic_version": 1,
            "payload_bytes": data.count,
            "payload_sha256": digest
        ]
        if let value = try? JSONSerialization.jsonObject(with: data) {
            if let object = value as? [String: Any] { summary["top_level_keys"] = object.keys.sorted() }
            let parsed = parse(value)
            if let taskID = parsed.taskID { summary["task_id"] = taskID }
            if let state = parsed.state { summary["state"] = state.rawValue }
            summary["media_count"] = parsed.mediaURLs.count
            if parsed.cost != nil { summary["provider_cost_present"] = true }
        } else {
            summary["invalid_json"] = true
        }
        return pretty(summary)
    }

    static func costRecord(in value: Any) -> JobCostRecord? {
        guard let top = value as? [String: Any] else { return nil }
        let usage = (top["usage"] as? [String: Any]) ?? ((top["data"] as? [String: Any])?["usage"] as? [String: Any]) ?? [:]
        let actualValue = top["total_cost"] ?? top["cost"] ?? usage["total_cost"] ?? usage["cost"]
        func decimal(_ value: Any?) -> Decimal? {
            guard let value else { return nil }
            if let number = value as? NSNumber { return number.decimalValue }
            if let string = value as? String { return Decimal(string: string) }
            return nil
        }
        func integer(_ value: Any?) -> Int? {
            if let number = value as? NSNumber { return number.intValue }
            if let string = value as? String { return Int(string) }
            return nil
        }
        let actual = decimal(actualValue)
        let input = integer(usage["input_tokens"] ?? usage["prompt_tokens"])
        let output = integer(usage["output_tokens"] ?? usage["completion_tokens"])
        guard actual != nil || input != nil || output != nil else { return nil }
        return JobCostRecord(
            currency: (top["currency"] as? String) ?? (usage["currency"] as? String) ?? "CNY",
            estimatedAmount: nil,
            actualAmount: actual,
            inputTokens: input,
            outputTokens: output,
            providerReported: true
        )
    }

    static func taskID(in value: Any) -> String? {
        for object in recursiveObjects(in: value) {
            for key in ["task_id", "taskId", "request_id"] {
                if let id = object[key] as? String, !id.isEmpty { return id }
            }
        }
        if let top = value as? [String: Any], let id = top["id"] as? String, !id.isEmpty { return id }
        return nil
    }

    static func mediaValues(in value: Any) -> [String] {
        let mediaKeys: Set<String> = ["url", "video_url", "image_url", "output_url", "file_url", "image", "video"]
        let base64Keys: Set<String> = ["b64_json", "base64", "image_base64"]
        var output: [String] = []

        func append(_ value: String) {
            guard value.hasPrefix("http://") || value.hasPrefix("https://") || value.hasPrefix("data:") else { return }
            if !output.contains(value) { output.append(value) }
        }

        func walk(_ value: Any, key: String?, depth: Int) {
            guard depth <= 16 else { return }
            if let string = value as? String, let key {
                let normalizedKey = key.lowercased()
                if mediaKeys.contains(normalizedKey) { append(string) }
                if base64Keys.contains(normalizedKey), !string.hasPrefix("data:") {
                    append("data:image/png;base64,\(string)")
                }
                return
            }
            if let object = value as? [String: Any] {
                if let inline = (object["inlineData"] ?? object["inline_data"]) as? [String: Any],
                   let data = inline["data"] as? String, !data.isEmpty {
                    let mime = (inline["mimeType"] ?? inline["mime_type"]) as? String ?? "image/png"
                    append("data:\(mime);base64,\(data)")
                }
                for childKey in object.keys.sorted() {
                    if let child = object[childKey] { walk(child, key: childKey, depth: depth + 1) }
                }
            } else if let array = value as? [Any] {
                for child in array { walk(child, key: key, depth: depth + 1) }
            }
        }

        walk(value, key: nil, depth: 0)
        return output
    }

    static func jobState(in value: Any) -> JobState? {
        for object in recursiveObjects(in: value) {
            for key in ["status", "state", "task_status"] {
                guard let raw = object[key] as? String else { continue }
                switch raw.lowercased() {
                case "succeeded", "success", "completed", "done": return .succeeded
                case "failed", "error": return .failed
                case "cancelled", "canceled": return .cancelled
                case "queued", "pending": return .queued
                case "running", "processing", "in_progress": return .running
                default: continue
                }
            }
        }
        return nil
    }

    static func errorMessage(in value: Any) -> String? {
        guard let object = value as? [String: Any] else { return nil }
        if let error = object["error"] as? [String: Any] { return error["message"] as? String }
        if let error = object["error"] as? String { return error }
        return object["message"] as? String
    }

    private static func recursiveObjects(in value: Any) -> [[String: Any]] {
        var output: [[String: Any]] = []
        func walk(_ value: Any, depth: Int) {
            guard depth <= 16 else { return }
            if let object = value as? [String: Any] {
                output.append(object)
                let preferred = ["data", "output", "result", "choices", "message", "content"]
                for key in preferred where object[key] != nil { walk(object[key] as Any, depth: depth + 1) }
                for key in object.keys.sorted() where !preferred.contains(key) {
                    if let child = object[key], child is [String: Any] || child is [Any] { walk(child, depth: depth + 1) }
                }
            } else if let array = value as? [Any] {
                for child in array { walk(child, depth: depth + 1) }
            }
        }
        walk(value, depth: 0)
        return output
    }

    private static func pretty(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else {
            return String(describing: value)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

enum CapabilityRegistry {
    static func profile(for id: String) -> CapabilityProfile {
        let name = id.split(separator: "/").last.map(String.init)?.lowercased() ?? id.lowercased()
        let operations: Set<CreativeOperation>
        let source: CapabilitySource

        if isUnsupported(name) {
            operations = []
            source = .unsupported
        } else if isExplicitVideo(name) {
            operations = [.video]
            source = .bundledProfile
        } else if isImage(name) {
            operations = [.image]
            source = .bundledProfile
        } else if name.contains("grok-imagine") {
            operations = [.image, .video]
            source = .bundledProfile
        } else if isChat(name) {
            operations = [.chat]
            source = .bundledProfile
        } else {
            operations = []
            source = .unknown
        }

        return CapabilityProfile(
            modelID: id,
            operations: operations,
            imageSizes: operations.contains(.image) ? ["1024x1024", "1536x1024", "1024x1536"] : [],
            aspectRatios: operations.contains(.video) ? ["16:9", "9:16", "1:1"] : [],
            qualities: operations.contains(.image) ? ["auto", "medium", "high"] : [],
            videoResolutions: operations.contains(.video) ? ["720p", "1080p"] : [],
            durations: operations.contains(.video) ? [4, 5, 8, 10] : [],
            source: source,
            verifiedAt: nil,
            inputModalities: operations.isEmpty ? nil : ["text"],
            imageMinimumWidth: operations.contains(.image) ? 256 : nil,
            imageMaximumWidth: operations.contains(.image) ? 4096 : nil,
            imageMinimumHeight: operations.contains(.image) ? 256 : nil,
            imageMaximumHeight: operations.contains(.image) ? 4096 : nil
        )
    }

    static func sanitizedCustomProfile(_ profile: CapabilityProfile) -> CapabilityProfile? {
        let bundled = self.profile(for: profile.modelID)
        guard bundled.source != .unsupported else { return nil }
        var result = profile
        if bundled.source == .bundledProfile {
            result.operations.formIntersection(bundled.operations)
            guard !result.operations.isEmpty else { return nil }
        }
        result.imageSizes = result.operations.contains(.image) ? result.imageSizes : []
        result.qualities = result.operations.contains(.image) ? result.qualities : []
        result.videoResolutions = result.operations.contains(.video) ? result.videoResolutions : []
        result.aspectRatios = result.operations.contains(.video) ? result.aspectRatios : []
        result.durations = result.operations.contains(.video) ? result.durations : []
        if result.operations.contains(.image) {
            result.imageMinimumWidth = result.imageMinimumWidth ?? bundled.imageMinimumWidth
            result.imageMaximumWidth = result.imageMaximumWidth ?? bundled.imageMaximumWidth
            result.imageMinimumHeight = result.imageMinimumHeight ?? bundled.imageMinimumHeight
            result.imageMaximumHeight = result.imageMaximumHeight ?? bundled.imageMaximumHeight
        } else {
            result.imageMinimumWidth = nil
            result.imageMaximumWidth = nil
            result.imageMinimumHeight = nil
            result.imageMaximumHeight = nil
        }
        result.source = .localProfile
        result.verifiedAt = nil
        return result
    }

    private static func isUnsupported(_ name: String) -> Bool {
        containsAny(name, [
            "embedding", "embed-", "-embed", "rerank", "ocr", "whisper", "transcribe",
            "-tts", "tts-", "speech", "audio", "music", "moderation", "guard"
        ])
    }

    private static func isExplicitVideo(_ name: String) -> Bool {
        containsAny(name, [
            "video", "seedance", "veo", "sora", "kling", "happyhorse", "hailuo",
            "pixverse", "runway", "-i2v", "-r2v", "-t2v"
        ])
    }

    private static func isImage(_ name: String) -> Bool {
        containsAny(name, [
            "image", "seedream", "dall-e", "dalle", "flux", "imagen", "z-image", "ideogram",
            "recraft", "stable-diffusion", "stable_diffusion", "sdxl", "midjourney", "hidream",
            "nano-banana", "nano_banana", "cogview", "paint"
        ])
    }

    private static func isChat(_ name: String) -> Bool {
        if ["o1", "o3", "o4"].contains(name) || ["o1-", "o3-", "o4-"].contains(where: name.hasPrefix) { return true }
        return containsAny(name, [
            "gpt", "claude", "deepseek", "qwen", "qwq", "glm", "kimi", "llama", "mistral",
            "command", "doubao", "gemini", "grok", "moonshot", "baichuan", "ernie", "hunyuan",
            "coder", "codex", "sonnet", "opus", "haiku", "minimax-m", "mimo", "step-",
            "sparkdesk", "agnes", "turbo"
        ])
    }

    private static func containsAny(_ value: String, _ tokens: [String]) -> Bool {
        tokens.contains(where: value.contains)
    }
}

enum GenerationHistoryMigrator {
    static func repaired(_ original: GenerationJob) -> (job: GenerationJob, changed: Bool) {
        var job = original
        guard !job.rawResponse.isEmpty else {
            if job.archiveState == .succeeded, !(job.remoteResultURLs ?? []).isEmpty {
                job.remoteResultURLs = nil
                return (job, true)
            }
            return (job, false)
        }

        if let parsed = ModelHubResponseParser.parse(rawJSON: job.rawResponse), !parsed.mediaURLs.isEmpty {
            if job.resultURLs.isEmpty, (job.remoteResultURLs ?? []).isEmpty {
                job.remoteResultURLs = parsed.mediaURLs
            }
            if job.resultURLs.isEmpty {
                job.state = .needsArchive
                job.submissionState = .submitted
                job.providerState = .succeeded
                job.archiveState = .failed
                job.taskID = job.taskID ?? parsed.taskID
                job.cost = job.cost ?? parsed.cost
                job.errorMessage = "供应商已返回媒体结果，本地尚未归档；可直接选择“存到本机”，无需再次付费生成。"
            }
        }

        if job.archiveState == .succeeded, !job.resultURLs.isEmpty { job.remoteResultURLs = nil }
        let summary = ModelHubResponseParser.diagnosticSummary(from: job.rawResponse)
        if job.rawResponse != summary { job.rawResponse = summary }
        return (job, job != original)
    }
}

enum SnapshotSanitizer {
    static func sanitized(_ snapshot: AppSnapshot) -> AppSnapshot {
        var snapshot = snapshot
        snapshot.schemaVersion = AppSnapshot.currentSchemaVersion
        snapshot.imageJobs = snapshot.imageJobs.map { GenerationHistoryMigrator.repaired($0).job }
        snapshot.videoJobs = snapshot.videoJobs.map { GenerationHistoryMigrator.repaired($0).job }
        return snapshot
    }
}

enum ParameterSelectionPolicy {
    static func preserving<Value: Equatable>(_ current: Value, allowed: [Value], fallback: Value) -> Value {
        if allowed.contains(current) { return current }
        return allowed.first ?? fallback
    }
}

enum BillingConfirmationPresentation {
    static func requiresModal(for operation: CreativeOperation) -> Bool {
        operation != .chat
    }
}

enum ImageDimensionValidation: Equatable, Sendable {
    case valid
    case invalid(String)

    var isValid: Bool {
        if case .valid = self { return true }
        return false
    }

    var message: String? {
        if case .invalid(let message) = self { return message }
        return nil
    }
}

enum ImageDimensionPolicy {
    static func parse(_ value: String) -> (width: Int, height: Int)? {
        let components = value.lowercased().split(separator: "x", maxSplits: 1)
        guard components.count == 2,
              let width = Int(components[0]), let height = Int(components[1]) else { return nil }
        return (width, height)
    }

    static func validation(width: Int, height: Int, profile: CapabilityProfile?) -> ImageDimensionValidation {
        let minimumWidth = profile?.imageMinimumWidth ?? 256
        let maximumWidth = profile?.imageMaximumWidth ?? 4096
        let minimumHeight = profile?.imageMinimumHeight ?? 256
        let maximumHeight = profile?.imageMaximumHeight ?? 4096
        guard (minimumWidth...maximumWidth).contains(width) else {
            return .invalid("宽度需在 \(minimumWidth)–\(maximumWidth) 像素之间")
        }
        guard (minimumHeight...maximumHeight).contains(height) else {
            return .invalid("高度需在 \(minimumHeight)–\(maximumHeight) 像素之间")
        }
        return .valid
    }

    static func requestValue(width: Int, height: Int) -> String { "\(width)x\(height)" }
}
