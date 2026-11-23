import SwiftUI

/// Liquid Glass where the system has it (iOS 26 / macOS 26), a frosted material elsewhere.
extension View {
    @ViewBuilder
    func glass<S: Shape>(in shape: S, interactive: Bool = true, tint: Color? = nil) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            self.glassEffect(Self.glassStyle(interactive: interactive, tint: tint), in: shape)
        } else {
            self.fallbackGlass(in: shape, tint: tint)
        }
        #else
        if #available(macOS 26.0, *) {
            self.glassEffect(Self.glassStyle(interactive: interactive, tint: tint), in: shape)
        } else {
            self.fallbackGlass(in: shape, tint: tint)
        }
        #endif
    }

    func glassCapsule(interactive: Bool = true, tint: Color? = nil) -> some View { glass(in: Capsule(), interactive: interactive, tint: tint) }
    func glassCircle(interactive: Bool = true, tint: Color? = nil) -> some View { glass(in: Circle(), interactive: interactive, tint: tint) }

    @available(iOS 26.0, macOS 26.0, *)
    private static func glassStyle(interactive: Bool, tint: Color?) -> Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        return interactive ? glass.interactive() : glass
    }

    private func fallbackGlass<S: Shape>(in shape: S, tint: Color?) -> some View {
        self
            .background(tint.map { AnyShapeStyle($0.opacity(0.85)) } ?? AnyShapeStyle(.ultraThinMaterial), in: shape)
            .overlay(shape.stroke(Color.white.opacity(0.1)))
    }
}

/// Groups glass shapes so they blend and morph together (iOS 26+); a plain container before.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: () -> Content
    var body: some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
        #else
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
        #endif
    }
}

/// A round glass icon button, like T3 Code's search button.
struct GlassIconButton: View {
    var icon: String
    var label: String
    var size: CGFloat = 52
    var tint: Color? = nil
    var foreground: Color = .white
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.4, weight: .medium))
                .foregroundStyle(foreground)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassCircle(tint: tint)
        .accessibilityLabel(label)
    }
}
