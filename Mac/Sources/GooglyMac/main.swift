import AppKit
import GooglyShared

MainActor.assumeIsolated {
    if CommandLine.arguments.contains("--focus-link-test") || CommandLine.arguments.contains("--focus-developer-test") || CommandLine.arguments.contains("--focus-nudge-test") {
        Task { @MainActor in exit(await FocusLinkProbe.run(developerMode: CommandLine.arguments.contains("--focus-developer-test"),
                                                          nudge: CommandLine.arguments.contains("--focus-nudge-test"))) }
        NSApplication.shared.run()
        return
    }
    if CommandLine.arguments.contains("--focus-api-test") || CommandLine.arguments.contains("--focus-screen-test") {
        Task { @MainActor in exit(await FocusDiagnostics.run(realScreen: CommandLine.arguments.contains("--focus-screen-test"))) }
        NSApplication.shared.run()
        return
    }
    if let i = CommandLine.arguments.firstIndex(of: "--journal") {
        // Prints a day's journal (default today) from ActivityWatch and the saved focus history. Sends nothing.
        let day = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : "today"
        Task { @MainActor in
            let journal = ActivityJournal()
            let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Googly/focus-history.json")
            let history = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([FocusSession].self, from: $0) } ?? []
            journal.focusHistory = { history }
            guard let date = ActivityJournal.resolveDay(day) else { print("Unknown day"); exit(1) }
            do { print(try await journal.markdown(for: date)); exit(0) } catch { print(error.localizedDescription); exit(1) }
        }
        NSApplication.shared.run()
        return
    }
    if let i = CommandLine.arguments.firstIndex(of: "--hermes-test") {
        // Live probe: today's ActivityWatch summary, then one real Hermes request (default: a harmless ping).
        let prompt = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : "Reply with exactly: pong"
        Task { @MainActor in exit(await HermesProbe.run(prompt: prompt)) }
        NSApplication.shared.run()
        return
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)  // menu bar only, no Dock icon
    app.run()
}
