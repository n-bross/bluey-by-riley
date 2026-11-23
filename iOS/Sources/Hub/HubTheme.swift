import SwiftUI
import UIKit

/// T3 Code's mobile design system (pingdotgg/t3code, apps/mobile, MIT): the default light and dark
/// palettes from `generated-uniwind-themes.css`, DM Sans and its type scale from `global.css`.
/// Every colour adapts to light and dark mode like the original.
enum T3 {
    private static func dynamic(_ light: UInt32, _ dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(UIColor { trait in
            let (hex, alpha) = trait.userInterfaceStyle == .dark ? (dark, darkAlpha) : (light, lightAlpha)
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
        })
    }

    static let screen = dynamic(0xFCFCFC, 0x0A0A0A)
    static let card = dynamic(0xFFFFFF, 0x111111)
    static let composerPanel = dynamic(0xFCFCFC, 0x0A0A0A, lightAlpha: 0.88, darkAlpha: 0.92)
    static let composerSurface = dynamic(0xF4F4F5, 0x1A1B1B, lightAlpha: 0.94, darkAlpha: 0.9)
    static let composerBorder = dynamic(0xE4E4E7, 0x191919, lightAlpha: 0.8, darkAlpha: 0.8)
    static let foreground = dynamic(0x27272A, 0xF5F5F5)
    static let foregroundSecondary = dynamic(0x6F6F79, 0x838383)
    static let foregroundTertiary = dynamic(0x71717B, 0x818181)
    static let border = dynamic(0xE4E4E7, 0x191919)
    static let separator = dynamic(0xE4E4E7, 0x191919, lightAlpha: 0.55, darkAlpha: 0.55)
    static let subtle = dynamic(0xFAFAFA, 0x111111)
    static let primary = dynamic(0x1B4ED8, 0x346BF1)
    static let primaryText = dynamic(0x1B4ED8, 0x4B7CF3)
    static let primaryForeground = Color.white
    static let input = dynamic(0xFFFFFF, 0x111111)
    static let inputBorder = dynamic(0xD4D4D8, 0x1E1E1E)
    static let icon = dynamic(0x27272A, 0xF5F5F5)
    static let iconMuted = dynamic(0x71717B, 0x818181)
    static let userBubble = dynamic(0xEFEFF1, 0x161616)
    static let userBubbleForeground = dynamic(0x27272A, 0xF5F5F5)
    static let drawer = dynamic(0xFAFAFA, 0x000000)
    static let drawerForeground = dynamic(0x27272A, 0xF1F3F7)
    static let drawerForegroundMuted = dynamic(0x71717B, 0xA3A3A3)
    static let drawerBorder = dynamic(0xE4E4E7, 0x141414)
    static let warning = dynamic(0xFCF4E8, 0x312108)
    static let warningForeground = dynamic(0xBB4D00, 0xFFB900)
    static let danger = dynamic(0xFCEBEC, 0x301214)
    static let dangerForeground = dynamic(0xC10007, 0xFF6467)
    static let success = dynamic(0x0A7D3E, 0x30D158)
    /// Pressed / active row background (T3's rgb(245 245 245 / 8%) in dark mode).
    static let rowActive = dynamic(0x000000, 0xF5F5F5, lightAlpha: 0.05, darkAlpha: 0.08)

    /// T3's type scale (size, line height) with DM Sans.
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
        let name: String
        switch weight {
        case .regular: name = "DMSans-Regular"
        case .medium: name = "DMSans-Medium"
        case .bold: name = "DMSans-Bold"
        }
        return .custom(name, size: size.rawValue)
    }

    static func mono(_ size: Size) -> Font { .system(size: size.rawValue, design: .monospaced) }
}

extension View {
    /// T3 text: DM Sans at a scale step, with its line height.
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
