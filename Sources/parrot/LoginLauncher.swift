import AppKit
import ArgumentParser
import Darwin
import Foundation

enum ParrotLoginService {
    static let bundleIdentifier = "com.digimata.parrot"
    static let applicationPath = "/Applications/Parrot.app"

    private static var markerDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Parrot/LoginService", isDirectory: true)
    }

    static func validatedToken(_ rawValue: String) -> UUID? {
        UUID(uuidString: rawValue)
    }

    static func prepareMarkerDirectory() throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: markerDirectoryURL.path) {
            let values = try markerDirectoryURL.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw NSError(
                    domain: "ParrotLoginService",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Login-service state path must be a real directory: \(markerDirectoryURL.path)"]
                )
            }
        } else {
            try manager.createDirectory(
                at: markerDirectoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try manager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: markerDirectoryURL.path
        )
    }

    static func clearQuitMarker(for token: UUID) throws {
        let url = markerURL(for: token)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    static func recordIntentionalQuit(token rawValue: String) throws {
        guard let token = validatedToken(rawValue) else {
            throw NSError(
                domain: "ParrotLoginService",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Invalid login-service quit token"]
            )
        }
        try prepareMarkerDirectory()
        let url = markerURL(for: token)
        try Data("intentional quit\n".utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    static func consumeIntentionalQuit(for token: UUID) throws -> Bool {
        let url = markerURL(for: token)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw NSError(
                domain: "ParrotLoginService",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Invalid login-service quit marker"]
            )
        }
        try FileManager.default.removeItem(at: url)
        return true
    }

    private static func markerURL(for token: UUID) -> URL {
        markerDirectoryURL.appendingPathComponent("quit-\(token.uuidString.lowercased())")
    }
}

func loginServiceProgramArguments(binary: String) -> [String] {
    [binary, "login-launcher"]
}

func loginApplicationProgramArguments(
    application: String,
    outputLogPath: String,
    errorLogPath: String,
    quitToken: UUID
) -> [String] {
    [
        "-W",
        "-g",
        "--stdout", outputLogPath,
        "--stderr", errorLogPath,
        application,
        "--args", "run", "--skip-doctor",
        "--login-quit-token", quitToken.uuidString.lowercased(),
    ]
}

func loginLauncherExitCode(intentionalQuitObserved: Bool) -> Int32 {
    intentionalQuitObserved ? EXIT_SUCCESS : EXIT_FAILURE
}

func processIsAlive(_ processIdentifier: pid_t) -> Bool {
    if kill(processIdentifier, 0) == 0 { return true }
    return errno != ESRCH
}

func terminateRunningParrotApplications() -> String? {
    let running = NSRunningApplication.runningApplications(
        withBundleIdentifier: ParrotLoginService.bundleIdentifier
    ).filter {
        $0.processIdentifier != getpid() && processIsAlive($0.processIdentifier)
    }
    guard !running.isEmpty else { return nil }

    for application in running {
        _ = application.terminate()
    }

    let gracefulDeadline = Date().addingTimeInterval(5)
    while Date() < gracefulDeadline {
        if running.allSatisfy({ !processIsAlive($0.processIdentifier) }) { return nil }
        Thread.sleep(forTimeInterval: 0.1)
    }

    for application in running where processIsAlive(application.processIdentifier) {
        _ = application.forceTerminate()
    }
    let forcedDeadline = Date().addingTimeInterval(2)
    while Date() < forcedDeadline {
        if running.allSatisfy({ !processIsAlive($0.processIdentifier) }) { return nil }
        Thread.sleep(forTimeInterval: 0.1)
    }

    let stuckPIDs = running
        .filter { processIsAlive($0.processIdentifier) }
        .map { String($0.processIdentifier) }
        .joined(separator: ", ")
    return "could not stop the previous Parrot app process(es): \(stuckPIDs)"
}

/// launchd supervises this small command directly. It opens the actual app via
/// Launch Services for a correct GUI/Spaces lifecycle, then converts the app's
/// exit into the status launchd needs: zero only for the menu's deliberate Quit
/// action, nonzero for crashes and fatal runtime recovery so KeepAlive restarts.
struct LoginLauncher: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "login-launcher",
        abstract: "Internal launch-at-login supervisor.",
        shouldDisplay: false
    )

    func run() throws {
        let token = UUID()
        try ParrotLoginService.prepareMarkerDirectory()
        try ParrotLoginService.clearQuitMarker(for: token)

        // A previous supervisor can be killed without taking down the app that
        // Launch Services owns. Reconcile that orphan before assigning a fresh
        // quit token so one supervisor always owns one GUI app lifetime.
        if let failure = terminateRunningParrotApplications() {
            FileHandle.standardError.write(Data("login launcher: \(failure)\n".utf8))
            throw ExitCode.failure
        }

        let logs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Parrot", isDirectory: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = loginApplicationProgramArguments(
            application: ParrotLoginService.applicationPath,
            outputLogPath: logs.appendingPathComponent("parrot.out.log").path,
            errorLogPath: logs.appendingPathComponent("parrot.err.log").path,
            quitToken: token
        )

        do {
            try process.run()
        } catch {
            FileHandle.standardError.write(Data("login launcher: could not open Parrot.app: \(error)\n".utf8))
            throw ExitCode.failure
        }
        process.waitUntilExit()

        let intentionalQuit: Bool
        do {
            intentionalQuit = try ParrotLoginService.consumeIntentionalQuit(for: token)
        } catch {
            FileHandle.standardError.write(Data("login launcher: invalid quit state: \(error)\n".utf8))
            throw ExitCode.failure
        }

        let status = loginLauncherExitCode(intentionalQuitObserved: intentionalQuit)
        if status == EXIT_SUCCESS {
            FileHandle.standardError.write(Data("login launcher: intentional Quit observed\n".utf8))
            return
        }

        FileHandle.standardError.write(Data(
            "login launcher: Parrot GUI exited unexpectedly; requesting launchd restart\n".utf8
        ))
        throw ExitCode(status)
    }
}
