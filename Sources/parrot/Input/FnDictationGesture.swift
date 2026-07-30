import Foundation

/// Turns raw Fn press/release edges into push-to-talk or locked-dictation
/// actions. The state machine is deliberately independent from audio and UI so
/// every timing edge can be tested without installing an event tap.
struct FnDictationGesture {
    enum Input {
        case pressed(at: TimeInterval)
        case released(at: TimeInterval)
        case secondTapTimedOut
    }

    enum Action: Equatable {
        case startRecording
        case stopRecording
        case showLocked
        case scheduleSecondTapTimeout(after: TimeInterval)
        case cancelSecondTapTimeout
    }

    private enum Phase {
        case idle
        case firstPress(startedAt: TimeInterval)
        case awaitingSecondTap
        case lockCandidatePress(startedAt: TimeInterval)
        case locked
        case stopPressHeld
    }

    private(set) var isLocked = false
    private var phase: Phase = .idle
    let quickTapMaximumDuration: TimeInterval
    let doubleTapInterval: TimeInterval

    init(
        quickTapMaximumDuration: TimeInterval = 0.30,
        doubleTapInterval: TimeInterval = 0.40
    ) {
        self.quickTapMaximumDuration = quickTapMaximumDuration
        self.doubleTapInterval = doubleTapInterval
    }

    mutating func handle(_ input: Input) -> [Action] {
        switch (phase, input) {
        case (.idle, let .pressed(time)):
            phase = .firstPress(startedAt: time)
            return [.startRecording]

        case (let .firstPress(startedAt), let .released(time)):
            if time - startedAt <= quickTapMaximumDuration {
                phase = .awaitingSecondTap
                return [.scheduleSecondTapTimeout(after: doubleTapInterval)]
            }
            phase = .idle
            return [.stopRecording]

        case (.awaitingSecondTap, let .pressed(time)):
            phase = .lockCandidatePress(startedAt: time)
            return [.cancelSecondTapTimeout]

        case (.awaitingSecondTap, .secondTapTimedOut):
            phase = .idle
            return [.stopRecording]

        case (let .lockCandidatePress(startedAt), let .released(time)):
            if time - startedAt <= quickTapMaximumDuration {
                phase = .locked
                isLocked = true
                return [.showLocked]
            }
            phase = .idle
            return [.stopRecording]

        case (.locked, .pressed):
            phase = .stopPressHeld
            return []

        case (.stopPressHeld, .released):
            phase = .idle
            isLocked = false
            return [.stopRecording]

        default:
            // Duplicate edges and cancelled timeout callbacks are harmless.
            return []
        }
    }

    mutating func reset() {
        phase = .idle
        isLocked = false
    }

    var hasActiveRecording: Bool {
        if case .idle = phase { return false }
        return true
    }
}

/// Main-thread runtime wrapper responsible only for the double-tap timer and
/// dispatching state-machine actions to the recording session.
@MainActor
final class FnDictationGestureController {
    private var gesture: FnDictationGesture
    private var timeoutWorkItem: DispatchWorkItem?
    private let startRecording: () -> Bool
    private let stopRecording: () -> Void
    private let showLocked: () -> Void

    init(
        doubleTapInterval: TimeInterval,
        startRecording: @escaping () -> Bool,
        stopRecording: @escaping () -> Void,
        showLocked: @escaping () -> Void
    ) {
        gesture = FnDictationGesture(doubleTapInterval: doubleTapInterval)
        self.startRecording = startRecording
        self.stopRecording = stopRecording
        self.showLocked = showLocked
    }

    func handle(_ event: HotkeyMonitor.Event) {
        if case .interrupted = event {
            let shouldStop = gesture.hasActiveRecording
            cancel()
            if shouldStop {
                stopRecording()
            }
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        let input: FnDictationGesture.Input = switch event {
        case .pressed: .pressed(at: now)
        case .released: .released(at: now)
        case .interrupted: fatalError("handled above")
        }
        perform(gesture.handle(input))
    }

    func cancel() {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        gesture.reset()
    }

    private func perform(_ actions: [FnDictationGesture.Action]) {
        for action in actions {
            switch action {
            case .startRecording:
                if !startRecording() {
                    cancel()
                }
            case .stopRecording:
                timeoutWorkItem?.cancel()
                timeoutWorkItem = nil
                stopRecording()
            case .showLocked:
                showLocked()
            case let .scheduleSecondTapTimeout(delay):
                timeoutWorkItem?.cancel()
                let workItem = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.timeoutWorkItem = nil
                    self.perform(self.gesture.handle(.secondTapTimedOut))
                }
                timeoutWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
            case .cancelSecondTapTimeout:
                timeoutWorkItem?.cancel()
                timeoutWorkItem = nil
            }
        }
    }
}
