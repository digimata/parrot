import Foundation

/// Which model parrot transcribes with: chosen in the menu bar, remembered
/// across restarts.
///
/// `--model` still wins for the launch that passes it, so a one-off run can try
/// a model without changing what the daemon comes back as.
final class ModelStore {
    private static let selectionKey = "modelID"
    private static let previousKey = "previousModelID"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var selectedID: String? {
        get { defaults.string(forKey: Self.selectionKey) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Self.selectionKey)
            } else {
                defaults.removeObject(forKey: Self.selectionKey)
            }
        }
    }

    /// The model switched away from, kept on disk so switching back does not
    /// mean downloading it again.
    var previousID: String? {
        get { defaults.string(forKey: Self.previousKey) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Self.previousKey)
            } else {
                defaults.removeObject(forKey: Self.previousKey)
            }
        }
    }

    var previous: TranscriptionModel? {
        previousID.flatMap(ModelRegistry.find)
    }

    /// Model to start with: the flag, else the remembered choice, else the
    /// registry's recommendation. A remembered model that no longer exists in
    /// the registry falls through instead of failing the launch.
    func resolved(flag: String?) -> TranscriptionModel? {
        if let flag { return ModelRegistry.find(flag) }
        if let selectedID, let model = ModelRegistry.find(selectedID) { return model }
        return ModelRegistry.recommended()
    }
}
