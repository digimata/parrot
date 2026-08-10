import CoreGraphics
import Foundation

/// Posts a string of text at the current cursor location by synthesizing
/// keyboard events with `CGEventKeyboardSetUnicodeString`. Works in nearly
/// every text field on macOS; some Electron apps and secure password fields
/// can drop characters (platform constraint).
enum TextInjector {
    /// Inject the given text at the current cursor location.
    /// Splits long strings into chunks because the underlying API has a
    /// per-event character limit (~20 chars).
    static func inject(_ text: String) {
        guard !text.isEmpty else { return }

        let utf16 = Array(text.utf16)
        let chunkSize = 20
        var index = 0

        while index < utf16.count {
            let end = min(index + chunkSize, utf16.count)
            var chunk = Array(utf16[index..<end])
            postChunk(&chunk)
            index = end
        }
    }

    private static func postChunk(_ chunk: inout [UniChar]) {
        let length = chunk.count
        guard length > 0 else { return }

        // NOTE: posting to `.cgSessionEventTap` collides with HotkeyMonitor's
        // own listen-only tap, which is installed at `.headInsertEventTap` on
        // that same `.cgSessionEventTap` location — the synthetic keystrokes
        // get silently swallowed before reaching the focused app. Posting to
        // `.cgAnnotatedSessionEventTap` (further down the pipeline, past that
        // tap) delivers reliably. Confirmed empirically: cghidEventTap and
        // cgSessionEventTap both silently no-op here; cgAnnotatedSessionEventTap
        // lands in the focused text field every time.
        let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
        down?.keyboardSetUnicodeString(stringLength: length, unicodeString: &chunk)
        down?.post(tap: .cgAnnotatedSessionEventTap)

        let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        up?.keyboardSetUnicodeString(stringLength: length, unicodeString: &chunk)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }
}
