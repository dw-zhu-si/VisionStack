import Foundation
import Security

enum AIProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case modelHub
    case openAICompatible
    case anthropic
    case googleGemini

    var id: String { rawValue }
    var title: String {
        switch self {
        case .modelHub: "ModelHub"
        case .openAICompatible: "OpenAI 兼容"
        case .anthropic: "Anthropic"
        case .googleGemini: "Google Gemini"
        }
    }

    var summary: String {
        switch self {
        case .modelHub: "本机统一模型目录与路由，适合聚合多家图片、视频和对话模型。"
        case .openAICompatible: "适用于 OpenAI 及提供兼容 API 的任意厂商；厂商名称与模型 ID 不设白名单。"
        case .anthropic: "使用 Anthropic Messages 与 Models API，当前用于对话模型。"
        case .googleGemini: "使用 Gemini Models 与 generateContent API，可用于对话及支持图片输出的 Gemini 模型。"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .modelHub: "http://127.0.0.1:11435/v1"
        case .openAICompatible: "https://api.openai.com/v1"
        case .anthropic: "https://api.anthropic.com/v1"
        case .googleGemini: "https://generativelanguage.googleapis.com/v1beta"
        }
    }

    var supportsStandardVideoAPI: Bool { self == .modelHub || self == .openAICompatible }
}

struct AIProviderConfiguration: Identifiable, Codable, Hashable, Sendable {
    static let defaultModelHubID = UUID(uuidString: "98A4E47E-9C3D-4F5B-8BC2-4EE118F9FA40")!
    static let modelHubDefault = AIProviderConfiguration(
        id: defaultModelHubID,
        displayName: "ModelHub（推荐）",
        kind: .modelHub,
        baseURL: AIProviderKind.modelHub.defaultBaseURL,
        manualModelIDs: []
    )

    var id: UUID
    var displayName: String
    var kind: AIProviderKind
    var baseURL: String
    var manualModelIDs: [String]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        displayName: String,
        kind: AIProviderKind,
        baseURL: String,
        manualModelIDs: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.baseURL = baseURL
        self.manualModelIDs = manualModelIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

enum ProviderRecommendation {
    static let modelHubAppStoreURL = URL(string: "https://apps.apple.com/app/id6797847364")!
}

enum ProviderEndpointPolicy {
    static func validate(kind: AIProviderKind, baseURL: String) throws -> URL {
        let raw = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, raw.utf8.count <= 2_048,
              !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let url = URL(string: raw), let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw VisionStackError.server("模型服务地址格式无效；不能包含账号、查询参数或片段。")
        }
        let scheme = url.scheme?.lowercased() ?? ""
        if kind == .modelHub {
            guard ["http", "https"].contains(scheme), isLoopback(host),
                  ["", "/", "/v1", "/v1/"].contains(url.path) else {
                throw VisionStackError.invalidLoopbackURL
            }
            return url
        }
        guard scheme == "https" else {
            throw VisionStackError.server("厂商直连地址必须使用 HTTPS。若需连接本机服务，请通过 ModelHub。")
        }
        guard !isPrivateOrReserved(host) else {
            throw VisionStackError.server("厂商直连地址不能指向回环、局域网、链路本地或云元数据地址；本机模型请通过 ModelHub。")
        }
        guard !url.path.split(separator: "/").contains("..") else {
            throw VisionStackError.server("模型服务地址不能包含上级目录片段。")
        }
        return url
    }

    private static func isLoopback(_ host: String) -> Bool {
        ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)
    }

    private static func isPrivateOrReserved(_ host: String) -> Bool {
        if isLoopback(host) || host == "0.0.0.0" || host == "169.254.169.254"
            || host.hasSuffix(".local") || host.hasSuffix(".internal") || host.hasSuffix(".localhost") {
            return true
        }
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if normalized == "::" || normalized.hasPrefix("fe8") || normalized.hasPrefix("fe9")
            || normalized.hasPrefix("fea") || normalized.hasPrefix("feb")
            || normalized.hasPrefix("fc") || normalized.hasPrefix("fd") {
            return true
        }
        let octets = normalized.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        switch (octets[0], octets[1]) {
        case (0, _), (10, _), (127, _), (169, 254), (192, 168): return true
        case (100, 64...127), (172, 16...31), (198, 18...19): return true
        case (224...255, _): return true
        default: return false
        }
    }
}

protocol ProviderCredentialStoring: Sendable {
    func readSecret(for providerID: UUID) async -> String
    func saveSecret(_ secret: String, for providerID: UUID) async throws
    func deleteSecret(for providerID: UUID) async throws
}

actor KeychainProviderCredentialStore: ProviderCredentialStoring {
    private let service = "app.visionstack.community.provider-credentials"

    func readSecret(for providerID: UUID) async -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { return "" }
        return value
    }

    func saveSecret(_ secret: String, for providerID: UUID) async throws {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID.uuidString
        ]
        if secret.isEmpty {
            let status = SecItemDelete(identity as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw VisionStackError.server("Keychain 清理失败（\(status)）。")
            }
            return
        }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(secret.utf8),
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

    func deleteSecret(for providerID: UUID) async throws {
        try await saveSecret("", for: providerID)
    }
}

private final class SameOriginRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let scheme: String
    let host: String
    let port: Int?

    init(baseURL: URL) {
        scheme = baseURL.scheme?.lowercased() ?? ""
        host = baseURL.host?.lowercased() ?? ""
        port = baseURL.port
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              url.scheme?.lowercased() == scheme,
              url.host?.lowercased() == host,
              url.port == port else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

actor DirectAIProviderClient: ModelHubServicing {
    private let configuration: AIProviderConfiguration
    private let apiKey: String
    private let baseURL: URL
    private let session: URLSession
    private var cachedCatalog: ModelCatalog?

    init(configuration: AIProviderConfiguration, apiKey: String) throws {
        guard configuration.kind != .modelHub else {
            throw VisionStackError.server("ModelHub 连接应使用本机网关客户端。")
        }
        let url = try ProviderEndpointPolicy.validate(kind: configuration.kind, baseURL: configuration.baseURL)
        self.configuration = configuration
        self.apiKey = apiKey
        self.baseURL = url
        let delegate = SameOriginRedirectDelegate(baseURL: url)
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    func health() async throws -> ModelHubRuntimeStatus {
        let result = try await catalog()
        return .init(service: configuration.displayName, providerCount: 1, routeCount: result.models.count)
    }

    func catalog() async throws -> ModelCatalog {
        if let cachedCatalog { return cachedCatalog }
        let manual = configuration.manualModelIDs.map {
            ModelDescriptor(id: $0, owner: configuration.displayName, availability: "available", source: "provider-manual", connectionID: configuration.id)
        }
        let remote: [ModelDescriptor]
        do {
            remote = parseModels(try await request(path: "models"))
        } catch {
            guard !manual.isEmpty else { throw error }
            remote = []
        }
        let models = (remote + manual).reduce(into: [String: ModelDescriptor]()) { result, model in
            result[model.id] = result[model.id] ?? model
        }.values.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        guard !models.isEmpty else {
            throw VisionStackError.invalidResponse("厂商没有返回模型目录；请至少填写一个准确的模型 ID。")
        }
        let profiles = models.compactMap { model -> CapabilityProfile? in
            let profile = CapabilityRegistry.profile(for: model.id)
            return profile.isConfigured ? profile : nil
        }
        let value = ModelCatalog(models: models, embeddedCapabilities: profiles)
        cachedCatalog = value
        return value
    }

    func capabilities(for modelID: String) async throws -> CapabilityProfile {
        let profile = CapabilityRegistry.profile(for: modelID)
        guard profile.isConfigured else {
            throw VisionStackError.invalidResponse("该厂商协议没有提供结构化能力声明，请在映栈中建立本地能力档案。")
        }
        return profile
    }

    func chat(model: String, messages: [[String: String]], requestContext: BillableRequestContext) async throws -> String {
        switch configuration.kind {
        case .openAICompatible:
            let json = try await request(
                path: "chat/completions",
                method: "POST",
                body: ["model": model, "messages": messages, "stream": false],
                requestContext: requestContext
            )
            guard let object = json as? [String: Any],
                  let choices = object["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                throw VisionStackError.invalidResponse("厂商聊天响应缺少 choices[0].message.content。")
            }
            return content
        case .anthropic:
            let system = messages.filter { $0["role"] == "system" }.compactMap { $0["content"] }.joined(separator: "\n\n")
            let conversational = messages.filter { $0["role"] != "system" }
            var body: [String: Any] = ["model": model, "messages": conversational, "max_tokens": 4_096]
            if !system.isEmpty { body["system"] = system }
            let json = try await request(path: "messages", method: "POST", body: body, requestContext: requestContext)
            guard let object = json as? [String: Any], let content = object["content"] as? [[String: Any]] else {
                throw VisionStackError.invalidResponse("Anthropic 响应缺少 content 数组。")
            }
            let text = content.compactMap { $0["text"] as? String }.joined()
            guard !text.isEmpty else { throw VisionStackError.invalidResponse("Anthropic 没有返回文本内容。") }
            return text
        case .googleGemini:
            let (system, contents) = geminiContents(messages)
            var body: [String: Any] = ["contents": contents]
            if !system.isEmpty { body["systemInstruction"] = ["parts": [["text": system]]] }
            let json = try await request(path: "models/\(encodedModel(model)):generateContent", method: "POST", body: body, requestContext: requestContext, pathIsPercentEncoded: true)
            guard let object = json as? [String: Any], let candidates = object["candidates"] as? [[String: Any]],
                  let content = candidates.first?["content"] as? [String: Any], let parts = content["parts"] as? [[String: Any]] else {
                throw VisionStackError.invalidResponse("Gemini 响应缺少 candidates[0].content.parts。")
            }
            let text = parts.compactMap { $0["text"] as? String }.joined()
            guard !text.isEmpty else { throw VisionStackError.invalidResponse("Gemini 没有返回文本内容。") }
            return text
        case .modelHub:
            throw VisionStackError.invalidResponse("连接类型错误。")
        }
    }

    func generateImage(model: String, prompt: String, size: String, quality: String, referenceImage: String?, requestContext: BillableRequestContext) async throws -> ParsedGenerationResponse {
        try await generateImage(model: model, prompt: prompt, size: size, quality: quality, referenceImages: referenceImage.map { [$0] } ?? [], requestContext: requestContext)
    }

    func generateImage(model: String, prompt: String, size: String, quality: String, referenceImages: [String], requestContext: BillableRequestContext) async throws -> ParsedGenerationResponse {
        switch configuration.kind {
        case .openAICompatible:
            var body: [String: Any] = ["model": model, "prompt": prompt]
            if !size.isEmpty { body["size"] = size }
            if !quality.isEmpty { body["quality"] = quality }
            if let first = referenceImages.first { body["image"] = first }
            return ModelHubResponseParser.parse(try await request(path: "images/generations", method: "POST", body: body, requestContext: requestContext))
        case .googleGemini:
            let parts: [[String: Any]] = referenceImages.compactMap(Self.geminiInlinePart) + [["text": prompt]]
            let body: [String: Any] = [
                "contents": [["role": "user", "parts": parts]],
                "generationConfig": ["responseModalities": ["TEXT", "IMAGE"]]
            ]
            return ModelHubResponseParser.parse(try await request(path: "models/\(encodedModel(model)):generateContent", method: "POST", body: body, requestContext: requestContext, pathIsPercentEncoded: true))
        case .anthropic:
            throw VisionStackError.noModel("Anthropic 图片生成")
        case .modelHub:
            throw VisionStackError.invalidResponse("连接类型错误。")
        }
    }

    func generateVideo(model: String, prompt: String, size: String, ratio: String, duration: Int, referenceImage: String?, requestContext: BillableRequestContext) async throws -> ParsedGenerationResponse {
        guard configuration.kind == .openAICompatible else {
            throw VisionStackError.noModel("该厂商直连协议的视频生成；可改用 ModelHub 路由")
        }
        var body: [String: Any] = ["model": model, "prompt": prompt, "duration_seconds": duration]
        if !size.isEmpty { body["size"] = size }
        if !ratio.isEmpty { body["aspect_ratio"] = ratio }
        if let referenceImage { body["image_url"] = referenceImage }
        return ModelHubResponseParser.parse(try await request(path: "videos/generations", method: "POST", body: body, requestContext: requestContext))
    }

    func videoTask(model: String, taskID: String) async throws -> ParsedGenerationResponse {
        guard configuration.kind == .openAICompatible else { throw VisionStackError.noModel("视频任务查询") }
        return ModelHubResponseParser.parse(try await request(path: "tasks/\(ModelHubProtocolParser.encodedPathSegment(taskID))?model=\(ModelHubProtocolParser.encodedPathSegment(model))", pathIsPercentEncoded: true))
    }

    func requestStatus(model: String, clientRequestID: UUID) async throws -> ParsedGenerationResponse {
        guard configuration.kind == .openAICompatible else { throw VisionStackError.noModel("请求对账") }
        return ModelHubResponseParser.parse(try await request(path: "requests/\(clientRequestID.uuidString)?model=\(ModelHubProtocolParser.encodedPathSegment(model))", pathIsPercentEncoded: true))
    }

    func cancelVideoTask(model: String, taskID: String) async throws {
        guard configuration.kind == .openAICompatible else { throw VisionStackError.noModel("视频任务取消") }
        _ = try await request(path: "tasks/\(ModelHubProtocolParser.encodedPathSegment(taskID))?model=\(ModelHubProtocolParser.encodedPathSegment(model))", method: "DELETE", pathIsPercentEncoded: true)
    }

    private func parseModels(_ json: Any) -> [ModelDescriptor] {
        let rows: [Any]
        if let object = json as? [String: Any], let data = object["data"] as? [Any] { rows = data }
        else if let object = json as? [String: Any], let models = object["models"] as? [Any] { rows = models }
        else { rows = [] }
        return rows.compactMap { value in
            if let id = value as? String {
                return ModelDescriptor(id: id, owner: configuration.displayName, availability: "available", source: "provider", connectionID: configuration.id)
            }
            guard let row = value as? [String: Any],
                  let rawID = (row["id"] ?? row["name"]) as? String else { return nil }
            let id = rawID.hasPrefix("models/") ? String(rawID.dropFirst("models/".count)) : rawID
            return ModelDescriptor(
                id: id,
                owner: row["owned_by"] as? String ?? configuration.displayName,
                availability: "available",
                source: "provider",
                connectionID: configuration.id
            )
        }
    }

    private func request(
        path: String,
        method: String = "GET",
        body: [String: Any]? = nil,
        requestContext: BillableRequestContext? = nil,
        pathIsPercentEncoded: Bool = false
    ) async throws -> Any {
        let url = try endpoint(path: path, pathIsPercentEncoded: pathIsPercentEncoded)
        var request = URLRequest(url: url, timeoutInterval: method == "GET" ? 30 : 180)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch configuration.kind {
        case .openAICompatible:
            if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        case .anthropic:
            if !apiKey.isEmpty { request.setValue(apiKey, forHTTPHeaderField: "x-api-key") }
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .googleGemini:
            if !apiKey.isEmpty { request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key") }
        case .modelHub: break
        }
        if let requestContext {
            request.setValue(requestContext.idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
            request.setValue(requestContext.clientRequestID.uuidString, forHTTPHeaderField: "X-Client-Request-ID")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        guard data.count <= 64 * 1_024 * 1_024 else { throw VisionStackError.invalidResponse("厂商响应超过 64 MB 安全上限。") }
        guard let http = response as? HTTPURLResponse else { throw VisionStackError.invalidResponse() }
        let json = (try? JSONSerialization.jsonObject(with: data)) ?? ["raw": String(data: data, encoding: .utf8) ?? ""]
        guard (200..<300).contains(http.statusCode) else {
            let rawMessage = ModelHubResponseParser.errorMessage(in: json) ?? "厂商返回 HTTP \(http.statusCode)。"
            let limitedMessage = String(rawMessage.prefix(500))
            let message = apiKey.isEmpty ? limitedMessage : limitedMessage.replacingOccurrences(of: apiKey, with: "••••")
            if ModelHubProtocolParser.isBillingBlocked(statusCode: http.statusCode, response: json) {
                throw VisionStackError.billingBlocked(message)
            }
            throw VisionStackError.httpStatus(http.statusCode, message)
        }
        return json
    }

    private func endpoint(path: String, pathIsPercentEncoded: Bool) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw VisionStackError.invalidResponse("无法解析厂商地址。")
        }
        let split = path.split(separator: "?", maxSplits: 1).map(String.init)
        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let childPath = split[0].trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let combined = "/" + [basePath, childPath].filter { !$0.isEmpty }.joined(separator: "/")
        if pathIsPercentEncoded { components.percentEncodedPath = combined }
        else { components.path = combined.removingPercentEncoding ?? combined }
        components.percentEncodedQuery = split.count == 2 ? split[1] : nil
        guard let url = components.url else { throw VisionStackError.invalidResponse("无法构造厂商请求地址。") }
        return url
    }

    private func encodedModel(_ model: String) -> String {
        let value = model.hasPrefix("models/") ? String(model.dropFirst("models/".count)) : model
        return ModelHubProtocolParser.encodedPathSegment(value)
    }

    private func geminiContents(_ messages: [[String: String]]) -> (String, [[String: Any]]) {
        let system = messages.filter { $0["role"] == "system" }.compactMap { $0["content"] }.joined(separator: "\n\n")
        let contents: [[String: Any]] = messages.filter { $0["role"] != "system" }.map {
            ["role": $0["role"] == "assistant" ? "model" : "user", "parts": [["text": $0["content"] ?? ""]]]
        }
        return (system, contents)
    }

    private static func geminiInlinePart(_ dataURL: String) -> [String: Any]? {
        guard dataURL.hasPrefix("data:"),
              let semicolon = dataURL.firstIndex(of: ";"),
              let comma = dataURL.firstIndex(of: ","), semicolon < comma else { return nil }
        let mime = String(dataURL[dataURL.index(dataURL.startIndex, offsetBy: 5)..<semicolon])
        let data = String(dataURL[dataURL.index(after: comma)...])
        guard !mime.isEmpty, !data.isEmpty else { return nil }
        return ["inlineData": ["mimeType": mime, "data": data]]
    }
}
