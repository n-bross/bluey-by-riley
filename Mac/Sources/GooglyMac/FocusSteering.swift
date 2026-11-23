import AppKit
import ApplicationServices

/// Keeps only the current round's window and blocked hosts, in memory.
@MainActor
final class FocusSteering {
    struct Context {
        let app: NSRunningApplication
        let window: AXUIElement?
        let url: URL?

        func matches(_ other: Context) -> Bool {
            app.processIdentifier == other.app.processIdentifier && window == other.window && url == other.url
        }
    }

    private var work: Context?
    private var blockedHosts = Set<String>()
    private var retryAfter = 0.0

    func reset() {
        work = nil
        blockedHosts.removeAll()
        retryAfter = 0
    }

    func frontContext() -> Context? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        guard ComputerControl.isTrusted else { return Context(app: app, window: nil, url: nil) }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.08)
        if let id = app.bundleIdentifier, Self.browsers.contains(id) {
            AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        let window: AXUIElement? = ControlsReader.attribute(element, kAXFocusedWindowAttribute)
        return Context(app: app, window: window, url: window.flatMap { browserURL(in: $0, app: app) })
    }

    func remember(_ context: Context) {
        guard let front = frontContext(), context.matches(front) else { return }
        work = context
    }

    func interrupt(_ context: Context) {
        guard let front = frontContext(), context.matches(front) else { return }
        if let host = Self.siteHost(front.url), !Self.matchesHost(Self.siteHost(work?.url), blockedBy: host) {
            blockedHosts.insert(host)
        }
        returnToWork(from: front, blocked: isBlocked(front))
    }

    func enforce() {
        guard !blockedHosts.isEmpty, ProcessInfo.processInfo.systemUptime >= retryAfter,
              let front = frontContext(), isBlocked(front) else { return }
        returnToWork(from: front, blocked: true)
    }

    private func isBlocked(_ context: Context) -> Bool {
        guard let host = Self.siteHost(context.url) else { return false }
        return blockedHosts.contains { Self.matchesHost(host, blockedBy: $0) }
    }

    private func returnToWork(from front: Context, blocked: Bool) {
        retryAfter = ProcessInfo.processInfo.systemUptime + 1
        if let work, !work.app.isTerminated, !work.matches(front) {
            if work.app.processIdentifier != front.app.processIdentifier || work.window != front.window {
                let activated = work.app.activate()
                if let window = work.window, AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success {
                    AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                    return
                }
                if activated, work.app.processIdentifier != front.app.processIdentifier { return }
            }
            // In the same browser window, reopen the confirmed work page without closing the distracting tab.
            if let url = work.url, let appURL = work.app.bundleURL, Self.siteHost(url) != nil, !isBlocked(work) {
                NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: .init(), completionHandler: nil)
                return
            }
        }
        // A blocked site with no usable work window must still leave the foreground.
        if blocked { front.app.hide() }
    }

    private func browserURL(in window: AXUIElement, app: NSRunningApplication) -> URL? {
        guard let id = app.bundleIdentifier, Self.browsers.contains(id) else { return nil }
        let document: String? = ControlsReader.attribute(window, kAXDocumentAttribute)
        if let document, let url = URL(string: document), Self.siteHost(url) != nil { return url }

        let deadline = ProcessInfo.processInfo.systemUptime + 0.08
        var queue = [window]
        var index = 0
        while index < queue.count, index < 100, ProcessInfo.processInfo.systemUptime < deadline {
            let node = queue[index]
            index += 1
            let role: String? = ControlsReader.attribute(node, kAXRoleAttribute)
            if role == "AXWebArea" {
                let url: URL? = ControlsReader.attribute(node, kAXURLAttribute)
                if Self.siteHost(url) != nil { return url }
                continue
            }
            let children: [AXUIElement] = ControlsReader.attribute(node, kAXChildrenAttribute) ?? []
            queue.append(contentsOf: children.prefix(25))
        }
        return nil
    }

    private static let browsers: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac",
        "org.mozilla.firefox", "company.thebrowser.Browser", "app.zen-browser.zen", "net.imput.helium",
    ]

    private static func matchesHost(_ host: String?, blockedBy domain: String) -> Bool {
        guard let host else { return false }
        return host == domain || host.hasSuffix("." + domain)
    }

    static func siteHost(_ url: URL?) -> String? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")), !host.isEmpty else { return nil }
        if host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com") { return "youtube.com" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
