import Foundation

protocol Transcriber: Sendable {
    var modelID: String { get }
    func warmUp() async throws
    func transcribe(_ audio: [Float]) async throws -> String
}

enum TranscriberRuntimeError: Error, CustomStringConvertible {
    case timedOut(seconds: TimeInterval)
    case insufficientDiskSpace(availableMB: Int64, requiredMB: Int64)

    var description: String {
        switch self {
        case .timedOut(let seconds):
            return "operation timed out after \(Int(seconds)) seconds"
        case .insufficientDiskSpace(let availableMB, let requiredMB):
            return "insufficient disk space (\(availableMB) MB available; \(requiredMB) MB required)"
        }
    }
}

private final class AsyncTimeoutResolver<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resolve(_ result: Result<Value, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

/// Bounds a live inference without holding the serial delivery queue forever.
/// Cancellation is forwarded to the model task; a misbehaving model may finish
/// later, but its late result is discarded by the one-shot resolver.
func withAsyncTimeout<Value: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    let operationTask = Task { try await operation() }
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            let resolver = AsyncTimeoutResolver(continuation)
            Task {
                do {
                    resolver.resolve(.success(try await operationTask.value))
                } catch {
                    resolver.resolve(.failure(error))
                }
            }
            Task {
                do {
                    try await Task.sleep(for: .seconds(seconds))
                } catch {
                    return
                }
                operationTask.cancel()
                resolver.resolve(.failure(TranscriberRuntimeError.timedOut(seconds: seconds)))
            }
        }
    } onCancel: {
        operationTask.cancel()
    }
}

/// Serializes asynchronous transcript delivery in the exact order recordings
/// stop. The queue is safe to append from the hotkey and safety-limit paths.
final class SerialAsyncTaskQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        lock.lock()
        let previous = tail
        let task = Task {
            if let previous { await previous.value }
            await operation()
        }
        tail = task
        lock.unlock()
    }

    func waitUntilIdle() async {
        let current = currentTask()
        await current?.value
    }

    private func currentTask() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return tail
    }
}

/// Thread-safe bridge for the CLI's blocking subcommands. The daemon must not
/// advertise itself as running forever while model initialization is hung.
private final class AsyncResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?

    func store(_ result: Result<Void, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func load() -> Result<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

func waitForAsyncOperation(
    timeout: TimeInterval,
    operation: @escaping @Sendable () async throws -> Void
) throws {
    let semaphore = DispatchSemaphore(value: 0)
    let resultBox = AsyncResultBox()

    Task.detached {
        do {
            try await operation()
            resultBox.store(.success(()))
        } catch {
            resultBox.store(.failure(error))
        }
        semaphore.signal()
    }

    guard semaphore.wait(timeout: .now() + timeout) == .success else {
        throw TranscriberRuntimeError.timedOut(seconds: timeout)
    }
    guard let result = resultBox.load() else {
        throw TranscriberRuntimeError.timedOut(seconds: timeout)
    }
    try result.get()
}

func ensureModelDiskSpace(for model: TranscriptionModel) throws {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let values = try home.resourceValues(forKeys: [
        .volumeAvailableCapacityForImportantUsageKey,
        .volumeAvailableCapacityKey,
    ])
    let availableBytes = values.volumeAvailableCapacityForImportantUsage
        ?? Int64(values.volumeAvailableCapacity ?? 0)
    let availableMB = availableBytes / 1_048_576
    // Model conversion and temporary files can exceed the advertised download
    // size. Keep at least 1 GiB or twice the model size, whichever is larger.
    let requiredMB = Int64(max(1_024, model.sizeMB * 2))
    guard availableMB >= requiredMB else {
        throw TranscriberRuntimeError.insufficientDiskSpace(
            availableMB: availableMB,
            requiredMB: requiredMB
        )
    }
}

func warmUpSynchronously(
    _ transcriber: any Transcriber,
    timeout: TimeInterval = 600
) throws {
    try waitForAsyncOperation(timeout: timeout) {
        try await transcriber.warmUp()
    }
}

func makeTranscriber(for model: TranscriptionModel) -> any Transcriber {
    switch model.engine {
    case .whisperKit:
        return WhisperKitTranscriber(model: model)
    case .parakeet:
        return ParakeetTranscriber(model: model)
    }
}
