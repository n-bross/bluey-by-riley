import AppKit
import GooglyShared
import SwiftUI

@MainActor
final class BlueyControlWindow {
    private var window: NSWindow?

    func show<Content: View>(@ViewBuilder content: () -> Content) {
        if window == nil {
            let panel = NSWindow(contentViewController: NSHostingController(rootView: content()))
            panel.title = "Bluey · Steuerung"
            panel.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            panel.setContentSize(NSSize(width: 480, height: 540))
            panel.contentMinSize = NSSize(width: 390, height: 490)
            panel.isReleasedWhenClosed = false
            panel.appearance = NSAppearance(named: .darkAqua)
            if !panel.setFrameUsingName("BlueyControl") { panel.center() }
            panel.setFrameAutosaveName("BlueyControl")
            window = panel
        }
        NSApp.activate(ignoringOtherApps: true)
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
    }
}

struct BlueyControlView: View {
    let animator: FaceAnimator
    let openSection: (WorkspaceTab) -> Void
    let toggleListening: () -> Void
    let isListening: () -> Bool
    let openLive: () -> Void
    let openMeetings: (() -> Void)?
    let stopActions: () -> Void
    let openSettings: () -> Void
    @AppStorage(AvatarStyle.defaultsKey) private var avatar = AvatarStyle.keramik3D

    var body: some View {
        VStack(spacing: 14) {
            TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
                Group {
                    if avatar == .bluey {
                        FaceView(animator: animator)
                    } else {
                        let frame = animator.step(timeline.date.timeIntervalSinceReferenceDate)
                        KeramikAvatarView(mood: KeramikMapping.mood(frame.mood), gaze: frame.gaze,
                                          zoom: avatar == .keramik3D ? 1.0 : 1.25,
                                          model3D: avatar == .keramik3D)
                            .id(avatar.rawValue)
                    }
                }
            }
            .frame(minHeight: 170, maxHeight: .infinity)
            .background(Theme.panel)
            .clipShape(.rect(cornerRadius: 14))

            HStack {
                Picker("Avatar", selection: $avatar) {
                    ForEach(AvatarStyle.allCases, id: \.self) { style in
                        Text(style.title).tag(style)
                    }
                }
                Spacer()
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    let listening = isListening()
                    Button(listening ? "Zuhören beenden" : "Zuhören starten",
                           systemImage: listening ? "mic.slash" : "mic",
                           action: toggleListening)
                }
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(WorkspaceTab.allCases.filter { $0 != .face }) { section in
                    control(section.title, icon: section.icon) { openSection(section) }
                }
                control("Hermes Live", icon: "display", openLive)
                if let openMeetings { control("Meeting-Aufnahmen", icon: "record.circle", openMeetings) }
                control("Einstellungen", icon: "gearshape", openSettings)
            }

            Button("Aktionen stoppen", systemImage: "stop.circle", action: stopActions)
                .tint(.red)
        }
        .padding(18)
        .background(Theme.background)
    }

    private func control(_ title: String, icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Theme.panel, in: .rect(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
