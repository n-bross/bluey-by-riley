import AppKit
import ApplicationServices
import SwiftUI

@available(macOS 15, *)
@MainActor
final class TeamsMeetingDetector {
    private var timer: Timer?
    private var candidate: String?
    private var offered: String?
    private var lastSeen = Date.distantPast
    private var panel: NSPanel?

    func start(meetings: @escaping @MainActor () -> MeetingWindow?) {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let meeting = meetings() else { return }
                self.check(meeting)
            }
        }
    }

    static let supportedBrowserBundles: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.microsoft.edgemac",
        "org.mozilla.firefox",
        "company.thebrowser.Browser",
        "net.imput.helium",
        "app.zen-browser.zen"
    ]

    private func check(_ meeting: MeetingWindow) {
        guard let app = NSWorkspace.shared.frontmostApplication, let bundle = app.bundleIdentifier else { return }
        let native = ["com.microsoft.teams2", "com.microsoft.teams"].contains(bundle)
        let browser = Self.supportedBrowserBundles.contains(bundle)
        guard native || browser else { return }
        guard let match = Self.meetingMatch(pid: app.processIdentifier, browser: browser) else {
            candidate = nil
            if Date().timeIntervalSince(lastSeen) > 20 {
                offered = nil
                dismiss()
            }
            return
        }
        let title = match.title
        lastSeen = Date()
        guard candidate == title else { candidate = title; return }
        guard offered != title, !meeting.busy else { return }
        offered = title
        dismiss()
        let pid = app.processIdentifier
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Bluey · Call-Notizen"
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = NSColor(Theme.background)
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.contentViewController = NSHostingController(rootView:
            VStack(alignment: .leading, spacing: 12) {
                Label("Teams-Meeting erkannt", systemImage: "video")
                    .font(.headline)
                Text("Möchtest du dieses Meeting für deine Call-Notizen aufzeichnen?")
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Nicht jetzt") { [weak self] in self?.dismiss() }
                    Button("Aufzeichnen") { [weak self, weak meeting] in
                        guard let self, let meeting else { return }
                        self.dismiss()
                        guard let current = Self.meetingMatch(pid: pid, browser: browser), current.title == title else { return }
                        meeting.show()
                        Task { await meeting.start(preferredWindowID: current.windowID) }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(18).frame(width: 365)
            .background(Theme.background).preferredColorScheme(.dark).tint(Theme.accentLight)
        )
        self.panel = panel
        panel.setContentSize(NSSize(width: 365, height: 150))
        panel.center()
        panel.orderFrontRegardless()
    }

    private func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }

    private static func meetingMatch(pid: pid_t, browser: Bool) -> (title: String, windowID: CGWindowID?)? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        func findWindowID(matching title: String) -> CGWindowID? {
            if let exact = windows.first(where: {
                $0[kCGWindowOwnerPID as String] as? Int32 == pid
                    && ($0[kCGWindowName as String] as? String) == title
            })?[kCGWindowNumber as String] as? CGWindowID {
                return exact
            }
            return windows.first(where: {
                $0[kCGWindowOwnerPID as String] as? Int32 == pid
                    && (($0[kCGWindowName as String] as? String)?.localizedCaseInsensitiveContains("Microsoft Teams") == true)
            })?[kCGWindowNumber as String] as? CGWindowID
        }

        if AXIsProcessTrusted() {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.15)
            if let window: AXUIElement = attribute(app, kAXFocusedWindowAttribute) {
                let title: String = attribute(window, kAXTitleAttribute) ?? ""
                let teamsWindow = !browser || title.localizedCaseInsensitiveContains("Microsoft Teams")
                if teamsWindow && (isMeetingTitle(title) || hasCallControls(window)) {
                    let resolvedTitle = title.isEmpty ? "Teams call \(pid)" : title
                    return (resolvedTitle, findWindowID(matching: title))
                }
            }
        }
        if let hit = windows.first(where: { window in
            window[kCGWindowOwnerPID as String] as? Int32 == pid
                && (window[kCGWindowName as String] as? String).map(isMeetingTitle) == true
        }), let title = hit[kCGWindowName as String] as? String {
            return (title, hit[kCGWindowNumber as String] as? CGWindowID)
        }
        return nil
    }

    static func isMeetingTitle(_ title: String) -> Bool {
        let lower = title.lowercased()
        if ["meeting - microsoft teams", "besprechung - microsoft teams"].contains(lower) { return true }
        let normalized = lower
            .components(separatedBy: " - ").first ?? title.lowercased()
        let parts = normalized.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts == ["microsoft teams meeting"] { return true }
        guard parts.contains(where: { $0 == "microsoft teams" || $0 == "teams" }) else { return false }
        return parts.contains { part in
            ["meeting", "meeting in progress", "microsoft teams meeting", "besprechung", "besprechung läuft",
             "anruf", "call", "call in progress"].contains(part)
                || part.hasPrefix("join meeting") || part.hasPrefix("an besprechung teilnehmen")
        }
    }

    private static func hasCallControls(_ window: AXUIElement) -> Bool {
        var elements = [window]
        var endCall = false
        var callMedia = false
        let deadline = Date().addingTimeInterval(0.25)
        for _ in 0..<150 {
            guard Date() < deadline, let element = elements.popLast() else { break }
            let labels = [kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute].compactMap {
                attribute(element, $0) as String?
            }.joined(separator: " ").lowercased()
            endCall = endCall || ["hang up", "leave meeting", "leave call", "call-hangup", "auflegen",
                                 "besprechung verlassen", "anruf verlassen"].contains(where: labels.contains)
            callMedia = callMedia || ["microphone", "mikrofon", "camera", "kamera", "toggle-mute"].contains(where: labels.contains)
            if endCall && callMedia { return true }
            let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) ?? []
            elements.append(contentsOf: children.reversed())
        }
        return false
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}
