import Foundation

/// Where model weights live on disk, and how to get the space back.
///
/// Every engine downloads under one root so switching models can reclaim the
/// previous one without knowing which engine wrote it.
enum ModelWeights {
    /// Not `Documents`: iCloud replicates that folder and evicts large files to
    /// dataless stubs, and CoreML's mmap of an evicted weight file blocks forever.
    static let root = URL.applicationSupportDirectory.appending(path: "parrot")

    /// WhisperKit appends `models/<repo>/<id>` to whatever base it is given.
    static let whisperKitBase = root.appending(path: "huggingface")

    static func directory(of model: TranscriptionModel) -> URL? {
        guard let engineID = model.engineID else { return nil }
        switch model.engine {
        case .whisperKit:
            return whisperKitBase.appending(path: "models/argmaxinc/whisperkit-coreml/\(engineID)")
        case .parakeet:
            return root.appending(path: "parakeet/\(engineID)")
        }
    }

    static func isInstalled(_ model: TranscriptionModel) -> Bool {
        guard let directory = directory(of: model) else { return false }
        return FileManager.default.fileExists(atPath: directory.path(percentEncoded: false))
    }

    /// Deletes the weights of every registered model except the ones named.
    /// Called after a switch succeeds, so a failed download never costs the
    /// user the model they had. The model switched away from is kept too:
    /// otherwise going back and forth between two engines re-downloads a
    /// gigabyte each way.
    @discardableResult
    static func purge(keeping wanted: [TranscriptionModel]) -> Int64 {
        let keepIDs = Set(wanted.map(\.id))
        var reclaimed: Int64 = 0
        for model in ModelRegistry.shared where !keepIDs.contains(model.id) {
            guard let directory = directory(of: model),
                  FileManager.default.fileExists(atPath: directory.path(percentEncoded: false))
            else { continue }
            reclaimed += bytes(at: directory)
            try? FileManager.default.removeItem(at: directory)
        }
        return reclaimed + sweep(keeping: wanted)
    }

    /// WhisperKit keeps tokenizers and download caches beside the weights, under
    /// folders the per-model delete above never names. A folder survives only
    /// when a kept model's engine id contains its name; guessing wrong costs a
    /// few MB of re-download, never a broken model.
    private static func sweep(keeping wanted: [TranscriptionModel]) -> Int64 {
        let roots = ["models/openai", "models/argmaxinc/whisperkit-coreml"]
        let keep = wanted.filter { $0.engine == .whisperKit }.compactMap(\.engineID)
        var reclaimed: Int64 = 0
        for root in roots {
            let directory = whisperKitBase.appending(path: root)
            let children = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? []
            for child in children
            where !keep.contains(where: { $0.contains(child.lastPathComponent) }) {
                reclaimed += bytes(at: child)
                try? FileManager.default.removeItem(at: child)
            }
        }
        return reclaimed
    }

    static func bytes(at directory: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            let size = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            total += Int64(size?.totalFileAllocatedSize ?? size?.fileAllocatedSize ?? 0)
        }
        return total
    }

    static func describe(bytes: Int64) -> String {
        let mb = Double(bytes) / 1_000_000
        return mb >= 1000 ? String(format: "%.1f GB", mb / 1000) : String(format: "%.0f MB", mb)
    }
}
