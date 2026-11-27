import AppKit
import Foundation

/// A local project folder that can receive tasks as new threads in T3 Code.
struct T3CodeProject: Identifiable, Hashable, Sendable {
    enum Source: String, Sendable {
        case saved, t3, repo, notes
    }

    var id: String { path }
    var name: String
    var path: String
    var source: Source
}

/// Outcome of starting a new T3 Code thread for a meeting task or note.
struct T3CodeSendResult: Equatable, Sendable {
    var threadID: String?
    var projectName: String
    var projectPath: String
    var rawOutput: String
}

/// Sends meeting tasks, notes, and transcript excerpts directly to T3 Code via the documented `t3` CLI.
enum T3CodeBridge {
    struct CommandOutput: Sendable {
        var exitCode: Int32
        var stdout: String
        var stderr: String
    }

    typealias CommandRunner = @Sendable (String, [String], String?) async throws -> CommandOutput

    enum Failure: LocalizedError {
        case cliNotFound
        case emptyPrompt
        case emptyProject
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .cliNotFound:
                return "Die `t3` CLI wurde nicht gefunden. Installiere T3 Code (oder führe `t3 install` aus) und versuche es erneut."
            case .emptyPrompt:
                return "Bitte gib eine Aufgabe oder Nachricht ein, bevor du sie an T3 Code sendest."
            case .emptyProject:
                return "Bitte wähle zuerst ein T3-Code-Projekt aus."
            case .commandFailed(let detail):
                return "T3 Code konnte die Aufgabe nicht annehmen: \(detail)"
            }
        }
    }

    private static let savedProjectsKey = "t3CodeSavedProjects"
    private static let lastProjectKey = "t3CodeLastProjectPath"
    private static let openAppAfterSendKey = "t3CodeOpenAppAfterSend"

    private static var candidateBinaries: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/opt/homebrew/bin/t3",
            "/usr/local/bin/t3",
            "\(home)/.t3/bin/t3",
            "\(home)/.local/bin/t3",
        ]
    }

    static var cliPath: String? {
        for path in candidateBinaries where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in pathEnv.split(separator: ":") {
            let candidate = String(dir) + "/t3"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    static var isInstalled: Bool { cliPath != nil }

    static var appBundleURL: URL? {
        let candidates = [
            "/Applications/T3 Code.app",
            "/Applications/T3 Code (Nightly).app",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/T3 Code.app").path,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/T3 Code (Nightly).app").path,
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    static var savedProjectPaths: [String] {
        get { UserDefaults.standard.stringArray(forKey: savedProjectsKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: savedProjectsKey) }
    }

    static var lastProjectPath: String? {
        get { UserDefaults.standard.string(forKey: lastProjectKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastProjectKey) }
    }

    static var openAppAfterSend: Bool {
        get { UserDefaults.standard.object(forKey: openAppAfterSendKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: openAppAfterSendKey) }
    }

    static func rememberProject(_ path: String) {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        var saved = savedProjectPaths
        if !saved.contains(normalized) {
            saved.insert(normalized, at: 0)
            savedProjectPaths = saved
        }
        lastProjectPath = normalized
    }

    /// Discovers local folders likely to be T3 Code projects (saved picks, ~/.t3/projects, ~/Programming, CodexProjects, Bluey Notes).
    static func discoverProjects() -> [T3CodeProject] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var seen = Set<String>()
        var projects: [T3CodeProject] = []

        func append(_ path: String, name: String? = nil, source: T3CodeProject.Source) {
            let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: normalized, isDirectory: &isDir), isDir.boolValue else { return }
            guard seen.insert(normalized).inserted else { return }
            let display = name ?? URL(fileURLWithPath: normalized).lastPathComponent
            projects.append(T3CodeProject(name: display, path: normalized, source: source))
        }

        // 1. Last used + explicitly saved projects first.
        if let last = lastProjectPath { append(last, source: .saved) }
        for path in savedProjectPaths { append(path, source: .saved) }

        // 2. Projects inside ~/.t3/projects
        let t3ProjectsDir = home.appendingPathComponent(".t3/projects", isDirectory: true)
        if let children = try? fm.contentsOfDirectory(at: t3ProjectsDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for child in children.sorted(by: { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }) {
                if (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    append(child.path, source: .t3)
                }
            }
        }

        // 3. Git repositories in ~/Programming (1 level deep) and CodexProjects (~/Documents)
        let programmingDir = home.appendingPathComponent("Programming", isDirectory: true)
        if let children = try? fm.contentsOfDirectory(at: programmingDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for child in children.sorted(by: { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }) {
                if (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                   fm.fileExists(atPath: child.appendingPathComponent(".git").path) {
                    append(child.path, source: .repo)
                }
            }
        }
        for repo in CodexProjects.all() {
            append(repo.path, name: repo.name, source: .repo)
        }

        // 4. Bluey Notes itself as a clean catch-all workspace for non-repo tasks.
        try? fm.createDirectory(at: MeetingNotes.root, withIntermediateDirectories: true)
        append(MeetingNotes.root.path, name: "Bluey Notes (Meetings)", source: .notes)

        return projects
    }

    @MainActor
    static func pickProjectFolder() -> T3CodeProject? {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Als T3-Projekt wählen"
        panel.message = "Wähle den Projektordner, in dem T3 Code die Aufgabe starten soll."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        rememberProject(url.path)
        return T3CodeProject(name: url.lastPathComponent, path: url.standardizedFileURL.path, source: .saved)
    }

    /// Formats a clean, self-contained task prompt for T3 Code with meeting context and file references.
    static func buildPrompt(
        taskTitle: String,
        taskDetails: String = "",
        meetingTitle: String,
        meetingDate: Date,
        durationText: String,
        notesFilePath: String? = nil,
        transcriptFilePath: String? = nil,
        excerpt: String? = nil
    ) -> String {
        let dateText = meetingDate.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().locale(Locale(identifier: "de_DE")))
        var sections: [String] = []
        sections.append("Aufgabe aus Meeting „\(meetingTitle)“ (\(dateText), Dauer: \(durationText)):")
        sections.append(taskTitle.trimmingCharacters(in: .whitespacesAndNewlines))

        let cleanDetails = taskDetails.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanDetails.isEmpty {
            sections.append("Details:\n\(cleanDetails)")
        }
        if let excerpt = excerpt?.trimmingCharacters(in: .whitespacesAndNewlines), !excerpt.isEmpty {
            sections.append("Relevanter Auszug aus dem Meeting:\n\(String(excerpt.prefix(2500)))")
        }

        var refs: [String] = []
        if let notesFilePath, !notesFilePath.isEmpty { refs.append("- Notizen: \(notesFilePath)") }
        if let transcriptFilePath, !transcriptFilePath.isEmpty { refs.append("- Transkript: \(transcriptFilePath)") }
        if !refs.isEmpty {
            sections.append("Meeting-Dateien (bei Bedarf für mehr Kontext lesen):\n" + refs.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    /// Sends a task directly to T3 Code by starting a new thread on the local T3 Code server.
    static func sendTask(
        title: String,
        prompt: String,
        projectPath: String,
        worktreeBase: String? = nil,
        openApp: Bool? = nil,
        cliOverride: String? = nil,
        runner: CommandRunner = { try await T3CodeBridge.runProcess(executable: $0, arguments: $1, stdinText: $2) }
    ) async throws -> T3CodeSendResult {
        let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPrompt.isEmpty else { throw Failure.emptyPrompt }
        let cleanPath = projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPath.isEmpty else { throw Failure.emptyProject }
        guard let binary = cliOverride ?? cliPath else { throw Failure.cliNotFound }

        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var args = ["thread", "start", "--json"]
        if !cleanTitle.isEmpty {
            args += ["--title", String(cleanTitle.prefix(90))]
        } else {
            args += ["--generate-title"]
        }
        if let base = worktreeBase?.trimmingCharacters(in: .whitespacesAndNewlines), !base.isEmpty {
            args += ["--worktree", base]
        }
        args += [cleanPath, "-"]

        var result = try await runner(binary, args, cleanPrompt)
        if result.exitCode != 0 && shouldAutoAddProject(stderr: result.stderr, stdout: result.stdout) {
            let addResult = try await runner(binary, ["project", "add", cleanPath], nil)
            if addResult.exitCode == 0 {
                result = try await runner(binary, args, cleanPrompt)
            }
        }

        guard result.exitCode == 0 else {
            let reason = [result.stderr, result.stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? "Exit-Code \(result.exitCode)"
            throw Failure.commandFailed(String(reason.prefix(260)))
        }

        let threadID = parseThreadID(from: result.stdout)
        let projectName = URL(fileURLWithPath: cleanPath).lastPathComponent
        if cliOverride == nil {
            rememberProject(cleanPath)
            if openApp ?? openAppAfterSend {
                await openInT3Code(projectPath: cleanPath)
            }
        }
        return T3CodeSendResult(
            threadID: threadID,
            projectName: projectName,
            projectPath: cleanPath,
            rawOutput: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    static func openInT3Code(projectPath: String? = nil) async {
        if let binary = cliPath, let projectPath, !projectPath.isEmpty {
            if let out = try? await runProcess(executable: binary, arguments: ["app", projectPath], stdinText: nil), out.exitCode == 0 {
                return
            }
        }
        await MainActor.run {
            if let appURL = appBundleURL {
                NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
            } else if let url = URL(string: "t3code://") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    static func parseThreadID(from stdout: String) -> String? {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let id = json["threadId"] as? String, !id.isEmpty { return id }
            if let id = json["id"] as? String, !id.isEmpty { return id }
            if let thread = json["thread"] as? [String: Any], let id = thread["id"] as? String, !id.isEmpty { return id }
        }
        // Plain text mode prints the thread ID on the first line.
        let firstLine = trimmed.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces)
        return firstLine?.isEmpty == false ? firstLine : nil
    }

    private static func shouldAutoAddProject(stderr: String, stdout: String) -> Bool {
        let combined = (stderr + "\n" + stdout).lowercased()
        return combined.contains("project") && (
            combined.contains("not found")
            || combined.contains("unknown")
            || combined.contains("no project")
            || combined.contains("not registered")
            || combined.contains("add it first")
        )
    }

    /// Executes a CLI process off the main actor with safe concurrent stdout/stderr draining.
    static func runProcess(executable: String, arguments: [String], stdinText: String?) async throws -> CommandOutput {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(FileManager.default.homeDirectoryForCurrentUser.path)/.t3/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
                process.environment = env

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                let stdinPipe = Pipe()
                if stdinText != nil {
                    process.standardInput = stdinPipe
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                if let stdinText {
                    if let data = stdinText.data(using: .utf8) {
                        stdinPipe.fileHandleForWriting.write(data)
                    }
                    try? stdinPipe.fileHandleForWriting.close()
                }

                let group = DispatchGroup()
                var outData = Data()
                var errData = Data()

                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }

                process.waitUntilExit()
                group.wait()

                let output = CommandOutput(
                    exitCode: process.terminationStatus,
                    stdout: String(data: outData, encoding: .utf8) ?? "",
                    stderr: String(data: errData, encoding: .utf8) ?? ""
                )
                continuation.resume(returning: output)
            }
        }
    }
}
