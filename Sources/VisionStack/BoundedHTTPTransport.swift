import Foundation

/// Cancellation can arrive before URLSession has created its task.
final class NetworkTaskCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false

    func install(_ task: URLSessionTask) {
        lock.lock()
        self.task = task
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let current = task
        lock.unlock()
        current?.cancel()
    }

    func clear() {
        lock.lock()
        task = nil
        lock.unlock()
    }
}

enum HTTPRedirectPolicy: Sendable {
    case sameOrigin
    case publicMedia

    func allows(_ target: URL, original: URL) -> Bool {
        switch self {
        case .sameOrigin:
            return target.scheme?.lowercased() == original.scheme?.lowercased()
                && target.host?.lowercased() == original.host?.lowercased()
                && target.port == original.port
                && target.user == nil && target.password == nil
        case .publicMedia:
            return MediaURLPolicy.isAllowedRemoteURL(target)
        }
    }
}

/// Receives chunks on one delegate queue and aborts before retaining an oversized body.
final class BoundedHTTPTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maximumBytes: Int
    private let originalURL: URL
    private let redirectPolicy: HTTPRedirectPolicy
    private let cancellation = NetworkTaskCancellation()
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var session: URLSession?
    private var response: URLResponse?
    private var body = Data()

    private init(maximumBytes: Int, originalURL: URL, redirectPolicy: HTTPRedirectPolicy) {
        self.maximumBytes = maximumBytes
        self.originalURL = originalURL
        self.redirectPolicy = redirectPolicy
    }

    static func data(
        for request: URLRequest,
        maximumBytes: Int,
        redirectPolicy: HTTPRedirectPolicy = .sameOrigin,
        configuration: URLSessionConfiguration = .ephemeral
    ) async throws -> (Data, URLResponse) {
        guard let url = request.url, maximumBytes > 0 else { throw URLError(.badURL) }
        let receiver = BoundedHTTPTransport(maximumBytes: maximumBytes, originalURL: url, redirectPolicy: redirectPolicy)
        return try await receiver.perform(request, configuration: configuration)
    }

    private func perform(_ request: URLRequest, configuration: URLSessionConfiguration) async throws -> (Data, URLResponse) {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                self.session = session
                let task = session.dataTask(with: request)
                cancellation.install(task)
                task.resume()
            }
        } onCancel: {
            self.cancellation.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard response.expectedContentLength <= Int64(maximumBytes) else {
            completionHandler(.cancel)
            finish(.failure(VisionStackError.invalidResponse("响应超过安全容量上限，已停止下载。")))
            return
        }
        self.response = response
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard continuation != nil else { return }
        guard data.count <= maximumBytes - body.count else {
            finish(.failure(VisionStackError.invalidResponse("响应超过安全容量上限，已停止下载。")))
            return
        }
        body.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let target = request.url, redirectPolicy.allows(target, original: originalURL) else {
            completionHandler(nil)
            finish(.failure(VisionStackError.invalidResponse("服务重定向越过连接边界，已停止请求。")))
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
        else if let response { finish(.success((body, response))) }
        else { finish(.failure(URLError(.badServerResponse))) }
    }

    private func finish(_ result: Result<(Data, URLResponse), Error>) {
        guard let continuation else { return }
        self.continuation = nil
        // Stop the owned request immediately on a policy failure, rather than
        // relying only on asynchronous session invalidation or timeout.
        if case .failure = result { cancellation.cancel() }
        cancellation.clear()
        session?.invalidateAndCancel()
        session = nil
        body = Data()
        continuation.resume(with: result)
    }
}
