import AppKit
import Foundation
import Testing
@testable import parrot

private actor OrderedRecorder {
    private var values = [Int]()

    func append(_ value: Int) {
        values.append(value)
    }

    func snapshot() -> [Int] {
        values
    }
}

@Test func computeRMSHandlesSilenceAndFullScaleAudio() {
    #expect(computeRMS([]) == 0)
    #expect(abs(computeRMS([1, -1, 1, -1]) - 1) < 0.0001)
}

@Test func whisperSanitizerRemovesNonSpeechTokens() {
    let input = " Hello [BLANK_AUDIO] (silence) *noise* <|nospeech|> world "
    #expect(WhisperKitTranscriber.sanitize(input) == "Hello world")
}

@Test func whisperSanitizerPreservesDictatedPunctuation() {
    let input = "Call John (not Jack) and keep [section one] *important*."
    #expect(WhisperKitTranscriber.sanitize(input) == input)
}

@Test func recommendedModelIsRegistered() {
    let recommended = ModelRegistry.recommended()
    #expect(recommended != nil)
    #expect(recommended?.recommended == true)
    #expect(ModelRegistry.find(recommended?.id ?? "")?.id == recommended?.id)
}

@Test func deliveryGuardStoreTracksLatestPendingGuard() {
    let store = DeliveryGuardStore()
    let first = DeliveryGuard(originalFocus: nil, uiGeneration: 1)
    let second = DeliveryGuard(originalFocus: nil, uiGeneration: 2)

    store.begin(first)
    #expect(store.releaseCurrent() === first)

    store.begin(second)
    #expect(first.uiGeneration == 1)
    #expect(second.uiGeneration == 2)

    store.remove(first)
    #expect(store.releaseCurrent() === second)
}

@Test func interactionGenerationOnlyAcceptsLatest() {
    let store = InteractionGenerationStore()
    let first = store.advance()
    let second = store.advance()

    #expect(!store.isLatest(first))
    #expect(store.isLatest(second))
}

@Test func settingsDecoderRejectsCorruptJSON() {
    do {
        _ = try ParrotSettings.decodeSelectedModelID(from: Data("not-json".utf8))
        Issue.record("corrupt settings should throw")
    } catch {
        #expect(error is DecodingError)
    }
}

@Test func toggleChordEmitsOncePerPhysicalPress() {
    var state = ToggleChordState()

    let firstPress = state.update(isDown: true)
    let repeatedFlags = state.update(isDown: true)
    let release = state.update(isDown: false)
    let secondPress = state.update(isDown: true)

    #expect(firstPress)
    #expect(!repeatedFlags)
    #expect(!release)
    #expect(secondPress)
}

@Test func interruptedChordWaitsForPhysicalRelease() {
    var state = ToggleChordState()

    let firstPress = state.update(isDown: true)
    state.recoveredAfterTapDisable(isChordCurrentlyDown: true)
    let interruptedNoise = state.update(isDown: true)
    let release = state.update(isDown: false)
    let nextPress = state.update(isDown: true)

    #expect(firstPress)
    #expect(!interruptedNoise)
    #expect(!release)
    #expect(nextPress)
}

@Test func tapRecoveryDoesNotWaitForAnAlreadyMissedRelease() {
    var state = ToggleChordState()

    let firstPress = state.update(isDown: true)
    state.recoveredAfterTapDisable(isChordCurrentlyDown: false)
    let nextPress = state.update(isDown: true)

    #expect(firstPress)
    #expect(nextPress)
}

@Test func tapRecoveryInvalidatesUnobservableInput() {
    var invalidated = false
    let monitor = HotkeyMonitor { event in
        if case .focusInteraction = event {
            invalidated = true
        }
    }

    monitor.reenableAfterSystemDisable()

    #expect(invalidated)
}

@Test func fnGlobeKeyDownDoesNotInvalidateEditorFocus() {
    #expect(!shouldMarkFocusInteractionForKeyDown(
        keyCode: fnGlobeVirtualKeyCode,
        isOwnProcess: false
    ))
}

@Test func payloadFreeDuplicateAtShortcutEdgeDoesNotInvalidateEditorFocus() {
    #expect(!shouldMarkFocusInteractionForKeyDown(
        keyCode: 0,
        isOwnProcess: false,
        isShortcutChordActive: true,
        unicodeCharacterCount: 0,
        secondsSinceToggle: 0.05
    ))
}

@Test func realInputDuringOrAfterShortcutStillInvalidatesEditorFocus() {
    #expect(shouldMarkFocusInteractionForKeyDown(
        keyCode: 0,
        isOwnProcess: false,
        isShortcutChordActive: true,
        unicodeCharacterCount: 1,
        secondsSinceToggle: 0.05
    ))
    #expect(shouldMarkFocusInteractionForKeyDown(
        keyCode: 123,
        isOwnProcess: false,
        isShortcutChordActive: true,
        unicodeCharacterCount: 0,
        secondsSinceToggle: 0.05
    ))
    #expect(shouldMarkFocusInteractionForKeyDown(
        keyCode: 0,
        isOwnProcess: false,
        isShortcutChordActive: true,
        unicodeCharacterCount: 0,
        canIgnoreShortcutDuplicate: false,
        secondsSinceToggle: 0.05
    ))
    #expect(shouldMarkFocusInteractionForKeyDown(
        keyCode: 0,
        isOwnProcess: false,
        isShortcutChordActive: true,
        unicodeCharacterCount: 0,
        secondsSinceToggle: shortcutDuplicateMaximumDelay + 0.01
    ))
}

@Test func onlyRealExternalInputConsumesShortcutDuplicateOpportunity() {
    #expect(shouldConsumeShortcutDuplicateOpportunity(
        keyCode: 0,
        isOwnProcess: false,
        isParrotInjected: false
    ))
    #expect(!shouldConsumeShortcutDuplicateOpportunity(
        keyCode: 0,
        isOwnProcess: true,
        isParrotInjected: false
    ))
    #expect(!shouldConsumeShortcutDuplicateOpportunity(
        keyCode: 0,
        isOwnProcess: false,
        isParrotInjected: true
    ))
    #expect(!shouldConsumeShortcutDuplicateOpportunity(
        keyCode: fnGlobeVirtualKeyCode,
        isOwnProcess: false,
        isParrotInjected: false
    ))
}

@Test func everyOtherExternalKeyDownInvalidatesEditorFocus() {
    // Letters and navigation keys must remain fail-safe even if the user
    // presses them before releasing the Control + Fn/Globe chord.
    #expect(shouldMarkFocusInteractionForKeyDown(
        keyCode: 0,
        isOwnProcess: false
    ))
    #expect(shouldMarkFocusInteractionForKeyDown(
        keyCode: 123,
        isOwnProcess: false
    ))
}

@Test func injectedKeyDownDoesNotInvalidateEditorFocus() {
    #expect(!shouldMarkFocusInteractionForKeyDown(
        keyCode: 0,
        isOwnProcess: true
    ))
    #expect(!shouldMarkFocusInteractionForKeyDown(
        keyCode: 0,
        isOwnProcess: false,
        isParrotInjected: true
    ))
}

@Test func consecutiveDictationGetsOnlyTheNeededBoundary() {
    #expect(textWithNaturalDictationBoundary(
        "What do you mean?",
        previousTrailingCharacter: "."
    ) == " What do you mean?")
    #expect(textWithNaturalDictationBoundary(
        "continues here",
        previousTrailingCharacter: "d"
    ) == " continues here")
    #expect(textWithNaturalDictationBoundary(
        "already spaced",
        previousTrailingCharacter: " "
    ) == "already spaced")
    #expect(textWithNaturalDictationBoundary(
        " world",
        previousTrailingCharacter: "."
    ) == " world")
    #expect(textWithNaturalDictationBoundary(
        ", then this",
        previousTrailingCharacter: "d"
    ) == ", then this")
    #expect(textWithNaturalDictationBoundary(
        "inside",
        previousTrailingCharacter: "("
    ) == "inside")
    #expect(textWithNaturalDictationBoundary(
        "inside smart quotes",
        previousTrailingCharacter: "“"
    ) == "inside smart quotes")
    #expect(textWithNaturalDictationBoundary(
        "”",
        previousTrailingCharacter: "d"
    ) == "”")
    #expect(textWithNaturalDictationBoundary(
        "first text",
        previousTrailingCharacter: nil
    ) == "first text")
}

@Test func clipboardFallbackKeepsTheRawTranscript() {
    let pasteboard = NSPasteboard(
        name: NSPasteboard.Name("parrot-tests-\(UUID().uuidString)")
    )
    let result = TextInjector.deliver(
        "standalone transcript",
        deliveryGuard: nil,
        pasteboard: pasteboard,
        prepareForInjection: { " " + $0 },
        currentFocusIsSecure: { false }
    )

    #expect(result == .copiedToClipboard)
    #expect(pasteboard.string(forType: .string) == "standalone transcript")
    pasteboard.clearContents()
}

@Test func secureFocusRaceNeverWritesTheClipboard() {
    let pasteboard = NSPasteboard(
        name: NSPasteboard.Name("parrot-secure-race-tests-\(UUID().uuidString)")
    )
    pasteboard.clearContents()
    #expect(pasteboard.setString("existing clipboard", forType: .string))
    var secureChecks = 0

    let result = TextInjector.deliver(
        "sensitive transcript",
        deliveryGuard: nil,
        pasteboard: pasteboard,
        currentFocusIsSecure: {
            secureChecks += 1
            return secureChecks > 2
        }
    )

    #expect(result == .blockedSecureField)
    #expect(secureChecks == 3)
    #expect(pasteboard.string(forType: .string) == "existing clipboard")
    pasteboard.clearContents()
}

@Test func caretAdvancesPastInsertedTextAndReplacedSelection() {
    let replacement = CFRange(location: 4, length: 3)
    let result = caretRangeAfterInsertion(
        replacing: replacement,
        insertedText: "go🙂"
    )

    #expect(result.location == 8)
    #expect(result.length == 0)
}

@Test func dictationToggleAlternatesAndRecoversFromStartFailure() {
    let state = DictationToggleState()

    #expect(state.toggle() == .start)
    state.startFailed()
    #expect(state.toggle() == .start)
    #expect(state.toggle() == .stop)
    #expect(!state.stopIfRecording())
}

@Test func safetyStopConsumesOnlyAnActiveRecording() {
    let state = DictationToggleState()

    #expect(!state.stopIfRecording())
    #expect(state.toggle() == .start)
    #expect(state.stopIfRecording())
    #expect(!state.stopIfRecording())
}

@Test func safetyStopCannotRaceIntoAReplacementRecording() {
    let state = DictationToggleState()
    let deadline = Date(timeIntervalSinceReferenceDate: 1_000)

    #expect(state.toggle(observedAt: deadline.addingTimeInterval(-1)) == .start)
    #expect(state.stopIfRecording(blockingRestartFor: 2, observedAt: deadline))
    // The event's callback observation time, not its later main-queue handling
    // time, decides whether this was the stop press racing the safety limit.
    #expect(state.toggle(observedAt: deadline) == .ignoredDuringSafetyRearm)
    #expect(state.toggle(observedAt: deadline.addingTimeInterval(2.1)) == .start)
}

@Test func serialAsyncTaskQueuePreservesStopOrder() async {
    let queue = SerialAsyncTaskQueue()
    let recorder = OrderedRecorder()

    queue.enqueue {
        try? await Task.sleep(for: .milliseconds(20))
        await recorder.append(1)
    }
    queue.enqueue {
        await recorder.append(2)
    }

    await queue.waitUntilIdle()
    #expect(await recorder.snapshot() == [1, 2])
}

@Test func asyncTimeoutReleasesAHungOperation() async {
    do {
        _ = try await withAsyncTimeout(seconds: 0.02) {
            try await Task.sleep(for: .seconds(60))
            return "late"
        }
        Issue.record("hung operation should time out")
    } catch let error as TranscriberRuntimeError {
        #expect(error.description == "operation timed out after 0 seconds")
    } catch {
        Issue.record("unexpected timeout error: \(error)")
    }
}
