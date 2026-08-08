import XCTest
@testable import parrot

final class ParakeetTranscriberTests: XCTestCase {
    func testDelegatesPreparationAndSamplesToAdapter() async throws {
        let adapter = FakeParakeetAdapter(result: "transcript")
        let transcriber = ParakeetTranscriber(modelID: "parakeet-tdt-0.6b-v3", adapter: adapter)
        let samples: [Float] = [0.25, -0.5]

        try await transcriber.prepare()
        let result = try await transcriber.transcribe(samples)

        XCTAssertEqual(result, "transcript")
        XCTAssertEqual(transcriber.modelID, "parakeet-tdt-0.6b-v3")
        let healthChecks = await adapter.healthChecks
        let transcribedSamples = await adapter.transcribedSamples
        let sampleRate = await adapter.sampleRate
        XCTAssertEqual(healthChecks, 1)
        XCTAssertEqual(transcribedSamples, samples)
        XCTAssertEqual(sampleRate, AudioCapture.targetSampleRate)
    }
}

private actor FakeParakeetAdapter: ParakeetAdapter {
    private(set) var healthChecks = 0
    private(set) var transcribedSamples: [Float] = []
    private(set) var sampleRate = 0.0
    let result: String

    init(result: String) {
        self.result = result
    }

    func checkHealth() {
        healthChecks += 1
    }

    func transcribe(samples: [Float], sampleRate: Double) -> String {
        transcribedSamples = samples
        self.sampleRate = sampleRate
        return result
    }
}
