import ArgumentParser
import Foundation

/// Manage parrot's LaunchAgent so the daemon starts at login.
///
/// We deliberately do NOT use SMAppService.mainApp here. A plain LaunchAgent
/// keeps the CLI workflow simple, but it must always launch the stable signed
/// app-bundled executable so macOS retains its TCC identity.
struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Install or remove the launch-at-login LaunchAgent."
    )

    @Flag(name: .long, help: "Register parrot to start at login.")
    var launchAtLogin: Bool = false

    @Flag(name: .long, help: "Remove the launch-at-login agent.")
    var uninstall: Bool = false

    func run() throws {
        if launchAtLogin == uninstall {
            FileHandle.standardError.write(Data(
                "specify exactly one of --launch-at-login or --uninstall\n".utf8
            ))
            throw ExitCode(64)
        }

        if uninstall {
            try removeAgent()
        } else {
            try writeAgent()
        }
    }

    // MARK: -

    private static let label = "com.digimata.parrot"
    private static let appPath = "/Applications/Parrot.app"

    private var logDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Parrot", isDirectory: true)
    }

    private var outputLogPath: String {
        logDirectoryURL.appendingPathComponent("parrot.out.log").path
    }

    private var errorLogPath: String {
        logDirectoryURL.appendingPathComponent("parrot.err.log").path
    }

    private var plistURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(Self.label).plist")
    }

    private func writeAgent() throws {
        let application = try resolveApplicationPath()
        try verifyApplicationIdentity(application)
        try preparePrivateLogs()
        let binary = "\(application)/Contents/MacOS/parrot"
        let logOffset = fileSize(at: errorLogPath)
        let previousPlist = try? Data(contentsOf: plistURL)
        let previousWasLoaded = runLaunchctl([
            "print", "gui/\(uid())/\(Self.label)",
        ]).status == 0

        let plist: [String: Any] = [
            "Label": Self.label,
            "RunAtLoad": true,
            "ProcessType": "Interactive",
            "StandardOutPath": outputLogPath,
            "StandardErrorPath": errorLogPath,
            "ProgramArguments": [binary, "run", "--skip-doctor"],
            "KeepAlive": ["SuccessfulExit": false] as [String: Any],
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

        // Replace any loaded copy, then verify launchd accepted the new job.
        _ = runLaunchctl(["bootout", "gui/\(uid())", url.path])
        let result = runLaunchctl(["bootstrap", "gui/\(uid())", url.path])
        if result.status != 0 {
            let rollbackFailure = rollbackAgent(
                previousPlist: previousPlist,
                wasLoaded: previousWasLoaded
            )
            FileHandle.standardError.write(Data(
                installFailureMessage(
                    "launchctl bootstrap failed (\(result.status)):\n\(result.stderr)",
                    rollbackFailure: rollbackFailure
                ).utf8
            ))
            throw ExitCode(1)
        }
        let verification = runLaunchctl(["print", "gui/\(uid())/\(Self.label)"])
        if verification.status != 0 {
            let rollbackFailure = rollbackAgent(
                previousPlist: previousPlist,
                wasLoaded: previousWasLoaded
            )
            FileHandle.standardError.write(Data(
                installFailureMessage(
                    "launch-at-login verification failed (\(verification.status)):\n\(verification.stderr)",
                    rollbackFailure: rollbackFailure
                ).utf8
            ))
            throw ExitCode(1)
        }
        if let failure = waitForAgentReadiness(startingAt: logOffset, timeout: 60) {
            let rollbackFailure = rollbackAgent(
                previousPlist: previousPlist,
                wasLoaded: previousWasLoaded
            )
            FileHandle.standardError.write(Data(
                installFailureMessage(
                    "launch-at-login did not become ready: \(failure)",
                    rollbackFailure: rollbackFailure
                ).utf8
            ))
            throw ExitCode(1)
        }

        print("✓ launch-at-login installed")
        print("  plist:  \(url.path)")
        print("  binary: \(binary)")
        print("  app:     \(application)")
        print("  logs:    \(outputLogPath), \(errorLogPath)")
    }

    private func removeAgent() throws {
        let url = plistURL
        let serviceTarget = "gui/\(uid())/\(Self.label)"
        let wasRegistered = runLaunchctl(["print", serviceTarget]).status == 0

        // launchd is authoritative. A job can remain registered even when its
        // source plist has been moved or deleted, so always query the label.
        if wasRegistered {
            let result = runLaunchctl(["bootout", serviceTarget])
            if result.status != 0 {
                FileHandle.standardError.write(Data(
                    "could not stop the running Parrot service: \(result.stderr)\n".utf8
                ))
                throw ExitCode(1)
            }
            if runLaunchctl(["print", serviceTarget]).status == 0 {
                FileHandle.standardError.write(Data(
                    "Parrot service is still registered; the plist was preserved.\n".utf8
                ))
                throw ExitCode(1)
            }
        }

        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
            print("✓ launch-at-login removed")
        } else if wasRegistered {
            print("✓ registered Parrot service stopped (no plist was present)")
        } else {
            print("nothing to remove (no registered service or plist)")
        }
    }

    private func rollbackAgent(previousPlist: Data?, wasLoaded: Bool) -> String? {
        let url = plistURL
        var failures = [String]()
        let serviceTarget = "gui/\(uid())/\(Self.label)"
        var failedJobRemoved = true
        if runLaunchctl(["print", serviceTarget]).status == 0 {
            let bootout = runLaunchctl(["bootout", serviceTarget])
            if bootout.status != 0 {
                failures.append("could not stop the failed new job: \(bootout.stderr)")
            }
            if runLaunchctl(["print", serviceTarget]).status == 0 {
                failures.append("the failed new job is still registered with launchd")
                failedJobRemoved = false
            }
        }

        if let previousPlist {
            do {
                try previousPlist.write(to: url, options: .atomic)
            } catch {
                failures.append("could not restore the previous plist: \(error)")
            }
            if wasLoaded {
                if failedJobRemoved {
                    let bootstrap = runLaunchctl(["bootstrap", "gui/\(uid())", url.path])
                    if bootstrap.status != 0 {
                        failures.append("could not reload the previous job: \(bootstrap.stderr)")
                    } else {
                        let verification = runLaunchctl(["print", serviceTarget])
                        if verification.status != 0 {
                            failures.append("the restored job is not registered with launchd")
                        }
                    }
                } else {
                    failures.append("could not reload the previous job while the failed job remains active")
                }
            } else if runLaunchctl(["print", serviceTarget]).status == 0 {
                failures.append("the previous unloaded state was not restored")
            }
        } else {
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            } catch {
                failures.append("could not remove the failed new plist: \(error)")
            }
            let verification = runLaunchctl(["print", serviceTarget])
            if verification.status == 0 {
                failures.append("the failed new job is still registered with launchd")
            }
            if wasLoaded {
                failures.append(
                    "the previous job was registered without a readable plist and could not be restored"
                )
            }
        }

        return failures.isEmpty ? nil : failures.joined(separator: "; ")
    }

    private func installFailureMessage(
        _ failure: String,
        rollbackFailure: String?
    ) -> String {
        if let rollbackFailure {
            return "\(failure)\nrollback also failed: \(rollbackFailure)\n"
        }
        return "\(failure)\nprevious launch-at-login state restored\n"
    }

    private func resolveApplicationPath() throws -> String {
        let executable = "\(Self.appPath)/Contents/MacOS/parrot"
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            FileHandle.standardError.write(Data(
                "Parrot.app is required for reliable login permissions. Re-run the installer first.\n".utf8
            ))
            throw ExitCode(1)
        }
        return Self.appPath
    }

    private func uid() -> uid_t { getuid() }

    private func verifyApplicationIdentity(_ application: String) throws {
        let verification = runProcess(
            executable: "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", application]
        )
        guard verification.status == 0 else {
            FileHandle.standardError.write(Data(
                "Parrot.app signature verification failed:\n\(verification.stderr)\n".utf8
            ))
            throw ExitCode(1)
        }

        let requirement = runProcess(
            executable: "/usr/bin/codesign",
            arguments: ["-d", "--requirements", "-", application]
        )
        let requirementText = requirement.stdout + requirement.stderr
        guard requirement.status == 0,
              requirementText.contains("identifier \"\(Self.label)\"")
        else {
            FileHandle.standardError.write(Data(
                "Parrot.app does not have the required \(Self.label) identity.\n".utf8
            ))
            throw ExitCode(1)
        }
    }

    /// launchd follows StandardOutPath/StandardErrorPath. Keep both files in a
    /// user-owned, non-symlinked 0700 directory so another local account cannot
    /// pre-create a shared /tmp symlink that Parrot would open with this user's
    /// permissions.
    private func preparePrivateLogs() throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: logDirectoryURL.path) {
            let values = try logDirectoryURL.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw NSError(
                    domain: "ParrotInstall",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Parrot log path must be a real directory: \(logDirectoryURL.path)"]
                )
            }
        } else {
            try manager.createDirectory(
                at: logDirectoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try manager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: logDirectoryURL.path
        )

        for path in [outputLogPath, errorLogPath] {
            if manager.fileExists(atPath: path) {
                let values = try URL(fileURLWithPath: path).resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                )
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw NSError(
                        domain: "ParrotInstall",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Parrot log must be a regular file: \(path)"]
                    )
                }
            } else {
                guard manager.createFile(
                    atPath: path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                ) else {
                    throw NSError(
                        domain: "ParrotInstall",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Could not create private Parrot log: \(path)"]
                    )
                }
            }
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
    }

    private func waitForAgentReadiness(
        startingAt logOffset: UInt64,
        timeout: TimeInterval
    ) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        var sawReadyLine = false
        var latestLog = ""

        while Date() < deadline {
            let job = runLaunchctl(["print", "gui/\(uid())/\(Self.label)"])
            latestLog = appendedLog(at: errorLogPath, startingAt: logOffset)
            sawReadyLine = sawReadyLine || latestLog.contains("listening for control + fn/globe toggle")

            if sawReadyLine && job.status == 0 && job.stdout.contains("state = running") {
                return nil
            }
            if latestLog.contains("warmup failed:")
                || latestLog.contains("failed to register hotkey tap:")
            {
                return latestLog.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            Thread.sleep(forTimeInterval: 0.25)
        }

        let suffix = latestLog.suffix(1_000)
        return suffix.isEmpty
            ? "timed out after \(Int(timeout)) seconds without a fresh ready line"
            : "timed out after \(Int(timeout)) seconds; latest log: \(suffix)"
    }

    private func fileSize(at path: String) -> UInt64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private func appendedLog(at path: String, startingAt offset: UInt64) -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? handle.close() }
        do {
            let end = try handle.seekToEnd()
            try handle.seek(toOffset: end >= offset ? offset : 0)
            let data = try handle.readToEnd() ?? Data()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    private func runLaunchctl(_ args: [String]) -> (status: Int32, stdout: String, stderr: String) {
        runProcess(executable: "/bin/launchctl", arguments: args)
    }

    private func runProcess(
        executable: String,
        arguments: [String]
    ) -> (status: Int32, stdout: String, stderr: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        let errPipe = Pipe()
        let outPipe = Pipe()
        task.standardError = errPipe
        task.standardOutput = outPipe
        do {
            try task.run()
        } catch {
            return (-1, "", "\(error)")
        }
        task.waitUntilExit()
        let out = String(
            data: outPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let err = String(
            data: errPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return (task.terminationStatus, out, err)
    }
}
