import Foundation

protocol Transcriber: Sendable {
    var modelID: String { get }
    func warmUp() async throws
    func transcribe(_ audio: [Float]) async throws -> String
}

enum SystemModel: String, CaseIterable {
    case appleSpeech = "apple-speech"
}
