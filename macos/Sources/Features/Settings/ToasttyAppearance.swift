import AppKit

/// The menu preference overrides window-theme without rewriting user files.
/// A nil preference leaves the configuration in control.
enum ToasttyAppearance: String, CaseIterable {
    case system
    case light
    case dark

    static let defaultsKey = "ToasttyAppearance"

    static var saved: ToasttyAppearance? {
        get { UserDefaults.ghostty.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) }
        set {
            if let newValue {
                UserDefaults.ghostty.set(newValue.rawValue, forKey: defaultsKey)
            } else {
                UserDefaults.ghostty.removeObject(forKey: defaultsKey)
            }
        }
    }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var configurationURL: URL? {
        Bundle.main.url(forResource: "ToasttyAppearance-\(rawValue)", withExtension: "ghostty")
    }
}
