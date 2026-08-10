import Foundation

struct ParakeetConfiguration {
    static let defaultURL = "http://127.0.0.1:5092"
    static let defaultMaximumWAVBytes = 25 * 1024 * 1024

    let baseURL: URL
    let apiKey: String?
    let startupTimeout: TimeInterval
    let transcriptionTimeout: TimeInterval
    let maximumWAVBytes: Int

    init(
        urlString: String,
        apiKey: String? = nil,
        startupTimeout: TimeInterval = 30,
        transcriptionTimeout: TimeInterval = 15,
        maximumWAVBytes: Int = ParakeetConfiguration.defaultMaximumWAVBytes
    ) throws {
        guard
            let components = URLComponents(string: urlString),
            let scheme = components.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            let host = components.host?.lowercased(),
            ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host),
            let port = components.port,
            (1...65_535).contains(port),
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil,
            components.path.isEmpty || components.path == "/",
            let baseURL = components.url
        else {
            throw ParakeetError.invalidEndpoint
        }

        self.baseURL = baseURL
        self.apiKey = apiKey?.isEmpty == false ? apiKey : nil
        self.startupTimeout = startupTimeout
        self.transcriptionTimeout = transcriptionTimeout
        self.maximumWAVBytes = maximumWAVBytes
    }
}

enum ParakeetError: LocalizedError, CustomStringConvertible {
    case invalidEndpoint
    case connection(String)
    case timeout(String)
    case unauthorized
    case redirect(status: Int)
    case clientFailure(status: Int, type: String?, message: String?)
    case serverFailure(status: Int, type: String?, message: String?)
    case malformedHealth
    case malformedResponse
    case unexpectedResponse
    case audioTooLarge(limit: Int)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "Parakeet URL must be an HTTP(S) loopback URL with an explicit port."
        case .connection(let operation):
            return "Could not reach the local Parakeet service while \(operation)."
        case .timeout(let operation):
            return "The local Parakeet service timed out while \(operation)."
        case .unauthorized:
            return "Parakeet rejected the API key; check PARROT_PARAKEET_API_KEY."
        case .redirect(let status):
            return "Parakeet redirected a local request (HTTP \(status)); redirects are blocked."
        case .clientFailure(let status, let type, let message):
            return Self.failureDescription("Parakeet rejected the request", status, type, message)
        case .serverFailure(let status, let type, let message):
            return Self.failureDescription("Parakeet service failed", status, type, message)
        case .malformedHealth:
            return "Parakeet health response was invalid; expected {\"status\":\"ok\"}."
        case .malformedResponse:
            return "Parakeet transcription response was invalid; expected JSON text."
        case .unexpectedResponse:
            return "Parakeet returned a non-HTTP response."
        case .audioTooLarge(let limit):
            return "Captured audio exceeds Parakeet's \(limit / 1024 / 1024) MiB upload limit."
        }
    }

    var description: String {
        errorDescription ?? "Parakeet service error."
    }

    private static func failureDescription(
        _ prefix: String,
        _ status: Int,
        _ type: String?,
        _ message: String?
    ) -> String {
        let detail = type.map { ", \($0)" } ?? ""
        let base = "\(prefix) (HTTP \(status)\(detail))"
        return message.map { "\(base): \($0)" } ?? "\(base)."
    }
}

final class ParakeetHTTPAdapter: ParakeetAdapter, @unchecked Sendable {
    private let configuration: ParakeetConfiguration
    private let session: URLSession
    private let redirectDelegate: RedirectBlockingDelegate?

    init(configuration: ParakeetConfiguration, session: URLSession? = nil) {
        self.configuration = configuration
        if let session {
            self.session = session
            redirectDelegate = nil
        } else {
            let production = Self.makeProductionSession()
            self.redirectDelegate = production.redirectDelegate
            self.session = production.session
        }
    }

    static func makeProductionSession() -> (session: URLSession, redirectDelegate: RedirectBlockingDelegate) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let redirectDelegate = RedirectBlockingDelegate()
        let session = URLSession(
            configuration: configuration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
        return (session, redirectDelegate)
    }

    func checkHealth() async throws {
        var request = URLRequest(url: endpoint("health"))
        request.httpMethod = "GET"
        request.timeoutInterval = configuration.startupTimeout
        authorize(&request)
        let (data, response) = try await perform(request, operation: "checking readiness")
        try validate(status: response.statusCode, data: data)

        guard
            let health = try? JSONDecoder().decode(HealthResponse.self, from: data),
            health.status == "ok"
        else {
            throw ParakeetError.malformedHealth
        }
    }

    func transcribe(samples: [Float], sampleRate: Double) async throws -> String {
        let maximumSamples = (configuration.maximumWAVBytes - 44) / 2
        guard samples.count <= maximumSamples else {
            throw ParakeetError.audioTooLarge(limit: configuration.maximumWAVBytes)
        }
        let wav = WAVEncoder.data(samples: samples, sampleRate: Int(sampleRate.rounded()))
        guard wav.count <= configuration.maximumWAVBytes else {
            throw ParakeetError.audioTooLarge(limit: configuration.maximumWAVBytes)
        }

        let boundary = "Parrot-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint("v1/audio/transcriptions"))
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.transcriptionTimeout
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        authorize(&request)
        request.httpBody = multipartBody(wav: wav, boundary: boundary)

        let (data, response) = try await perform(request, operation: "transcribing")
        try validate(status: response.statusCode, data: data)
        guard let transcription = try? JSONDecoder().decode(TranscriptionResponse.self, from: data) else {
            throw ParakeetError.malformedResponse
        }
        return transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func endpoint(_ path: String) -> URL {
        configuration.baseURL.appendingPathComponent(path)
    }

    private func authorize(_ request: inout URLRequest) {
        if let apiKey = configuration.apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
    }

    private func perform(
        _ request: URLRequest,
        operation: String
    ) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw ParakeetError.unexpectedResponse
            }
            return (data, response)
        } catch let error as ParakeetError {
            throw error
        } catch let error as URLError {
            if error.code == .timedOut {
                throw ParakeetError.timeout(operation)
            }
            throw ParakeetError.connection(operation)
        } catch {
            throw ParakeetError.connection(operation)
        }
    }

    private func validate(status: Int, data: Data) throws {
        guard status == 200 else {
            if (300...399).contains(status) { throw ParakeetError.redirect(status: status) }
            if status == 401 || status == 403 { throw ParakeetError.unauthorized }
            let upstream = (try? JSONDecoder().decode(UpstreamError.self, from: data))?.error
            let type = Self.sanitizedField(upstream?.type, maximumBytes: 80)
            let message = Self.sanitizedField(upstream?.message, maximumBytes: 240)
            if (400...499).contains(status) {
                throw ParakeetError.clientFailure(status: status, type: type, message: message)
            }
            throw ParakeetError.serverFailure(status: status, type: type, message: message)
        }
    }

    private static func sanitizedField(_ value: String?, maximumBytes: Int) -> String? {
        guard let value else { return nil }
        var withoutControls = ""
        for scalar in value.unicodeScalars where scalar.properties.generalCategory != .control {
            withoutControls.unicodeScalars.append(scalar)
        }
        let normalized = withoutControls.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !normalized.isEmpty else { return nil }

        guard normalized.utf8.count > maximumBytes else { return normalized }
        var truncated = ""
        for scalar in normalized.unicodeScalars {
            let next = String(scalar)
            guard truncated.utf8.count + next.utf8.count <= maximumBytes - 3 else { break }
            truncated.append(contentsOf: next)
        }
        return "\(truncated)..."
    }

    private func multipartBody(wav: Data, boundary: String) -> Data {
        var body = Data()
        appendField("model", value: "parakeet-tdt-0.6b", boundary: boundary, to: &body)
        appendField("response_format", value: "json", boundary: boundary, to: &body)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }

    private func appendField(_ name: String, value: String, boundary: String, to body: inout Data) {
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(value)\r\n".data(using: .utf8)!)
    }
}

final class RedirectBlockingDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private struct HealthResponse: Decodable {
    let status: String
}

private struct TranscriptionResponse: Decodable {
    let text: String
}

private struct UpstreamError: Decodable {
    struct Detail: Decodable {
        let message: String?
        let type: String?
    }

    let error: Detail?
}
