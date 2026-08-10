import AppKit
import ApplicationServices
import Foundation

enum FocusCaptureError: Error {
    case secureField
}

/// Identifies the app and accessibility element that owned keyboard focus when
/// dictation started. Parrot uses this to avoid inserting a finished transcript
/// into a different field if the user clicks away while recording or while the
/// speech model is still transcribing.
struct FocusSnapshot {
    private let applicationPID: pid_t
    private let element: AXUIElement?

    static func capture() throws -> FocusSnapshot? {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let rawElement = focusedElement(requiringEditable: false)
        if let rawElement, isSecureTextElement(rawElement) {
            throw FocusCaptureError.secureField
        }

        return FocusSnapshot(
            applicationPID: application.processIdentifier,
            element: rawElement.flatMap { isSpecificEditableElement($0) ? $0 : nil }
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
}

/// Mutable, per-dictation delivery state. Pointer and keyboard interactions are
/// treated as fail-safe focus changes while transcription is pending.
final class DeliveryGuard {
    private let originalFocus: FocusSnapshot?
    let uiGeneration: UInt64
    private(set) var observedPointerInteraction = false

    init(originalFocus: FocusSnapshot?, uiGeneration: UInt64) {
        self.originalFocus = originalFocus
        self.uiGeneration = uiGeneration
    }

    func notePointerInteraction() {
        observedPointerInteraction = true
    }

    func canInjectIntoOriginalFocus() -> Bool {
        !observedPointerInteraction && originalFocus?.stillOwnsFocus() == true
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
