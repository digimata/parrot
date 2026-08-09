import AppKit
import ArgumentParser
import Darwin
import Foundation
import WhisperKit

@main
struct Parrot: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "parrot",
        abstract: "Minimal macOS dictation daemon. Hold Control + Fn/Globe, speak, release.",
        subcommands: [Run.self, Setup.self, Doctor.self, Models.self, Install.self],
        defaultSubcommand: Run.self
    )

    static func main() {
        // Finder and `open` add a process-serial-number argument when they
        // launch a bundled macOS app. It is not a Parrot command-line option.
        let arguments = CommandLine.arguments
            .dropFirst()
            .filter { !$0.hasPrefix("-psn_") }
        Self.main(arguments)
    }
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

    @Flag(name: .long, help: "Write each capture to a private temporary WAV for inspection.")
    var dumpWav: Bool = false

    @Flag(name: .long, help: "Disable the on-screen recording overlay.")
    var noOverlay: Bool = false

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
        if let id = try (model ?? ParrotSettings.selectedModelID()) {
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

        let transcriber = makeTranscriber(for: chosenModel)
        do {
            try ensureModelDiskSpace(for: chosenModel)
            try warmUpSynchronously(transcriber)
        } catch {
            FileHandle.standardError.write(Data("warmup failed: \(error)\n".utf8))
            throw ExitCode(1)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let monitor = HotkeyMonitor(debug: debugHotkey)
        let capture = AudioCapture()
        let dumpWav = self.dumpWav
        let overlay: RecordingOverlay? = noOverlay ? nil : MainActor.assumeIsolated { RecordingOverlay() }
        if let overlay {
            capture.onLevel = { level in overlay.pushLevel(level) }
        }
        let menuBar = MainActor.assumeIsolated { MenuBarController(modelID: chosenModel.id) }
        let deliveryGuards = DeliveryGuardStore()
        let interactionGenerations = InteractionGenerationStore()
        var transcriptionTail: Task<Void, Never>?

        do {
            try monitor.start { event in
                switch event {
                case .pressed:
                    let uiGeneration = interactionGenerations.advance()
                    do {
                        try capture.start()
                        // Start the microphone before querying Accessibility.
                        // Some apps can make the AX lookup slow; audio should
                        // still cover the full hotkey hold while that completes.
                        let deliveryGuard = DeliveryGuard(
                            originalFocus: FocusSnapshot.capture(),
                            uiGeneration: uiGeneration
                        )
                        deliveryGuards.begin(deliveryGuard)
                        FileHandle.standardError.write(Data("● recording\n".utf8))
                        MainActor.assumeIsolated {
                            overlay?.show(.recording)
                            menuBar.setRecording(true)
                        }
                    } catch {
                        FileHandle.standardError.write(Data("capture failed: \(error)\n".utf8))
                        MainActor.assumeIsolated {
                            menuBar.setCaptureError("audio capture failed · try again")
                            NSSound.beep()
                        }
                    }
                case .released:
                    let result = capture.stop()
                    let samples = result.samples
                    guard let deliveryGuard = deliveryGuards.releaseCurrent() else { return }
                    MainActor.assumeIsolated {
                        overlay?.show(.transcribing)
                        menuBar.setTranscribing()
                    }
                    let seconds = Double(samples.count) / AudioCapture.targetSampleRate
                    let rms = computeRMS(samples)
                    FileHandle.standardError.write(Data(String(
                        format: "○ held %.2fs · captured %.2fs · callbacks %d · input frames %d · rms %.3f\n",
                        result.wallDuration,
                        seconds,
                        result.callbackCount,
                        result.inputFrameCount,
                        rms
                    ).utf8))
                    if result.configurationChanged {
                        FileHandle.standardError.write(Data(
                            "  audio device changed during recording · please retry\n".utf8
                        ))
                        deliveryGuards.remove(deliveryGuard)
                        MainActor.assumeIsolated {
                            overlay?.hide()
                            menuBar.setCaptureError("audio device changed · try again")
                            NSSound.beep()
                        }
                        return
                    }
                    if let error = result.conversionError {
                        FileHandle.standardError.write(Data(
                            "  audio conversion failed: \(error)\n".utf8
                        ))
                        deliveryGuards.remove(deliveryGuard)
                        MainActor.assumeIsolated {
                            overlay?.hide()
                            menuBar.setCaptureError("audio capture failed · try again")
                            NSSound.beep()
                        }
                        return
                    }
                    if dumpWav, !samples.isEmpty {
                        let path = FileManager.default.temporaryDirectory
                            .appendingPathComponent(
                                "parrot-debug-\(getpid())-\(UUID().uuidString).wav"
                            )
                            .path
                        do {
                            try WAVWriter.write(samples: samples, sampleRate: 16_000, to: path)
                            FileHandle.standardError.write(Data("  wrote \(path)\n".utf8))
                        } catch {
                            FileHandle.standardError.write(Data("  wav write failed: \(error)\n".utf8))
                        }
                    }
                    guard !samples.isEmpty else {
                        deliveryGuards.remove(deliveryGuard)
                        MainActor.assumeIsolated {
                            overlay?.hide()
                            if result.wallDuration >= 0.25 {
                                menuBar.setCaptureError("no microphone audio · try again")
                                NSSound.beep()
                            } else {
                                menuBar.setRecording(false)
                            }
                        }
                        return
                    }
                    let previousTranscription = transcriptionTail
                    let transcriptionTask = Task {
                        if let previousTranscription {
                            await previousTranscription.value
                        }
                        let started = Date()
                        do {
                            let text = try await transcriber.transcribe(samples)
                            guard !text.isEmpty else { throw TranscriberError.emptyResult }
                            let elapsed = Date().timeIntervalSince(started)
                            FileHandle.standardError.write(Data(
                                String(format: "→ %.2fs · %d chars\n", elapsed, text.count).utf8
                            ))
                            await MainActor.run {
                                let shouldResetUI = interactionGenerations.isLatest(
                                    deliveryGuard.uiGeneration
                                )
                                let delivery = TextInjector.deliver(text, deliveryGuard: deliveryGuard)
                                switch delivery {
                                case .injected:
                                    FileHandle.standardError.write(Data("  delivered to original cursor\n".utf8))
                                case .copiedToClipboard:
                                    FileHandle.standardError.write(Data("  focus changed · copied transcript to clipboard\n".utf8))
                                    NSSound.beep()
                                case .clipboardCopyFailed:
                                    FileHandle.standardError.write(Data("  focus changed · clipboard copy failed\n".utf8))
                                    NSSound.beep()
                                }
                                if shouldResetUI {
                                    overlay?.hide()
                                    menuBar.setRecording(false)
                                }
                                deliveryGuards.remove(deliveryGuard)
                            }
                        } catch {
                            FileHandle.standardError.write(Data("transcription failed: \(error)\n".utf8))
                            await MainActor.run {
                                if interactionGenerations.isLatest(deliveryGuard.uiGeneration) {
                                    overlay?.hide()
                                    menuBar.setCaptureError("transcription failed · try again")
                                    NSSound.beep()
                                }
                                deliveryGuards.remove(deliveryGuard)
                            }
                        }
                    }
                    transcriptionTail = transcriptionTask
                case .focusInteraction:
                    deliveryGuards.notePointerInteraction()
                case .tapRecoveryFailed:
                    FileHandle.standardError.write(Data(
                        "fatal: global hotkey tap could not be recovered; exiting for launchd restart\n".utf8
                    ))
                    monitor.stop()
                    Darwin.exit(EXIT_FAILURE)
                }
            }
        } catch {
            FileHandle.standardError.write(Data("failed to register hotkey tap: \(error)\n".utf8))
            FileHandle.standardError.write(Data("run `parrot setup` to configure permissions.\n".utf8))
            throw ExitCode(1)
        }

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler {
            FileHandle.standardError.write(Data("\nshutting down\n".utf8))
            monitor.stop()
            NSApp.terminate(nil)
        }
        sigint.resume()
        signal(SIGINT, SIG_IGN)

        FileHandle.standardError.write(Data("listening on control + fn/globe hold · model: \(chosenModel.id) · ^C to quit\n".utf8))
        app.run()
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check microphone, accessibility, and Fn key configuration."
    )

    @Flag(name: .long, help: "Record briefly and verify that Core Audio returns real microphone frames.")
    var liveAudio: Bool = false

    @Flag(name: .long, help: "Load the selected model and verify it is ready for transcription.")
    var modelReady: Bool = false

    func run() throws {
        let selectedModel = try ParrotSettings.selectedModelID().flatMap(ModelRegistry.find)
            ?? ModelRegistry.recommended()
        let checks = DoctorReport.run(
            includeLiveAudio: liveAudio,
            modelToVerify: modelReady ? selectedModel : nil
        )
        DoctorReport.print(checks)
        if !DoctorReport.allOK(checks) {
            throw ExitCode(1)
        }
    }
}

struct Models: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage transcription models.",
        subcommands: [List.self, Download.self, Smoke.self, Select.self]
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
            let t = makeTranscriber(for: m)
            try ensureModelDiskSpace(for: m)
            try warmUpSynchronously(t)
        }
    }

    struct Smoke: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Verify a Parakeet model with generated local speech."
        )

        @Argument(help: "Model id to verify.") var id: String

        func run() throws {
            guard let model = ModelRegistry.find(id), model.engine == .parakeet else {
                print("smoke is currently available for a Parakeet model")
                throw ExitCode(1)
            }

            let fixture = FileManager.default.temporaryDirectory
                .appendingPathComponent("parrot-parakeet-smoke-\(UUID().uuidString).aiff")
            defer { try? FileManager.default.removeItem(at: fixture) }

            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-o", fixture.path, "Parrot local transcription test"]
            try say.run()
            say.waitUntilExit()
            guard say.terminationStatus == 0 else {
                throw ExitCode(say.terminationStatus)
            }

            let transcriber = ParakeetTranscriber(model: model)
            try ensureModelDiskSpace(for: model)
            try waitForAsyncOperation(timeout: 600) {
                try await transcriber.warmUp()
                let text = try await transcriber.transcribeFile(fixture)
                guard !text.isEmpty else { throw ParakeetTranscriberError.emptyResult }
            }
            print("✓ local Parakeet transcription smoke test passed")
        }
    }

    struct Select: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Select the model used by the login dictation service."
        )

        @Argument(help: "Model id to select.") var id: String

        func run() throws {
            guard ModelRegistry.find(id) != nil else {
                print("unknown model: \(id)")
                throw ExitCode(1)
            }
            try ParrotSettings.select(modelID: id)
            print("✓ selected \(id) for the next Parrot launch")
            print("  restart the login service with `parrot install --launch-at-login`")
        }
    }
}
