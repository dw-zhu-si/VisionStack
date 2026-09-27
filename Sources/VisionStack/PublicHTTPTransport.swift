import Foundation
import Network
import Security
import Darwin

/// Every connection uses a numeric, checked IP endpoint. TLS still verifies the
/// original DNS name and sends that name as SNI. No second DNS lookup is performed
/// by the transport, including after redirects.
enum PublicHTTPTransport {
    static func data(for request: URLRequest, maximumBytes: Int) async throws -> (Data, URLResponse) {
        let result = try await perform(request, maximumBytes: Int64(maximumBytes), file: nil, policy: .sameOrigin, progress: nil)
        return (result.data, result.response)
    }

    static func download(_ request: URLRequest, maximumBytes: Int64,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> (URL, HTTPURLResponse) {
        let file = FileManager.default.temporaryDirectory.appending(path: "visionstack-public-download-\(UUID().uuidString)")
        do {
            let result = try await perform(request, maximumBytes: maximumBytes, file: file, policy: .publicMedia, progress: progress)
            return (file, result.response)
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    private static func perform(_ original: URLRequest, maximumBytes: Int64, file: URL?,
                                policy: HTTPRedirectPolicy, progress: (@Sendable (Double) -> Void)?) async throws -> PublicHTTPResult {
        guard let originalURL = original.url else { throw URLError(.badURL) }
        var request = original
        for hop in 0...5 {
            try Task.checkCancellation()
            guard let url = request.url, url.scheme?.lowercased() == "https", url.user == nil, url.password == nil, let host = url.host else { throw URLError(.unsupportedURL) }
            if case .publicMedia = policy, !MediaURLPolicy.isAllowedRemoteURL(url) { throw URLError(.unsupportedURL) }
            let address = try await PublicAddressPolicy.resolve(host)
            try Task.checkCancellation()
            let transfer = PublicHTTPTransfer(request: request, hostname: host, address: address, maximumBytes: maximumBytes, file: file, progress: progress)
            let result = try await transfer.run()
            guard [301, 302, 303, 307, 308].contains(result.response.statusCode),
                  let location = result.response.value(forHTTPHeaderField: "Location") else { return result }
            guard hop < 5, let target = URL(string: location, relativeTo: url)?.absoluteURL,
                  policy.allows(target, original: originalURL) else { throw URLError(.httpTooManyRedirects) }
            // Do not replay a generation POST after an automatic redirect: it may
            // already have been accepted and charged by the previous endpoint.
            guard request.httpMethod == nil || request.httpMethod == "GET" || request.httpMethod == "HEAD" else {
                throw VisionStackError.invalidResponse("模型提交发生重定向，已停止自动重发；请核对服务地址和任务状态。")
            }
            request.url = target
        }
        throw URLError(.httpTooManyRedirects)
    }
}

enum PublicAddressPolicy {
    static func isPublic(_ address: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            let n = UInt32(bigEndian: v4.s_addr)
            let a = (n >> 24) & 255, b = (n >> 16) & 255, c = (n >> 8) & 255
            return !(a == 0 || a == 10 || a == 127 || a >= 224
                || (a == 100 && (64...127).contains(b)) || (a == 169 && b == 254)
                || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168)
                || (a == 192 && b == 0 && (c == 0 || c == 2))
                || (a == 198 && (b == 18 || b == 19 || (b == 51 && c == 100)))
                || (a == 203 && b == 0 && c == 113))
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, address, &v6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: &v6) { Array($0) }
        // Only global unicast, excluding transition mechanisms that can embed a
        // private IPv4 endpoint and documentation addresses.
        guard bytes[0] & 0xe0 == 0x20 else { return false }
        if bytes[0] == 0x20 && bytes[1] == 0x02 { return false } // 6to4
        if bytes[0] == 0x20 && bytes[1] == 0x01 {
            if bytes[2] == 0 && bytes[3] <= 0x1f { return false } // protocol assignments / Teredo / ORCHID
            if bytes[2] == 0x0d && bytes[3] == 0xb8 { return false }
        }
        return true
    }

    static func resolve(_ hostname: String) async throws -> String {
        let host = hostname.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return try await CancellableHostResolver.resolve {
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            hints.ai_protocol = IPPROTO_TCP
            var results: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, "443", &hints, &results) == 0, let first = results else { throw URLError(.cannotFindHost) }
            defer { freeaddrinfo(first) }
            var addresses: [String] = []
            var cursor: UnsafeMutablePointer<addrinfo>? = first
            while let item = cursor {
                defer { cursor = item.pointee.ai_next }
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(item.pointee.ai_addr, item.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
                let address = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                guard isPublic(address) else {
                    throw VisionStackError.invalidResponse("服务域名解析到非公网地址，已拒绝连接。")
                }
                if !addresses.contains(address) { addresses.append(address) }
            }
            guard let selected = addresses.first(where: { !$0.contains(":") }) ?? addresses.first else { throw URLError(.cannotFindHost) }
            return selected
        }
    }
}

/// getaddrinfo itself is a blocking system call. Cancellation releases the
/// awaiting Swift task immediately; a late system result is discarded. The
/// operation remains on a utility queue until the system resolver finishes.
final class CancellableHostResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    private var finished = false

    static func resolve(using operation: @escaping @Sendable () throws -> String) async throws -> String {
        let bridge = CancellableHostResolver()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                bridge.start(continuation, operation: operation)
            }
        } onCancel: {
            bridge.complete(.failure(CancellationError()))
        }
    }

    private func start(_ continuation: CheckedContinuation<String, Error>, operation: @escaping @Sendable () throws -> String) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()
        DispatchQueue.global(qos: .utility).async {
            self.lock.lock()
            let shouldRun = !self.finished
            self.lock.unlock()
            guard shouldRun else { return }
            self.complete(Result(catching: operation))
        }
    }

    private func complete(_ result: Result<String, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

struct PublicHTTPResult: Sendable {
    let data: Data
    let response: HTTPURLResponse
}

/// All mutable connection/continuation state is confined to queue.
private final class PublicHTTPTransfer: @unchecked Sendable {
    private var sentRequest = false
    private let queue = DispatchQueue(label: "studio.yeluzi.visionstack.public-http")
    private let request: URLRequest
    private let hostname: String
    private let address: String
    private let maximumBytes: Int64
    private let file: URL?
    private let progress: (@Sendable (Double) -> Void)?
    private var continuation: CheckedContinuation<PublicHTTPResult, Error>?
    private var connection: NWConnection?
    private var timer: DispatchSourceTimer?
    private var cancelled = false
    private var decoder: HTTPBodyDecoder?
    private var handle: FileHandle?
    private var body = Data()

    init(request: URLRequest, hostname: String, address: String, maximumBytes: Int64,
         file: URL?, progress: (@Sendable (Double) -> Void)?) {
        self.request = request; self.hostname = hostname; self.address = address
        self.maximumBytes = maximumBytes; self.file = file; self.progress = progress
    }

    func run() async throws -> PublicHTTPResult {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async { self.start(continuation) }
            }
        } onCancel: {
            self.queue.async {
                self.cancelled = true
                self.finish(.failure(CancellationError()))
            }
        }
    }

    private func start(_ continuation: CheckedContinuation<PublicHTTPResult, Error>) {
        self.continuation = continuation
        guard !cancelled else { finish(.failure(CancellationError())); return }
        do {
            guard let url = request.url else { throw URLError(.badURL) }
            decoder = HTTPBodyDecoder(url: url, maximumBytes: maximumBytes)
            if let file {
                // Atomic truncate; never reuse bytes from a previous redirect.
                try Data().write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                handle = try FileHandle(forWritingTo: file)
            }
            let wireRequest = try Self.serialize(request)
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, hostname)
            sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
            let serverName = hostname
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
                let reference = sec_trust_copy_ref(trust).takeRetainedValue()
                SecTrustSetPolicies(reference, SecPolicyCreateSSL(true, serverName as CFString))
                // Trust validation must not open implicit AIA/OCSP network requests
                // outside this transport's checked destination policy.
                SecTrustSetNetworkFetchAllowed(reference, false)
                complete(SecTrustEvaluateWithError(reference, nil))
            }, queue)
            let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
            guard let port = NWEndpoint.Port(rawValue: UInt16(exactly: url.port ?? 443) ?? 0), port.rawValue > 0 else { throw URLError(.badURL) }
            let connection = NWConnection(host: NWEndpoint.Host(address), port: port, using: parameters)
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                guard let self, self.continuation != nil else { return }
                switch state {
                case .ready:
                    guard !self.sentRequest else { return }
                    self.sentRequest = true
                    connection.send(content: wireRequest, completion: .contentProcessed { [weak self] error in
                        guard let self else { return }
                        if let error { self.finish(.failure(error)) } else { self.receive() }
                    })
                case .failed(let error): self.finish(.failure(error))
                case .cancelled: self.finish(.failure(CancellationError()))
                default: break
                }
            }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + max(1, request.timeoutInterval))
            timer.setEventHandler { [weak self] in self?.finish(.failure(URLError(.timedOut))) }
            self.timer = timer
            timer.resume()
            connection.start(queue: queue)
        } catch { finish(.failure(error)) }
    }

    private func receive() {
        guard continuation != nil else { return }
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self] data, _, complete, error in
            guard let self, self.continuation != nil else { return }
            do {
                try self.decoder?.append(data ?? Data(), endOfStream: complete) { chunk in
                    if let handle = self.handle { try handle.write(contentsOf: chunk) }
                    else { self.body.append(chunk) }
                }
                if let decoder = self.decoder, decoder.isFinished, let response = decoder.response {
                    self.finish(.success(PublicHTTPResult(data: self.body, response: response)))
                    return
                }
                if let error { throw error }
                if let decoder = self.decoder, let length = decoder.expectedLength, length > 0 {
                    self.progress?(min(1, Double(decoder.receivedBytes) / Double(length)))
                }
                self.receive()
            } catch { self.finish(.failure(error)) }
        }
    }

    private func finish(_ result: Result<PublicHTTPResult, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.cancel(); timer = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel(); connection = nil
        do { try handle?.close() } catch {
            handle = nil
            body = Data()
            continuation.resume(throwing: error)
            return
        }
        handle = nil
        body = Data()
        continuation.resume(with: result)
    }

    static func serialize(_ request: URLRequest) throws -> Data {
        guard let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = url.host, request.httpBodyStream == nil else { throw URLError(.badURL) }
        let method = request.httpMethod ?? "GET"
        var target = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if let query = components.percentEncodedQuery { target += "?" + query }
        guard !method.contains(where: { $0.isWhitespace }), !target.contains("\r"), !target.contains("\n") else { throw URLError(.badURL) }
        var headers = request.allHTTPHeaderFields ?? [:]
        for key in Array(headers.keys) where ["host", "connection", "content-length", "transfer-encoding", "accept-encoding"].contains(key.lowercased()) { headers[key] = nil }
        headers["Host"] = host + ((url.port != nil && url.port != 443) ? ":\(url.port!)" : "")
        headers["Connection"] = "close"
        headers["Accept-Encoding"] = "identity"
        if let body = request.httpBody { headers["Content-Length"] = String(body.count) }
        var text = "\(method) \(target) HTTP/1.1\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            guard !name.contains(where: { $0.isWhitespace || $0 == ":" }),
                  !value.contains("\r"), !value.contains("\n") else { throw URLError(.badURL) }
            text += "\(name): \(value)\r\n"
        }
        var data = Data((text + "\r\n").utf8)
        if let body = request.httpBody { data.append(body) }
        return data
    }
}

/// Incremental HTTP/1.1 framing. The retained parsing buffer is limited to a
/// header or a single receive chunk, independently of total media size.
struct HTTPBodyDecoder {
    private enum Phase { case headers, fixed(Int64), untilEOF, chunkSize, chunk(Int64), chunkEnd, trailers, finished }
    private var phase: Phase = .headers
    private var buffer = Data()
    private let url: URL
    private let maximumBytes: Int64
    private(set) var response: HTTPURLResponse?
    private(set) var receivedBytes: Int64 = 0
    private(set) var expectedLength: Int64?
    var isFinished: Bool { if case .finished = phase { return true }; return false }

    init(url: URL, maximumBytes: Int64) { self.url = url; self.maximumBytes = maximumBytes }

    mutating func append(_ data: Data, endOfStream: Bool = false, sink: (Data) throws -> Void) throws {
        guard !isFinished else { return }
        buffer.append(data)
        let separator = Data("\r\n\r\n".utf8), newline = Data("\r\n".utf8)
        while !isFinished {
            switch phase {
            case .headers:
                guard let range = buffer.range(of: separator) else {
                    guard buffer.count <= 65_536 else { throw URLError(.badServerResponse) }
                    if endOfStream { throw URLError(.badServerResponse) }; return
                }
                guard buffer.distance(from: buffer.startIndex, to: range.upperBound) <= 65_536,
                      let text = String(data: buffer[..<range.lowerBound], encoding: .isoLatin1) else { throw URLError(.badServerResponse) }
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                let lines = text.components(separatedBy: "\r\n")
                let statusParts = (lines.first ?? "").split(separator: " ")
                guard statusParts.count >= 2, ["HTTP/1.0", "HTTP/1.1"].contains(String(statusParts[0])), let status = Int(statusParts[1]) else { throw URLError(.badServerResponse) }
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { throw URLError(.badServerResponse) }
                    let name = String(line[..<colon]).lowercased()
                    let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    if headers[name] != nil && ["content-length", "transfer-encoding"].contains(name) { throw URLError(.badServerResponse) }
                    headers[name] = value
                }
                if (100..<200).contains(status) {
                    guard status != 101 else { throw URLError(.badServerResponse) }
                    continue
                }
                guard headers["content-encoding"] == nil || headers["content-encoding"]?.lowercased() == "identity" else { throw VisionStackError.invalidResponse("服务未遵循 identity 响应编码，已拒绝未经限额解压的数据。") }
                guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: String(statusParts[0]), headerFields: headers) else { throw URLError(.badServerResponse) }
                self.response = response
                if status == 204 || status == 304 { phase = .finished }
                else if let coding = headers["transfer-encoding"] {
                    guard coding.lowercased() == "chunked", headers["content-length"] == nil else { throw URLError(.badServerResponse) }
                    phase = .chunkSize
                } else if let rawLength = headers["content-length"] {
                    guard let length = Int64(rawLength), length >= 0, length <= maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
                    expectedLength = length
                    phase = length == 0 ? .finished : .fixed(length)
                } else { phase = .untilEOF }
            case .fixed(let remaining):
                let count = min(Int64(buffer.count), remaining)
                if count > 0 { try emit(Int(count), sink: sink); phase = count == remaining ? .finished : .fixed(remaining - count) }
                else { if endOfStream { throw URLError(.networkConnectionLost) }; return }
            case .untilEOF:
                if !buffer.isEmpty { try emit(buffer.count, sink: sink) }
                if endOfStream { phase = .finished } else { return }
            case .chunkSize:
                guard let range = buffer.range(of: newline) else {
                    guard buffer.count <= 8_192, !endOfStream else { throw URLError(.badServerResponse) }; return
                }
                guard let line = String(data: buffer[..<range.lowerBound], encoding: .ascii), line.utf8.count <= 8_192,
                      let rawSize = line.split(separator: ";", maxSplits: 1).first,
                      let size = Int64(rawSize, radix: 16), size >= 0, size <= maximumBytes - receivedBytes else { throw URLError(.dataLengthExceedsMaximum) }
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                phase = size == 0 ? .trailers : .chunk(size)
            case .chunk(let remaining):
                let count = min(Int64(buffer.count), remaining)
                if count > 0 { try emit(Int(count), sink: sink); phase = count == remaining ? .chunkEnd : .chunk(remaining - count) }
                else { if endOfStream { throw URLError(.networkConnectionLost) }; return }
            case .chunkEnd:
                guard buffer.count >= 2 else { if endOfStream { throw URLError(.badServerResponse) }; return }
                guard buffer.prefix(2) == newline else { throw URLError(.badServerResponse) }
                buffer.removeFirst(2); phase = .chunkSize
            case .trailers:
                if buffer.starts(with: newline) { buffer.removeFirst(2); phase = .finished }
                else if let range = buffer.range(of: separator) {
                    guard buffer.distance(from: buffer.startIndex, to: range.upperBound) <= 65_536 else { throw URLError(.badServerResponse) }
                    buffer.removeSubrange(buffer.startIndex..<range.upperBound); phase = .finished
                } else { guard buffer.count <= 65_536, !endOfStream else { throw URLError(.badServerResponse) }; return }
            case .finished: return
            }
        }
    }

    private mutating func emit(_ count: Int, sink: (Data) throws -> Void) throws {
        guard Int64(count) <= maximumBytes - receivedBytes else { throw URLError(.dataLengthExceedsMaximum) }
        let chunk = Data(buffer.prefix(count))
        try sink(chunk)
        receivedBytes += Int64(count)
        buffer.removeFirst(count)
    }
}
