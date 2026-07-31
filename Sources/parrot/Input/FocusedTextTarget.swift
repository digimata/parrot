import ApplicationServices
import Foundation

enum FocusedTextTarget {
    static var isEditable: Bool {
        let system = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success, let focusedValue else {
            return false
        }

        let focused = focusedValue as! AXUIElement
        if isSecureTextElement(focused) {
            return false
        }
        if isEditableElement(focused) || hasEditableAncestor(focused) {
            return true
        }
        var remainingNodes = 96
        return containsEditableDescendant(
            focused,
            remainingDepth: 4,
            remainingNodes: &remainingNodes
        )
    }

    private static func isEditableElement(_ element: AXUIElement) -> Bool {
        let role = stringAttribute(kAXRoleAttribute, of: element)
        let subrole = stringAttribute(kAXSubroleAttribute, of: element)

        if subrole == kAXSecureTextFieldSubrole as String {
            return false
        }

        let editableRoles = [
            kAXTextAreaRole as String,
            kAXTextFieldRole as String,
            kAXComboBoxRole as String,
        ]
        if let role, editableRoles.contains(role)
            || subrole == kAXSearchFieldSubrole as String {
            return true
        }

        if isSettable(kAXSelectedTextAttribute, on: element)
            || isSettable(kAXSelectedTextRangeAttribute, on: element) {
            return true
        }

        let roleDescription = stringAttribute(kAXRoleDescriptionAttribute, of: element)?
            .lowercased()
        return roleDescription?.contains("text") == true
            && isSettable(kAXValueAttribute, on: element)
    }

    private static func isSecureTextElement(_ element: AXUIElement) -> Bool {
        stringAttribute(kAXSubroleAttribute, of: element)
            == kAXSecureTextFieldSubrole as String
    }

    private static func hasEditableAncestor(_ element: AXUIElement) -> Bool {
        var current = element
        for _ in 0..<6 {
            guard let parent = elementAttribute(kAXParentAttribute, of: current) else {
                return false
            }
            if isSecureTextElement(parent) {
                return false
            }
            if isEditableElement(parent) {
                return true
            }
            current = parent
        }
        return false
    }

    private static func containsEditableDescendant(
        _ element: AXUIElement,
        remainingDepth: Int,
        remainingNodes: inout Int
    ) -> Bool {
        guard remainingDepth > 0, remainingNodes > 0 else { return false }

        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &childrenValue
        ) == .success, let children = childrenValue as? [AXUIElement] else {
            return false
        }

        for child in children {
            guard remainingNodes > 0 else { return false }
            remainingNodes -= 1
            if isSecureTextElement(child) {
                continue
            }
            if boolAttribute(kAXFocusedAttribute, of: child) == true
                && isEditableElement(child)
                || containsEditableDescendant(
                    child,
                    remainingDepth: remainingDepth - 1,
                    remainingNodes: &remainingNodes
                ) {
                return true
            }
        }
        return false
    }

    private static func boolAttribute(
        _ attribute: String,
        of element: AXUIElement
    ) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success else {
            return nil
        }
        return value as? Bool
    }

    private static func isSettable(
        _ attribute: String,
        on element: AXUIElement
    ) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(
            element,
            attribute as CFString,
            &settable
        ) == .success && settable.boolValue
    }

    private static func elementAttribute(
        _ attribute: String,
        of element: AXUIElement
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success, let value else {
            return nil
        }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private static func stringAttribute(
        _ attribute: String,
        of element: AXUIElement
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success else {
            return nil
        }
        return value as? String
    }
}
