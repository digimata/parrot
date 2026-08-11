import AVFoundation
import Darwin
import Foundation

/// Captures microphone audio while recording is active and returns a 16 kHz
/// mono Float32 buffer when stopped. Format-converts on the fly so callers
/// don't have to worry about the input device's native rate.
final class AudioCapture {
    enum CaptureError: Error {
        case engineStartFailed(Error)
        case converterCreationFailed
        case inputUnavailable(sampleRate: Double, channels: AVAudioChannelCount)
    }

    struct CaptureResult {
        let samples: [Float]
        let configurationChanged: Bool
        let conversionError: Error?
        let callbackCount: Int
        let inputFrameCount: Int
        let wallDuration: TimeInterval
    }

    static let targetSampleRate: Double = 16_000

    // Audio routes can change while this login daemon remains alive for days.
    // A fresh engine per recording avoids retaining an input node that belongs
    // to a stale Core Audio aggregate device after sleep, docking, or plugging
    // in headphones/a microphone.
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var configurationObserver: NSObjectProtocol?
    private var samples: [Float] = []
    private var configurationChanged = false
    private var conversionError: Error?
    private var callbackCount = 0
    private var inputFrameCount = 0
    private var startedAt: TimeInterval?
    private var isRecording = false
    private let lock = NSLock()

    /// Called for every audio buffer with the buffer's RMS level (0…~1).
    /// Invoked on an arbitrary thread; hop to main if you touch UI.
    var onLevel: ((Float) -> Void)?

    /// Begin recording. Idempotent — calling while already recording is a no-op.
    func start() throws {
        guard !isRecording else { return }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError.inputUnavailable(
                sampleRate: inputFormat.sampleRate,
                channels: inputFormat.channelCount
            )
        }

        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioCapture.targetSampleRate,
            channels: 1,
            interleaved: false
        )!

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw CaptureError.converterCreationFailed
        }
        self.converter = converter

        lock.lock()
        samples.removeAll(keepingCapacity: true)
        configurationChanged = false
        conversionError = nil
        callbackCount = 0
        inputFrameCount = 0
        lock.unlock()

        let configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            // Apple warns against tearing the engine down inside this callback.
            // Record the invalidation and let stop() perform synchronous cleanup.
            self?.markConfigurationChanged()
        }
        self.engine = engine
        self.configurationObserver = configurationObserver

        // Tap with input format; convert inside the callback.
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer: buffer, converter: converter, targetFormat: targetFormat)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
            self.engine = nil
            self.converter = nil
            throw CaptureError.engineStartFailed(error)
        }

        isRecording = true
        startedAt = ProcessInfo.processInfo.systemUptime
    }

    /// Stop recording and return all captured samples (16 kHz mono Float32).
    @discardableResult
    func stop() -> CaptureResult {
        guard isRecording, let engine else {
            return CaptureResult(
                samples: [],
                configurationChanged: false,
                conversionError: nil,
                callbackCount: 0,
                inputFrameCount: 0,
                wallDuration: 0
            )
        }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        engine.reset()
        isRecording = false
        let wallDuration = startedAt.map {
            max(0, ProcessInfo.processInfo.systemUptime - $0)
        } ?? 0
        startedAt = nil

        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        self.configurationObserver = nil
        self.engine = nil
        self.converter = nil

        lock.lock()
        let captured = samples
        let didChangeConfiguration = configurationChanged
        let capturedConversionError = conversionError
        let capturedCallbackCount = callbackCount
        let capturedInputFrameCount = inputFrameCount
        samples.removeAll(keepingCapacity: true)
        configurationChanged = false
        conversionError = nil
        callbackCount = 0
        inputFrameCount = 0
        lock.unlock()
        return CaptureResult(
            samples: captured,
            configurationChanged: didChangeConfiguration,
            conversionError: capturedConversionError,
            callbackCount: capturedCallbackCount,
            inputFrameCount: capturedInputFrameCount,
            wallDuration: wallDuration
        )
    }

    private func process(
        buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) {
        // Output buffer capacity scales with sample-rate ratio.
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64

        guard let outBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outCapacity
        ) else { return }

        var consumed = false
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }

        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error, withInputFrom: inputBlock)
        guard status != .error, let channelData = outBuffer.floatChannelData else {
            if let error {
                lock.lock()
                conversionError = error
                lock.unlock()
            }
            return
        }

        let count = Int(outBuffer.frameLength)
        let ptr = channelData[0]
        let chunk = Array(UnsafeBufferPointer(start: ptr, count: count))

        lock.lock()
        callbackCount += 1
        inputFrameCount += Int(buffer.frameLength)
        samples.append(contentsOf: chunk)
        lock.unlock()

        if let onLevel {
            onLevel(computeRMS(chunk))
        }
    }

    private func markConfigurationChanged() {
        lock.lock()
        configurationChanged = true
        lock.unlock()
    }
}

// MARK: - WAV writer (for debugging M3 captures)

enum WAVWriter {
    /// Write Float32 mono samples as 16-bit PCM WAV to `path`.
    static func write(samples: [Float], sampleRate: Int, to path: String) throws {
        let bytesPerSample = 2
        let dataSize = samples.count * bytesPerSample

        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(uint32LE(36 + UInt32(dataSize)))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(uint32LE(16))                       // fmt chunk size
        data.append(uint16LE(1))                        // PCM
        data.append(uint16LE(1))                        // mono
        data.append(uint32LE(UInt32(sampleRate)))
        data.append(uint32LE(UInt32(sampleRate * bytesPerSample)))
        data.append(uint16LE(UInt16(bytesPerSample)))   // block align
        data.append(uint16LE(16))                       // bits per sample
        data.append(contentsOf: Array("data".utf8))
        data.append(uint32LE(UInt32(dataSize)))

        for s in samples {
            let clamped = max(-1.0, min(1.0, s))
            let i = Int16(clamped * 32767.0)
            data.append(uint16LE(UInt16(bitPattern: i)))
        }

        // Audio can contain private dictation. Create the file atomically with
        // mode 0600 and refuse existing paths/symlinks instead of writing first
        // and tightening permissions afterwards.
        let descriptor = Darwin.open(
            path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        var completed = false
        defer {
            Darwin.close(descriptor)
            if !completed {
                try? FileManager.default.removeItem(atPath: path)
            }
        }

        var writeError: Int32?
        let bytesWritten = data.withUnsafeBytes { rawBuffer -> Int in
            guard let baseAddress = rawBuffer.baseAddress else { return 0 }
            var total = 0
            while total < rawBuffer.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: total),
                    rawBuffer.count - total
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    writeError = errno
                    return total
                }
                total += count
            }
            return total
        }
        guard bytesWritten == data.count, writeError == nil else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(writeError ?? EIO)
            )
        }
        completed = true
    }

    private static func uint32LE(_ v: UInt32) -> Data {
        var x = v.littleEndian
        return Data(bytes: &x, count: 4)
    }
    private static func uint16LE(_ v: UInt16) -> Data {
        var x = v.littleEndian
        return Data(bytes: &x, count: 2)
    }
}

func computeRMS(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    var sum: Double = 0
    for s in samples { sum += Double(s * s) }
    return Float((sum / Double(samples.count)).squareRoot())
}
