import AppKit
import CoreGraphics
import Foundation

/// Delivers the transcript to whatever holds the keyboard focus.
@MainActor
enum TextInjector {
    enum Mode: String, CaseIterable {
        /// Put the text on the pasteboard and synthesize ⌘V, then restore the
        /// previous pasteboard contents. Terminals and Electron apps read key
        /// events in ways that drop synthesized unicode, but all of them
        /// implement paste.
        case paste
        /// Synthesize the characters directly. Leaves the pasteboard alone, but
        /// silently loses text in apps that ignore unicode-string key events.
        case typeUnicode = "type-unicode"
    }

    /// Grace period for the target app to read the pasteboard before we put the
    /// user's previous contents back. Paste is asynchronous in the target, so
    /// restoring immediately races it.
    private static let pasteSettleDelay: TimeInterval = 0.25

    static func inject(_ text: String, mode: Mode = .paste) {
        guard !text.isEmpty else { return }
        switch mode {
        case .paste: pasteInject(text)
        case .typeUnicode: unicodeInject(text)
        }
    }

    // MARK: - Paste

    /// The user's pasteboard, held while one or more injections are in flight.
    private static var savedContents: [[NSPasteboard.PasteboardType: Data]]?
    private static var restoreGeneration = 0

    private static func pasteInject(_ text: String) {
        let pasteboard = NSPasteboard.general

        // Only snapshot when no restore is already pending. Two injections
        // inside the settle delay would otherwise capture the first one's text
        // as "the user's pasteboard" and restore that, losing the real contents.
        if savedContents == nil {
            savedContents = snapshot(pasteboard)
        }
        restoreGeneration &+= 1
        let generation = restoreGeneration

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        postCommandV()

        DispatchQueue.main.asyncAfter(deadline: .now() + pasteSettleDelay) {
            // Superseded by a later injection; that one owns the restore.
            guard generation == restoreGeneration else { return }
            if let saved = savedContents {
                restore(saved, to: pasteboard)
            }
            savedContents = nil
        }
    }

    /// Capture every representation of every item, not just the plain string —
    /// otherwise dictating over a copied image or file silently destroys it.
    private static func snapshot(
        _ pasteboard: NSPasteboard
    ) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var contents: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { contents[type] = data }
            }
            return contents
        }
    }

    private static func restore(
        _ snapshot: [[NSPasteboard.PasteboardType: Data]],
        to pasteboard: NSPasteboard
    ) {
        pasteboard.clearContents()
        guard !snapshot.isEmpty else { return }
        pasteboard.writeObjects(
            snapshot.map { contents in
                let item = NSPasteboardItem()
                for (type, data) in contents { item.setData(data, forType: type) }
                return item
            })
    }

    private static func postCommandV() {
        // Keycode 9 is `v` on the ASCII-capable layout macOS uses to match
        // command key equivalents, so this stays correct on non-QWERTY layouts.
        let vKey: CGKeyCode = 9
        let source = CGEventSource(stateID: .combinedSessionState)
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else { return }
        // Set flags explicitly: any modifier the user is still physically
        // holding would otherwise ride along and turn this into a different
        // shortcut.
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }

    // MARK: - Unicode

    /// Splits into chunks because the underlying API has a per-event character
    /// limit (~20 chars).
    private static func unicodeInject(_ text: String) {
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

        let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
        down?.keyboardSetUnicodeString(stringLength: length, unicodeString: &chunk)
        down?.post(tap: .cgSessionEventTap)

        let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        up?.keyboardSetUnicodeString(stringLength: length, unicodeString: &chunk)
        up?.post(tap: .cgSessionEventTap)
    }
}
