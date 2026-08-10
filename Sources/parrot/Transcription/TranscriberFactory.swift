import Foundation

enum TranscriberFactory {
    static func make(
        model: TranscriptionModel,
        parakeetURL: String = ParakeetConfiguration.defaultURL,
        parakeetAPIKey: String? = nil
    ) throws -> any Transcriber {
        switch model.engine {
        case .whisperKit:
            return WhisperKitTranscriber(model: model)
        case .parakeet:
            let configuration = try ParakeetConfiguration(
                urlString: parakeetURL,
                apiKey: parakeetAPIKey
            )
            let adapter = ParakeetHTTPAdapter(configuration: configuration)
            return ParakeetTranscriber(modelID: model.id, adapter: adapter)
        }
    }
}
