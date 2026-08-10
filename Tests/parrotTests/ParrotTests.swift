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
