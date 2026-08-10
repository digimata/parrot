import AppKit
import ApplicationServices
import Foundation

enum FocusCaptureError: Error {
    case secureField
}

struct EditableSelectionSnapshot {
    let range: CFRange
}

/// Identifies the app and accessibility element that owned keyboard focus when
/// dictation started. Parrot uses this to avoid inserting a finished transcript
/// into a different field if the user clicks away while recording or while the
/// speech model is still transcribing.
struct FocusSnapshot {
    private let applicationPID: pid_t
    private let element: AXUIElement?
    private let capturedSelection: EditableSelectionSnapshot?

    static func capture() throws -> FocusSnapshot? {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let rawElement = focusedElement(requiringEditable: false)
        if let rawElement, isSecureTextElement(rawElement) {
            throw FocusCaptureError.secureField
        }

        let editableElement = rawElement.flatMap {
            isSpecificEditableElement($0) ? $0 : nil
        }
        return FocusSnapshot(
            applicationPID: application.processIdentifier,
            element: editableElement,
            capturedSelection: editableElement.flatMap {
                selectedTextRange(of: $0).map(EditableSelectionSnapshot.init)
            }
        )
    }

    func stillOwnsFocus() -> Bool {
        guard
            let application = NSWorkspace.shared.frontmostApplication,
            application.processIdentifier == applicationPID
        else {
            return false
        }

        // If the original control is unavailable, there is no reliable way to
        // prove that focus stayed in the same field. Fail closed to clipboard;
        // the frontmost app alone is not enough because Tab or app code can move
        // focus without changing applications.
        guard let element else { return false }
        guard let currentElement = Self.focusedElement(requiringEditable: true) else {
            return false
        }
        return CFEqual(element, currentElement)
    }

    func identifiesSameEditableElement(as other: FocusSnapshot) -> Bool {
        guard applicationPID == other.applicationPID else { return false }
        guard let element, let otherElement = other.element else { return false }
        return CFEqual(element, otherElement)
    }

    func editableSelectionSnapshot() -> EditableSelectionSnapshot? {
        guard let element else { return nil }
        guard let range = Self.selectedTextRange(of: element) else { return nil }
        return EditableSelectionSnapshot(range: range)
    }

    func restoreCapturedSelection() -> Bool {
        // An editable element without a readable capture-time selection cannot
        // prove where the user intended the transcript to land.
        guard let capturedSelection else { return false }
        return restoreSelection(capturedSelection.range)
    }

    func restoreCaret(toUTF16Location targetLocation: Int) -> Bool {
        restoreSelection(CFRange(location: targetLocation, length: 0))
    }

    private func restoreSelection(_ targetRange: CFRange) -> Bool {
        guard let element else { return false }
        guard targetRange.location >= 0, targetRange.length >= 0 else { return false }
        guard
            let characterCount = Self.numberOfCharacters(of: element),
            targetRange.location <= characterCount,
            targetRange.length <= characterCount - targetRange.location
        else {
            return false
        }

        if Self.selection(of: element, equals: targetRange) {
            return true
        }

        // AXSelectedTextRange is writable for editable text elements. Setting
        // a collapsed range avoids mapping UTF-16 offsets to arrow presses,
        // which is incorrect for emoji, combining marks, and active selections.
        if Self.setSelectedTextRange(
            targetRange,
            of: element
        ), Self.selection(of: element, equals: targetRange) {
            return true
        }

        // Some Chromium content-editables expose AXSelectedTextRange but reject
        // writes. At the verified end of an AXTextArea, one bounded navigation
        // event is deterministic enough to retry. Readback is mandatory; other
        // roles and mid-field positions fail closed to clipboard.
        guard
            targetRange.length == 0,
            targetRange.location == characterCount,
            Self.role(of: element) == (kAXTextAreaRole as String),
            stillOwnsFocus()
        else {
            return false
        }
        Self.postNavigationKey(keyCode: 125, flags: [.maskCommand])
        for _ in 0 ..< 10 {
            if Self.selection(of: element, equals: targetRange) {
                // Let the target app finish processing the navigation event
                // before Parrot posts the next Unicode chunk.
                Thread.sleep(forTimeInterval: 0.03)
                return Self.selection(of: element, equals: targetRange)
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
    }

    static func currentFocusIsSecure() -> Bool {
        guard let element = focusedElement(requiringEditable: false) else {
            return false
        }
        return isSecureTextElement(element)
    }

    private static func focusedElement(requiringEditable: Bool) -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &value
        )

        guard
            status == .success,
            let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }

        let element = value as! AXUIElement
        if requiringEditable {
            return isSpecificEditableElement(element) && !isSecureTextElement(element)
                ? element
                : nil
        }
        return element
    }

    private static func isSecureTextElement(_ element: AXUIElement) -> Bool {
        var subroleValue: CFTypeRef?
        let subroleStatus = AXUIElementCopyAttributeValue(
            element,
            kAXSubroleAttribute as CFString,
            &subroleValue
        )
        return subroleStatus == .success
            && (subroleValue as? String) == (kAXSecureTextFieldSubrole as String)
    }

    private static func isSpecificEditableElement(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &value
        )
        guard status == .success, let role = value as? String else { return false }
        return role == (kAXTextFieldRole as String)
            || role == (kAXTextAreaRole as String)
            || role == (kAXComboBoxRole as String)
    }

    private static func selectedTextRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        )
        guard status == .success, let value else { return nil }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let rangeValue = value as! AXValue
        guard AXValueGetType(rangeValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range) else { return nil }
        return range
    }

    private static func numberOfCharacters(of element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element,
            kAXNumberOfCharactersAttribute as CFString,
            &value
        )
        guard status == .success else { return nil }
        return value as? Int
    }

    private static func role(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &value
        )
        guard status == .success else { return nil }
        return value as? String
    }

    private static func setSelectedTextRange(
        _ range: CFRange,
        of element: AXUIElement
    ) -> Bool {
        var mutableRange = range
        guard let value = AXValueCreate(.cfRange, &mutableRange) else {
            return false
        }
        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            value
        ) == .success
    }

    private static func selection(
        of element: AXUIElement,
        equals expectedRange: CFRange
    ) -> Bool {
        guard let range = selectedTextRange(of: element) else { return false }
        return range.location == expectedRange.location
            && range.length == expectedRange.length
    }

    private static func postNavigationKey(
        keyCode: CGKeyCode,
        flags: CGEventFlags
    ) {
        let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)
        down?.flags = flags
        down?.setIntegerValueField(.eventSourceUserData, value: parrotInjectedEventMarker)
        down?.post(tap: .cgSessionEventTap)

        let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        // Release the modifier with the navigation key. Keeping Command on the
        // key-up leaves Chromium treating the following Unicode event as a
        // command shortcut, so the transcript is silently dropped.
        up?.flags = []
        up?.setIntegerValueField(.eventSourceUserData, value: parrotInjectedEventMarker)
        up?.post(tap: .cgSessionEventTap)
    }
}

func caretRangeAfterInsertion(replacing range: CFRange, insertedText: String) -> CFRange {
    CFRange(location: range.location + insertedText.utf16.count, length: 0)
}

/// Mutable, per-dictation delivery state. Pointer and keyboard interactions are
/// treated as fail-safe focus changes while transcription is pending.
final class DeliveryGuard {
    private let originalFocus: FocusSnapshot?
    let uiGeneration: UInt64
    private(set) var observedPointerInteraction = false
    private var expectedCaretUTF16Location: Int?

    init(originalFocus: FocusSnapshot?, uiGeneration: UInt64) {
        self.originalFocus = originalFocus
        self.uiGeneration = uiGeneration
    }

    func notePointerInteraction() {
        observedPointerInteraction = true
    }

    func canInjectIntoOriginalFocus() -> Bool {
        return !observedPointerInteraction && originalFocus?.stillOwnsFocus() == true
    }

    func editableSelectionSnapshot() -> EditableSelectionSnapshot? {
        originalFocus?.editableSelectionSnapshot()
    }

    func restoreCapturedSelection() -> Bool {
        guard !observedPointerInteraction else { return false }
        return originalFocus?.restoreCapturedSelection() == true
    }

    func recordExpectedCaretAfterInsertion(
        _ text: String,
        replacing selection: EditableSelectionSnapshot?
    ) {
        guard let selection else {
            expectedCaretUTF16Location = nil
            return
        }
        expectedCaretUTF16Location = caretRangeAfterInsertion(
            replacing: selection.range,
            insertedText: text
        ).location
    }

    func restoreExpectedCaret() -> Bool {
        guard !observedPointerInteraction else { return false }
        guard let expectedCaretUTF16Location else { return false }
        return originalFocus?.restoreCaret(
            toUTF16Location: expectedCaretUTF16Location
        ) == true
    }

    func sharesOriginalFocus(with other: DeliveryGuard) -> Bool {
        guard let originalFocus, let otherFocus = other.originalFocus else { return false }
        return originalFocus.identifiesSameEditableElement(as: otherFocus)
    }
}

/// Keeps overlapping recording/transcription deliveries independent. A new
/// recording can begin while the previous one is still transcribing, so every
/// pending transcript must observe later pointer interactions until delivery.
final class DeliveryGuardStore {
    private var current: DeliveryGuard?
    private var pending = [DeliveryGuard]()

    func begin(_ guardToTrack: DeliveryGuard) {
        current = guardToTrack
        pending.append(guardToTrack)
    }

    func releaseCurrent() -> DeliveryGuard? {
        defer { current = nil }
        return current
    }

    func notePointerInteraction() {
        pending.forEach { $0.notePointerInteraction() }
    }

    func remove(_ guardToRemove: DeliveryGuard?) {
        guard let guardToRemove else { return }
        pending.removeAll { $0 === guardToRemove }
    }
}

/// Thread-safe interaction ordering for UI state. Transcription tasks complete
/// asynchronously, so an older result must never clear a newer recording or
/// error indicator.
final class InteractionGenerationStore: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: UInt64 = 0

    func advance() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        latest &+= 1
        return latest
    }

    func isLatest(_ generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == latest
    }
}
