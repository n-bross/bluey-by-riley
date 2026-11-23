import AppKit
import QuartzCore
import GooglyShared

/// The Keramik look, shared by the drone pointer, the notch and the settings window.
enum Keramik {
    static let ceramic: UInt32 = 0xFFFFFF
    static let ceramicShade: UInt32 = 0xE5E5EA
    static let rim: UInt32 = 0xD1D1D6
    static let metal: UInt32 = 0xB8B8BE
    static let prop: UInt32 = 0x8E8E93
    static let visor: UInt32 = 0x1D1D1F
    static let glow: UInt32 = 0x64D2FF
    static let glowSoft: UInt32 = 0xBFE3FF
    static let accent: UInt32 = 0x0A84FF
    static let green: UInt32 = 0x30D158
    static let amber: UInt32 = 0xFFD60A
    static let red: UInt32 = 0xFF453A
}

/// What his pointer looks like.
enum PointerStyle: String, CaseIterable {
    /// A tiny Keramik drone that hovers over the target and lights it up.
    case drone
    /// The original blueberry teardrop with googly eyes.
    case blueberry

    var title: String { self == .drone ? "Keramik Drone" : "Blueberry" }
}

/// The drone pointer: a small Keramik drone (white ceramic body, black visor, glowing eyes, two rotors and a
/// cyan light underneath). Pointing, it hovers above the target and throws a cone of light onto it, with a
/// glowing frame around the thing itself. All layers, positioned every frame by `CursorView`.
final class DronePointer {
    let root = CALayer()          // whole drone, moved and tilted as one
    private let body = DroneBodyLayer()
    private let props: [CALayer] = [CALayer(), CALayer()]
    private let eyes: [CALayer] = [CALayer(), CALayer()]
    private let led = CALayer()
    let cone = CAGradientLayer()  // in overlay space, under the drone
    private let coneMask = CAShapeLayer()
    let ring = CAShapeLayer()      // the frame around the target
    private var built: (width: CGFloat, scale: CGFloat)?
    private var coneAmount: CGFloat = 0
    private var tilt: CGFloat = 0
    /// Where the drone's top edge is right now (overlay space, y down), for his speech bubble.
    private(set) var topCenter = CGPoint.zero

    init() {
        root.addSublayer(body)
        for p in props { root.addSublayer(p) }
        for e in eyes { root.addSublayer(e) }
        root.addSublayer(led)
        cone.colors = [NSColor(hex: Keramik.glow, alpha: 0.55).cgColor, NSColor(hex: Keramik.glow, alpha: 0.0).cgColor]
        cone.startPoint = CGPoint(x: 0.5, y: 1)   // layer space is y-up: top of the cone at the drone
        cone.endPoint = CGPoint(x: 0.5, y: 0)
        cone.mask = coneMask
        ring.fillColor = NSColor(hex: Keramik.glow, alpha: 0.06).cgColor
        ring.strokeColor = NSColor(hex: Keramik.glow).cgColor
        ring.lineWidth = 2.5
        ring.shadowColor = NSColor(hex: Keramik.glow).cgColor
        ring.shadowRadius = 8
        ring.shadowOpacity = 0.9
        ring.shadowOffset = .zero
        led.backgroundColor = NSColor(hex: Keramik.glow).cgColor
        led.shadowColor = NSColor(hex: Keramik.glow).cgColor
        led.shadowRadius = 5
        led.shadowOpacity = 1
        led.shadowOffset = .zero
        for e in eyes {
            e.backgroundColor = NSColor.white.cgColor
            e.shadowColor = NSColor(hex: Keramik.glowSoft).cgColor
            e.shadowRadius = 3
            e.shadowOpacity = 0.9
            e.shadowOffset = .zero
        }
        for p in props { p.backgroundColor = NSColor(hex: Keramik.prop, alpha: 0.75).cgColor }
    }

    /// Body width; the whole drone is about 1 × 0.7 of this.
    private func build(width w: CGFloat, scale: CGFloat) {
        if let b = built, b.width == w, b.scale == scale { return }
        built = (w, scale)
        let h = w * 0.72
        root.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        for l in [root, body, led, cone, coneMask, ring] + props + eyes { l.contentsScale = scale }
        body.frame = root.bounds
        body.setNeedsDisplay()
        body.displayIfNeeded()
        // Layer space is y-up. Rotors sit at the arms' tips, near the top.
        for (i, p) in props.enumerated() {
            p.bounds = CGRect(x: 0, y: 0, width: w * 0.34, height: w * 0.05)
            p.cornerRadius = w * 0.025
            p.position = CGPoint(x: i == 0 ? w * 0.13 : w * 0.87, y: h * 0.93)
        }
        let face = DroneBodyLayer.faceRect(in: root.bounds)
        for (i, e) in eyes.enumerated() {
            e.bounds = CGRect(x: 0, y: 0, width: face.width * 0.15, height: face.height * 0.5)
            e.cornerRadius = face.width * 0.075
            e.position = CGPoint(x: face.minX + face.width * (i == 0 ? 0.36 : 0.64), y: face.midY)
        }
        led.bounds = CGRect(x: 0, y: 0, width: w * 0.07, height: w * 0.07)
        led.cornerRadius = w * 0.035
        led.position = CGPoint(x: w * 0.5, y: h * 0.06)
    }

    /// Places the drone. `tip` is the point (overlay space, y down) he's showing; `target` the thing's frame.
    /// `pointing`: hovering over something (cone and frame on); otherwise it's just flying or parked.
    func update(tip: CGPoint, target: CGRect?, pointing: Bool, velocity: CGVector, size: CGFloat, now: Double,
                dt: Double, blinking: Bool, look: CGPoint, opacity: Float, bounds: CGSize, scale: CGFloat) {
        let w = size * 0.95
        build(width: w, scale: scale)
        let h = w * 0.72
        let gap = w * 0.95                                  // cone length when pointing
        let bob = CGFloat(sin(now * 2.6)) * w * 0.03         // gentle hover
        let top = target.map { min($0.minY, tip.y) } ?? tip.y
        let center = CGPoint(x: target?.midX ?? tip.x, y: (pointing ? top - gap : tip.y - h * 0.2) - h / 2 + bob)
        root.position = CGPoint(x: center.x, y: bounds.height - center.y)
        topCenter = CGPoint(x: center.x, y: center.y - h / 2)
        // Leans into its flight, like a real drone.
        let want = max(-0.35, min(0.35, velocity.dx / 1400))
        tilt += (want - tilt) * CGFloat(min(1, dt * 8))
        root.transform = CATransform3DMakeRotation(-tilt, 0, 0, 1)
        root.opacity = opacity
        // Spinning rotors: a quick squash-and-stretch reads as blur.
        for (i, p) in props.enumerated() {
            let spin = abs(CGFloat(sin(now * 46 + Double(i) * 1.3)))
            p.transform = CATransform3DMakeScale(0.35 + 0.65 * spin, 1, 1)
        }
        let face = DroneBodyLayer.faceRect(in: root.bounds)
        for (i, e) in eyes.enumerated() {
            let base = CGPoint(x: face.minX + face.width * (i == 0 ? 0.36 : 0.64), y: face.midY)
            e.position = CGPoint(x: base.x + look.x * face.width * 0.05, y: base.y - look.y * face.height * 0.08)
            e.transform = CATransform3DMakeScale(1, blinking ? 0.15 : 1, 1)
        }
        led.opacity = 0.75 + 0.25 * Float(sin(now * 3))

        // Cone and frame fade in once it's hovering.
        let wantCone: CGFloat = pointing ? 1 : 0
        coneAmount += (wantCone - coneAmount) * CGFloat(min(1, dt * 6))
        let ledPoint = CGPoint(x: center.x, y: center.y + h * 0.44)
        let footWidth = max(w * 0.6, min(target?.width ?? w * 0.6, w * 2.4) * 1.05)
        let footY = target.map { $0.minY + min($0.height, 30) * 0.5 } ?? tip.y
        let coneRect = CGRect(x: ledPoint.x - footWidth / 2, y: ledPoint.y, width: footWidth, height: max(1, footY - ledPoint.y))
        cone.frame = CGRect(x: coneRect.minX, y: bounds.height - coneRect.maxY, width: coneRect.width, height: coneRect.height)
        let m = CGMutablePath()
        let topHalf = w * 0.045
        m.move(to: CGPoint(x: coneRect.width / 2 - topHalf, y: coneRect.height))
        m.addLine(to: CGPoint(x: coneRect.width / 2 + topHalf, y: coneRect.height))
        m.addLine(to: CGPoint(x: coneRect.width, y: 0))
        m.addLine(to: CGPoint(x: 0, y: 0))
        m.closeSubpath()
        coneMask.frame = cone.bounds
        coneMask.path = m
        cone.opacity = Float(coneAmount) * opacity

        let frame = (target ?? CGRect(x: tip.x - 14, y: tip.y - 14, width: 28, height: 28)).insetBy(dx: -6, dy: -5)
        let flipped = CGRect(x: frame.minX, y: bounds.height - frame.maxY, width: frame.width, height: frame.height)
        ring.frame = CGRect(origin: .zero, size: bounds)
        ring.path = CGPath(roundedRect: flipped, cornerWidth: min(14, frame.height / 2), cornerHeight: min(14, frame.height / 2), transform: nil)
        ring.opacity = Float(coneAmount) * opacity
    }

    func hide() {
        root.opacity = 0; cone.opacity = 0; ring.opacity = 0
    }
}

/// The drone's static art: arms, ceramic body, black visor with a little slot on top.
final class DroneBodyLayer: CALayer {
    override init() { super.init(); needsDisplayOnBoundsChange = true }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The body (y-up layer space).
    static func bodyRect(in b: CGRect) -> CGRect {
        CGRect(x: b.width * 0.25, y: b.height * 0.1, width: b.width * 0.5, height: b.height * 0.62)
    }

    /// The black visor inside the body.
    static func faceRect(in b: CGRect) -> CGRect {
        bodyRect(in: b).insetBy(dx: b.width * 0.045, dy: b.height * 0.1).offsetBy(dx: 0, dy: -b.height * 0.02)
    }

    override func draw(in ctx: CGContext) {
        let b = bounds
        let w = b.width
        let body = Self.bodyRect(in: b)
        // Arms: from the body's shoulders out and up to the rotor hubs.
        ctx.setStrokeColor(NSColor(hex: Keramik.metal).cgColor)
        ctx.setLineWidth(w * 0.035)
        ctx.setLineCap(.round)
        for side in [-1.0, 1.0] as [CGFloat] {
            let shoulder = CGPoint(x: b.midX + side * body.width * 0.45, y: body.maxY - body.height * 0.25)
            let hub = CGPoint(x: b.midX + side * w * 0.37, y: b.height * 0.9)
            ctx.move(to: shoulder)
            ctx.addLine(to: CGPoint(x: hub.x, y: shoulder.y))
            ctx.addLine(to: hub)
            ctx.strokePath()
            ctx.setFillColor(NSColor(hex: Keramik.metal).cgColor)
            ctx.fillEllipse(in: CGRect(x: hub.x - w * 0.03, y: hub.y - w * 0.03, width: w * 0.06, height: w * 0.06))
        }
        // Soft shadow under the body.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -w * 0.02), blur: w * 0.06, color: NSColor(white: 0, alpha: 0.35).cgColor)
        let shell = CGPath(roundedRect: body, cornerWidth: body.height * 0.42, cornerHeight: body.height * 0.42, transform: nil)
        ctx.addPath(shell)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        // Ceramic: white with a cool shade toward the bottom, and a light rim.
        ctx.saveGState()
        ctx.addPath(shell)
        ctx.clip()
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        if let g = CGGradient(colorsSpace: space, colors: [NSColor.white.cgColor, NSColor(hex: Keramik.ceramicShade).cgColor] as CFArray,
                              locations: [0.35, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: body.midX, y: body.maxY), end: CGPoint(x: body.midX, y: body.minY), options: [])
        }
        ctx.restoreGState()
        ctx.addPath(shell)
        ctx.setStrokeColor(NSColor(hex: Keramik.rim).cgColor)
        ctx.setLineWidth(max(1, w * 0.012))
        ctx.strokePath()
        // Visor.
        let face = Self.faceRect(in: b)
        ctx.addPath(CGPath(roundedRect: face, cornerWidth: face.height * 0.45, cornerHeight: face.height * 0.45, transform: nil))
        ctx.setFillColor(NSColor(hex: Keramik.visor).cgColor)
        ctx.fillPath()
        // The little slot on top, like the hatch on his head.
        let slot = CGRect(x: body.midX - body.width * 0.18, y: body.maxY - body.height * 0.09, width: body.width * 0.36, height: max(1.5, body.height * 0.05))
        ctx.addPath(CGPath(roundedRect: slot, cornerWidth: slot.height / 2, cornerHeight: slot.height / 2, transform: nil))
        ctx.setStrokeColor(NSColor(hex: Keramik.rim).cgColor)
        ctx.setLineWidth(max(0.8, w * 0.008))
        ctx.strokePath()
    }
}
