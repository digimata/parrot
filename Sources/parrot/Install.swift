import ArgumentParser
import Foundation

/// Manage parrot's LaunchAgent so the daemon starts at login.
///
/// We deliberately do NOT use SMAppService.mainApp here — that requires a full
/// .app bundle. Since parrot ships as a single binary in /usr/local/bin, a
/// plain LaunchAgent plist is the simpler, more honest mechanism.
struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Install or remove the launch-at-login LaunchAgent."
    )

    @Flag(name: .long, help: "Register parrot to start at login.")
    var launchAtLogin: Bool = false

    @Flag(name: .long, help: "Remove the launch-at-login agent.")
    var uninstall: Bool = false

    @Flag(
        name: .long,
        help: "Update the launch-at-login agent's model. Pass a model id or choose interactively."
    )
    var selectModel: Bool = false

    @Argument(help: "Model id to use with --select-model.")
    var selectedModelID: String?

    func run() throws {
        if selectedModelID != nil && !selectModel {
            FileHandle.standardError.write(Data(
                "model id can only be specified with --select-model\n".utf8
            ))
            throw ExitCode(64)
        }

        let actionCount = [launchAtLogin, uninstall, selectModel].filter { $0 }.count
        if actionCount != 1 {
            FileHandle.standardError.write(Data(
                "specify exactly one of --launch-at-login, --uninstall, or --select-model\n".utf8
            ))
            throw ExitCode(64)
        }

        if uninstall {
            try removeAgent()
        } else if selectModel {
            let model = try resolveSelectedModel()
            try writeAgent(selectedModelID: model.id, actionName: "updated")
        } else {
            try writeAgent(selectedModelID: nil, actionName: "installed")
        }
    }

    // MARK: -

    private static let label = "com.digimata.parrot"

    private var plistURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(Self.label).plist")
    }

    private func writeAgent(selectedModelID: String?, actionName: String) throws {
        let binary = try resolveBinaryPath()
        var programArguments = [binary, "run", "--skip-doctor"]
        if let selectedModelID {
            programArguments.append(contentsOf: ["--model", selectedModelID])
        }

        let plist: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": programArguments,
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false] as [String: Any],
            "ProcessType": "Interactive",
            "StandardOutPath": "/tmp/parrot.out.log",
            "StandardErrorPath": "/tmp/parrot.err.log",
        ]

        let url = plistURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: url, options: .atomic)

        // Best-effort restart of the managed LaunchAgent. This only targets
        // parrot's launchd label, not manually started foreground processes.
        _ = runLaunchctl(["bootout", "gui/\(uid())", url.path])
        let result = runLaunchctl(["bootstrap", "gui/\(uid())", url.path])
        if result.status != 0 {
            FileHandle.standardError.write(Data(
                "warning: launchctl bootstrap exited \(result.status):\n\(result.stderr)\n".utf8
            ))
        }
        let kickstart = runLaunchctl(["kickstart", "-k", "gui/\(uid())/\(Self.label)"])
        if kickstart.status != 0 {
            FileHandle.standardError.write(Data(
                "warning: launchctl kickstart exited \(kickstart.status):\n\(kickstart.stderr)\n".utf8
            ))
        }

        print("✓ launch-at-login \(actionName)")
        print("  plist:  \(url.path)")
        print("  binary: \(binary)")
        if let selectedModelID {
            print("  model:  \(selectedModelID)")
        }
        print("  logs:   /tmp/parrot.out.log, /tmp/parrot.err.log")
    }

    private func resolveSelectedModel() throws -> TranscriptionModel {
        let id: String
        if let selectedModelID {
            id = selectedModelID
        } else {
            id = try promptForModelID()
        }

        guard let model = ModelRegistry.find(id) else {
            FileHandle.standardError.write(Data("unknown model: \(id)\n".utf8))
            FileHandle.standardError.write(Data("run `parrot models list` to see options.\n".utf8))
            throw ExitCode(1)
        }
        return model
    }

    private func promptForModelID() throws -> String {
        print("Select a model for the launch-at-login agent:")
        for (index, model) in ModelRegistry.shared.enumerated() {
            let marker = model.recommended ? " (recommended)" : ""
            print("  \(index + 1). \(model.id) - \(model.displayName)\(marker)")
        }
        print("Enter a number: ", terminator: "")
        fflush(stdout)

        guard let line = readLine(), !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            FileHandle.standardError.write(Data("no model selected\n".utf8))
            throw ExitCode(64)
        }

        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let choice = Int(trimmed),
            ModelRegistry.shared.indices.contains(choice - 1)
        else {
            FileHandle.standardError.write(Data("invalid model selection: \(trimmed)\n".utf8))
            throw ExitCode(64)
        }

        return ModelRegistry.shared[choice - 1].id
    }

    private func removeAgent() throws {
        let url = plistURL
        if FileManager.default.fileExists(atPath: url.path) {
            _ = runLaunchctl(["bootout", "gui/\(uid())", url.path])
            try FileManager.default.removeItem(at: url)
            print("✓ launch-at-login removed")
        } else {
            print("nothing to remove (no agent at \(url.path))")
        }
    }

    private func resolveBinaryPath() throws -> String {
        // /usr/local/bin/parrot is the canonical install path. Honor a real
        // location if running from elsewhere (e.g. dev).
        let candidate = "/usr/local/bin/parrot"
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        // Fall back to the running executable's resolved path.
        let argv0 = CommandLine.arguments.first ?? "parrot"
        if argv0.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: argv0) {
            FileHandle.standardError.write(Data(
                "note: /usr/local/bin/parrot not found; using \(argv0)\n".utf8
            ))
            return argv0
        }
        FileHandle.standardError.write(Data(
            "couldn't locate the parrot binary. install it to /usr/local/bin/parrot first.\n".utf8
        ))
        throw ExitCode(1)
    }

    private func uid() -> uid_t { getuid() }

    private func runLaunchctl(_ args: [String]) -> (status: Int32, stderr: String) {
        let task = Process()
        task.launchPath = "/bin/launchctl"
        task.arguments = args
        let errPipe = Pipe()
        task.standardError = errPipe
        task.standardOutput = Pipe()
        do {
            try task.run()
        } catch {
            return (-1, "\(error)")
        }
        task.waitUntilExit()
        let err = String(
            data: errPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return (task.terminationStatus, err)
    }
}
