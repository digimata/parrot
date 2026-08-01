import AppKit

/// Status bar item in the top-right of the menu bar. Shows recording state at
/// a glance and provides the only persistent control surface for the daemon
/// (since we run as `.accessory` — no dock icon, no main window).
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let modelLabel: NSMenuItem
    private let stateLabel: NSMenuItem
    private let modelItem: NSMenuItem
    private var model: TranscriptionModel
    /// The model being switched to. Set on click so the menu answers the click
    /// rather than the download, which can take minutes.
    private var pending: TranscriptionModel?
    /// Set after construction: switching needs the daemon, and the daemon needs
    /// the controller it reports back to.
    var onModel: ((TranscriptionModel) -> Void)?

    init(model: TranscriptionModel) {
        self.model = model
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.autoenablesItems = false

        stateLabel = NSMenuItem(title: "idle · hold fn to dictate", action: nil, keyEquivalent: "")
        stateLabel.isEnabled = false
        menu.addItem(stateLabel)

        modelLabel = NSMenuItem(title: "model: \(model.id)", action: nil, keyEquivalent: "")
        modelLabel.isEnabled = false
        menu.addItem(modelLabel)

        modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        let modelMenu = NSMenu()
        modelMenu.autoenablesItems = false
        modelItem.submenu = modelMenu
        menu.addItem(modelItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit parrot",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        super.init()

        quit.target = self
        menu.addItem(quit)

        // Rebuild the model list on open so a switch in flight is reflected
        // without the menu holding its own copy of the state.
        menu.delegate = self

        statusItem.menu = menu
        configureButton(recording: false)
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard let modelSubmenu = modelItem.submenu else { return }
        modelSubmenu.removeAllItems()
        for candidate in ModelRegistry.shared {
            let active = candidate.id == model.id
            let arriving = candidate.id == pending?.id
            let item = NSMenuItem(
                title: "\(candidate.displayName) · \(candidate.sizeMB) MB",
                action: #selector(modelSelected),
                keyEquivalent: "")
            item.target = self
            item.representedObject = candidate.id
            // A dash rather than a tick while it arrives: the choice is taken,
            // the model is not ready, and pretending otherwise is what made the
            // menu look like it ignored the click.
            item.state = arriving ? .mixed : (active ? .on : .off)
            // One switch at a time, and the model in use is already here.
            item.isEnabled = pending == nil && !active
            modelSubmenu.addItem(item)
        }
    }

    /// Hands the choice to the daemon, which loads it before dropping the model
    /// in use. The label follows on `setModel` once that succeeds.
    @objc private func modelSelected(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let chosen = ModelRegistry.find(id), chosen.id != model.id
        else { return }
        pending = chosen
        modelLabel.title = "loading \(chosen.id)…"
        onModel?(chosen)
    }

    /// Download fraction, which is the only part either engine reports. Loading
    /// afterwards shows as the same line without a number.
    func setSwitchProgress(_ fraction: Double) {
        guard let pending else { return }
        modelLabel.title = fraction < 1
            ? String(format: "downloading %@… %.0f%%", pending.id, fraction * 100)
            : "loading \(pending.id)…"
    }

    func setModel(_ model: TranscriptionModel) {
        self.model = model
        self.pending = nil
        modelLabel.title = "model: \(model.id)"
    }

    func setModelFailed(_ attempted: TranscriptionModel) {
        pending = nil
        modelLabel.title = "model: \(model.id) · \(attempted.id) failed"
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
}
