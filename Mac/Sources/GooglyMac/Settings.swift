import Foundation
import GooglyShared

/// User choices from the menu bar, kept between launches.
final class Settings {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    var onChange: (() -> Void)?

    /// Cursor size in points (the design's default is 72).
    var cursorSize: Double {
        get { defaults.object(forKey: "cursorSize") as? Double ?? 72 }
        set { defaults.set(newValue, forKey: "cursorSize"); onChange?() }
    }

    var showCursor: Bool {
        get { defaults.object(forKey: "showCursor") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showCursor"); onChange?() }
    }

    /// Where the phone sits under the screen, 0 = left edge, 1 = right edge.
    var phonePosition: Double {
        get { defaults.object(forKey: "phonePosition") as? Double ?? 0.5 }
        set { defaults.set(newValue, forKey: "phonePosition"); onChange?() }
    }

    /// When idle, hide the big cursor and let the phone's eyes follow your own mouse.
    var followMouse: Bool {
        get { defaults.object(forKey: "followMouse") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "followMouse"); onChange?() }
    }

    var captions: Bool {
        get { defaults.object(forKey: "captions") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "captions"); onChange?() }
    }

    /// Lets him click, type, press keys and open things when you ask.
    var computerControl: Bool {
        get { defaults.object(forKey: "computerControl") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "computerControl"); onChange?() }
    }

    /// Bluey lives in the MacBook's notch and works without the phone (voice and focus run on the Mac).
    var notchMode: Bool {
        get { defaults.object(forKey: "notchMode") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "notchMode"); onChange?() }
    }

    /// Keep a daily journal of what you worked on (~/Documents/Bluey Journal).
    var journalEnabled: Bool {
        get { defaults.object(forKey: "journalEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "journalEnabled"); onChange?() }
    }

    /// Send each day's journal to Hermes, so it knows your days.
    var journalToHermes: Bool {
        get { defaults.object(forKey: "journalToHermes") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "journalToHermes"); onChange?() }
    }

    /// From this hour, today's journal goes to Hermes (finished days go the next time Bluey runs).
    var journalHour: Int {
        get { defaults.object(forKey: "journalHour") as? Int ?? 18 }
        set { defaults.set(min(23, max(0, newValue)), forKey: "journalHour"); onChange?() }
    }

    /// Hidden with the hide shortcut: no notch, pointer or avatar until shown again.
    var hidden: Bool {
        get { defaults.bool(forKey: "hidden") }
        set { defaults.set(newValue, forKey: "hidden"); onChange?() }
    }

    /// What his pointer looks like (the Keramik drone by default).
    var pointerStyle: PointerStyle {
        get { PointerStyle(rawValue: defaults.string(forKey: "pointerStyle") ?? "") ?? .drone }
        set { defaults.set(newValue.rawValue, forKey: "pointerStyle"); onChange?() }
    }

    /// How the cursor's path shows while it flies.
    var trail: PointerTrail {
        get { PointerTrail(rawValue: defaults.string(forKey: "trail") ?? "") ?? .comet }
        set { defaults.set(newValue.rawValue, forKey: "trail"); onChange?() }
    }

    /// Shows the user's Keramik avatar in a small floating window.
    var showAvatarWindow: Bool {
        get { defaults.object(forKey: "showAvatarWindow") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showAvatarWindow"); onChange?() }
    }

    /// The mood picked by hand in the menu.
    var mood: Mood {
        get { Mood(rawValue: defaults.string(forKey: "mood") ?? "") ?? .listening }
        set { defaults.set(newValue.rawValue, forKey: "mood"); onChange?() }
    }
}
