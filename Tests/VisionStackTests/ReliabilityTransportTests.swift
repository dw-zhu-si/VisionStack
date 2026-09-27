import Foundation
import XCTest
@testable import VisionStack

final class ReliabilityTransportTests: XCTestCase {
    private let url = URL(string: "https://fixture.invalid/result")!

    func testDNSCancellationReturnsBeforeBlockedResolverAndDiscardsLateResult() async throws {
        let began = expectation(description: "resolver started")
        let cancelled = expectation(description: "awaiting task cancelled before resolver completed")
        let workerExited = expectation(description: "late resolver result produced")
        let release = DispatchSemaphore(value: 0)
        let task = Task {
            do {
                _ = try await CancellableHostResolver.resolve {
                    began.fulfill()
                    release.wait()
                    workerExited.fulfill()
                    return "8.8.8.8"
                }
                XCTFail("cancelled DNS must not return the late address")
            } catch { XCTAssertTrue(error is CancellationError) }
            cancelled.fulfill()
        }
        await fulfillment(of: [began], timeout: 2)
        task.cancel()
        // The worker is still blocked: task completion cannot depend on the
        // blocking system call returning.
        await fulfillment(of: [cancelled], timeout: 2)
        release.signal()
        await fulfillment(of: [workerExited], timeout: 2)
        _ = await task.value
    }

    func testDNSAlreadyCancelledDoesNotStartResolver() async {
        let called = DispatchSemaphore(value: 0)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await CancellableHostResolver.resolve { called.signal(); return "8.8.8.8" }
                XCTFail("already cancelled resolver must throw")
            } catch { XCTAssertTrue(error is CancellationError) }
        }
        await task.value
        XCTAssertEqual(called.wait(timeout: .now()), .timedOut)
    }

    func testDNSSuccessAndFailureAreForwardedWithoutNetwork() async throws {
        let address = try await CancellableHostResolver.resolve { "8.8.8.8" }
        XCTAssertEqual(address, "8.8.8.8")
        do {
            _ = try await CancellableHostResolver.resolve { throw URLError(.cannotFindHost) }
            XCTFail("resolver error must propagate")
        } catch { XCTAssertEqual((error as? URLError)?.code, .cannotFindHost) }
    }

    func testFixedBodyParsesOneByteAtATime() throws {
        var decoder = HTTPBodyDecoder(url: url, maximumBytes: 10)
        var result = Data()
        for byte in Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello".utf8) {
            try decoder.append(Data([byte])) { result.append($0) }
        }
        XCTAssertEqual(String(decoding: result, as: UTF8.self), "hello")
        XCTAssertTrue(decoder.isFinished)
        XCTAssertEqual(decoder.receivedBytes, 5)
    }

    func testChunkedBodyAndTrailersParseAcrossEveryBoundary() throws {
        var decoder = HTTPBodyDecoder(url: url, maximumBytes: 10)
        var result = Data()
        for byte in Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2;ext=yes\r\nhe\r\n3\r\nllo\r\n0\r\nX-Final: yes\r\n\r\n".utf8) {
            try decoder.append(Data([byte])) { result.append($0) }
        }
        XCTAssertEqual(String(decoding: result, as: UTF8.self), "hello")
        XCTAssertTrue(decoder.isFinished)
    }

    func testDeclaredOversizeRejectsBeforeWritingBody() {
        var decoder = HTTPBodyDecoder(url: url, maximumBytes: 4)
        var received = 0
        XCTAssertThrowsError(try decoder.append(Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello".utf8)) { received += $0.count })
        XCTAssertEqual(received, 0)
    }

    func testUnknownLengthAndChunkedBodiesCannotExceedLimit() throws {
        var decoder = HTTPBodyDecoder(url: url, maximumBytes: 4)
        var result = Data()
        try decoder.append(Data("HTTP/1.1 200 OK\r\n\r\n1234".utf8)) { result.append($0) }
        XCTAssertThrowsError(try decoder.append(Data("5".utf8)) { result.append($0) })
        XCTAssertEqual(result.count, 4)
        var chunked = HTTPBodyDecoder(url: url, maximumBytes: 4)
        XCTAssertThrowsError(try chunked.append(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n".utf8)) { _ in XCTFail("oversized chunk must not be emitted") })
    }

    func testPrematureEOFAndAmbiguousFramingFailClosed() throws {
        var short = HTTPBodyDecoder(url: url, maximumBytes: 10)
        XCTAssertThrowsError(try short.append(Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhi".utf8), endOfStream: true) { _ in })
        var ambiguous = HTTPBodyDecoder(url: url, maximumBytes: 10)
        XCTAssertThrowsError(try ambiguous.append(Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)) { _ in })
        var headers = HTTPBodyDecoder(url: url, maximumBytes: 10)
        XCTAssertThrowsError(try headers.append(Data(repeating: 65, count: 65_537)) { _ in })
    }

    func testPublicAddressPolicyRejectsPrivateTransitionAndReservedAddresses() {
        for address in ["127.0.0.1", "10.0.0.1", "100.64.0.1", "169.254.169.254", "172.31.0.1", "192.168.0.1", "198.18.0.1", "192.0.2.1", "224.0.0.1", "::1", "::ffff:127.0.0.1", "::ffff:7f00:1", "fc00::1", "fe80::1", "2002:7f00:1::", "2001:db8::1", "public.example"] {
            XCTAssertFalse(PublicAddressPolicy.isPublic(address), address)
        }
        XCTAssertTrue(PublicAddressPolicy.isPublic("8.8.8.8"))
        XCTAssertTrue(PublicAddressPolicy.isPublic("2606:4700:4700::1111"))
    }

    func testBoundedURLSessionAcceptsBodyAndRejectsOversizeWithoutNetwork() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineResponseProtocol.self]
        let (data, _) = try await BoundedHTTPTransport.data(for: URLRequest(url: URL(string: "https://fixture.invalid/small")!), maximumBytes: 5, configuration: configuration)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "hello")
        for path in ["oversize", "stream-oversize"] {
            let url = URL(string: "https://fixture.invalid/\(path)?id=\(UUID().uuidString)")!
            defer { OfflineResponseProtocol.stops.remove(url.absoluteString) }
            let clock = ContinuousClock()
            let began = clock.now
            do {
                _ = try await BoundedHTTPTransport.data(for: URLRequest(url: url, timeoutInterval: 3), maximumBytes: 5, configuration: configuration)
                XCTFail("oversized response must fail")
            } catch {
                guard case VisionStackError.invalidResponse(let message) = error else {
                    XCTFail("expected safety-capacity error, got \(error)")
                    continue
                }
                XCTAssertTrue(message.contains("安全容量上限"))
            }
            XCTAssertLessThan(began.duration(to: clock.now), .seconds(1), "must reject promptly, not pass by transport timeout")
            for _ in 0..<50 where !OfflineResponseProtocol.stops.contains(url.absoluteString) {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(OfflineResponseProtocol.stops.contains(url.absoluteString), "must stop the underlying request")
        }
    }

    func testBoundedURLSessionCancellationResumesExactlyOnceWithoutNetwork() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineResponseProtocol.self]
        let task = Task {
            try await BoundedHTTPTransport.data(for: URLRequest(url: URL(string: "https://fixture.invalid/wait")!), maximumBytes: 5, configuration: configuration)
        }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        do { _ = try await task.value; XCTFail("cancel must throw") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
    }
}

private final class OfflineResponseProtocol: URLProtocol, @unchecked Sendable {
    static let stops = OfflineStopRegistry()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url?.path == "/wait" { return }
        let oversize = request.url?.path == "/oversize"
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: request.url?.path == "/stream-oversize" ? ["Content-Type": "application/json"] : ["Content-Type": "application/json", "Content-Length": oversize ? "1000000" : "5"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if oversize {
            // Keep this response open without sending any body or EOF: the
            // declared-length guard must cancel it from the headers alone.
            return
        } else if request.url?.path == "/stream-oversize" {
            client?.urlProtocol(self, didLoad: Data("123456".utf8))
        } else {
            client?.urlProtocol(self, didLoad: Data("hello".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { if let url = request.url { Self.stops.insert(url.absoluteString) } }
}

private final class OfflineStopRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var values: Set<String> = []
    func insert(_ value: String) { lock.lock(); defer { lock.unlock() }; values.insert(value) }
    func contains(_ value: String) -> Bool { lock.lock(); defer { lock.unlock() }; return values.contains(value) }
    func remove(_ value: String) { lock.lock(); defer { lock.unlock() }; values.remove(value) }
}
