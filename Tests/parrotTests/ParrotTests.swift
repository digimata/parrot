import Foundation
import Testing
@testable import parrot

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
