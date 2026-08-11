import AppKit
import CoreGraphics
import Foundation

protocol DictationDeliveryGuard: AnyObject {
    func canInjectIntoOriginalFocus() -> Bool
}

/// Posts a string of text at the current cursor location by synthesizing
/// keyboard events with CGEventKeyboardSetUnicodeString.
enum TextInjector {
    enum DeliveryResult: Equatable {
        case sentUnconfirmed(String)
        case copiedToClipboard
        case clipboardCopyFailed
        case blockedSecureField
        case blockedUnobservableFocus
    }

    /// Deliver only the current transcript, and only while the editable element
    /// captured at recording start still owns focus. Interaction history may
    /// invalidate that target, but no prior transcript or predicted caret can
    /// influence this attempt.
    static func deliver(
        _ text: String,
        deliveryGuard: (any DictationDeliveryGuard)?,
        pasteboard: NSPasteboard = .general,
        currentFocusSecurity: () -> FocusSecurityStatus = {
            FocusSnapshot.currentFocusSecurity()
        },
        postText: (String) -> Bool = { inject($0) }
    ) -> DeliveryResult {
        guard !text.isEmpty else { return .sentUnconfirmed(text) }

        // A transcript captured from or delivered into a secure field must
        // never reach either synthesized input or the global clipboard.
        if let blocked = blockedResult(for: currentFocusSecurity()) {
            return blocked
        }

        if deliveryGuard?.canInjectIntoOriginalFocus() == true {
            let insertionText = textWithIndependentDictationBoundary(text)
            // Accessibility and event delivery can race a focus change. Check
            // both predicates immediately before posting global text events.
            if let blocked = blockedResult(for: currentFocusSecurity()) {
                return blocked
            }
            if deliveryGuard?.canInjectIntoOriginalFocus() == true {
                if postText(insertionText) {
                    // CGEvent posting has no target receipt. This result means
                    // the complete event batch was constructed and sent.
                    return .sentUnconfirmed(insertionText)
                }
            }
        }

        if let blocked = blockedResult(for: currentFocusSecurity()) {
            return blocked
        }

        return copyToPasteboard(
            text,
            pasteboard: pasteboard,
            currentFocusSecurity: currentFocusSecurity
        )
    }

    private static func copyToPasteboard(
        _ text: String,
        pasteboard: NSPasteboard,
        currentFocusSecurity: () -> FocusSecurityStatus
    ) -> DeliveryResult {
        let previousItems = snapshot(pasteboard)
        if let blocked = blockedResult(for: currentFocusSecurity()) {
            return blocked
        }

        pasteboard.clearContents()
        if pasteboard.setString(text, forType: .string) {
            return .copiedToClipboard
        }

        // A failed clipboard write must not destroy whatever the user had
        // copied before dictation.
        pasteboard.clearContents()
        if !previousItems.isEmpty {
            _ = pasteboard.writeObjects(previousItems)
        }
        return .clipboardCopyFailed
    }

    private static func blockedResult(
        for status: FocusSecurityStatus
    ) -> DeliveryResult? {
        switch status {
        case .nonsecure:
            return nil
        case .secure:
            return .blockedSecureField
        case .unobservable:
            return .blockedUnobservableFocus
        }
    }

    /// Split long strings because Core Graphics limits Unicode payload size.
    private static func inject(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }

        let utf16 = Array(text.utf16)
        let chunkSize = 20
        var index = 0
        var eventPairs = [(CGEvent, CGEvent)]()

        while index < utf16.count {
            let end = min(index + chunkSize, utf16.count)
            guard let pair = makeInjectionEventPair(
                chunk: Array(utf16[index ..< end])
            ) else {
                return false
            }
            eventPairs.append(pair)
            index = end
        }

        for (keyDown, keyUp) in eventPairs {
            keyDown.post(tap: .cgSessionEventTap)
            keyUp.post(tap: .cgSessionEventTap)
        }
        return true
    }

    /// A private event source plus explicit empty flags prevents a stop chord
    /// that is still physically held from leaking Control/Fn modifiers into
    /// the transcript events.
    static func makeInjectionEventPair(chunk: [UniChar]) -> (CGEvent, CGEvent)? {
        guard let source = CGEventSource(stateID: .privateState) else { return nil }
        guard
            let keyDown = makeInjectionEvent(chunk: chunk, keyDown: true, source: source),
            let keyUp = makeInjectionEvent(chunk: chunk, keyDown: false, source: source)
        else {
            return nil
        }
        return (keyDown, keyUp)
    }

    static func makeInjectionEvent(
        chunk: [UniChar],
        keyDown: Bool,
        source: CGEventSource? = nil
    ) -> CGEvent? {
        let eventSource = source ?? CGEventSource(stateID: .privateState)
        let event = CGEvent(
            keyboardEventSource: eventSource,
            virtualKey: 0,
            keyDown: keyDown
        )
        event?.flags = []
        event?.setIntegerValueField(
            .eventSourceUserData,
            value: parrotInjectedEventMarker
        )
        var mutableChunk = chunk
        event?.keyboardSetUnicodeString(
            stringLength: mutableChunk.count,
            unicodeString: &mutableChunk
        )
        return event
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

/// Each capture owns its own separator. No previous transcript, caret, or
/// delivery receipt is retained between recordings.
func textWithIndependentDictationBoundary(_ text: String) -> String {
    guard text.last?.isWhitespace == false else { return text }
    return text + " "
}
