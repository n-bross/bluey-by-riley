import SwiftUI
import UIKit

/// Hub controls share Bluey's workspace palette in dark mode and adapt to the system in light mode.
enum T3 {
    private static func dynamic(_ light: UInt32, _ dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(UIColor { trait in
            let (hex, alpha) = trait.userInterfaceStyle == .dark ? (dark, darkAlpha) : (light, lightAlpha)
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
        })
    }

    static let screen = dynamic(0xFCFCFC, Palette.workspaceCanvas)
    static let card = dynamic(0xFFFFFF, Palette.workspaceSidebar)
    static let composerPanel = dynamic(0xFCFCFC, Palette.workspaceCanvas, lightAlpha: 0.88, darkAlpha: 0.92)
    static let composerSurface = dynamic(0xF4F4F5, Palette.workspaceRaised, lightAlpha: 0.94, darkAlpha: 0.9)
    static let composerBorder = dynamic(0xE4E4E7, Palette.workspaceEdge, lightAlpha: 0.8, darkAlpha: 0.8)
    static let foreground = dynamic(0x27272A, Palette.workspaceText)
    static let foregroundSecondary = dynamic(0x6F6F79, Palette.workspaceMuted)
    static let foregroundTertiary = dynamic(0x71717B, Palette.workspaceMuted)
    static let border = dynamic(0xE4E4E7, Palette.workspaceEdge)
    static let separator = dynamic(0xE4E4E7, Palette.workspaceEdge, lightAlpha: 0.55, darkAlpha: 0.55)
    static let subtle = dynamic(0xFAFAFA, Palette.workspaceSidebar)
    static let primary = dynamic(0x1B4ED8, Palette.berry3)
    static let primaryText = dynamic(0x1B4ED8, Palette.berry1)
    static let primaryForeground = Color.white
    static let input = dynamic(0xFFFFFF, Palette.workspaceSidebar)
    static let inputBorder = dynamic(0xD4D4D8, Palette.workspaceEdge)
    static let icon = dynamic(0x27272A, Palette.workspaceText)
    static let iconMuted = dynamic(0x71717B, Palette.workspaceMuted)
    static let userBubble = dynamic(0xEFEFF1, Palette.workspaceRaised)
    static let userBubbleForeground = dynamic(0x27272A, Palette.workspaceText)
    static let drawer = dynamic(0xFAFAFA, Palette.workspaceSidebar)
    static let drawerForeground = dynamic(0x27272A, Palette.workspaceText)
    static let drawerForegroundMuted = dynamic(0x71717B, Palette.workspaceMuted)
    static let drawerBorder = dynamic(0xE4E4E7, Palette.workspaceEdge)
    static let warning = dynamic(0xFCF4E8, 0x312108)
    static let warningForeground = dynamic(0xBB4D00, 0xFFB900)
    static let danger = dynamic(0xFCEBEC, 0x301214)
    static let dangerForeground = dynamic(0xC10007, 0xFF6467)
    static let success = dynamic(0x0A7D3E, 0x30D158)
    /// Pressed / active row background (T3's rgb(245 245 245 / 8%) in dark mode).
    static let rowActive = dynamic(0x000000, Palette.workspaceText, lightAlpha: 0.05, darkAlpha: 0.08)

    /// Bluey's compact type scale for Hub content.
    enum Size: CGFloat {
        case xs3 = 11, xs2 = 12, xs = 13, sm = 14, base = 16, lg = 18, xl = 21, xl2 = 26, xl3 = 30
        var lineHeight: CGFloat {
            switch self {
            case .xs3: return 14
            case .xs2: return 16
            case .xs: return 17
            case .sm: return 19
            case .base: return 23
            case .lg: return 23
            case .xl: return 28
            case .xl2: return 32
            case .xl3: return 36
            }
        }
    }

    enum Weight { case regular, medium, bold }

    static func font(_ size: Size, _ weight: Weight = .regular) -> Font {
        .plexSans(size.rawValue)
            .weight(weight == .bold ? .bold : weight == .medium ? .medium : .regular)
    }

    static func mono(_ size: Size) -> Font { .system(size: size.rawValue, design: .monospaced) }
}

extension View {
    /// Workspace text at a scale step, with its line height.
    func t3Text(_ size: T3.Size, _ weight: T3.Weight = .regular, color: Color = T3.foreground) -> some View {
        font(T3.font(size, weight))
            .lineSpacing(max(0, size.lineHeight - size.rawValue * 1.2))
            .foregroundStyle(color)
    }
}

/// Hub screens run in portrait; the app-wide orientation lock is main's `OrientationDelegate`.
enum OrientationLock {
    static func set(_ mask: UIInterfaceOrientationMask) {
        if mask == .landscape { OrientationDelegate.lock(.landscape, prefer: .landscapeRight) }
        else { OrientationDelegate.lock(.allButUpsideDown, prefer: .portrait) }
    }
}
