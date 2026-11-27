import AppKit
import Carbon.HIToolbox

/// A global key combination (Carbon key code and modifiers, which is what RegisterEventHotKey takes).
struct Shortcut: Codable, Equatable {
    var keyCode: Int
    var modifiers: Int
    /// The key's label, e.g. "B" or "Space".
    var key: String

    var display: String {
        var s = ""
        if modifiers & controlKey != 0 { s += "⌃" }
        if modifiers & optionKey != 0 { s += "⌥" }
        if modifiers & shiftKey != 0 { s += "⇧" }
        if modifiers & cmdKey != 0 { s += "⌘" }
        return s + key
    }

    /// For menu items: the same combination as an AppKit key equivalent.
    var menuKey: (key: String, modifiers: NSEvent.ModifierFlags) {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & controlKey != 0 { flags.insert(.control) }
        if modifiers & optionKey != 0 { flags.insert(.option) }
        if modifiers & shiftKey != 0 { flags.insert(.shift) }
        if modifiers & cmdKey != 0 { flags.insert(.command) }
        let key = keyCode == kVK_Space ? " " : (self.key.count == 1 ? self.key.lowercased() : "")
        return (key, flags)
    }

    static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋", kVK_Delete: "⌫",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// Reads a key press from the recorder. Needs at least one modifier (or a function key),
    /// so plain typing can never become a global shortcut.
    init?(event: NSEvent) {
        let flags = event.modifierFlags
        var mods = 0
        if flags.contains(.control) { mods |= controlKey }
        if flags.contains(.option) { mods |= optionKey }
        if flags.contains(.shift) { mods |= shiftKey }
        if flags.contains(.command) { mods |= cmdKey }
        let code = Int(event.keyCode)
        let isFunctionKey = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7,
                                                                   kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12].contains(code)
        guard mods != 0 && mods != shiftKey || isFunctionKey else { return nil }
        let label = Self.specialKeys[code] ?? (event.charactersIgnoringModifiers ?? "").uppercased()
        guard !label.isEmpty else { return nil }
        self.init(keyCode: code, modifiers: mods, key: label)
    }

    init(keyCode: Int, modifiers: Int, key: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.key = key
    }
}

/// Everything Bluey does from the keyboard. Each can be changed or turned off in Settings ▸ Shortcuts.
enum ShortcutAction: String, CaseIterable, Identifiable {
    case talk, typeToBluey, notes, annotateScreen, meetingNotes, meetingRecord, meetingToT3, hide, wake, stop, pointHere, followMouse, stopPointing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .talk: return "Mit Bluey sprechen"
        case .typeToBluey: return "Bluey schreiben"
        case .hide: return "Bluey aus- oder einblenden"
        case .wake: return "Zuhören starten oder beenden"
        case .stop: return "Blueys Aktionen stoppen"
        case .pointHere: return "Auf meinen Mauszeiger zeigen"
        case .followMouse: return "Augen folgen dem Mauszeiger"
        case .stopPointing: return "Zeigen beenden"
        case .notes: return "Schnellnotizen"
        case .annotateScreen: return "Auf Bildschirm zeichnen"
        case .meetingNotes: return "Call-Notizen öffnen"
        case .meetingRecord: return "Meeting-Aufnahme starten / stoppen"
        case .meetingToT3: return "Meeting-Aufgabe an T3 Code"
        }
    }

    var detail: String {
        switch self {
        case .talk: return "Gedrückt halten, sprechen und loslassen. Ein verbundenes iPhone wird dabei aktiviert."
        case .typeToBluey: return "Öffnet die Notch und setzt den Cursor ins Textfeld."
        case .hide: return "Blendet Notch, Zeiger und Avatar aus. Fokus-Timer laufen weiter."
        case .wake: return "Öffnet oder beendet die Mikrofon-Session."
        case .stop: return "Stoppt Klicks, Eingaben und Zeigen sofort."
        case .pointHere: return "Blueys Zeiger bewegt sich zum Mauszeiger."
        case .followMouse: return "Schaltet die Blickverfolgung um."
        case .stopPointing: return "Lässt Blueys Zeiger zurückkehren."
        case .notes: return "Öffnet oder verbirgt das Notizfenster. Die Notizen bleiben mit iPhone und Hermes synchron."
        case .annotateScreen: return "Zeichne direkt auf deinen Bildschirm (mit Huion-Stift oder Maus) zum Teilen oder an Bluey senden."
        case .meetingNotes: return "Öffnet das Call-Notizen-Fenster mit Zeiterfassung, Transkript und Aufgaben."
        case .meetingRecord: return "Startet oder stoppt die Meeting-Aufnahme samt Zeiterfassung aus jeder App."
        case .meetingToT3: return "Öffnet direkt den Dialog, um eine Meeting-Aufgabe an T3 Code zu senden."
        }
    }

    var defaultShortcut: Shortcut? {
        let co = controlKey | optionKey
        switch self {
        case .talk: return Shortcut(keyCode: kVK_Space, modifiers: co, key: "Space")
        case .typeToBluey: return Shortcut(keyCode: kVK_ANSI_B, modifiers: co, key: "B")
        case .hide: return Shortcut(keyCode: kVK_ANSI_H, modifiers: co, key: "H")
        case .wake: return Shortcut(keyCode: kVK_ANSI_W, modifiers: co, key: "W")
        case .stop: return Shortcut(keyCode: kVK_ANSI_S, modifiers: co, key: "S")
        case .pointHere: return Shortcut(keyCode: kVK_ANSI_P, modifiers: co, key: "P")
        case .followMouse: return Shortcut(keyCode: kVK_ANSI_F, modifiers: co, key: "F")
        case .stopPointing: return Shortcut(keyCode: kVK_ANSI_D, modifiers: co, key: "D")
        case .notes: return Shortcut(keyCode: kVK_ANSI_N, modifiers: co, key: "N")
        case .annotateScreen: return Shortcut(keyCode: kVK_ANSI_A, modifiers: co, key: "A")
        case .meetingNotes: return Shortcut(keyCode: kVK_ANSI_M, modifiers: co, key: "M")
        case .meetingRecord: return Shortcut(keyCode: kVK_ANSI_R, modifiers: co, key: "R")
        case .meetingToT3: return Shortcut(keyCode: kVK_ANSI_T, modifiers: co, key: "T")
        }
    }
}

/// Saved shortcuts. Unset means the default; an explicit "off" is stored as empty data.
enum ShortcutStore {
    private static func key(_ action: ShortcutAction) -> String { "shortcut." + action.rawValue }

    static func get(_ action: ShortcutAction) -> Shortcut? {
        guard let data = UserDefaults.standard.data(forKey: key(action)) else { return action.defaultShortcut }
        return data.isEmpty ? nil : try? JSONDecoder().decode(Shortcut.self, from: data)
    }

    static func set(_ action: ShortcutAction, _ shortcut: Shortcut?) {
        let data = shortcut.flatMap { try? JSONEncoder().encode($0) } ?? Data()
        UserDefaults.standard.set(data, forKey: key(action))
    }

    static func resetAll() {
        for action in ShortcutAction.allCases { UserDefaults.standard.removeObject(forKey: key(action)) }
    }

    /// Another action already using this combination, if any.
    static func conflict(_ shortcut: Shortcut, except action: ShortcutAction) -> ShortcutAction? {
        ShortcutAction.allCases.first { $0 != action && get($0).map { $0.keyCode == shortcut.keyCode && $0.modifiers == shortcut.modifiers } == true }
    }
}
