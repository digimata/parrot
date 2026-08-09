import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Watches a required modifier chord and emits press/release edges.
/// Requires Accessibility permission. If the tap fails to register, callers
/// will see an error from `start()`.
final class HotkeyMonitor {
    enum Event { case pressed, released, focusInteraction, tapRecoveryFailed }
    enum HotkeyError: Error { case tapCreateFailed }

    /// Dictation starts only when both Control and Fn/Globe are held.
    private let requiredFlags: CGEventFlags
    private let debug: Bool
    private var onEvent: ((Event) -> Void)?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isPressed = false
    private var waitingForPhysicalRelease = false
    private var holdWatchdog: DispatchWorkItem?
    private let maximumHoldDuration: TimeInterval

    init(
        requiredFlags: CGEventFlags = [.maskControl, .maskSecondaryFn],
        debug: Bool = false,
        maximumHoldDuration: TimeInterval = 120
    ) {
        self.requiredFlags = requiredFlags
        self.debug = debug
        self.maximumHoldDuration = maximumHoldDuration
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
        holdWatchdog?.cancel()
        holdWatchdog = nil
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
        let interruptedPress = isPressed
        isPressed = false
        waitingForPhysicalRelease = interruptedPress
        holdWatchdog?.cancel()
        holdWatchdog = nil
        CGEvent.tapEnable(tap: tap, enable: true)
        guard CGEvent.tapIsEnabled(tap: tap) else {
            if interruptedPress { onEvent?(.released) }
            FileHandle.standardError.write(Data("hotkey tap recovery failed\n".utf8))
            onEvent?(.tapRecoveryFailed)
            return
        }
        if interruptedPress {
            // The matching key-up may have been lost while the tap was disabled.
            // End the active capture now so the monitor cannot remain stuck in
            // the pressed state until Parrot is restarted.
            onEvent?(.released)
            FileHandle.standardError.write(Data(
                "hotkey tap re-enabled · interrupted recording released\n".utf8
            ))
        } else {
            FileHandle.standardError.write(Data("hotkey tap re-enabled\n".utf8))
        }
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
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
        let pressed = event.flags.contains(requiredFlags)
        if waitingForPhysicalRelease {
            if !pressed { waitingForPhysicalRelease = false }
            return
        }
        guard pressed != isPressed else { return }
        isPressed = pressed
        if pressed {
            scheduleHoldWatchdog()
        } else {
            holdWatchdog?.cancel()
            holdWatchdog = nil
        }
        onEvent?(pressed ? .pressed : .released)
    }

    private func scheduleHoldWatchdog() {
        holdWatchdog?.cancel()
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, self.isPressed else { return }
            self.isPressed = false
            self.waitingForPhysicalRelease = true
            self.holdWatchdog = nil
            FileHandle.standardError.write(Data(
                "maximum dictation hold reached · recording released\n".utf8
            ))
            self.onEvent?(.released)
        }
        holdWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + maximumHoldDuration, execute: watchdog)
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
    DispatchQueue.main.async {
        if let copy {
            monitor.handle(type: type, event: copy)
        }
    }
    return Unmanaged.passUnretained(event)
}
