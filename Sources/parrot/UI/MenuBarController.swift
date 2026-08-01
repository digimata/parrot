import AppKit

/// Status bar item in the top-right of the menu bar. Shows recording state at
/// a glance and provides the only persistent control surface for the daemon
/// (since we run as `.accessory` — no dock icon, no main window).
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let modelLabel: NSMenuItem
    private let stateLabel: NSMenuItem
    private let inputItem: NSMenuItem
    private let modelID: String
    private let devices: InputDeviceStore

    init(modelID: String, devices: InputDeviceStore) {
        self.modelID = modelID
        self.devices = devices
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.autoenablesItems = false

        stateLabel = NSMenuItem(title: "idle · hold fn to dictate", action: nil, keyEquivalent: "")
        stateLabel.isEnabled = false
        menu.addItem(stateLabel)

        modelLabel = NSMenuItem(title: "model: \(modelID)", action: nil, keyEquivalent: "")
        modelLabel.isEnabled = false
        menu.addItem(modelLabel)

        inputItem = NSMenuItem(title: "Input", action: nil, keyEquivalent: "")
        let inputMenu = NSMenu()
        inputMenu.autoenablesItems = false
        inputItem.submenu = inputMenu
        menu.addItem(inputItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit parrot",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        super.init()

        quit.target = self
        menu.addItem(quit)

        // Rebuild the device list on open so plugging a mic in is reflected
        // without watching CoreAudio for device changes.
        menu.delegate = self

        statusItem.menu = menu
        configureButton(recording: false)
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard let submenu = inputItem.submenu else { return }
        submenu.removeAllItems()

        let selected = devices.selectedUID
        submenu.addItem(inputChoice(title: "Same as System", uid: nil, checked: selected == nil))
        submenu.addItem(.separator())
        for device in devices.available() {
            submenu.addItem(inputChoice(title: device.name, uid: device.uid, checked: device.uid == selected))
        }
    }

    private func inputChoice(title: String, uid: String?, checked: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(inputSelected), keyEquivalent: "")
        item.target = self
        item.representedObject = uid
        item.state = checked ? .on : .off
        return item
    }

    /// Only writes the preference — the next recording resolves it, so there is
    /// nothing to notify.
    @objc private func inputSelected(_ sender: NSMenuItem) {
        devices.selectedUID = sender.representedObject as? String
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
