import Foundation

/// Small, local-only preference store shared by the CLI and LaunchAgent.
enum ParrotSettings {
    private struct Values: Codable {
        var selectedModelID: String?
    }

    private static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/parrot", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    static func selectedModelID() throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try decodeSelectedModelID(from: Data(contentsOf: url))
        } catch {
            throw ParrotSettingsError.unreadable(url: url, underlying: error)
        }
    }

    static func decodeSelectedModelID(from data: Data) throws -> String? {
        try JSONDecoder().decode(Values.self, from: data).selectedModelID
    }

    static func select(modelID: String) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Values(selectedModelID: modelID))
        try data.write(to: url, options: .atomic)
    }
}

enum ParrotSettingsError: LocalizedError {
    case unreadable(url: URL, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .unreadable(let url, let underlying):
            return "could not read Parrot settings at \(url.path): \(underlying.localizedDescription)"
        }
    }
}
