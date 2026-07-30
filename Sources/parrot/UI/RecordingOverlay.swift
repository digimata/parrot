import AppKit
import SwiftUI

/// Borderless, click-through pill near the bottom of the active screen.
/// Driven by the daemon's hotkey + transcription lifecycle.
@MainActor
final class RecordingOverlay {
    enum State: Equatable {
        case hidden
        case recording
        case transcribing
    }

    private var window: NSPanel?
    private let model = OverlayModel()
    /// Invalidates a pending `hide()` when a new recording starts inside the
    /// dismiss animation window, which would otherwise order the freshly shown
    /// panel back out.
    private var hideGeneration = 0

    func show(_ state: State) {
        ensureWindow()
        guard let window else { return }
        hideGeneration &+= 1
        if state == .recording {
            model.resetLevels()
        }
        let wasHidden = !window.isVisible
        // Reposition and re-order on every show: the active screen and Space
        // can both change between recordings.
        position(window)
        window.orderFrontRegardless()
        if wasHidden {
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
        model.state = .hidden
        hideGeneration &+= 1
        let generation = hideGeneration
        // Let the SwiftUI scale+fade animation play out before yanking the
        // window — otherwise it just pops away.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self, self.hideGeneration == generation else { return }
            self.window?.orderOut(nil)
        }
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
            contentRect: NSRect(x: 0, y: 0, width: 96, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // Above full-screen windows, which sit above .statusBar. Without this
        // the pill is invisible whenever the frontmost app is full-screen.
        panel.level = .screenSaver
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

    private func position(_ window: NSPanel) {
        // `NSScreen.main` follows keyboard focus and is nil when no window has
        // it — unreliable for a background agent. The screen under the pointer
        // is the one the user is looking at.
        let pointer = NSEvent.mouseLocation
        guard
            let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) })
                ?? NSScreen.main ?? NSScreen.screens.first
        else { return }
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
