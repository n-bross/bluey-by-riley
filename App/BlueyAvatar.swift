import SwiftUI
#if canImport(GooglyShared)
import GooglyShared
#endif

/// A tiny Bluey: the blob with two googly eyes.
struct MiniBluey: View {
    var body: some View { BlueyAvatar(mood: .listening, animated: false) }
}

/// Bluey as an avatar: blinks, looks around a little, bobs while thinking, squints when happy.
struct BlueyAvatar: View {
    var mood: Mood = .listening
    var animated = true
    /// Where he looks, -1…1 on each axis. Nil lets him glance around by himself.
    var gaze: CGPoint? = nil

    var body: some View {
        if animated {
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                face(at: context.date.timeIntervalSinceReferenceDate)
            }
        } else {
            face(at: 0)
        }
    }

    private func face(at t: Double) -> some View {
        GeometryReader { geo in
            let w = min(geo.size.width, geo.size.height * 1.12)
            let blink = animated ? Self.blink(t) : 0
            let look = gaze ?? (animated ? Self.wander(t, mood: mood) : .zero)
            let bob = mood == .thinking ? sin(t * 5) * w * 0.03 : mood == .talking ? abs(sin(t * 9)) * w * 0.03 : 0
            let squint = mood == .happy ? 0.45 : mood == .sleepy ? 0.6 : 0
            ZStack {
                BlobShape().fill(BlobShape.linear)
                BlobShape().fill(RadialGradient(colors: [.white.opacity(0.35), .clear], center: UnitPoint(x: 0.3, y: 0.25),
                                                startRadius: 0, endRadius: w * 0.5))
                HStack(spacing: w * 0.1) {
                    ForEach(0..<2, id: \.self) { _ in
                        let eye = w * 0.26
                        ZStack {
                            Circle().fill(.white)
                            Circle().fill(Color(hex: Palette.ink))
                                .frame(width: eye * 0.46)
                                .offset(x: look.x * eye * 0.2, y: look.y * eye * 0.2)
                        }
                        .frame(width: eye, height: eye)
                        .scaleEffect(x: 1, y: max(0.08, 1 - max(blink, squint)), anchor: mood == .happy ? .top : .center)
                    }
                }
                .offset(y: -w * 0.04 - bob)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(1.12, contentMode: .fit)
        .accessibilityLabel("Bluey")
    }

    /// A blink every few seconds (sometimes a double blink).
    static func blink(_ t: Double) -> Double {
        let period = 4.3
        let phase = t.truncatingRemainder(dividingBy: period)
        func pulse(_ start: Double) -> Double {
            let d = phase - start
            guard d >= 0, d < 0.16 else { return 0 }
            return sin(d / 0.16 * .pi)
        }
        let seed = Int(t / period) % 3
        return max(pulse(0), seed == 0 ? pulse(0.24) : 0)
    }

    static func wander(_ t: Double, mood: Mood) -> CGPoint {
        switch mood {
        case .thinking: return CGPoint(x: 0.6, y: -0.6)
        case .sleepy, .resting: return CGPoint(x: 0, y: 0.4)
        default:
            let step = floor(t / 2.2)
            let x = sin(step * 12.9898) * 0.6
            let y = cos(step * 78.233) * 0.4
            return CGPoint(x: x, y: y)
        }
    }
}

/// Colors and small styles used across the workspace screens.
enum Theme {
    static let background = Color(hex: Palette.workspaceCanvas)
    static let panel = Color(hex: Palette.workspaceSidebar)
    static let raised = Color(hex: Palette.workspaceRaised)
    static let text = Color(hex: Palette.workspaceText)
    static let card = Color.white.opacity(0.06)
    static let cardStrong = Color(hex: Palette.workspaceRaised)
    static let line = Color(hex: Palette.workspaceEdge)
    static let soft = Color(hex: Palette.workspaceMuted)
    static let accent = Color(hex: Palette.berry2)
    static let accentLight = Color(hex: Palette.berry1)
    static let green = Color(hex: 0x5BE49B)
    static let peach = Color(hex: 0xFFB38A)
    static let red = Color(hex: 0xE5547A)
    static let yellow = Color(hex: 0xFFD66B)
    /// T3-style selection blue.
    static let blue = Color(hex: 0x4F8BFF)
}

struct SectionLabel: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.plexMono(11))
            .textCase(.uppercase)
            .foregroundStyle(Theme.soft)
    }
}

struct CardBackground: ViewModifier {
    var padding: CGFloat = 14
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

extension View {
    func card(padding: CGFloat = 14) -> some View { modifier(CardBackground(padding: padding)) }
}

/// A big friendly empty state with Bluey.
struct BlueyEmptyState: View {
    var title: String
    var subtitle: String
    var mood: Mood = .listening
    var body: some View {
        VStack(spacing: 14) {
            BlueyAvatar(mood: mood).frame(width: 110, height: 98)
            Text(title).font(.fredoka(22)).foregroundStyle(.white).multilineTextAlignment(.center)
            Text(subtitle).font(.plexSans(14)).foregroundStyle(Theme.soft).multilineTextAlignment(.center)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


#if os(macOS)
struct WorkspacePaneHeader<Leading: View, Actions: View>: View {
    let title: String
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: 8) {
            leading()
            Text(title).font(.plexSans(14)).fontWeight(.medium).lineLimit(1)
            Spacer(minLength: 4)
            actions()
        }
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}
#endif
