import Foundation

protocol ParakeetAdapter: Sendable {
    func checkHealth() async throws
    func transcribe(samples: [Float], sampleRate: Double) async throws -> String
}
