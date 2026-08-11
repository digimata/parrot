import AppKit
import ApplicationServices
import Foundation

enum FocusCaptureError: Error {
    case secureField
    case unobservableFocus
}

enum FocusSecurityStatus: Equatable {
    case nonsecure
    case secure
    case unobservable
}

func focusSecurityStatusForSubroleLookup(
    status: AXError,
    subrole: String?,
    valueWasPresent: Bool
) -> FocusSecurityStatus {
    if status == .attributeUnsupported || status == .noValue {
        return .nonsecure
    }
    guard status == .success else { return .unobservable }
    guard valueWasPresent else { return .unobservable }
    guard let subrole else { return .unobservable }
    return subrole == (kAXSecureTextFieldSubrole as String) ? .secure : .nonsecure
}

func focusSecurityStatusForProtectedContentLookup(
    status: AXError,
    containsProtectedContent: Bool?,
    valueWasPresent: Bool
) -> FocusSecurityStatus {
    if status == .attributeUnsupported || status == .noValue {
        return .nonsecure
    }
    guard status == .success else { return .unobservable }
    guard valueWasPresent, let containsProtectedContent else { return .unobservable }
    return containsProtectedContent ? .secure : .nonsecure
}

func combinedFocusSecurityStatus(
    _ first: FocusSecurityStatus,
    _ second: FocusSecurityStatus
) -> FocusSecurityStatus {
    if first == .secure || second == .secure { return .secure }
    if first == .unobservable || second == .unobservable { return .unobservable }
    return .nonsecure
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

        let rawElement: AXUIElement?
        switch observeFocusedElement() {
        case .element(let element):
            rawElement = element
        case .none:
            rawElement = nil
        case .unobservable:
            throw FocusCaptureError.unobservableFocus
        }

        if let rawElement {
            switch securityStatus(of: rawElement) {
            case .nonsecure:
                break
            case .secure:
                throw FocusCaptureError.secureField
            case .unobservable:
                throw FocusCaptureError.unobservableFocus
            }
        }

        let editableElement = rawElement.flatMap {
            isSpecificEditableElement($0) ? $0 : nil
        }
        return FocusSnapshot(
            applicationPID: application.processIdentifier,
            element: editableElement
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
        guard case .element(let currentElement) = Self.observeFocusedElement() else {
            return false
        }
        guard Self.securityStatus(of: currentElement) == .nonsecure else { return false }
        guard Self.isSpecificEditableElement(currentElement) else { return false }
        return CFEqual(element, currentElement)
    }

    static func currentFocusSecurity() -> FocusSecurityStatus {
        switch observeFocusedElement() {
        case .element(let element):
            return securityStatus(of: element)
        case .none:
            return .nonsecure
        case .unobservable:
            return .unobservable
        }
    }

    private enum FocusedElementObservation {
        case element(AXUIElement)
        case none
        case unobservable
    }

    private static func observeFocusedElement() -> FocusedElementObservation {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &value
        )

        if status == .noValue {
            return .none
        }
        guard status == .success else {
            return .unobservable
        }
        guard let value else { return .unobservable }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return .unobservable
        }
        return .element(value as! AXUIElement)
    }

    private static func securityStatus(of element: AXUIElement) -> FocusSecurityStatus {
        var subroleValue: CFTypeRef?
        let subroleStatus = AXUIElementCopyAttributeValue(
            element,
            kAXSubroleAttribute as CFString,
            &subroleValue
        )
        let subroleSecurity = focusSecurityStatusForSubroleLookup(
            status: subroleStatus,
            subrole: subroleValue as? String,
            valueWasPresent: subroleValue != nil
        )

        var protectedValue: CFTypeRef?
        let protectedStatus = AXUIElementCopyAttributeValue(
            element,
            NSAccessibility.Attribute.containsProtectedContent.rawValue as CFString,
            &protectedValue
        )
        let protectedSecurity = focusSecurityStatusForProtectedContentLookup(
            status: protectedStatus,
            containsProtectedContent: (protectedValue as? NSNumber)?.boolValue,
            valueWasPresent: protectedValue != nil
        )
        return combinedFocusSecurityStatus(subroleSecurity, protectedSecurity)
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
final class DeliveryGuard: DictationDeliveryGuard {
    private let originalFocus: FocusSnapshot?
    let uiGeneration: UInt64
    private let interactionLock = NSLock()
    private var observedPointerInteraction = false

    init(originalFocus: FocusSnapshot?, uiGeneration: UInt64) {
        self.originalFocus = originalFocus
        self.uiGeneration = uiGeneration
    }

    func notePointerInteraction() {
        interactionLock.lock()
        observedPointerInteraction = true
        interactionLock.unlock()
    }

    func canInjectIntoOriginalFocus() -> Bool {
        interactionLock.lock()
        let interactionWasObserved = observedPointerInteraction
        interactionLock.unlock()
        return !interactionWasObserved && originalFocus?.stillOwnsFocus() == true
    }

}

/// Keeps overlapping recording/transcription deliveries independent. A new
/// recording can begin while the previous one is still transcribing, so every
/// pending transcript must observe later pointer interactions until delivery.
final class DeliveryGuardStore {
    private let lock = NSLock()
    private var current: DeliveryGuard?
    private var pending = [DeliveryGuard]()

    func begin(_ guardToTrack: DeliveryGuard) {
        lock.lock()
        defer { lock.unlock() }
        current = guardToTrack
        pending.append(guardToTrack)
    }

    func releaseCurrent() -> DeliveryGuard? {
        lock.lock()
        defer { lock.unlock() }
        defer { current = nil }
        return current
    }

    func notePointerInteraction() {
        lock.lock()
        let guards = pending
        lock.unlock()
        guards.forEach { $0.notePointerInteraction() }
    }

    func remove(_ guardToRemove: DeliveryGuard?) {
        guard let guardToRemove else { return }
        lock.lock()
        defer { lock.unlock() }
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
