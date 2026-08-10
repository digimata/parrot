import Foundation

final class ParakeetTranscriber: Transcriber, @unchecked Sendable {
    let modelID: String
    private let adapter: any ParakeetAdapter

    init(modelID: String, adapter: any ParakeetAdapter) {
        self.modelID = modelID
        self.adapter = adapter
    }

    func prepare() async throws {
        try await adapter.checkHealth()
    }

    func transcribe(_ audio: [Float]) async throws -> String {
        try await adapter.transcribe(
            samples: audio,
            sampleRate: AudioCapture.targetSampleRate
        )
    }
}
