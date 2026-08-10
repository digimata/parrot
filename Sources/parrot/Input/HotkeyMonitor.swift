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

    init(
        requiredFlags: CGEventFlags = [.maskControl, .maskSecondaryFn],
        debug: Bool = false
    ) {
        self.requiredFlags = requiredFlags
        self.debug = debug
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

    fileprivate func reenableAfterSystemDisable() {
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
            if sourcePID != Int64(getpid()) {
                onEvent?(.focusInteraction)
            }
            return
        }
        guard type == .flagsChanged else { return }
        let chordIsDown = event.flags.contains(requiredFlags)
        if chordState.update(isDown: chordIsDown) {
            onEvent?(.toggleRequested(observedAt: observedAt))
        }
    }
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
        DispatchQueue.main.async {
            monitor.reenableAfterSystemDisable()
        }
        return Unmanaged.passUnretained(event)
    }

    let copy = event.copy()
    // Capture observation time in the event-tap callback, before main-queue
    // work such as stopping and converting a long recording can delay handling.
    let observedAt = Date()
    DispatchQueue.main.async {
        if let copy {
            monitor.handle(type: type, event: copy, observedAt: observedAt)
        }
    }
    return Unmanaged.passUnretained(event)
}
