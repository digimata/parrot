@preconcurrency import AVFoundation
import Foundation
import Speech

@available(macOS 26.0, *)
actor AppleSpeechTranscriber: Transcriber {
    let modelID = SystemModel.appleSpeech.rawValue
    private let requestedLocale: Locale
    private var locale: Locale?

    init(locale: Locale = .current) {
        self.requestedLocale = locale
    }

    func warmUp() async throws {
        if locale != nil { return }
        guard SpeechTranscriber.isAvailable else {
            throw AppleSpeechError.unavailable
        }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw AppleSpeechError.unsupportedLocale(requestedLocale.identifier)
        }

        let transcriber = SpeechTranscriber(locale: supported, preset: .transcription)
        let modules: [any SpeechModule] = [transcriber]
        let status = await AssetInventory.status(forModules: modules)
        guard status == .installed else {
            throw AppleSpeechError.assetsNotInstalled(supported.identifier)
        }
        _ = try await AssetInventory.reserve(locale: supported)
        self.locale = supported
        FileHandle.standardError.write(Data("✓ \(modelID) ready (\(supported.identifier))\n".utf8))
    }

    func transcribe(_ audio: [Float]) async throws -> String {
        if locale == nil { try await warmUp() }
        guard let locale else { throw TranscriberError.notLoaded }
        guard !audio.isEmpty else { return "" }

        let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioCapture.targetSampleRate,
            channels: 1,
            interleaved: false
        )!
        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(audio.count)
        ), let channel = sourceBuffer.floatChannelData?[0] else {
            throw AppleSpeechError.audioBufferCreationFailed
        }
        sourceBuffer.frameLength = AVAudioFrameCount(audio.count)
        audio.withUnsafeBufferPointer { samples in
            channel.update(from: samples.baseAddress!, count: audio.count)
        }

        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let modules: [any SpeechModule] = [transcriber]
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: modules,
            considering: sourceFormat
        ) else {
            throw AppleSpeechError.noCompatibleAudioFormat
        }
        let analyzerBuffer = try Self.convert(
            sourceBuffer,
            from: sourceFormat,
            to: analyzerFormat
        )
        let options = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
        let analyzer = SpeechAnalyzer(modules: modules, options: options)
        try await analyzer.prepareToAnalyze(in: analyzerFormat)

        let input = AsyncStream<AnalyzerInput> { continuation in
            continuation.yield(AnalyzerInput(buffer: analyzerBuffer))
            continuation.finish()
        }
        async let resultText = Self.collectResults(from: transcriber)
        if let lastSampleTime = try await analyzer.analyzeSequence(input) {
            try await analyzer.finalizeAndFinish(through: lastSampleTime)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await resultText
    }

    private static func convert(
        _ source: AVAudioPCMBuffer,
        from sourceFormat: AVAudioFormat,
        to destinationFormat: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        if sourceFormat == destinationFormat {
            return source
        }
        guard let converter = AVAudioConverter(from: sourceFormat, to: destinationFormat) else {
            throw AppleSpeechError.audioConversionFailed
        }
        let ratio = destinationFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(source.frameLength) * ratio)) + 64
        guard let output = AVAudioPCMBuffer(
            pcmFormat: destinationFormat,
            frameCapacity: capacity
        ) else {
            throw AppleSpeechError.audioBufferCreationFailed
        }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .endOfStream
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return source
        }
        guard status != .error else {
            throw conversionError ?? AppleSpeechError.audioConversionFailed
        }
        return output
    }

    private static func collectResults(from transcriber: SpeechTranscriber) async throws -> String {
        var parts: [String] = []
        for try await result in transcriber.results {
            let text = String(result.text.characters)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                parts.append(text)
            }
        }
        return parts.joined(separator: " ")
    }
}

enum AppleSpeechError: LocalizedError {
    case unavailable
    case unsupportedLocale(String)
    case assetsNotInstalled(String)
    case audioBufferCreationFailed
    case noCompatibleAudioFormat
    case audioConversionFailed

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Apple SpeechAnalyzer is unavailable on this Mac"
        case .unsupportedLocale(let locale):
            return "Apple SpeechAnalyzer does not support \(locale)"
        case .assetsNotInstalled(let locale):
            return "Apple Speech assets for \(locale) are not installed; enable on-device Dictation in System Settings first"
        case .audioBufferCreationFailed:
            return "Could not create an Apple Speech audio buffer"
        case .noCompatibleAudioFormat:
            return "Apple Speech has no compatible audio format for the installed model"
        case .audioConversionFailed:
            return "Could not convert audio into Apple Speech's required format"
        }
    }
}
