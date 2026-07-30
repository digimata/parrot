import Foundation

enum HotkeyPreferences {
    private static let key = "pushToTalkHotkey"

    static var selected: HotkeyMonitor.Hotkey {
        get {
            guard
                let rawValue = UserDefaults.standard.string(forKey: key),
                let hotkey = HotkeyMonitor.Hotkey(rawValue: rawValue)
            else { return .fn }
            return hotkey
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
        }
    }
}
