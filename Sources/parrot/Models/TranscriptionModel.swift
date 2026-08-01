import Foundation

enum Engine: String, Codable {
    case whisperKit
    case parakeet
}

struct TranscriptionModel: Codable {
    let id: String
    let displayName: String
    let engine: Engine
    /// The id the engine itself knows the model by.
    let engineID: String?
    let sizeMB: Int
    let languages: [String]
    let recommended: Bool
}

struct ModelsManifest: Codable {
    let models: [TranscriptionModel]
}
