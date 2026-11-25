import SwiftUI
#if canImport(GooglyShared)
import GooglyShared
#endif

/// Cross-platform Apple-Notes-style vector ink canvas (works with Huion Note USB/BLE live pen,
/// mouse/trackpad on Mac, and finger/Apple Pencil on iOS).
struct InkCanvasView: View {
    @Binding var drawing: InkDrawing
    var liveSample: HuionProtocol.PenSample?
    var liveSampleSeq: Int
    /// Returns the elapsed seconds of an active meeting/video recording, if any.
    var recordingOffsetProvider: (() -> Double?)? = nil
    var onStrokeCommitted: (() -> Void)?

    @State private var selectedColor = "#141820"
    @State private var tool: InkTool = .pen
    @State private var strokeSize: Double = 0.0034
    @State private var activeStroke: InkStroke?
    @State private var eraserMode = false
    @State private var hoverPoint: CGPoint?

    private static let lightColors: [(String, String)] = [
        ("Tinte", "#141820"),
        ("Bluey Blau", "#2563EB"),
        ("Rot", "#DC2626"),
        ("Grün", "#16A34A"),
        ("Gelb", "#EAB308"),
    ]

    private static let darkColors: [(String, String)] = [
        ("Weiß", "#F8FAFC"),
        ("Cyan", "#38BDF8"),
        ("Gelb", "#FACC15"),
        ("Rot", "#F87171"),
        ("Grün", "#4ADE80"),
    ]

    private var palette: [(String, String)] {
        drawing.paper.isLight ? Self.lightColors : Self.darkColors
    }

    var body: some View {
        VStack(spacing: 8) {
            toolbar
            canvasSurface
        }
        .onAppear {
            normalizeDefaultColor()
        }
        .onChange(of: drawing.paper) { _, _ in
            normalizeDefaultColor()
        }
        .onChange(of: liveSampleSeq) { _, _ in
            if let sample = liveSample {
                handleHardwarePen(sample)
            }
        }
    }

    private func normalizeDefaultColor() {
        if drawing.paper.isLight && selectedColor == "#F8FAFC" {
            selectedColor = "#141820"
        } else if !drawing.paper.isLight && selectedColor == "#141820" {
            selectedColor = "#F8FAFC"
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            // Color dots
            HStack(spacing: 6) {
                ForEach(palette, id: \.1) { entry in
                    Button {
                        eraserMode = false
                        selectedColor = entry.1
                    } label: {
                        Circle()
                            .fill(Color(inkHex: entry.1))
                            .frame(width: 16, height: 16)
                            .overlay(
                                Circle().stroke(
                                    !eraserMode && selectedColor == entry.1 ? Theme.accentLight : Color.white.opacity(0.25),
                                    lineWidth: !eraserMode && selectedColor == entry.1 ? 2.2 : 1
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .help(entry.0)
                }
            }

            Divider().frame(height: 16).overlay(Theme.line)

            // Pen / Highlighter / Eraser
            toolButton("pencil.tip", active: !eraserMode && tool == .pen, help: "Stift") {
                eraserMode = false; tool = .pen
            }
            toolButton("highlighter", active: !eraserMode && tool == .highlighter, help: "Textmarker") {
                eraserMode = false; tool = .highlighter
            }
            toolButton("eraser", active: eraserMode, help: "Strich-Radierer") {
                eraserMode.toggle()
            }

            // Stroke thickness
            Menu {
                Button("Fein") { strokeSize = 0.0022 }
                Button("Normal") { strokeSize = 0.0034 }
                Button("Dick") { strokeSize = 0.0056 }
            } label: {
                Image(systemName: "lineweight")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.soft)
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
            .help("Strichstärke")

            // Paper style
            Menu {
                ForEach(InkPaperStyle.allCases, id: \.self) { style in
                    Button {
                        drawing.paper = style
                        onStrokeCommitted?()
                    } label: {
                        if drawing.paper == style {
                            Label(style.title, systemImage: "checkmark")
                        } else {
                            Text(style.title)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "doc.plaintext")
                    Text(drawing.paper.title)
                }
                .font(.plexSans(11))
                .foregroundStyle(Theme.soft)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            Button {
                guard !drawing.strokes.isEmpty else { return }
                drawing.strokes.removeLast()
                onStrokeCommitted?()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 12))
                    .foregroundStyle(drawing.strokes.isEmpty ? Theme.soft.opacity(0.35) : Theme.soft)
            }
            .buttonStyle(.plain)
            .disabled(drawing.strokes.isEmpty)
            .help("Letzten Strich rückgängig machen")

            Button {
                guard !drawing.strokes.isEmpty else { return }
                drawing.strokes.removeAll()
                activeStroke = nil
                onStrokeCommitted?()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(drawing.strokes.isEmpty ? Theme.soft.opacity(0.35) : Theme.red.opacity(0.85))
            }
            .buttonStyle(.plain)
            .disabled(drawing.strokes.isEmpty)
            .help("Zeichnung leeren")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.line, lineWidth: 1))
    }

    private func toolButton(_ symbol: String, active: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(active ? .white : Theme.soft)
                .frame(width: 26, height: 24)
                .background(active ? Theme.blue.opacity(0.65) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var canvasSurface: some View {
        GeometryReader { geo in
            ZStack {
                paperBackground(size: geo.size)
                Canvas { ctx, size in
                    for stroke in drawing.strokes {
                        draw(stroke: stroke, in: &ctx, size: size)
                    }
                    if let active = activeStroke {
                        draw(stroke: active, in: &ctx, size: size)
                    }
                    if let hp = hoverPoint {
                        let pt = CGPoint(x: hp.x * size.width, y: hp.y * size.height)
                        let r: CGFloat = eraserMode ? 9 : 5
                        let ring = CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)
                        ctx.stroke(Path(ellipseIn: ring),
                                   with: .color(eraserMode ? Theme.red : Theme.accentLight),
                                   lineWidth: 1.5)
                    }
                }
                .allowsHitTesting(false)

                if drawing.strokes.isEmpty && activeStroke == nil {
                    VStack(spacing: 4) {
                        Image(systemName: "pencil.and.scribble")
                            .font(.system(size: 20))
                            .foregroundStyle(drawing.paper.isLight ? Color.black.opacity(0.28) : Color.white.opacity(0.28))
                        Text("Mit dem Huion-Stift oder Trackpad schreiben…")
                            .font(.plexSans(12))
                            .foregroundStyle(drawing.paper.isLight ? Color.black.opacity(0.35) : Color.white.opacity(0.35))
                    }
                    .allowsHitTesting(false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.line, lineWidth: 1))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard geo.size.width > 1, geo.size.height > 1 else { return }
                        let nx = min(max(value.location.x / geo.size.width, 0), 1)
                        let ny = min(max(value.location.y / geo.size.height, 0), 1)
                        if eraserMode {
                            eraseNear(nx: nx, ny: ny)
                        } else {
                            let pt = InkPoint(x: nx, y: ny, p: 0.55)
                            if activeStroke == nil {
                                activeStroke = InkStroke(color: selectedColor, width: strokeSize, tool: tool, points: [pt],
                                                         createdAt: Date(), recordingOffsetSeconds: recordingOffsetProvider?())
                            } else {
                                activeStroke?.points.append(pt)
                            }
                        }
                    }
                    .onEnded { _ in
                        commitActiveStroke()
                    }
            )
        }
        .aspectRatio(drawing.aspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func paperBackground(size: CGSize) -> some View {
        let light = drawing.paper.isLight
        ZStack {
            Rectangle().fill(light ? Color(inkHex: "#FAF8F3") : Color(inkHex: "#11161F"))
            if drawing.paper == .grid || drawing.paper == .lined {
                Canvas { ctx, s in
                    let step = max(14, s.width / 26.0)
                    let lineColor = light ? Color(inkHex: "#E4DFD3") : Color(inkHex: "#222B3B")
                    var path = Path()
                    var y = step
                    while y < s.height {
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: s.width, y: y))
                        y += step
                    }
                    if drawing.paper == .grid {
                        var x = step
                        while x < s.width {
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: s.height))
                            x += step
                        }
                    }
                    ctx.stroke(path, with: .color(lineColor), lineWidth: 0.75)
                }
                .allowsHitTesting(false)
            }
        }
    }

    private func handleHardwarePen(_ sample: HuionProtocol.PenSample) {
        if !sample.hovering {
            hoverPoint = nil
            commitActiveStroke()
            return
        }
        hoverPoint = CGPoint(x: sample.x, y: sample.y)
        let isErasing = eraserMode || sample.eraser
        if sample.touching {
            if isErasing {
                eraseNear(nx: sample.x, ny: sample.y)
            } else {
                let pt = InkPoint(x: sample.x, y: sample.y, p: max(0.08, sample.pressure))
                if activeStroke == nil {
                    activeStroke = InkStroke(color: selectedColor, width: strokeSize, tool: tool, points: [pt],
                                             createdAt: Date(), recordingOffsetSeconds: recordingOffsetProvider?())
                } else {
                    activeStroke?.points.append(pt)
                }
            }
        } else {
            commitActiveStroke()
        }
    }

    private func commitActiveStroke() {
        guard let stroke = activeStroke else { return }
        activeStroke = nil
        guard !stroke.points.isEmpty else { return }
        drawing.strokes.append(stroke.simplified(minDistance: 0.001))
        onStrokeCommitted?()
    }

    private func eraseNear(nx: Double, ny: Double) {
        let radiusSq = 0.025 * 0.025
        let before = drawing.strokes.count
        drawing.strokes.removeAll { stroke in
            stroke.points.contains { pt in
                let dx = pt.x - nx, dy = pt.y - ny
                return dx * dx + dy * dy <= radiusSq
            }
        }
        if drawing.strokes.count != before {
            onStrokeCommitted?()
        }
    }

    private func draw(stroke: InkStroke, in ctx: inout GraphicsContext, size: CGSize) {
        guard !stroke.points.isEmpty else { return }
        let color = Color(inkHex: stroke.color).opacity(stroke.tool == .highlighter ? 0.34 : 1.0)
        let baseW = max(1.1, stroke.width * size.width)
        if stroke.points.count == 1 {
            let p = stroke.points[0]
            let r = max(0.9, baseW * (0.45 + 0.85 * p.p) * 0.5)
            ctx.fill(Path(ellipseIn: CGRect(x: p.x * size.width - r, y: p.y * size.height - r, width: r * 2, height: r * 2)),
                     with: .color(color))
            return
        }
        if stroke.tool == .highlighter {
            var path = Path()
            path.move(to: CGPoint(x: stroke.points[0].x * size.width, y: stroke.points[0].y * size.height))
            for p in stroke.points.dropFirst() {
                path.addLine(to: CGPoint(x: p.x * size.width, y: p.y * size.height))
            }
            ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: baseW * 3.8, lineCap: .round, lineJoin: .round))
        } else {
            let pts = stroke.points
            for i in 1..<pts.count {
                let a = pts[i - 1], b = pts[i]
                var seg = Path()
                seg.move(to: CGPoint(x: a.x * size.width, y: a.y * size.height))
                seg.addLine(to: CGPoint(x: b.x * size.width, y: b.y * size.height))
                let w = max(0.8, baseW * (0.35 + 1.05 * ((a.p + b.p) * 0.5)))
                ctx.stroke(seg, with: .color(color), style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

private extension Color {
    init(inkHex: String) {
        let cleaned = inkHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if cleaned.count == 6, let val = UInt32(cleaned, radix: 16) {
            self.init(hex: val)
        } else {
            self = .white
        }
    }
}
