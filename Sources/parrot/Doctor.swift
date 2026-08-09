import AVFoundation
import AppKit
import ApplicationServices
import Foundation

enum CheckStatus {
    case ok
    case warn(String)
    case fail(String)
}

struct Check {
    let name: String
    let status: CheckStatus
    let remediation: String?
}

enum DoctorReport {
    static func run(
        includeLiveAudio: Bool = false,
        modelToVerify: TranscriptionModel? = nil
    ) -> [Check] {
        var checks = [
            checkMicrophone(),
            checkAccessibility(),
            checkHotkeyTap(),
            checkFnKeyMapping(),
        ]
        if includeLiveAudio {
            checks.append(checkLiveAudio())
        }
        if let modelToVerify {
            checks.append(checkModelReadiness(modelToVerify))
        }
        return checks
    }

    static func checkMicrophone() -> Check {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return Check(name: "microphone", status: .ok, remediation: nil)
        case .notDetermined:
            return Check(
                name: "microphone",
                status: .warn("not yet requested — will prompt on first recording"),
                remediation: "run `parrot setup`, then hold Control + Fn/Globe once"
            )
        case .denied, .restricted:
            return Check(
                name: "microphone",
                status: .fail("denied"),
                remediation: "System Settings → Privacy & Security → Microphone → enable for \(permissionHostName())"
            )
        @unknown default:
            return Check(name: "microphone", status: .fail("unknown state"), remediation: nil)
        }
    }

    static func checkAccessibility() -> Check {
        if AXIsProcessTrusted() {
            return Check(name: "accessibility", status: .ok, remediation: nil)
        }
        return Check(
            name: "accessibility",
            status: .fail("not granted"),
            remediation: "System Settings → Privacy & Security → Accessibility → enable for \(permissionHostName())"
        )
    }

    static func checkHotkeyTap() -> Check {
        let monitor = HotkeyMonitor()
        do {
            try monitor.start { _ in }
            monitor.stop()
            return Check(name: "global hotkey event tap", status: .ok, remediation: nil)
        } catch {
            monitor.stop()
            return Check(
                name: "global hotkey event tap",
                status: .fail("could not create or enable the tap"),
                remediation: "run the app-bundled `parrot setup`, then restart Parrot"
            )
        }
    }

    /// macOS routes Fn (🌐) to one of: Do Nothing / Change Input Source / Show Emoji / Start Dictation.
    /// We need "Do Nothing" so Fn is a clean modifier.
    static func checkFnKeyMapping() -> Check {
        let raw = readDefault(domain: "com.apple.HIToolbox", key: "AppleFnUsageType")
        guard let raw, let value = Int(raw) else {
            return Check(
                name: "fn key mapping",
                status: .warn("unset — system default may intercept Fn"),
                remediation: "System Settings → Keyboard → Press 🌐 key to → Do Nothing"
            )
        }
        switch value {
        case 0:
            return Check(name: "fn key mapping", status: .ok, remediation: nil)
        case 1:
            return Check(
                name: "fn key mapping",
                status: .fail("set to Change Input Source"),
                remediation: "System Settings → Keyboard → Press 🌐 key to → Do Nothing"
            )
        case 2:
            return Check(
                name: "fn key mapping",
                status: .fail("set to Show Emoji & Symbols"),
                remediation: "System Settings → Keyboard → Press 🌐 key to → Do Nothing"
            )
        case 3:
            return Check(
                name: "fn key mapping",
                status: .fail("set to Start Dictation"),
                remediation: "System Settings → Keyboard → Press 🌐 key to → Do Nothing"
            )
        default:
            return Check(
                name: "fn key mapping",
                status: .warn("unknown value \(value)"),
                remediation: "System Settings → Keyboard → Press 🌐 key to → Do Nothing"
            )
        }
    }

    /// Permissions alone do not prove that Core Audio is returning frames.
    /// This explicit check records briefly, discards the audio, and verifies the
    /// real input path used by the daemon.
    static func checkLiveAudio(duration: TimeInterval = 0.75) -> Check {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            return Check(
                name: "live microphone capture",
                status: .fail("microphone permission is not granted"),
                remediation: "run `parrot setup`, then retry `parrot doctor --live-audio`"
            )
        }

        let capture = AudioCapture()
        do {
            try capture.start()
        } catch {
            return Check(
                name: "live microphone capture",
                status: .fail("could not start: \(error)"),
                remediation: "select a working input device in System Settings → Sound → Input, then retry"
            )
        }

        Thread.sleep(forTimeInterval: duration)
        let result = capture.stop()
        if result.configurationChanged {
            return Check(
                name: "live microphone capture",
                status: .fail("audio device changed during the check"),
                remediation: "wait for the input device to settle, then retry"
            )
        }
        if let error = result.conversionError {
            return Check(
                name: "live microphone capture",
                status: .fail("audio conversion failed: \(error)"),
                remediation: "select a working input device in System Settings → Sound → Input, then retry"
            )
        }
        guard !result.samples.isEmpty else {
            return Check(
                name: "live microphone capture",
                status: .fail("no audio frames received"),
                remediation: "restart Parrot; if this persists, select a working input device and retry"
            )
        }

        return Check(name: "live microphone capture", status: .ok, remediation: nil)
    }

    static func checkModelReadiness(_ model: TranscriptionModel) -> Check {
        let transcriber = makeTranscriber(for: model)
        do {
            try ensureModelDiskSpace(for: model)
            try warmUpSynchronously(transcriber)
            return Check(name: "model readiness (\(model.id))", status: .ok, remediation: nil)
        } catch {
            return Check(
                name: "model readiness (\(model.id))",
                status: .fail("\(error)"),
                remediation: "free disk space or run `parrot models download \(model.id)`, then retry"
            )
        }
    }

    private static func readDefault(domain: String, key: String) -> String? {
        let task = Process()
        task.launchPath = "/usr/bin/defaults"
        task.arguments = ["read", domain, key]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            return nil
        }
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parentProcessName() -> String? {
        let ppid = getppid()
        let task = Process()
        task.launchPath = "/bin/ps"
        task.arguments = ["-p", String(ppid), "-o", "comm="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            return nil
        }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return nil
        }
        return (s as NSString).lastPathComponent
    }

    private static func permissionHostName() -> String {
        if Bundle.main.bundleURL.pathExtension == "app" {
            return Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Parrot"
        }
        return parentProcessName() ?? "your terminal"
    }

    static func print(_ checks: [Check]) {
        for c in checks {
            let (mark, label): (String, String) = {
                switch c.status {
                case .ok: return ("✓", "ok")
                case .warn(let msg): return ("!", msg)
                case .fail(let msg): return ("✗", msg)
                }
            }()
            Swift.print("\(mark) \(c.name): \(label)")
            if let r = c.remediation {
                Swift.print("    → \(r)")
            }
        }
    }

    /// True if no checks are in a hard-fail state. Warnings don't block.
    static func allOK(_ checks: [Check]) -> Bool {
        checks.allSatisfy {
            if case .fail = $0.status { return false }
            return true
        }
    }

    /// True only if every check passed cleanly (used by `parrot doctor` exit code).
    static func allClean(_ checks: [Check]) -> Bool {
        checks.allSatisfy {
            if case .ok = $0.status { return true }
            return false
        }
    }
}
