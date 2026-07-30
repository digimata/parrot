import Foundation
import WhisperKit

actor WhisperKitTranscriber: Transcriber {
    let modelID: String
    private let model: TranscriptionModel
    private var pipeline: WhisperKit?

    init(model: TranscriptionModel) {
        self.modelID = model.id
        self.model = model
    }

    /// Where model weights are cached.
    ///
    /// WhisperKit delegates downloads to HubApi, which defaults to
    /// ~/Documents/huggingface. ~/Documents is TCC-protected on macOS: a process
    /// launched from a terminal inherits the terminal's access, but one started by
    /// launchd has none of its own, so model loading fails with a permission
    /// error. Application Support sits outside TCC, so caching there keeps the
    /// LaunchAgent working without granting parrot access to Documents — fewer
    /// privileges, not more.
    static var modelCacheDirectory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("parrot", isDirectory: true)
    }

    /// Loads the model into memory; downloads first if not already on disk.
    /// Call once at startup so the first hotkey press isn't blocked on model
    /// download/load.
    func warmUp() async throws {
        if pipeline != nil { return }
        guard let whisperKitID = model.whisperKitID else {
            throw TranscriberError.missingEngineID
        }
        FileHandle.standardError.write(Data("loading \(model.id)...\n".utf8))

        let cache = Self.modelCacheDirectory
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

        let config = WhisperKitConfig(
            model: whisperKitID,
            downloadBase: cache,
            verbose: false,
            prewarm: true,
            load: true
        )
        pipeline = try await WhisperKit(config)
        FileHandle.standardError.write(Data("✓ \(model.id) ready\n".utf8))
    }

    func transcribe(_ audio: [Float]) async throws -> String {
        if pipeline == nil { try await warmUp() }
        guard let pipeline else { throw TranscriberError.notLoaded }

        let results = try await pipeline.transcribe(audioArray: audio)
        let raw = results.map(\.text).joined(separator: " ")
        return Self.sanitize(raw)
    }

    /// Strip Whisper's non-speech bracket tokens ([BLANK_AUDIO], [MUSIC],
    /// (silence), <|nospeech|>, etc.) and collapse whitespace. When the model
    /// hears silence it emits these literally; we don't want to paste them.
    static func sanitize(_ text: String) -> String {
        let patterns = [
            #"\[[^\]]*\]"#,        // [BLANK_AUDIO], [MUSIC], [Applause]
            #"\([^)]*\)"#,          // (silence), (music playing)
            #"<\|[^|]*\|>"#,        // <|nospeech|>, <|endoftext|>
            #"\*[^*]*\*"#,          // *background noise*
        ]
        var out = text
        for p in patterns {
            out = out.replacingOccurrences(of: p, with: " ", options: .regularExpression)
        }
        out = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum TranscriberError: Error {
    case missingEngineID
    case notLoaded
}
