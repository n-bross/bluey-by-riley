import SwiftUI
import WebKit
import GooglyShared

enum HermesWindowPlacement: String, CaseIterable, Identifiable {
    case left = "Linke Hälfte"
    case right = "Rechte Hälfte"
    case center = "Zentrieren"
    var id: Self { self }

    func frame(in bounds: CGRect, current: CGRect) -> CGRect {
        if self == .center {
            let width = min(current.width, bounds.width)
            let height = min(current.height, bounds.height)
            return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
        }
        let width = min(bounds.width, max(320, bounds.width / 2))
        return CGRect(x: self == .left ? bounds.minX : bounds.maxX - width, y: bounds.minY,
                      width: width, height: bounds.height)
    }
}

/// The same Hub-hosted interactive viewer used on iPhone, alongside the Mac workspace.
struct MacHermesScreenPane: View {
    @ObservedObject var model: WorkspaceModel
    let close: () -> Void
    var move: (() -> Void)?
    var detached = false
    var snap: ((HermesWindowPlacement) -> Void)?
    @State private var request: URLRequest?
    @State private var connection = UUID()
    @State private var issue: String?

    private func contextTitle(_ thread: ChatThread?) -> String {
        guard let thread else { return "Neuer Chat" }
        if thread.id != model.selectedWorkspaceThread { return "Hermes arbeitet in „\(thread.title)“" }
        return "Chat · \(thread.title)"
    }

    var body: some View {
        let thread = model.hermesScreenThread()
        let activity = thread.flatMap { model.screenTool(for: $0) }
        let approvals = model.hermesApprovals.filter { $0.threadID == thread?.id }
        VStack(spacing: 0) {
            WorkspacePaneHeader(title: "Hermes Live", leading: { HermesModelIcon(size: 16) }, actions: {
                HStack(spacing: 4) {
                    if let snap {
                        Menu {
                            ForEach(HermesWindowPlacement.allCases) { placement in
                                Button(placement.rawValue) { snap(placement) }
                            }
                        } label: { Image(systemName: "rectangle.split.2x1") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .help("Fenster anordnen").accessibilityLabel("Fenster anordnen")
                    }
                    if let move {
                        action(detached ? "Andocken" : "Abdocken",
                               symbol: detached ? "rectangle.inset.filled.trailing" : "macwindow.on.rectangle", run: move)
                    }
                    action("Neu verbinden", symbol: "arrow.clockwise", run: reconnect)
                    action("Hermes Live schließen", symbol: "xmark", run: close)
                }
            })
            if let request, issue == nil {
                MacHermesScreenWebView(request: request) { issue = $0 }
                    .id(connection)
                    .frame(minHeight: 140, maxHeight: .infinity)
            } else if let issue {
                VStack(spacing: 8) {
                    Text(issue).font(.plexSans(13)).foregroundStyle(Theme.soft)
                        .multilineTextAlignment(.center)
                    Button("Neu verbinden", action: reconnect).buttonStyle(.bordered)
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider().overlay(Theme.line)
            VStack(alignment: .leading, spacing: 7) {
                Text(contextTitle(thread))
                    .fontWeight(.medium).foregroundStyle(Theme.text).lineLimit(2)
                if let thread, thread.model == "hermes", thread.isStreaming || !approvals.isEmpty {
                    WorkspaceHermesActivity(
                        title: approvals.isEmpty ? (activity?.title ?? "Hermes arbeitet …") : "Wartet auf deine Antwort",
                        tool: activity,
                        stop: thread.isStreaming ? { model.stop(threadID: thread.id) } : nil
                    )
                } else {
                    Label("Keine aktive Bildschirmaktion", systemImage: "display")
                        .foregroundStyle(Theme.soft)
                }
                if !approvals.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            if let respond = model.answerHermesApproval {
                                ForEach(approvals) { approval in
                                    WorkspaceHermesPromptCard(prompt: approval.prompt) { answer in
                                        try await respond(approval, answer)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 168)
                }
            }
            .font(.plexSans(12))
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel)
        }
        .background(Theme.background)
        .onAppear(perform: reconnect)
    }

    private func action(_ title: String, symbol: String, run: @escaping () -> Void) -> some View {
        Button(action: run) { Image(systemName: symbol).frame(width: 24, height: 28) }
            .buttonStyle(.plain).help(title).accessibilityLabel(title)
    }

    private func reconnect() {
        let base = HubSettings.url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/screen"),
              let scheme = url.scheme, ["https", "http"].contains(scheme), url.host != nil else {
            issue = "Hinterlege die Bluey-Hub-Adresse in den Hermes-Einstellungen."
            request = nil
            return
        }
        var next = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        if !HubSettings.key.isEmpty {
            next.setValue("Bearer \(HubSettings.key)", forHTTPHeaderField: "Authorization")
        }
        request = next
        issue = nil
        connection = UUID()
    }
}

private struct MacHermesScreenWebView: NSViewRepresentable {
    let request: URLRequest
    let onIssue: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(url: request.url, onIssue: onIssue) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        HermesViewerPresentation.apply(to: config)
        let view = WKWebView(frame: .zero, configuration: config)
        view.underPageBackgroundColor = NSColor(Theme.background)
        view.navigationDelegate = context.coordinator
        view.load(request)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.navigationDelegate = nil
        view.evaluateJavaScript("window.dispatchEvent(new Event('pagehide'))", completionHandler: nil)
        view.stopLoading()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let url: URL?
        let onIssue: (String) -> Void

        init(url: URL?, onIssue: @escaping (String) -> Void) {
            self.url = url
            self.onIssue = onIssue
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.targetFrame?.isMainFrame == true && action.request.url == url ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            guard let http = response.response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                decisionHandler(.cancel)
                onIssue("Hermes Live ist über diesen Bluey Hub nicht erreichbar. Prüfe die Bot-Desktop-Einrichtung.")
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { onIssue(error.localizedDescription) }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            onIssue("Der Stream wurde beendet. Verbinde dich erneut.")
        }
    }
}
