import AppKit
import ArgumentParser
import Foundation
import WhisperKit

@main
struct Parrot: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "parrot",
        abstract: "Minimal macOS dictation daemon. Hold Fn, speak, release.",
        subcommands: [Run.self, Setup.self, Doctor.self, Models.self, Install.self],
        defaultSubcommand: Run.self
    )
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the daemon (default)."
    )

    @Flag(name: .long, help: "Skip permission checks at startup.")
    var skipDoctor: Bool = false

    @Flag(name: .long, help: "Print every keyboard event the tap sees (debug).")
    var debugHotkey: Bool = false

    @Flag(name: .long, help: "Write each capture to /tmp/parrot-last.wav for inspection.")
    var dumpWav: Bool = false

    @Flag(name: .long, help: "Disable the on-screen recording overlay.")
    var noOverlay: Bool = false

    @Flag(name: .long, help: "Mute the active macOS output while recording.")
    var muteOutput: Bool = false

    @Option(name: .long, help: "Model id to use. Defaults to the recommended model.")
    var model: String?

    func run() throws {
        if !skipDoctor {
            let checks = DoctorReport.run()
            if !DoctorReport.allOK(checks) {
                FileHandle.standardError.write(Data("startup checks failed:\n".utf8))
                DoctorReport.print(checks)
                FileHandle.standardError.write(Data("\nfix the above or pass --skip-doctor\n".utf8))
                throw ExitCode(1)
            }
        }

        let chosenModel: TranscriptionModel
        if let id = model {
            guard let m = ModelRegistry.find(id) else {
                FileHandle.standardError.write(Data("unknown model: \(id)\n".utf8))
                FileHandle.standardError.write(Data("run `parrot models list` to see options.\n".utf8))
                throw ExitCode(1)
            }
            chosenModel = m
        } else {
            guard let m = ModelRegistry.recommended() else {
                FileHandle.standardError.write(Data("no models registered\n".utf8))
                throw ExitCode(1)
            }
            chosenModel = m
        }

        let transcriber = WhisperKitTranscriber(model: chosenModel)
        let warmupSemaphore = DispatchSemaphore(value: 0)
        var warmupError: Error?
        Task.detached {
            do {
                try await transcriber.warmUp()
            } catch {
                warmupError = error
            }
            warmupSemaphore.signal()
        }
        warmupSemaphore.wait()
        if let warmupError {
            FileHandle.standardError.write(Data("warmup failed: \(warmupError)\n".utf8))
            throw ExitCode(1)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let monitor = HotkeyMonitor(debug: debugHotkey)
        let capture = AudioCapture()
        let outputMute = muteOutput ? OutputMuteController() : nil
        let dumpWav = self.dumpWav
        let overlay: RecordingOverlay? = noOverlay ? nil : MainActor.assumeIsolated { RecordingOverlay() }
        if let overlay {
            capture.onLevel = { level in overlay.pushLevel(level) }
        }
        let menuBar = MainActor.assumeIsolated { MenuBarController(modelID: chosenModel.id) }

        func beginRecording() -> Bool {
            outputMute?.mute()
            do {
                try capture.start()
                FileHandle.standardError.write(Data("● recording\n".utf8))
                MainActor.assumeIsolated {
                    overlay?.show(.recording)
                    menuBar.setRecording(true)
                }
                return true
            } catch {
                outputMute?.restore()
                FileHandle.standardError.write(Data("capture failed: \(error)\n".utf8))
                return false
            }
        }

        func finishRecording() {
            let samples = capture.stop()
            outputMute?.restore()
            MainActor.assumeIsolated {
                overlay?.show(.transcribing)
                menuBar.setTranscribing()
            }
            let seconds = Double(samples.count) / AudioCapture.targetSampleRate
            let rms = computeRMS(samples)
            FileHandle.standardError.write(Data(
                String(format: "○ captured %.2fs · rms %.3f\n", seconds, rms).utf8
            ))
            if dumpWav, !samples.isEmpty {
                let path = "/tmp/parrot-last.wav"
                do {
                    try WAVWriter.write(samples: samples, sampleRate: 16_000, to: path)
                    FileHandle.standardError.write(Data("  wrote \(path)\n".utf8))
                } catch {
                    FileHandle.standardError.write(Data("  wav write failed: \(error)\n".utf8))
                }
            }
            guard !samples.isEmpty else {
                MainActor.assumeIsolated {
                    overlay?.hide()
                    menuBar.setRecording(false)
                }
                return
            }
            Task {
                let started = Date()
                do {
                    let text = try await transcriber.transcribe(samples)
                    let elapsed = Date().timeIntervalSince(started)
                    FileHandle.standardError.write(Data(
                        String(format: "→ %.2fs · %@\n", elapsed, text).utf8
                    ))
                    await MainActor.run {
                        TextInjector.inject(text)
                        overlay?.hide()
                        menuBar.setRecording(false)
                    }
                } catch {
                    FileHandle.standardError.write(Data("transcription failed: \(error)\n".utf8))
                    await MainActor.run {
                        overlay?.hide()
                        menuBar.setRecording(false)
                    }
                }
            }
        }

        // Respect the user's macOS double-click preference, while keeping the
        // recognition window short enough to feel immediate for Fn dictation.
        let doubleTapInterval = min(max(NSEvent.doubleClickInterval, 0.30), 0.50)
        let gestureController = MainActor.assumeIsolated {
            FnDictationGestureController(
                doubleTapInterval: doubleTapInterval,
                startRecording: beginRecording,
                stopRecording: finishRecording,
                showLocked: {
                    FileHandle.standardError.write(Data("🔒 recording locked · tap fn to stop\n".utf8))
                    overlay?.show(.locked)
                    menuBar.setLockedRecording()
                }
            )
        }

        do {
            try monitor.start { event in
                MainActor.assumeIsolated {
                    gestureController.handle(event)
                }
            }
        } catch {
            FileHandle.standardError.write(Data("failed to register hotkey tap: \(error)\n".utf8))
            FileHandle.standardError.write(Data("run `parrot setup` to configure permissions.\n".utf8))
            throw ExitCode(1)
        }

        let cleanUp = {
            MainActor.assumeIsolated {
                gestureController.cancel()
            }
            _ = capture.stop()
            outputMute?.restore()
        }
        let terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: app,
            queue: .main
        ) { _ in
            cleanUp()
        }

        let shutDown = {
            FileHandle.standardError.write(Data("\nshutting down\n".utf8))
            monitor.stop()
            cleanUp()
            NSApp.terminate(nil)
        }

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler(handler: shutDown)
        sigint.resume()
        signal(SIGINT, SIG_IGN)

        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigterm.setEventHandler(handler: shutDown)
        sigterm.resume()
        signal(SIGTERM, SIG_IGN)

        FileHandle.standardError.write(Data("listening on fn hold · model: \(chosenModel.id) · ^C to quit\n".utf8))
        app.run()
        NotificationCenter.default.removeObserver(terminationObserver)
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check microphone, accessibility, and Fn key configuration."
    )

    func run() throws {
        let checks = DoctorReport.run()
        DoctorReport.print(checks)
        if !DoctorReport.allOK(checks) {
            throw ExitCode(1)
        }
    }
}

struct Models: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage transcription models.",
        subcommands: [List.self, Download.self]
    )

    struct List: ParsableCommand {
        func run() throws {
            for m in ModelRegistry.shared {
                let star = m.recommended ? "★" : " "
                let id = m.id.padding(toLength: 26, withPad: " ", startingAt: 0)
                let langs = "[\(m.languages.joined(separator: ","))]"
                    .padding(toLength: 9, withPad: " ", startingAt: 0)
                let size = String(format: "%5d MB", m.sizeMB)
                print("\(star) \(id) \(size)  \(langs)  \(m.displayName)")
            }
        }
    }

    struct Download: ParsableCommand {
        @Argument(help: "Model id to download.") var id: String

        func run() throws {
            guard let m = ModelRegistry.find(id) else {
                print("unknown model: \(id)")
                throw ExitCode(1)
            }
            let t = WhisperKitTranscriber(model: m)

            let sem = DispatchSemaphore(value: 0)
            var capturedError: Error?
            Task.detached {
                do { try await t.warmUp() } catch { capturedError = error }
                sem.signal()
            }
            sem.wait()
            if let e = capturedError { throw e }
        }
    }
}
