import AppKit
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

/// The Bluey app window on the Mac: the same screens as on the iPhone, with a sidebar.
@MainActor
final class WorkspaceWindow: NSObject, NSWindowDelegate {
    let model: WorkspaceModel
    let animator = FaceAnimator()
    private let backend: LocalWorkspaceBackend
    private var window: NSWindow?
    var phoneName: () -> String? = { nil }
    var openWebApp: () -> Void = {}
    var pairPhone: () -> Void = {}
    var openMeetings: (() -> Void)? = nil

    init(store: WorkspaceStore) {
        backend = LocalWorkspaceBackend(store: store)
        model = WorkspaceModel(snapshot: store.snapshot)
        super.init()
        model.backend = backend
        model.setConnected(true)
        store.listen(snapshot: { [weak model] in model?.receive($0) }, delta: { [weak model] in model?.receive($0) })
    }

    func show(tab: WorkspaceTab? = nil) {
        if let tab { UserDefaults.standard.set(tab.rawValue, forKey: "workspaceTab") }
        if window == nil {
            let root = MacWorkspaceRoot(model: model, animator: animator, phoneName: phoneName, openWebApp: openWebApp, pairPhone: pairPhone, openMeetings: openMeetings)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Bluey"
            window.titlebarAppearsTransparent = true
            window.backgroundColor = .black
            window.minSize = NSSize(width: 760, height: 520)
            window.contentViewController = NSHostingController(rootView: root)
            window.setFrameAutosaveName("BlueyWorkspace")
            if !window.setFrameUsingName("BlueyWorkspace") { window.center() }
            window.isReleasedWhenClosed = false
            window.delegate = self
            self.window = window
        }
        // A real app while the window is open: Dock icon, ⌘Tab and a menu bar with Edit (copy/paste).
        NSApp.setActivationPolicy(.regular)
        NSApp.mainMenu = Self.mainMenu()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    var keepsDockIcon = false

    func windowWillClose(_ notification: Notification) {
        if !keepsDockIcon { NSApp.setActivationPolicy(.accessory) }
    }

    private static func mainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let app = NSMenu()
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
    var phoneName: () -> String?
    var openWebApp: () -> Void
    var pairPhone: () -> Void
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
                          showSettings: $showSettings)
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
