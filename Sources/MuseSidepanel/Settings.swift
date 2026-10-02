import AppKit

enum Side: String {
    case left, right
}

enum Settings {
    static let minWidth: CGFloat = 360
    static let maxWidth: CGFloat = 760

    private static let defaults = UserDefaults.standard

    static var side: Side {
        get { Side(rawValue: defaults.string(forKey: "side") ?? "") ?? .right }
        set { defaults.set(newValue.rawValue, forKey: "side") }
    }

    static var width: CGFloat {
        get {
            let stored = defaults.double(forKey: "width")
            return stored == 0 ? 440 : min(max(stored, minWidth), maxWidth)
        }
        set { defaults.set(Double(min(max(newValue, minWidth), maxWidth)), forKey: "width") }
    }

    /// When pinned the panel stays open after you click into another app.
    static var pinned: Bool {
        get { defaults.bool(forKey: "pinned") }
        set { defaults.set(newValue, forKey: "pinned") }
    }

    /// Drop the web page after the panel has been hidden for a while.
    static var unloadWhenIdle: Bool {
        get { defaults.object(forKey: "unloadWhenIdle") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "unloadWhenIdle") }
    }

    /// Where the conversation was left, so a reloaded page lands on the same thread.
    static var lastURL: URL? {
        get { defaults.url(forKey: "lastURL") }
        set { defaults.set(newValue, forKey: "lastURL") }
    }
}
