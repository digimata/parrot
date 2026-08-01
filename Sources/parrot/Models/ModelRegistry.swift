import Foundation

/// Built-in transcription model registry.
///
/// The model list lives directly in source rather than as a JSON resource so
/// the binary stays self-contained — no `Bundle.module` lookup, no per-target
/// resource bundle to ship alongside the executable.
enum ModelRegistry {
    static let shared: [TranscriptionModel] = [
        TranscriptionModel(
            id: "whisper-base.en",
            displayName: "Whisper Base (English)",
            engine: .whisperKit,
            engineID: "openai_whisper-base.en",
            sizeMB: 145,
            languages: ["en"],
            recommended: false
        ),
        TranscriptionModel(
            id: "whisper-large-v3-turbo",
            displayName: "Whisper Large v3 Turbo",
            engine: .whisperKit,
            engineID: "openai_whisper-large-v3-v20240930_turbo",
            sizeMB: 1620,
            languages: ["multi"],
            recommended: false
        ),
        TranscriptionModel(
            id: "whisper-large-v3-turbo-compressed",
            displayName: "Whisper Large v3 Turbo (compressed)",
            engine: .whisperKit,
            engineID: "openai_whisper-large-v3-v20240930_turbo_632MB",
            sizeMB: 632,
            languages: ["multi"],
            recommended: false
        ),
        TranscriptionModel(
            id: "whisper-small.en",
            displayName: "Whisper Small (English)",
            engine: .whisperKit,
            engineID: "openai_whisper-small.en",
            sizeMB: 488,
            languages: ["en"],
            recommended: false
        ),
        TranscriptionModel(
            id: "parakeet-tdt-v3",
            displayName: "Parakeet TDT v3",
            engine: .parakeet,
            engineID: "parakeet-tdt-0.6b-v3",
            sizeMB: 461,
            languages: ["multi"],
            // Measured over 32 recordings against every other model here: best
            // accuracy on the speaker's own language, faster than the rest by an
            // order of magnitude, and ahead of whisper-base.en on English too
            // while covering 24 more languages.
            recommended: true
        ),
    ]

    static func find(_ id: String) -> TranscriptionModel? {
        shared.first { $0.id == id }
    }

    static func recommended() -> TranscriptionModel? {
        shared.first { $0.recommended } ?? shared.first
    }
}
