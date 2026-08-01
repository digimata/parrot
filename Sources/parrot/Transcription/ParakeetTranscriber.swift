import FluidAudio
import Foundation

/// Parakeet TDT (CoreML) via FluidAudio.
///
/// Measured against Whisper large-v3-turbo on the same corpus: an order of
/// magnitude faster, better on short utterances carrying English technical
/// terms, worse on long sentences. Offered as a choice rather than a default
/// because which side of that trade matters depends on how you dictate.
actor ParakeetTranscriber: Transcriber {
    let modelID: String
    private let model: TranscriptionModel
    private var manager: AsrManager?

    init(model: TranscriptionModel) {
        self.modelID = model.id
        self.model = model
    }

    func warmUp(onProgress: (@Sendable (Double) -> Void)? = nil) async throws {
        if manager != nil { return }
        guard model.engineID != nil, let directory = ModelWeights.directory(of: model) else {
            throw TranscriberError.missingEngineID
        }
        FileHandle.standardError.write(Data("loading \(model.id)...\n".utf8))
        let weights = try await AsrModels.downloadAndLoad(
            to: directory, version: .v3,
            progressHandler: { progress in onProgress?(progress.fractionCompleted) })
        let manager = AsrManager(config: .default)
        try await manager.loadModels(weights)
        self.manager = manager
        FileHandle.standardError.write(Data("✓ \(model.id) ready\n".utf8))
    }

    func transcribe(_ audio: [Float]) async throws -> String {
        if manager == nil { try await warmUp() }
        guard let manager else { throw TranscriberError.notLoaded }

        // Shorter than the engine's own minimum it throws instead of returning
        // nothing, and a tap on the hotkey is silence rather than a failure.
        let minimum = ASRConstants.minimumRequiredSamples(
            forSampleRate: Int(AudioCapture.targetSampleRate))
        guard audio.count >= minimum else { return "" }

        // Dictation hands over one finished utterance at a time, so the decoder
        // starts clean rather than continuing the previous phrase's state.
        var state = try TdtDecoderState()
        let result = try await manager.transcribe(audio, decoderState: &state)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func unload() async {
        await manager?.cleanup()
        manager = nil
    }
}
