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

    func show(_ state: State) {
        ensureWindow()
        if state == .recording {
            model.resetLevels()
        }
        guard let window else { return }
        model.state = state
        positionAtBottomCenter(window)
        if !window.isVisible {
            window.orderFrontRegardless()
        }
    }

    func hide() {
        model.state = .hidden
        window?.orderOut(nil)
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
            contentRect: NSRect(x: 0, y: 0, width: 196, height: 44),
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
        // Accessory apps do not reliably have an `NSScreen.main`. Prefer the
        // display under the pointer so the indicator follows the app being
        // dictated into, then fall back to the main/first display.
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        let frame = window.frame
        let visible = screen.visibleFrame
        let x = visible.midX - frame.width / 2
        let y = visible.minY + 32
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

@MainActor
func announceParrotState(_ text: String) {
    guard !text.isEmpty else { return }
    let userInfo: [NSAccessibility.NotificationUserInfoKey: Any] = [
        .announcement: text,
        .priority: NSAccessibilityPriorityLevel.high.rawValue,
    ]
    NSAccessibility.post(
        element: NSApp as Any,
        notification: .announcementRequested,
        userInfo: userInfo
    )
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
            .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .hidden:
            EmptyView()
        case .recording:
            HStack(spacing: 10) {
                Waveform(levels: model.levels)
                    .frame(width: 54, height: 22)
                Text("⌃ + 🌐 to stop")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
            }
            .frame(width: 168, height: 22)
        case .transcribing:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.8)
                Text("Transcribing…")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))
            }
            .frame(width: 168, height: 22)
        }
    }

    private var accessibilityLabel: String {
        switch model.state {
        case .hidden:
            return "Parrot idle"
        case .recording:
            return "Parrot recording. Press Control and Fn or Globe to stop."
        case .transcribing:
            return "Parrot transcribing"
        }
    }
}

private struct Waveform: View {
    let levels: [Float]
    private let color = Color(red: 181/255.0, green: 209/255.0, blue: 255/255.0)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(color)
                    .frame(width: 2.5)
                    .frame(maxHeight: .infinity)
                    .scaleEffect(y: max(0.10, CGFloat(level)), anchor: .center)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.09), value: level)
            }
        }
    }
}
