import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Watches a single modifier key (default: Fn) and turns raw key edges into
/// recording lifecycle events.
///
/// Two gestures drive the same `.start` / `.stop` pair, so callers never have
/// to know which one fired:
///
///   • **Push-to-talk** — press and hold past `holdThreshold`, speak, release.
///     `.start` fires immediately on key-down (zero added latency), `.stop`
///     fires on release. This is the original behavior and is always on.
///
///   • **Hands-free latch** — double-tap quickly to start a recording that
///     keeps running after you let go, then tap once more to stop. Enabled by
///     default; disable with `handsFree: false` for pure push-to-talk.
///
/// Requires Accessibility permission. If the tap fails to register, callers
/// will see an error from `start()`.
final class HotkeyMonitor {
    /// `.start` begins recording, `.stop` ends it. `.lock` is a UI-only hint
    /// that a double-tap just latched the session into hands-free mode —
    /// recording is already running and continues; callers use it to surface
    /// the "tap to stop" affordance.
    enum Event { case start, lock, stop }
    enum HotkeyError: Error { case tapCreateFailed }

    /// Mask of the modifier we treat as the hotkey. Fn = `.maskSecondaryFn`.
    private let mask: CGEventFlags
    private let debug: Bool

    // MARK: Gesture tuning

    /// Whether the double-tap-to-latch gesture is active. When false, the
    /// monitor behaves exactly like the original push-to-talk: `.start` on
    /// key-down, `.stop` on key-up, no timers.
    private let handsFree: Bool
    /// A press shorter than this counts as a "tap"; longer counts as a "hold".
    private let holdThreshold: TimeInterval
    /// Maximum gap between the two taps of a double-tap.
    private let doubleTapWindow: TimeInterval

    // MARK: CGEventTap plumbing

    private var onEvent: ((Event) -> Void)?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isPressed = false

    // MARK: Gesture state machine

    /// What the key sequence so far means. All transitions happen on the main
    /// run loop (the callback hops there), so no locking is needed.
    private enum Phase {
        case idle          // nothing happening
        case holding       // key down after starting from idle (push-to-talk)
        case firstTapWait  // one quick tap done; waiting to see if a second follows
        case secondTap     // second tap's key is currently down
        case latched       // hands-free recording; key is up, mic stays hot
    }
    private var phase: Phase = .idle
    private var pressDownTime: TimeInterval = 0
    private var tapTimeout: DispatchWorkItem?

    init(
        mask: CGEventFlags = .maskSecondaryFn,
        handsFree: Bool = true,
        holdThreshold: TimeInterval = 0.25,
        doubleTapWindow: TimeInterval = 0.4,
        debug: Bool = false
    ) {
        self.mask = mask
        self.handsFree = handsFree
        self.holdThreshold = holdThreshold
        self.doubleTapWindow = doubleTapWindow
        self.debug = debug
    }

    func start(onEvent: @escaping (Event) -> Void) throws {
        self.onEvent = onEvent

        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        if !trusted {
            FileHandle.standardError.write(Data(
                "accessibility not granted — system prompt opened. Grant access, then quit and relaunch parrot.\n".utf8
            ))
            throw HotkeyError.tapCreateFailed
        }

        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
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
        tapTimeout?.cancel()
        tapTimeout = nil
        tap = nil
        runLoopSource = nil
        onEvent = nil
    }

    /// Re-enable the tap after the system disables it (timeout / heavy input).
    /// macOS will silently kill a slow tap; without this a long hands-free
    /// session could leave parrot deaf with no indication why.
    fileprivate func reEnableTap() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        if debug {
            FileHandle.standardError.write(Data("  [debug] tap re-enabled\n".utf8))
        }
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        if debug {
            let flags = event.flags
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            FileHandle.standardError.write(
                Data(
                    "  [debug] type=\(type.rawValue) keycode=\(keycode) flags=\(String(flags.rawValue, radix: 16))\n"
                        .utf8
                ))
        }
        guard type == .flagsChanged else { return }
        let pressed = event.flags.contains(mask)
        guard pressed != isPressed else { return }
        isPressed = pressed

        // Pure push-to-talk: key-down starts, key-up stops. No gesture machine.
        guard handsFree else {
            onEvent?(pressed ? .start : .stop)
            return
        }

        // systemUptime is monotonic — immune to wall-clock changes mid-gesture.
        let now = ProcessInfo.processInfo.systemUptime
        if pressed {
            keyDown(at: now)
        } else {
            keyUp(at: now)
        }
    }

    // MARK: Gesture transitions (main run loop only)

    private func keyDown(at now: TimeInterval) {
        switch phase {
        case .idle:
            // Start recording immediately — push-to-talk latency is unchanged.
            pressDownTime = now
            phase = .holding
            onEvent?(.start)
        case .firstTapWait:
            // Second press began inside the window — a double-tap is forming.
            // Recording is still running from the first tap; keep it going.
            tapTimeout?.cancel()
            tapTimeout = nil
            pressDownTime = now
            phase = .secondTap
        case .latched:
            // A press while hands-free is the "stop" tap.
            phase = .idle
            onEvent?(.stop)
        case .holding, .secondTap:
            // A down with no intervening up — shouldn't happen; ignore.
            break
        }
    }

    private func keyUp(at now: TimeInterval) {
        switch phase {
        case .holding:
            if now - pressDownTime >= holdThreshold {
                // Genuine press-and-hold: finish and transcribe.
                phase = .idle
                onEvent?(.stop)
            } else {
                // Quick tap — could be the first of a double-tap. Keep the mic
                // hot and wait; if no second tap arrives, treat it as a hold
                // that happened to be brief and transcribe it.
                phase = .firstTapWait
                scheduleTapTimeout()
            }
        case .secondTap:
            if now - pressDownTime < holdThreshold {
                // Two quick taps → latch into hands-free. Recording continues
                // untouched; the next tap will stop it. Emit `.lock` so the UI
                // can show that we're now hands-free.
                phase = .latched
                onEvent?(.lock)
            } else {
                // The second press was actually held — behave like push-to-talk
                // and transcribe what we have.
                phase = .idle
                onEvent?(.stop)
            }
        case .idle, .firstTapWait, .latched:
            // .idle/.latched: trailing release of a stop-tap — already handled
            // on key-down. .firstTapWait: key is already up. Nothing to do.
            break
        }
    }

    private func scheduleTapTimeout() {
        tapTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.phase == .firstTapWait else { return }
            // No second tap arrived — it was a lone short press. Finish it.
            self.phase = .idle
            self.onEvent?(.stop)
        }
        tapTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapWindow, execute: work)
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
        // The system disabled our tap; re-enable it on the main loop so the
        // daemon keeps listening instead of silently going deaf.
        DispatchQueue.main.async { monitor.reEnableTap() }
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
