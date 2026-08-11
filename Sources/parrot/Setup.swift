import ApplicationServices
import ArgumentParser
import AVFoundation
import Foundation

func waitForConsecutiveAccessibilityChecks(
    maxAttempts: Int,
    requiredConsecutiveChecks: Int = 2,
    isTrusted: () -> Bool,
    pause: () -> Void
) -> Bool {
    guard maxAttempts > 0, requiredConsecutiveChecks > 0 else { return false }

    var consecutiveChecks = 0
    for attempt in 0..<maxAttempts {
        if isTrusted() {
            consecutiveChecks += 1
            if consecutiveChecks >= requiredConsecutiveChecks {
                return true
            }
        } else {
            consecutiveChecks = 0
        }

        if attempt + 1 < maxAttempts {
            pause()
        }
    }

    return false
}

struct Setup: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Walk through first-run permission setup."
    )

    func run() throws {
        print("parrot setup")
        print("============")
        print()
        print("Parrot needs two permissions:")
        print("  1. Accessibility: detect Control + Fn/Globe and insert text at the cursor.")
        print("  2. Microphone: record between Control + Fn/Globe toggle presses.")
        print()
        let host = Bundle.main.bundleURL.pathExtension == "app" ? "Parrot" : "your terminal app"
        print("These attach to \(host).")
        print()

        try waitForAccessibility()
        print()
        try waitForMicrophone()
        print()
        try configureGlobeKey()
        print()
        try prepareSelectedModel()
        print()
        print("✓ setup complete")
    }

    private func waitForAccessibility() throws {
        if AXIsProcessTrusted() {
            print("✓ accessibility already granted")
            return
        }

        print("→ opening Accessibility settings...")
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)

        print()
        let host = Bundle.main.bundleURL.pathExtension == "app" ? "Parrot" : "your terminal"
        print("  1. Toggle \(host) on in the Accessibility list.")
        print("  2. Keep this window open. Setup will continue automatically.")
        print()
        print("→ waiting for Accessibility approval (up to 5 minutes)...")

        let granted = waitForConsecutiveAccessibilityChecks(
            maxAttempts: 300,
            isTrusted: { AXIsProcessTrusted() },
            pause: { Thread.sleep(forTimeInterval: 1) }
        )
        guard granted else {
            print("✗ Accessibility was not approved in time.")
            print("  Enable \(host), then run `parrot setup` again.")
            throw ExitCode(1)
        }
        print("✓ accessibility granted")
    }

    private func waitForMicrophone() throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            print("✓ microphone already granted")
            return
        case .denied, .restricted:
            print("✗ microphone is denied. macOS will not show the prompt again.")
            print("  opening Settings > Privacy & Security > Microphone...")
            openSettings("Privacy_Microphone")
            print("  enable your terminal, then re-run `parrot setup`.")
            throw ExitCode(1)
        case .notDetermined:
            print("→ requesting microphone access...")
            let semaphore = DispatchSemaphore(value: 0)
            var granted = false
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                granted = ok
                semaphore.signal()
            }
            semaphore.wait()
            if granted {
                print("  ✓ microphone granted")
            } else {
                print("  ✗ microphone denied")
                throw ExitCode(1)
            }
        @unknown default:
            print("? microphone in unknown state")
        }
    }

    private func configureGlobeKey() throws {
        if case .ok = DoctorReport.checkFnKeyMapping().status {
            print("✓ Globe key already set to Do Nothing")
            return
        }

        print("→ setting the Globe key to Do Nothing for Parrot's shortcut...")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = [
            "write",
            "com.apple.HIToolbox",
            "AppleFnUsageType",
            "-int",
            "0",
        ]
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            print("✗ could not update the Globe key setting: \(error)")
            throw ExitCode(1)
        }
        guard task.terminationStatus == 0 else {
            print("✗ could not update the Globe key setting")
            print("  Set System Settings > Keyboard > Press Globe key to > Do Nothing.")
            throw ExitCode(1)
        }
        print("✓ Globe key set to Do Nothing")
    }

    private func openSettings(_ pane: String) {
        let url = "x-apple.systempreferences:com.apple.preference.security?\(pane)"
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = [url]
        try? task.run()
    }

    private func prepareSelectedModel() throws {
        let model = try ParrotSettings.selectedModelID().flatMap(ModelRegistry.find)
            ?? ModelRegistry.recommended()
        guard let model else {
            print("✗ no transcription model is registered")
            throw ExitCode(1)
        }

        print("→ preparing \(model.id)...")
        do {
            try ensureModelDiskSpace(for: model)
            try warmUpSynchronously(makeTranscriber(for: model))
            print("✓ transcription model ready")
        } catch {
            print("✗ model preparation failed: \(error)")
            throw ExitCode(1)
        }
    }
}
