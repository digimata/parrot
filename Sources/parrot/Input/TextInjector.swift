import AppKit
import CoreGraphics
import Foundation

/// Posts a string of text at the current cursor location by synthesizing
/// keyboard events with `CGEventKeyboardSetUnicodeString`. Works in nearly
/// every text field on macOS; some Electron apps and secure password fields
/// can drop characters (platform constraint).
enum TextInjector {
    enum DeliveryResult: Equatable {
        case injected(String)
        case copiedToClipboard
        case clipboardCopyFailed
        case blockedSecureField
    }

    /// Deliver text only if the field that owned focus when recording began is
    /// still focused. Otherwise keep the transcript recoverable on the system
    /// clipboard instead of typing it into an unrelated field.
    static func deliver(
        _ text: String,
        deliveryGuard: DeliveryGuard?,
        pasteboard: NSPasteboard = .general,
        prepareForInjection: (String) -> String = { $0 },
        currentFocusIsSecure: () -> Bool = { FocusSnapshot.currentFocusIsSecure() }
    ) -> DeliveryResult {
        guard !text.isEmpty else { return .injected(text) }

        // Re-check at delivery as well as capture start. A user can move into
        // a password field while recording or while inference is pending; in
        // that case the transcript must be discarded, never copied globally.
        if currentFocusIsSecure() {
            return .blockedSecureField
        }

        if deliveryGuard?.canInjectIntoOriginalFocus() == true {
            let insertionText = prepareForInjection(text)
            inject(insertionText)
            return .injected(insertionText)
        }

        let previousItems = snapshot(pasteboard)
        pasteboard.clearContents()
        if pasteboard.setString(text, forType: .string) {
            return .copiedToClipboard
        }

        // A failed clipboard write must not destroy whatever the user had
        // copied before dictation. Restore every pasteboard representation we
        // could snapshot, then report the failed transcript copy.
        pasteboard.clearContents()
        if !previousItems.isEmpty {
            _ = pasteboard.writeObjects(previousItems)
        }
        return .clipboardCopyFailed
    }

    /// Inject the given text at the current cursor location.
    /// Splits long strings into chunks because the underlying API has a
    /// per-event character limit (~20 chars).
    private static func inject(_ text: String) {
        guard !text.isEmpty else { return }

        let utf16 = Array(text.utf16)
        let chunkSize = 20
        var index = 0

        while index < utf16.count {
            let end = min(index + chunkSize, utf16.count)
            var chunk = Array(utf16[index..<end])
            postChunk(&chunk)
            index = end
        }
    }

    private static func postChunk(_ chunk: inout [UniChar]) {
        let length = chunk.count
        guard length > 0 else { return }

        let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
        down?.setIntegerValueField(.eventSourceUserData, value: parrotInjectedEventMarker)
        down?.keyboardSetUnicodeString(stringLength: length, unicodeString: &chunk)
        down?.post(tap: .cgSessionEventTap)

        let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        up?.setIntegerValueField(.eventSourceUserData, value: parrotInjectedEventMarker)
        up?.keyboardSetUnicodeString(stringLength: length, unicodeString: &chunk)
        up?.post(tap: .cgSessionEventTap)
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }
}

/// Adds only the separator needed to continue a prior Parrot insertion. It
/// does not otherwise rewrite model output or add spaces around punctuation.
func textWithNaturalDictationBoundary(
    _ text: String,
    previousTrailingCharacter: Character?
) -> String {
    guard
        let previousTrailingCharacter,
        let firstCharacter = text.first,
        !previousTrailingCharacter.isWhitespace,
        !firstCharacter.isWhitespace,
        !".,!?;:%)]}…’”".contains(firstCharacter),
        !"([{‘“".contains(previousTrailingCharacter)
    else {
        return text
    }
    return " " + text
}

/// Remembers only Parrot's last successful direct insertion. Any real keyboard
/// or pointer interaction clears this state before a later transcript arrives.
final class DictationContinuationState {
    private var previousGuard: DeliveryGuard?
    private var previousTrailingCharacter: Character?

    func textForInsertion(_ text: String, using currentGuard: DeliveryGuard) -> String {
        guard
            let previousGuard,
            currentGuard.sharesOriginalFocus(with: previousGuard)
        else {
            return text
        }
        return textWithNaturalDictationBoundary(
            text,
            previousTrailingCharacter: previousTrailingCharacter
        )
    }

    func recordSuccessfulInsertion(_ text: String, using deliveryGuard: DeliveryGuard) {
        previousGuard = deliveryGuard
        previousTrailingCharacter = text.last
    }

    func clear() {
        previousGuard = nil
        previousTrailingCharacter = nil
    }
}
