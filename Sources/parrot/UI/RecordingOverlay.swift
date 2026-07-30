import AppKit
import SwiftUI

/// Borderless, click-through pill near the bottom of the active screen.
/// Driven by the daemon's hotkey + transcription lifecycle.
@MainActor
final class RecordingOverlay {
    enum State: Equatable {
        case hidden
        case recording
        case locked
        case transcribing
    }

    private var window: NSPanel?
    private var pendingHide: DispatchWorkItem?
    private let model = OverlayModel()

    func show(_ state: State) {
        pendingHide?.cancel()
        pendingHide = nil
        ensureWindow()
        if state == .recording {
            model.resetLevels()
        }
        guard let window else { return }
        let needsAppear = !window.isVisible
        if needsAppear {
            positionAtBottomCenter(window)
            window.orderFrontRegardless()
            // Defer the state change so SwiftUI lays out in the .hidden style
            // first, then animates to the visible style on the next runloop tick.
            DispatchQueue.main.async { [model] in
                model.state = state
            }
        } else {
            model.state = state
        }
    }

    func hide() {
        pendingHide?.cancel()
        model.state = .hidden
        // Let the SwiftUI scale+fade animation play out before yanking the
        // window — otherwise it just pops away.
        let window = self.window
        let workItem = DispatchWorkItem { [weak self] in
            window?.orderOut(nil)
            self?.pendingHide = nil
        }
        pendingHide = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
    }

    /// Push a new audio level (0…~1). Safe to call from any thread.
    nonisolated func pushLevel(_ level: Float) {
        Task { @MainActor in
            self.model.pushLevel(level)
        }
    }

    private func ensureWindow() {
        if window != nil { return }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 112, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false

        let host = NSHostingView(rootView: OverlayPill(model: model))
        host.frame = panel.contentView?.bounds ?? .zero
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        window = panel
    }

    private func positionAtBottomCenter(_ window: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = window.frame
        let visible = screen.visibleFrame
        let x = visible.midX - frame.width / 2
        let y = visible.minY + 32
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// Observable state for the SwiftUI pill.
@MainActor
final class OverlayModel: ObservableObject {
    static let barCount = 6
    /// Per-bar height multiplier — center bars peak higher than edge bars.
    private static let envelope: [Float] = [0.55, 0.85, 1.0, 1.0, 0.85, 0.55]

    @Published var state: RecordingOverlay.State = .hidden
    @Published var levels: [Float] = Array(repeating: 0, count: barCount)

    func pushLevel(_ level: Float) {
        let shaped = min(1.0, sqrt(max(0, level)) * 3.4)
        var next = [Float]()
        next.reserveCapacity(Self.barCount)
        for i in 0..<Self.barCount {
            // Small per-bar jitter so the bars don't all move in lockstep.
            let jitter = Float.random(in: 0.78...1.0)
            next.append(shaped * Self.envelope[i] * jitter)
        }
        levels = next
    }

    func resetLevels() {
        levels = Array(repeating: 0, count: Self.barCount)
    }
}

private struct OverlayPill: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                Capsule()
                    .fill(Color(red: 16/255, green: 18/255, blue: 18/255))
            )
            .scaleEffect(model.state == .hidden ? 0 : 1)
            .animation(
                .timingCurve(0.16, 1, 0.3, 1, duration: 0.3),
                value: model.state
            )
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .hidden, .recording:
            Waveform(levels: model.levels)
                .frame(width: 54, height: 22)
        case .locked:
            HStack(spacing: 7) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color(red: 181/255.0, green: 209/255.0, blue: 255/255.0))
                Waveform(levels: model.levels)
                    .frame(width: 54, height: 22)
            }
            .frame(width: 72, height: 22)
        case .transcribing:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.8)
                .frame(width: 54, height: 22)
        }
    }
}

private struct Waveform: View {
    let levels: [Float]
    private let color = Color(red: 181/255.0, green: 209/255.0, blue: 255/255.0)

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(color)
                    .frame(width: 2.5)
                    .frame(maxHeight: .infinity)
                    .scaleEffect(y: max(0.10, CGFloat(level)), anchor: .center)
                    .animation(.easeOut(duration: 0.09), value: level)
            }
        }
    }
}
