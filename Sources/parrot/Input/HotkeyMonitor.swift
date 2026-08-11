import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Watches a required modifier chord and emits one toggle request per press.
/// Requires Accessibility permission. If the tap fails to register, callers
/// will see an error from `start()`.
final class HotkeyMonitor {
    enum Event {
        case toggleRequested(observedAt: Date)
        case focusInteraction
        case tapRecoveryFailed
    }
    enum HotkeyError: Error { case tapCreateFailed }

    /// Dictation toggles only when Control and Fn/Globe become held together.
    private let requiredFlags: CGEventFlags
    private let debug: Bool
    private var onEvent: ((Event) -> Void)?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var chordState = ToggleChordState()
    private var lastToggleObservedAt: Date?
    private var shortcutDuplicateAvailable = false

    init(
        requiredFlags: CGEventFlags = [.maskControl, .maskSecondaryFn],
        debug: Bool = false,
        onEvent: ((Event) -> Void)? = nil
    ) {
        self.requiredFlags = requiredFlags
        self.debug = debug
        self.onEvent = onEvent
    }

    func start(onEvent: @escaping (Event) -> Void) throws {
        self.onEvent = onEvent

        // A login service must not trigger a permission dialog on every retry.
        // `parrot setup` is the explicit, user-initiated place to request it.
        let trusted = AXIsProcessTrusted()
        if !trusted {
            FileHandle.standardError.write(Data(
                "accessibility not granted — run `parrot setup` to request it, then relaunch parrot.\n".utf8
            ))
            throw HotkeyError.tapCreateFailed
        }

        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        // .cgSessionEventTap is the right level for an accessibility-granted
        // user process (.cghidEventTap requires root).
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: hotkeyCallback,
                userInfo: userInfo
            )
        else {
            throw HotkeyError.tapCreateFailed
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        guard CGEvent.tapIsEnabled(tap: tap) else {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFMachPortInvalidate(tap)
            throw HotkeyError.tapCreateFailed
        }

        self.tap = tap
        self.runLoopSource = source
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        onEvent = nil
    }

    func reenableAfterSystemDisable() {
        // Input is unobservable while the tap is disabled. Fail closed even
        // when recovery succeeds because a click or caret move may be missing.
        onEvent?(.focusInteraction)
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        guard CGEvent.tapIsEnabled(tap: tap) else {
            FileHandle.standardError.write(Data("hotkey tap recovery failed\n".utf8))
            onEvent?(.tapRecoveryFailed)
            return
        }
        let currentFlags = CGEventSource.flagsState(.combinedSessionState)
        let chordIsStillDown = currentFlags.contains(requiredFlags)
        chordState.recoveredAfterTapDisable(isChordCurrentlyDown: chordIsStillDown)
        if chordIsStillDown {
            // Suppress all modifier noise until the interrupted physical chord
            // is released. Recording truth is independent of key-up in toggle
            // mode, so a transient tap recovery must not stop the microphone.
            FileHandle.standardError.write(Data(
                "hotkey tap re-enabled · waiting for chord release\n".utf8
            ))
        } else {
            FileHandle.standardError.write(Data("hotkey tap re-enabled\n".utf8))
        }
    }

    fileprivate func invalidateFocusForUnobservableInput() {
        onEvent?(.focusInteraction)
    }

    fileprivate func handle(type: CGEventType, event: CGEvent, observedAt: Date) {
        if debug {
            let flags = event.flags
            FileHandle.standardError.write(
                Data(
                    "  [debug] type=\(type.rawValue) flags=\(String(flags.rawValue, radix: 16))\n"
                        .utf8
                ))
        }
        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            onEvent?(.focusInteraction)
            return
        }
        if type == .keyDown {
            let sourcePID = event.getIntegerValueField(.eventSourceUnixProcessID)
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let sourceMarker = event.getIntegerValueField(.eventSourceUserData)
            let isOwnProcess = sourcePID == Int64(getpid())
            let isParrotInjected = sourceMarker == parrotInjectedEventMarker
            var unicodeLength = 0
            event.keyboardGetUnicodeString(
                maxStringLength: 0,
                actualStringLength: &unicodeLength,
                unicodeString: nil
            )
            let sessionFlags = CGEventSource.flagsState(.combinedSessionState)
            let hasShortcutModifier = event.flags.contains(.maskControl)
                || event.flags.contains(.maskSecondaryFn)
                || sessionFlags.contains(.maskControl)
                || sessionFlags.contains(.maskSecondaryFn)
            let canIgnoreShortcutDuplicate = shortcutDuplicateAvailable
            if shouldConsumeShortcutDuplicateOpportunity(
                keyCode: keyCode,
                isOwnProcess: isOwnProcess,
                isParrotInjected: isParrotInjected,
                hasShortcutModifier: hasShortcutModifier,
                unicodeCharacterCount: unicodeLength,
                canIgnoreShortcutDuplicate: canIgnoreShortcutDuplicate,
                secondsSinceToggle: lastToggleObservedAt.map {
                    observedAt.timeIntervalSince($0)
                }
            ) {
                shortcutDuplicateAvailable = false
            }
            let shouldMarkInteraction = shouldMarkFocusInteractionForKeyDown(
                keyCode: keyCode,
                isOwnProcess: isOwnProcess,
                isParrotInjected: isParrotInjected,
                hasShortcutModifier: hasShortcutModifier,
                unicodeCharacterCount: unicodeLength,
                canIgnoreShortcutDuplicate: canIgnoreShortcutDuplicate,
                secondsSinceToggle: lastToggleObservedAt.map {
                    observedAt.timeIntervalSince($0)
                }
            )
            if shouldMarkInteraction {
                onEvent?(.focusInteraction)
            }
            return
        }
        guard type == .flagsChanged else { return }
        let chordIsDown = event.flags.contains(requiredFlags)
        if chordState.update(isDown: chordIsDown) {
            lastToggleObservedAt = observedAt
            shortcutDuplicateAvailable = true
            onEvent?(.toggleRequested(observedAt: observedAt))
        }
    }
}

/// The Fn/Globe shortcut can produce a payload-free physical control keyDown
/// before its modifier edge and a payload-free duplicate immediately after it.
/// Only those control signatures are excluded from focus invalidation. Real
/// text, navigation keys, and later ordinary events remain fail-safe.
let fnGlobeVirtualKeyCode: Int64 = 63
// The built-in keyboard also emits this payload-free auxiliary Globe event.
// It is part of the physical shortcut, not text or navigation input.
let globeAuxiliaryVirtualKeyCode: Int64 = 179
let shortcutDuplicateMaximumDelay: TimeInterval = 0.2
// A per-process marker distinguishes Parrot's synthesized Unicode events from
// real user input without trusting the source PID reported by Core Graphics.
let parrotInjectedEventMarker = Int64.random(in: 1 ... Int64.max)

func shouldConsumeShortcutDuplicateOpportunity(
    keyCode: Int64,
    isOwnProcess: Bool,
    isParrotInjected: Bool,
    hasShortcutModifier: Bool = false,
    unicodeCharacterCount: Int = 1,
    canIgnoreShortcutDuplicate: Bool = true,
    secondsSinceToggle: TimeInterval? = nil
) -> Bool {
    !isOwnProcess
        && !isParrotInjected
        && !isShortcutDuplicateKeyDown(
            keyCode: keyCode,
            hasShortcutModifier: hasShortcutModifier,
            unicodeCharacterCount: unicodeCharacterCount,
            canIgnoreShortcutDuplicate: canIgnoreShortcutDuplicate,
            secondsSinceToggle: secondsSinceToggle
        )
}

func isShortcutDuplicateKeyDown(
    keyCode: Int64,
    hasShortcutModifier: Bool,
    unicodeCharacterCount: Int,
    canIgnoreShortcutDuplicate: Bool,
    secondsSinceToggle: TimeInterval?
) -> Bool {
    let isPhysicalShortcutKey = keyCode == fnGlobeVirtualKeyCode
        || keyCode == globeAuxiliaryVirtualKeyCode
    let isPhysicalShortcutControl = isPhysicalShortcutKey
        && hasShortcutModifier
        && unicodeCharacterCount == 0
    let isPostEdgeDuplicate = canIgnoreShortcutDuplicate
        && keyCode == 0
        && hasShortcutModifier
        && unicodeCharacterCount == 0
        && secondsSinceToggle.map {
            $0 >= 0 && $0 <= shortcutDuplicateMaximumDelay
        } == true
    return isPhysicalShortcutControl || isPostEdgeDuplicate
}

func shouldMarkFocusInteractionForKeyDown(
    keyCode: Int64,
    isOwnProcess: Bool,
    isParrotInjected: Bool = false,
    hasShortcutModifier: Bool = false,
    unicodeCharacterCount: Int = 1,
    canIgnoreShortcutDuplicate: Bool = true,
    secondsSinceToggle: TimeInterval? = nil
) -> Bool {
    let isShortcutDuplicate = isShortcutDuplicateKeyDown(
        keyCode: keyCode,
        hasShortcutModifier: hasShortcutModifier,
        unicodeCharacterCount: unicodeCharacterCount,
        canIgnoreShortcutDuplicate: canIgnoreShortcutDuplicate,
        secondsSinceToggle: secondsSinceToggle
    )
    return !isOwnProcess
        && !isParrotInjected
        && !isShortcutDuplicate
}

private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        // Invalidate before queueing recovery. A completed transcript must not
        // overtake the signal that some input may have been missed.
        monitor.invalidateFocusForUnobservableInput()
        DispatchQueue.main.async {
            monitor.reenableAfterSystemDisable()
        }
        return Unmanaged.passUnretained(event)
    }

    // Classify the event in the tap callback so a click or keystroke cannot sit
    // behind a completed transcript on the main queue. The caller records
    // focus invalidation immediately and queues heavier toggle work separately.
    let observedAt = Date()
    monitor.handle(type: type, event: event, observedAt: observedAt)
    return Unmanaged.passUnretained(event)
}
