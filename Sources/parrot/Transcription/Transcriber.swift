import Foundation

protocol Transcriber: Sendable {
    var modelID: String { get }
    func prepare() async throws
    func transcribe(_ audio: [Float]) async throws -> String
}
