import FluidAudio
import Darwin
import Foundation

/// NVIDIA Parakeet TDT 0.6B v2 through FluidAudio's Core ML runtime.
/// The model downloads once, then runs entirely on-device on Apple Silicon.
actor ParakeetTranscriber: Transcriber {
    let modelID: String
    private var manager: AsrManager?

    init(model: TranscriptionModel) {
        self.modelID = model.id
    }

    func warmUp() async throws {
        guard manager == nil else { return }
        Self.cleanupStaleTemporaryAudio()
        FileHandle.standardError.write(Data("loading \(modelID)...\n".utf8))
        let models = try await AsrModels.downloadAndLoad(version: .v2)
        FileHandle.standardError.write(Data("loading Parakeet Core ML models...\n".utf8))
        let manager = AsrManager()
        try await manager.loadModels(models)
        self.manager = manager
        FileHandle.standardError.write(Data("✓ \(modelID) ready\n".utf8))
    }

    func transcribe(_ audio: [Float]) async throws -> String {
        if manager == nil { try await warmUp() }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "parrot-audio-\(getpid())-\(UUID().uuidString).wav"
            )
        defer { try? FileManager.default.removeItem(at: url) }
        try WAVWriter.write(samples: audio, sampleRate: Int(AudioCapture.targetSampleRate), to: url.path)

        return try await transcribeFile(url)
    }

    func transcribeFile(_ url: URL) async throws -> String {
        if manager == nil { try await warmUp() }
        guard let manager else { throw ParakeetTranscriberError.notLoaded }

        var decoderState = try TdtDecoderState()
        let result = try await manager.transcribe(url, decoderState: &decoderState)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanupStaleTemporaryAudio() {
        let directory = FileManager.default.temporaryDirectory
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for url in urls where url.lastPathComponent.hasPrefix("parrot-") && url.pathExtension == "wav" {
            let name = url.deletingPathExtension().lastPathComponent
            let components = name.split(separator: "-")

            // Current files include their creator PID. warmUp runs before this
            // actor creates audio, so same-PID files are leftovers from a rare
            // PID reuse and are safe to remove. Legacy UUID-only names also
            // belong to an earlier Parrot run.
            if components.count < 4 || components[1] != "audio" {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            guard let ownerPID = Int32(components[2]) else { continue }
            if ownerPID == getpid() {
                try? FileManager.default.removeItem(at: url)
                continue
            }

            errno = 0
            if Darwin.kill(ownerPID, 0) == -1, errno == ESRCH {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

enum ParakeetTranscriberError: Error {
    case notLoaded
    case emptyResult
}
