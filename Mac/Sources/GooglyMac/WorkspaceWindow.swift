import AppKit
import CoreGraphics
import SwiftUI
import GooglyShared

/// The Mac's workspace backend: the local store, no network in between.
@MainActor
final class LocalWorkspaceBackend: WorkspaceBackend {
    private let store: WorkspaceStore
    init(store: WorkspaceStore) { self.store = store }
    var isConnected: Bool { true }
    func push(_ partial: WorkspaceSnapshot) { store.apply(partial) }
    func send(_ request: ChatRequest) async throws -> UUID { try store.send(request) }
    func stop(threadID: UUID) { store.stop(threadID) }
    func upload(_ data: Data, name: String, mime: String) async throws -> ChatAttachment {
        try store.storeAttachment(data, name: name, mime: mime)
    }
    func attachmentData(_ id: UUID) async -> Data? { store.attachmentData(id) }
    func setDefaultModel(_ id: String) { store.setDefaultModel(id) }
}

@MainActor
private final class MacWorkspacePanels: ObservableObject {
    @Published var showHermesScreen = false
}

/// The Bluey app window on the Mac: the same screens as on the iPhone, with a sidebar.
@MainActor
final class WorkspaceWindow: NSObject, NSWindowDelegate {
    let model: WorkspaceModel
    let animator = FaceAnimator()
    private let backend: LocalWorkspaceBackend
    private var window: NSWindow?
    private let panels = MacWorkspacePanels()
    private var detachedHermes: NSWindow?
    var openSettingsWindow: (() -> Void)?
    var phoneName: () -> String? = { nil }
    var openWebApp: () -> Void = {}
    var pairPhone: () -> Void = {}
    var openMeetings: (() -> Void)? = nil

    init(store: WorkspaceStore) {
        backend = LocalWorkspaceBackend(store: store)
        model = WorkspaceModel(snapshot: store.snapshot)
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(displaysChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        model.backend = backend
        model.openHermesScreen = { [weak self] _ in
            guard let self else { return }
            if let floating = self.detachedHermes { floating.makeKeyAndOrderFront(nil) }
            else { self.panels.showHermesScreen = true }
        }
        model.detachHermesScreen = { [weak self] in self?.detachHermes() }
        model.setConnected(true)
        store.listen(snapshot: { [weak model] in model?.receive($0) }, delta: { [weak model] in model?.receive($0) })
    }

    func show(tab: WorkspaceTab? = nil) {
        if let tab { UserDefaults.standard.set(tab.rawValue, forKey: "workspaceTab") }
        if window == nil {
            let root = MacWorkspaceRoot(model: model, animator: animator, panels: panels, phoneName: phoneName, openWebApp: openWebApp, pairPhone: pairPhone, openSettingsWindow: openSettingsWindow, openMeetings: openMeetings)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Bluey"
            window.titlebarAppearsTransparent = true
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(Theme.background)
            window.minSize = NSSize(width: 760, height: 520)
            window.contentViewController = NSHostingController(rootView: root)
            window.setFrameAutosaveName("BlueyWorkspace")
            if !window.setFrameUsingName("BlueyWorkspace") { window.center() }
            Self.keepVisible(window)
            window.isReleasedWhenClosed = false
            window.delegate = self
            self.window = window
        }
        // A real app while the window is open: Dock icon, ⌘Tab and a menu bar with Edit (copy/paste).
        NSApp.setActivationPolicy(.regular)
        NSApp.mainMenu = mainMenu()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func detachHermes() {
        guard detachedHermes == nil else { return }
        panels.showHermesScreen = false
        let floating = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        floating.title = "Bluey · Hermes Live"
        floating.titleVisibility = .hidden
        floating.titlebarAppearsTransparent = true
        floating.appearance = NSAppearance(named: .darkAqua)
        floating.backgroundColor = NSColor(Theme.panel)
        floating.minSize = NSSize(width: 320, height: 400)
        floating.isReleasedWhenClosed = false
        floating.contentViewController = NSHostingController(rootView:
            MacHermesScreenPane(model: model,
                                close: { [weak floating] in floating?.close() },
                                move: { [weak self, weak floating] in
                                    floating?.close()
                                    self?.show(tab: .chat)
                                    self?.panels.showHermesScreen = true
                                }, detached: true,
                                snap: { [weak self, weak floating] placement in
                                    guard let floating, let screen = floating.screen ?? NSScreen.main else { return }
                                    floating.setFrame(placement.frame(in: screen.visibleFrame, current: floating.frame), display: true, animate: true)
                                    self?.saveHermesFrame(floating)
                                })
                .preferredColorScheme(.dark)
                .tint(Theme.accentLight)
        )
        Self.restoreHermesFrame(floating, fallback: window?.screen)
        floating.delegate = self
        detachedHermes = floating
        model.hermesScreenDetached = true
        floating.makeKeyAndOrderFront(nil)
    }

    private static let hermesDisplayKey = "BlueyHermesLive.lastDisplay"
    private static func displayKey(for screen: NSScreen) -> String {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else {
            return screen.localizedName
        }
        return CFUUIDCreateString(nil, uuid) as String
    }

    private static func restoreHermesFrame(_ window: NSWindow, fallback: NSScreen?) {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: hermesDisplayKey)
        guard let screen = NSScreen.screens.first(where: { displayKey(for: $0) == previous })
            ?? fallback ?? NSScreen.main else { return }
        let key = displayKey(for: screen)
        let bounds = screen.visibleFrame
        let restored = defaults.string(forKey: "BlueyHermesLive.frame." + key).map(NSRectFromString)
        // Saved origins are relative to their screen so changing monitor order is safe.
        let frame = restored.map { $0.offsetBy(dx: bounds.minX, dy: bounds.minY) }
        let initial = frame.flatMap { $0.isEmpty ? nil : $0 }
            ?? HermesWindowPlacement.center.frame(in: bounds, current: window.frame)
        window.setFrame(bounded(initial, inside: bounds), display: false)
    }

    private func saveHermesFrame(_ window: NSWindow) {
        guard window === detachedHermes, let screen = window.screen else { return }
        let key = Self.displayKey(for: screen)
        let frame = window.frame.offsetBy(dx: -screen.visibleFrame.minX, dy: -screen.visibleFrame.minY)
        let defaults = UserDefaults.standard
        defaults.set(NSStringFromRect(frame), forKey: "BlueyHermesLive.frame." + key)
        defaults.set(key, forKey: Self.hermesDisplayKey)
    }

    private static func bounded(_ frame: NSRect, inside bounds: NSRect) -> NSRect {
        let width = min(frame.width, bounds.width)
        let height = min(frame.height, bounds.height)
        return NSRect(x: min(max(frame.minX, bounds.minX), bounds.maxX - width),
                      y: min(max(frame.minY, bounds.minY), bounds.maxY - height),
                      width: width, height: height)
    }

    private static func keepVisible(_ window: NSWindow) {
        guard let bounds = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let frame = bounded(window.frame, inside: bounds)
        if frame != window.frame { window.setFrame(frame, display: false) }
    }

    func windowDidMove(_ notification: Notification) {
        if let window = notification.object as? NSWindow { saveHermesFrame(window) }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        if let window = notification.object as? NSWindow { saveHermesFrame(window) }
    }

    var keepsDockIcon = false

    @objc private func displaysChanged() {
        if let window { Self.keepVisible(window) }
        if let detachedHermes { Self.keepVisible(detachedHermes) }
    }

    func windowDidChangeScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window.screen == nil { Self.keepVisible(window) }
        saveHermesFrame(window)
    }

    func windowWillClose(_ notification: Notification) {
        if let closing = notification.object as? NSWindow, closing === detachedHermes {
            saveHermesFrame(closing)
            detachedHermes = nil
            model.hermesScreenDetached = false
            if window?.isVisible != true, !keepsDockIcon { NSApp.setActivationPolicy(.accessory) }
            return
        }
        panels.showHermesScreen = false
        if !keepsDockIcon, detachedHermes == nil { NSApp.setActivationPolicy(.accessory) }
    }

    @objc private func selectWorkspaceTab(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let tab = WorkspaceTab(rawValue: raw) else { return }
        show(tab: tab)
    }

    @objc private func showHermesFromMenu() {
        show(tab: .chat)
        model.openHermesScreen?(model.selectedWorkspaceThread)
    }

    private func mainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let app = NSMenu()
        if #available(macOS 15, *) {
            let meetings = app.addItem(withTitle: "Meeting-Aufnahmen …", action: #selector(AppDelegate.openMeetings), keyEquivalent: "")
            meetings.target = NSApp.delegate
            app.addItem(.separator())
        }
        app.addItem(withTitle: "Bluey ausblenden", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        app.addItem(withTitle: "Bluey beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Bearbeiten")
        edit.addItem(withTitle: "Widerrufen", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Wiederholen", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Ausschneiden", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Kopieren", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Einsetzen", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Alles auswählen", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: "Ansicht")
        for (index, tab) in WorkspaceTab.allCases.enumerated() {
            let item = viewMenu.addItem(withTitle: tab.title, action: #selector(selectWorkspaceTab(_:)),
                                        keyEquivalent: String(index + 1))
            item.representedObject = tab.rawValue
            item.target = self
        }
        viewMenu.addItem(.separator())
        let hermesItem = viewMenu.addItem(withTitle: "Hermes Live", action: #selector(showHermesFromMenu), keyEquivalent: "")
        hermesItem.target = self
        viewItem.submenu = viewMenu
        let windowItem = NSMenuItem(); main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Fenster")
        windowMenu.addItem(withTitle: "Schließen", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimieren", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        return main
    }
}

private struct MacWorkspaceRoot: View {
    @ObservedObject var model: WorkspaceModel
    let animator: FaceAnimator
    @ObservedObject var panels: MacWorkspacePanels
    var phoneName: () -> String?
    var openWebApp: () -> Void
    var pairPhone: () -> Void
    var openSettingsWindow: (() -> Void)?
    var openMeetings: (() -> Void)? = nil
    @AppStorage("workspaceTab") private var tabRaw = WorkspaceTab.chat.rawValue
    @State private var showSettings = false

    var body: some View {
        WorkspaceRootView(model: model,
                          tab: Binding(get: { WorkspaceTab(rawValue: tabRaw) ?? .chat }, set: { tabRaw = $0.rawValue }),
                          connectionName: phoneName().map { "iPhone: \($0)" } ?? "Dieser Mac",
                          openMeetings: openMeetings,
                          face: { MacFaceTab(model: model, animator: animator) },
                          settings: { MacWorkspaceSettings(openWebApp: openWebApp, pairPhone: pairPhone) },
                          showSettings: $showSettings,
                          showHermesScreen: $panels.showHermesScreen,
                          openSettingsWindow: openSettingsWindow)
            .frame(minWidth: 760, minHeight: 520)
    }
}

/// His face on the Mac, driven by the same cursor engine that drives the phone.
private struct MacFaceTab: View {
    @ObservedObject var model: WorkspaceModel
    let animator: FaceAnimator
    var body: some View {
        ZStack(alignment: .topLeading) {
            FaceView(animator: animator)
            if let focus = model.currentFocus, focus.status != .ended {
                VStack(alignment: .leading, spacing: 4) {
                    Text(focus.task).font(.fredoka(20)).foregroundStyle(.white)
                    Text("\(FocusSession.clock(focus.remaining)) · \(focus.detail)").font(.plexSans(13)).foregroundStyle(Theme.soft)
                }
                .padding(24)
            }
        }
    }
}

private struct MacWorkspaceSettings: View {
    @Environment(\.dismiss) private var dismiss
    var openWebApp: () -> Void
    var pairPhone: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                BlueyAvatar(mood: .happy).frame(width: 50, height: 45)
                Text("Einstellungen").font(.fredoka(24)).foregroundStyle(.white)
            }
            Text("Der OpenAI-Schlüssel, die Persönlichkeit und alles rund ums Zeigen findest du im Bluey-Menü in der Menüleiste.")
                .font(.plexSans(13)).foregroundStyle(Theme.soft)
            Button("Web-App im Browser öffnen") { openWebApp(); dismiss() }
            Button("iPhone koppeln (QR)…") { pairPhone(); dismiss() }
            HStack { Spacer(); Button("Fertig") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24)
        .frame(width: 420)
        .background(Theme.panel)
    }
}

/// `GooglyMac --workspace-preview [--data <folder>]`: the window and web app on port 4787+, nothing else
/// (no phone server, cursor or hot keys), so it can run next to the real Bluey while developing.
@MainActor
final class WorkspacePreview: NSObject, NSApplicationDelegate {
    private var store: WorkspaceStore!
    private var web: WebServer!
    private var window: WorkspaceWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Fonts.registerBundled()
        let args = CommandLine.arguments
        let folder = args.firstIndex(of: "--data").flatMap { args.indices.contains($0 + 1) ? URL(fileURLWithPath: args[$0 + 1]) : nil }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("bluey-workspace-preview")
        store = WorkspaceStore(folder: folder)
        store.start()
        web = WebServer(store: store)
        web.start(port: 4787)
        window = WorkspaceWindow(store: store)
        window.keepsDockIcon = true
        window.openWebApp = { [weak self] in if let url = self?.web.url { NSWorkspace.shared.open(url) } }
        window.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            print("Web app: \(self.web.url.absoluteString)")
            fflush(stdout)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { store.save() }
}
