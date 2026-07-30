import AppKit

/// Status bar item in the top-right of the menu bar. Shows recording state at
/// a glance and provides the only persistent control surface for the daemon
/// (since we run as `.accessory` — no dock icon, no main window).
@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let modelLabel: NSMenuItem
    private let stateLabel: NSMenuItem
    private let modelID: String

    init(modelID: String) {
        self.modelID = modelID
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.autoenablesItems = false

        stateLabel = NSMenuItem(title: "idle · hold fn to dictate", action: nil, keyEquivalent: "")
        stateLabel.isEnabled = false
        menu.addItem(stateLabel)

        modelLabel = NSMenuItem(title: "model: \(modelID)", action: nil, keyEquivalent: "")
        modelLabel.isEnabled = false
        menu.addItem(modelLabel)

        menu.addItem(.separator())

        let dictionary = NSMenuItem(
            title: "Add dictionary correction…",
            action: #selector(addDictionaryCorrectionClicked),
            keyEquivalent: ""
        )
        dictionary.target = self
        menu.addItem(dictionary)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit parrot",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        configureButton(recording: false)
    }

    func setRecording(_ recording: Bool) {
        stateLabel.title = recording ? "● recording" : "idle · hold fn to dictate"
    }

    func setTranscribing() {
        stateLabel.title = "transcribing…"
    }

    private func configureButton(recording: Bool) {
        guard let button = statusItem.button else { return }
        let image = Self.birdImage()
        image?.isTemplate = true
        button.image = image
    }

    // Inlined Lucide bird SVG. Keeping it in source means the executable has
    // no separate resource bundle to install alongside it — true single-binary.
    private static let birdSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" \
    viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" \
    stroke-linecap="round" stroke-linejoin="round">\
    <path d="M16 7h.01"/>\
    <path d="M3.4 18H12a8 8 0 0 0 8-8V7a4 4 0 0 0-7.28-2.3L2 20"/>\
    <path d="m20 7 2 .5-2 .5"/>\
    <path d="M10 18v3"/>\
    <path d="M14 17.75V21"/>\
    <path d="M7 18a6 6 0 0 0 3.84-10.61"/>\
    </svg>
    """

    private static func birdImage() -> NSImage? {
        guard let data = birdSVG.data(using: .utf8),
              let image = NSImage(data: data)
        else { return nil }
        // Menu-bar status icons are nominally 18pt tall; size the SVG to match.
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    @objc private func quitClicked() {
        NSApp.terminate(nil)
    }

    @objc private func addDictionaryCorrectionClicked() {
        let transcribedAs = NSTextField(string: "")
        transcribedAs.placeholderString = "e.g. acme api"
        transcribedAs.controlSize = .regular

        let correctSpelling = NSTextField(string: "")
        correctSpelling.placeholderString = "e.g. AcmeAPI"
        correctSpelling.controlSize = .regular

        let alert = NSAlert()
        alert.messageText = "Add dictionary correction"
        alert.informativeText = "Enter what Parrot wrote, then your preferred spelling."
        alert.addButton(withTitle: "Add correction")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = dictionaryForm(
            transcribedAs: transcribedAs,
            correctSpelling: correctSpelling
        )
        alert.window.initialFirstResponder = transcribedAs

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try LocalDictionary.addCorrection(
                transcribedAs: transcribedAs.stringValue,
                correctSpelling: correctSpelling.stringValue
            )
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func dictionaryForm(
        transcribedAs: NSTextField,
        correctSpelling: NSTextField
    ) -> NSView {
        let stack = NSStackView(views: [
            fieldGroup(title: "Parrot wrote", field: transcribedAs),
            fieldGroup(title: "Use this spelling", field: correctSpelling),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12

        // NSAlert sizes an accessory view from its frame rather than resolving
        // external constraints. Give it a concrete, pre-laid-out size so the
        // form stays inside the alert on every supported macOS version.
        stack.layoutSubtreeIfNeeded()
        let form = NSView(frame: NSRect(origin: .zero, size: stack.fittingSize))
        stack.frame = form.bounds
        stack.autoresizingMask = [.width, .height]
        form.addSubview(stack)
        return form
    }

    private func fieldGroup(title: String, field: NSTextField) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)

        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 360).isActive = true

        let group = NSStackView(views: [label, field])
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 4
        return group
    }
}
