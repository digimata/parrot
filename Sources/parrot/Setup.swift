import ApplicationServices
import ArgumentParser
import AVFoundation
import Foundation

struct Setup: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Walk through first-run permission setup."
    )

    func run() throws {
        print("parrot setup")
        print("============")
        print()
        print("Parrot needs two permissions:")
        print("  1. Accessibility — to detect Control + Fn/Globe globally and inject text at the cursor.")
        print("  2. Microphone — to record audio while you hold Control + Fn/Globe.")
        print()
        let host = Bundle.main.bundleURL.pathExtension == "app" ? "Parrot" : "your terminal app"
        print("These attach to \(host).")
        print()

        try waitForAccessibility()
        print()
        try waitForMicrophone()
        print()
        try prepareSelectedModel()
        print()
        print("✓ all set. Run `parrot` to start the daemon.")
    }

    private func waitForAccessibility() throws {
        if AXIsProcessTrusted() {
            print("✓ accessibility already granted")
            return
        }

        print("→ opening accessibility prompt...")
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)

        print()
        let host = Bundle.main.bundleURL.pathExtension == "app" ? "Parrot" : "your terminal"
        print("  1. Toggle \(host) on in the Accessibility list.")
        print("  2. Re-run `parrot setup` — macOS only picks up the grant on a fresh process.")
        // Setup is not complete yet. A nonzero exit prevents scripts and the
        // user from mistaking an opened Settings pane for a granted permission.
        throw ExitCode(1)
    }

    private func waitForMicrophone() throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            print("✓ microphone already granted")
            return
        case .denied, .restricted:
            print("✗ microphone is denied — macOS won't re-prompt once denied.")
            print("  opening Settings → Privacy & Security → Microphone...")
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
