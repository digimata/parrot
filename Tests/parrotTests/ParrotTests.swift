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

private final class FakeDictationDeliveryGuard: DictationDeliveryGuard {
    var allowsInjection: Bool

    init(allowsInjection: Bool = true) {
        self.allowsInjection = allowsInjection
    }

    func canInjectIntoOriginalFocus() -> Bool {
        allowsInjection
    }
}

@Test func accessibilityUncertaintyIsNeverClassifiedAsNonsecure() {
    #expect(focusSecurityStatusForSubroleLookup(
        status: .cannotComplete,
        subrole: nil,
        valueWasPresent: false
    ) == .unobservable)
    #expect(focusSecurityStatusForSubroleLookup(
        status: .success,
        subrole: nil,
        valueWasPresent: false
    ) == .unobservable)
    #expect(focusSecurityStatusForSubroleLookup(
        status: .success,
        subrole: nil,
        valueWasPresent: true
    ) == .unobservable)
    #expect(focusSecurityStatusForSubroleLookup(
        status: .success,
        subrole: kAXSecureTextFieldSubrole as String,
        valueWasPresent: true
    ) == .secure)
    #expect(focusSecurityStatusForSubroleLookup(
        status: .noValue,
        subrole: nil,
        valueWasPresent: false
    ) == .nonsecure)
    #expect(focusSecurityStatusForProtectedContentLookup(
        status: .success,
        containsProtectedContent: true,
        valueWasPresent: true
    ) == .secure)
    #expect(focusSecurityStatusForProtectedContentLookup(
        status: .success,
        containsProtectedContent: false,
        valueWasPresent: true
    ) == .nonsecure)
    #expect(focusSecurityStatusForProtectedContentLookup(
        status: .success,
        containsProtectedContent: nil,
        valueWasPresent: false
    ) == .unobservable)
    #expect(focusSecurityStatusForProtectedContentLookup(
        status: .cannotComplete,
        containsProtectedContent: nil,
        valueWasPresent: false
    ) == .unobservable)
    #expect(combinedFocusSecurityStatus(.nonsecure, .secure) == .secure)
    #expect(combinedFocusSecurityStatus(.nonsecure, .unobservable) == .unobservable)
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
        isOwnProcess: false,
        hasShortcutModifier: true,
        unicodeCharacterCount: 0,
        secondsSinceToggle: 1.836
    ))
}

@Test func observedGlobeAuxiliaryKeyDownDoesNotInvalidateEditorFocus() {
    // The live Mac emits key code 179 with no Unicode payload during the
    // second Control + Globe cycle. It is control input, not composer input.
    #expect(!shouldMarkFocusInteractionForKeyDown(
        keyCode: globeAuxiliaryVirtualKeyCode,
        isOwnProcess: false,
        hasShortcutModifier: true,
        unicodeCharacterCount: 0,
        secondsSinceToggle: 1.836
    ))
}

@Test func unrelatedGlobeAuxiliaryEventsInvalidateEditorFocus() {
    #expect(shouldMarkFocusInteractionForKeyDown(
        keyCode: globeAuxiliaryVirtualKeyCode,
        isOwnProcess: false,
        hasShortcutModifier: true,
        unicodeCharacterCount: 1,
        secondsSinceToggle: 0.05
    ))
    #expect(shouldMarkFocusInteractionForKeyDown(
        keyCode: globeAuxiliaryVirtualKeyCode,
        isOwnProcess: false,
        unicodeCharacterCount: 0,
        secondsSinceToggle: 0.05
    ))
    #expect(shouldMarkFocusInteractionForKeyDown(
        keyCode: 0,
        isOwnProcess: false,
        hasShortcutModifier: true,
        unicodeCharacterCount: 0,
        secondsSinceToggle: 30
    ))
}

@Test func payloadFreeDuplicateAfterPartialModifierReleaseDoesNotInvalidateEditorFocus() {
    // The payload-free duplicate can arrive after either Control or Fn/Globe
    // has lifted. One remaining shortcut modifier still identifies it as part
    // of the same physical toggle.
    #expect(!shouldMarkFocusInteractionForKeyDown(
        keyCode: 0,
        isOwnProcess: false,
        hasShortcutModifier: true,
        unicodeCharacterCount: 0,
        secondsSinceToggle: 0.05
    ))
}

@Test func realInputDuringOrAfterShortcutStillInvalidatesEditorFocus() {
    #expect(shouldMarkFocusInteractionForKeyDown(
        keyCode: 0,
        isOwnProcess: false,
        hasShortcutModifier: true,
        unicodeCharacterCount: 1,
        secondsSinceToggle: 0.05
    ))
    #expect(shouldMarkFocusInteractionForKeyDown(
        keyCode: 123,
        isOwnProcess: false,
        hasShortcutModifier: true,
        unicodeCharacterCount: 0,
        secondsSinceToggle: 0.05
    ))
    #expect(shouldMarkFocusInteractionForKeyDown(
        keyCode: 0,
        isOwnProcess: false,
        hasShortcutModifier: true,
        unicodeCharacterCount: 0,
        canIgnoreShortcutDuplicate: false,
        secondsSinceToggle: 0.05
    ))
    #expect(shouldMarkFocusInteractionForKeyDown(
        keyCode: 0,
        isOwnProcess: false,
        hasShortcutModifier: true,
        unicodeCharacterCount: 0,
        secondsSinceToggle: shortcutDuplicateMaximumDelay + 0.01
    ))
}

@Test func onlyRealExternalInputConsumesShortcutDuplicateOpportunity() {
    #expect(shouldConsumeShortcutDuplicateOpportunity(
        keyCode: 0,
        isOwnProcess: false,
        isParrotInjected: false,
        hasShortcutModifier: false,
        unicodeCharacterCount: 1,
        secondsSinceToggle: 0.05
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
        isParrotInjected: false,
        hasShortcutModifier: true,
        unicodeCharacterCount: 0,
        secondsSinceToggle: 1.836
    ))
    #expect(!shouldConsumeShortcutDuplicateOpportunity(
        keyCode: globeAuxiliaryVirtualKeyCode,
        isOwnProcess: false,
        isParrotInjected: false,
        hasShortcutModifier: true,
        unicodeCharacterCount: 0,
        secondsSinceToggle: 1.836
    ))
    #expect(shouldConsumeShortcutDuplicateOpportunity(
        keyCode: globeAuxiliaryVirtualKeyCode,
        isOwnProcess: false,
        isParrotInjected: false,
        unicodeCharacterCount: 0,
        secondsSinceToggle: 0.05
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

@Test func everyCaptureOwnsItsTrailingBoundary() {
    #expect(textWithIndependentDictationBoundary("Okay.") == "Okay. ")
    #expect(textWithIndependentDictationBoundary("already spaced ") == "already spaced ")
    #expect(textWithIndependentDictationBoundary("") == "")
}

@Test func twoDistinctCapturesInsertTheirOwnTextExactlyOnce() {
    let guardForFirstCapture = FakeDictationDeliveryGuard()
    let guardForSecondCapture = FakeDictationDeliveryGuard()
    var editor = ""
    var payloads = [String]()

    let first = TextInjector.deliver(
        "Okay.",
        deliveryGuard: guardForFirstCapture,
        currentFocusSecurity: { .nonsecure },
        postText: {
            payloads.append($0)
            editor += $0
            return true
        }
    )
    let second = TextInjector.deliver(
        "What do you mean?",
        deliveryGuard: guardForSecondCapture,
        currentFocusSecurity: { .nonsecure },
        postText: {
            payloads.append($0)
            editor += $0
            return true
        }
    )

    #expect(first == .sentUnconfirmed("Okay. "))
    #expect(second == .sentUnconfirmed("What do you mean? "))
    #expect(payloads == ["Okay. ", "What do you mean? "])
    #expect(editor == "Okay. What do you mean? ")
}

@Test func injectedTextEventsNeverInheritThePhysicalShortcutModifiers() {
    let chunk = Array("current transcript".utf16)
    let pair = TextInjector.makeInjectionEventPair(chunk: chunk)
    #expect(pair != nil)
    guard let (keyDown, keyUp) = pair else { return }

    #expect(keyDown.getIntegerValueField(.eventSourceStateID)
        == keyUp.getIntegerValueField(.eventSourceStateID))

    for event in [keyDown, keyUp] {
        #expect(event.flags.intersection([
            .maskControl,
            .maskSecondaryFn,
            .maskCommand,
            .maskAlternate,
            .maskShift
        ]).isEmpty == true)
        #expect(event.getIntegerValueField(.eventSourceUserData)
            == parrotInjectedEventMarker)

        var actualLength = 0
        var actual = [UniChar](repeating: 0, count: chunk.count)
        event.keyboardGetUnicodeString(
            maxStringLength: chunk.count,
            actualStringLength: &actualLength,
            unicodeString: &actual
        )
        #expect(actualLength == chunk.count)
        #expect(Array(actual.prefix(actualLength)) == chunk)
    }
}

@Test func clipboardFallbackKeepsTheRawTranscript() {
    let pasteboard = NSPasteboard(
        name: NSPasteboard.Name("parrot-tests-\(UUID().uuidString)")
    )
    pasteboard.clearContents()
    #expect(pasteboard.setString("prior transcript", forType: .string))
    let result = TextInjector.deliver(
        "current transcript",
        deliveryGuard: nil,
        pasteboard: pasteboard,
        currentFocusSecurity: { .nonsecure }
    )

    #expect(result == .copiedToClipboard)
    #expect(pasteboard.string(forType: .string) == "current transcript")
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
        currentFocusSecurity: {
            secureChecks += 1
            return secureChecks > 2 ? .secure : .nonsecure
        }
    )

    #expect(result == .blockedSecureField)
    #expect(secureChecks == 3)
    #expect(pasteboard.string(forType: .string) == "existing clipboard")
    pasteboard.clearContents()
}

@Test func unobservableFocusNeverPostsOrWritesTheClipboard() {
    let pasteboard = NSPasteboard(
        name: NSPasteboard.Name("parrot-unobservable-focus-tests-\(UUID().uuidString)")
    )
    pasteboard.clearContents()
    #expect(pasteboard.setString("existing clipboard", forType: .string))
    var posted = false

    let result = TextInjector.deliver(
        "sensitive transcript",
        deliveryGuard: FakeDictationDeliveryGuard(),
        pasteboard: pasteboard,
        currentFocusSecurity: { .unobservable },
        postText: { _ in
            posted = true
            return true
        }
    )

    #expect(result == .blockedUnobservableFocus)
    #expect(!posted)
    #expect(pasteboard.string(forType: .string) == "existing clipboard")
    pasteboard.clearContents()
}

@Test func eventConstructionFailureFallsBackToRawCurrentTranscript() {
    let pasteboard = NSPasteboard(
        name: NSPasteboard.Name("parrot-post-failure-tests-\(UUID().uuidString)")
    )
    pasteboard.clearContents()

    let result = TextInjector.deliver(
        "current transcript",
        deliveryGuard: FakeDictationDeliveryGuard(),
        pasteboard: pasteboard,
        currentFocusSecurity: { .nonsecure },
        postText: { _ in false }
    )

    #expect(result == .copiedToClipboard)
    #expect(pasteboard.string(forType: .string) == "current transcript")
    pasteboard.clearContents()
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

@Test func accessibilityApprovalRequiresTwoConsecutiveTrustedChecks() {
    var checks = [false, true, false, true, true]
    var pauses = 0

    let granted = waitForConsecutiveAccessibilityChecks(
        maxAttempts: checks.count,
        isTrusted: { checks.removeFirst() },
        pause: { pauses += 1 }
    )

    #expect(granted)
    #expect(checks.isEmpty)
    #expect(pauses == 4)
}

@Test func accessibilityApprovalTimesOutWithoutStableTrust() {
    var checks = [false, true, false, true]
    var pauses = 0

    let granted = waitForConsecutiveAccessibilityChecks(
        maxAttempts: checks.count,
        isTrusted: { checks.removeFirst() },
        pause: { pauses += 1 }
    )

    #expect(!granted)
    #expect(checks.isEmpty)
    #expect(pauses == 3)
}

@Test func accessibilityApprovalRejectsInvalidPollingConfiguration() {
    var checked = false
    let granted = waitForConsecutiveAccessibilityChecks(
        maxAttempts: 0,
        requiredConsecutiveChecks: 0,
        isTrusted: {
            checked = true
            return true
        },
        pause: {}
    )

    #expect(!granted)
    #expect(!checked)
}
