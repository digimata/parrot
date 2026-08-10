import Foundation
import XCTest
@testable import parrot

final class ParakeetHTTPAdapterTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    func testHealthRequiresExpectedEndpointAndPayload() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/health")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer health-key")
            return Self.response(for: request, status: 200, body: #"{"status":"ok"}"#)
        }

        try await adapter(apiKey: "health-key").checkHealth()
    }

    func testMapsMalformedHealthAndTransportFailures() async throws {
        StubURLProtocol.handler = { request in
            Self.response(for: request, status: 200, body: #"{"status":"starting"}"#)
        }
        do {
            try await adapter().checkHealth()
            XCTFail("Expected malformed health failure")
        } catch let error as ParakeetError {
            guard case .malformedHealth = error else { return XCTFail("Unexpected \(error)") }
        }

        StubURLProtocol.handler = { _ in throw URLError(.timedOut) }
        do {
            try await adapter().checkHealth()
            XCTFail("Expected timeout failure")
        } catch let error as ParakeetError {
            guard case .timeout = error else { return XCTFail("Unexpected \(error)") }
        }

        StubURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        do {
            try await adapter().checkHealth()
            XCTFail("Expected connection failure")
        } catch let error as ParakeetError {
            guard case .connection = error else { return XCTFail("Unexpected \(error)") }
        }
    }

    func testRedirectDelegateAndAdapterRefuseRedirects() async throws {
        let production = ParakeetHTTPAdapter.makeProductionSession()
        let session = production.session
        let delegate = production.redirectDelegate
        defer { session.invalidateAndCancel() }
        XCTAssertTrue(session.configuration.connectionProxyDictionary?.isEmpty ?? false)
        let task = session.dataTask(with: URL(string: "http://127.0.0.1:5092/health")!)
        let response = HTTPURLResponse(
            url: URL(string: "http://127.0.0.1:5092/health")!,
            statusCode: 307,
            httpVersion: nil,
            headerFields: ["Location": "https://example.com/v1/audio/transcriptions"]
        )!
        var redirectedRequest: URLRequest?

        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: "https://example.com/v1/audio/transcriptions")!)
        ) { redirectedRequest = $0 }
        XCTAssertNil(redirectedRequest)

        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "127.0.0.1")
            return Self.response(for: request, status: 307, body: "")
        }
        do {
            _ = try await adapter().transcribe(samples: [], sampleRate: 16_000)
            XCTFail("Expected redirect failure")
        } catch let error as ParakeetError {
            guard case .redirect(let status) = error else { return XCTFail("Unexpected \(error)") }
            XCTAssertEqual(status, 307)
            XCTAssertEqual(
                error.errorDescription,
                "Parakeet redirected a local request (HTTP 307); redirects are blocked."
            )
        }
    }

    func testTranscriptionUploadsMultipartWAVWithAuthAndTrimsText() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/audio/transcriptions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=Parrot-") ?? false)
            let body = try XCTUnwrap(Self.requestBody(from: request))
            XCTAssertTrue(body.range(of: Data("name=\"model\"\r\n\r\nparakeet-tdt-0.6b".utf8)) != nil)
            XCTAssertTrue(body.range(of: Data("name=\"response_format\"\r\n\r\njson".utf8)) != nil)
            XCTAssertTrue(body.range(of: Data("filename=\"audio.wav\"".utf8)) != nil)
            XCTAssertTrue(body.range(of: Data("Content-Type: audio/wav".utf8)) != nil)
            XCTAssertTrue(body.range(of: Data("RIFF".utf8)) != nil)
            return Self.response(for: request, status: 200, body: #"{"text":"  hello world \n"}"#)
        }

        let text = try await adapter(apiKey: "test-key").transcribe(samples: [0, 0.5], sampleRate: 16_000)

        XCTAssertEqual(text, "hello world")
    }

    func testEmptyTextIsSuccessfulSilenceResult() async throws {
        StubURLProtocol.handler = { request in
            Self.response(for: request, status: 200, body: #"{"text":""}"#)
        }

        let text = try await adapter().transcribe(samples: [], sampleRate: 16_000)
        XCTAssertEqual(text, "")
    }

    func testMapsUnauthorizedAndStructuredFailuresWithBoundedMessage() async throws {
        StubURLProtocol.handler = { request in
            Self.response(for: request, status: 403, body: #"{"error":{"type":"authentication_error","message":"secret"}}"#)
        }
        do {
            _ = try await adapter().transcribe(samples: [], sampleRate: 16_000)
            XCTFail("Expected authorization failure")
        } catch let error as ParakeetError {
            guard case .unauthorized = error else { return XCTFail("Unexpected \(error)") }
        }

        StubURLProtocol.handler = { request in
            Self.response(
                for: request,
                status: 500,
                body: #"{"error":{"type":"server_error","message":"Transcription failed: \naudio too long for a single pass; enable long-audio mode"}}"#
            )
        }
        do {
            _ = try await adapter().transcribe(samples: [], sampleRate: 16_000)
            XCTFail("Expected server failure")
        } catch let error as ParakeetError {
            guard case .serverFailure(let status, let type, let message) = error else { return XCTFail("Unexpected \(error)") }
            XCTAssertEqual(status, 500)
            XCTAssertEqual(type, "server_error")
            XCTAssertEqual(message, "Transcription failed: audio too long for a single pass; enable long-audio mode")
            XCTAssertEqual(
                error.errorDescription,
                "Parakeet service failed (HTTP 500, server_error): Transcription failed: audio too long for a single pass; enable long-audio mode"
            )
        }

        StubURLProtocol.handler = { request in
            Self.response(for: request, status: 400, body: #"{"error":{"type":"invalid_request_error"}}"#)
        }
        do {
            _ = try await adapter().transcribe(samples: [], sampleRate: 16_000)
            XCTFail("Expected client failure")
        } catch let error as ParakeetError {
            guard case .clientFailure(let status, let type, let message) = error else { return XCTFail("Unexpected \(error)") }
            XCTAssertEqual(status, 400)
            XCTAssertEqual(type, "invalid_request_error")
            XCTAssertNil(message)
        }

        let longType = String(repeating: "t", count: 120) + "\u{001B}\u{0000}\nsecond type"
        let longMessage = String(repeating: "x", count: 500) + "\u{0000}\nsecond line"
        StubURLProtocol.handler = { request in
            Self.response(
                for: request,
                status: 500,
                body: Self.structuredErrorBody(type: longType, message: longMessage)
            )
        }
        do {
            _ = try await adapter().transcribe(samples: [], sampleRate: 16_000)
            XCTFail("Expected bounded server failure")
        } catch let error as ParakeetError {
            guard case .serverFailure(_, let type, let message) = error else { return XCTFail("Unexpected \(error)") }
            XCTAssertLessThanOrEqual(type?.utf8.count ?? 0, 80)
            XCTAssertFalse(type?.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) ?? true)
            XCTAssertFalse(type?.contains("\n") ?? true)
            XCTAssertTrue(type?.hasSuffix("...") ?? false)
            XCTAssertLessThanOrEqual(message?.utf8.count ?? 0, 240)
            XCTAssertFalse(message?.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) ?? true)
            XCTAssertTrue(message?.hasSuffix("...") ?? false)
            XCTAssertFalse(error.errorDescription?.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) ?? true)
        }
    }

    func testRejectsOversizedWAVBeforeRequest() async throws {
        let smallLimit = 45
        let configuration = try ParakeetConfiguration(
            urlString: ParakeetConfiguration.defaultURL,
            maximumWAVBytes: smallLimit
        )
        let adapter = ParakeetHTTPAdapter(configuration: configuration, session: session())

        do {
            _ = try await adapter.transcribe(samples: [0], sampleRate: 16_000)
            XCTFail("Expected audio size failure")
        } catch let error as ParakeetError {
            guard case .audioTooLarge(let limit) = error else { return XCTFail("Unexpected \(error)") }
            XCTAssertEqual(limit, smallLimit)
        }
    }

    func testConfigurationAllowsOnlyExplicitLoopbackRoots() throws {
        XCTAssertNoThrow(try ParakeetConfiguration(urlString: "https://localhost:5092/"))
        XCTAssertNoThrow(try ParakeetConfiguration(urlString: "http://[::1]:5092"))
        for url in [
            "http://example.com:5092",
            "http://127.0.0.1",
            "http://user:pass@127.0.0.1:5092",
            "http://127.0.0.1:5092/v1",
            "http://127.0.0.1:5092?debug=1",
            "http://127.0.0.1:5092#fragment",
        ] {
            XCTAssertThrowsError(try ParakeetConfiguration(urlString: url), "Expected \(url) to be rejected")
        }
    }

    private func adapter(apiKey: String? = nil) -> ParakeetHTTPAdapter {
        let configuration = try! ParakeetConfiguration(
            urlString: ParakeetConfiguration.defaultURL,
            apiKey: apiKey
        )
        return ParakeetHTTPAdapter(configuration: configuration, session: session())
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func response(
        for request: URLRequest,
        status: Int,
        body: String
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: try! XCTUnwrap(request.url),
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(body.utf8))
    }

    private static func structuredErrorBody(type: String, message: String) -> String {
        let payload = ["error": ["type": type, "message": message]]
        return String(data: try! JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
    }

    private static func requestBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            body.append(buffer, count: count)
        }
        return body.isEmpty ? nil : body
    }
}

private final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handler)
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
