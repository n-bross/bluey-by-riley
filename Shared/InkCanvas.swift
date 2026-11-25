import Foundation

/// Drawing tool for vector ink strokes.
public enum InkTool: String, Codable, Equatable, Sendable {
    case pen
    case highlighter
}

/// Visual paper background for handwritten notes.
public enum InkPaperStyle: String, Codable, Equatable, Sendable, CaseIterable {
    case paper
    case grid
    case lined
    case dark

    public var title: String {
        switch self {
        case .paper: return "Papier"
        case .grid: return "Karo"
        case .lined: return "Liniert"
        case .dark: return "Dunkel"
        }
    }

    public var isLight: Bool { self != .dark }
}

/// One normalized sample along a stroke: coordinates in 0...1, pressure in 0...1.
public struct InkPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var p: Double

    public init(x: Double, y: Double, p: Double = 0.5) {
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, 0), 1)
        self.p = min(max(p, 0), 1)
    }
}

/// A single continuous pen or highlighter stroke in normalized canvas space.
public struct InkStroke: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var color: String
    /// Relative stroke width (fraction of canvas width, e.g. 0.0032 for a fine pen).
    public var width: Double
    public var tool: InkTool
    public var points: [InkPoint]
    /// Wall-clock timestamp when this stroke started.
    public var createdAt: Date?
    /// Elapsed seconds from the start of a live meeting / video recording (e.g. 252.4 -> 04:12).
    public var recordingOffsetSeconds: Double?

    public init(id: UUID = UUID(), color: String = "#141820", width: Double = 0.0034,
                tool: InkTool = .pen, points: [InkPoint] = [],
                createdAt: Date? = nil, recordingOffsetSeconds: Double? = nil) {
        self.id = id
        self.color = color
        self.width = width
        self.tool = tool
        self.points = points
        self.createdAt = createdAt
        self.recordingOffsetSeconds = recordingOffsetSeconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? "#141820"
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 0.0034
        tool = try c.decodeIfPresent(InkTool.self, forKey: .tool) ?? .pen
        points = try c.decodeIfPresent([InkPoint].self, forKey: .points) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        recordingOffsetSeconds = try c.decodeIfPresent(Double.self, forKey: .recordingOffsetSeconds)
    }

    /// Drops redundant near-duplicate points to keep storage and sync fast without losing detail.
    public func simplified(minDistance: Double = 0.0012) -> InkStroke {
        guard points.count > 2 else { return self }
        let thresholdSq = minDistance * minDistance
        var kept: [InkPoint] = [points[0]]
        kept.reserveCapacity(points.count)
        for pt in points.dropFirst().dropLast() {
            let last = kept[kept.count - 1]
            let dx = pt.x - last.x
            let dy = pt.y - last.y
            let dp = abs(pt.p - last.p)
            if dx * dx + dy * dy >= thresholdSq || dp >= 0.08 {
                kept.append(pt)
            }
        }
        kept.append(points[points.count - 1])
        var copy = self
        copy.points = kept
        return copy
    }
}

/// A handwritten vector page (synced between Mac, iPhone and Web, and exportable to SVG/PNG).
public struct InkDrawing: Codable, Equatable, Sendable {
    /// Default A5 portrait aspect ratio matching Huion Note X10 (28200 / 37400).
    public static let huionAspectRatio: Double = 28200.0 / 37400.0

    public var aspectRatio: Double
    public var paper: InkPaperStyle
    public var strokes: [InkStroke]

    public init(aspectRatio: Double = InkDrawing.huionAspectRatio,
                paper: InkPaperStyle = .paper,
                strokes: [InkStroke] = []) {
        self.aspectRatio = aspectRatio > 0.1 ? aspectRatio : InkDrawing.huionAspectRatio
        self.paper = paper
        self.strokes = strokes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let ratio = try c.decodeIfPresent(Double.self, forKey: .aspectRatio) ?? InkDrawing.huionAspectRatio
        self.aspectRatio = ratio > 0.1 ? ratio : InkDrawing.huionAspectRatio
        self.paper = try c.decodeIfPresent(InkPaperStyle.self, forKey: .paper) ?? .paper
        self.strokes = try c.decodeIfPresent([InkStroke].self, forKey: .strokes) ?? []
    }

    public var isEmpty: Bool { strokes.allSatisfy { $0.points.isEmpty } }

    public var pointCount: Int { strokes.reduce(0) { $0 + $1.points.count } }

    /// Earliest and latest video/meeting recording offset across all strokes in this drawing.
    public var videoTimeRange: (start: Double, end: Double)? {
        let offsets = strokes.compactMap(\.recordingOffsetSeconds).filter { $0 >= 0 }
        guard let lo = offsets.min(), let hi = offsets.max() else { return nil }
        return (lo, hi)
    }

    /// Formats elapsed seconds as `MM:SS` (or `H:MM:SS` for >= 1 hour).
    public static func formatVideoTime(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    /// Filename-safe timecode stamp such as `04m12s` or `1h04m12s`.
    public static func formatFileTime(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%dh%02dm%02ds", h, m, s) }
        return String(format: "%02dm%02ds", m, s)
    }

    /// Renders a clean, self-contained vector SVG suitable for archiving or browser display.
    public func toSVG(width: Double = 846, height: Double? = nil, forceLightPaper: Bool = false) -> String {
        let w = max(100, width)
        let h = max(100, height ?? (w / aspectRatio))
        let light = forceLightPaper || paper.isLight
        let bg = light ? "#FAF8F3" : "#11161F"

        func fmt(_ v: Double) -> String { String(format: "%.2f", v) }

        var lines: [String] = []
        lines.append("""
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(fmt(w)) \(fmt(h))" width="\(fmt(w))" height="\(fmt(h))">
        """)
        lines.append(#"  <rect width="100%" height="100%" fill="\#(bg)"/>"#)

        if paper == .grid || paper == .lined {
            let step = w / 28.0
            let guideColor = light ? "#E4DFD3" : "#222B3B"
            lines.append(#"  <g stroke="\#(guideColor)" stroke-width="0.75">"#)
            var y = step
            while y < h {
                lines.append(#"    <line x1="0" y1="\#(fmt(y))" x2="\#(fmt(w))" y2="\#(fmt(y))"/>"#)
                y += step
            }
            if paper == .grid {
                var x = step
                while x < w {
                    lines.append(#"    <line x1="\#(fmt(x))" y1="0" x2="\#(fmt(x))" y2="\#(fmt(h))"/>"#)
                    x += step
                }
            }
            lines.append("  </g>")
        }

        for stroke in strokes where !stroke.points.isEmpty {
            let strokeColor: String
            if forceLightPaper && Self.isNearWhite(stroke.color) {
                strokeColor = "#141820"
            } else {
                strokeColor = stroke.color
            }
            let opacity = stroke.tool == .highlighter ? "0.34" : "1"
            let baseW = max(1.0, stroke.width * w)

            let timeAttrs: String
            if let off = stroke.recordingOffsetSeconds {
                timeAttrs = #" data-timecode="\#(Self.formatVideoTime(off))" data-offset-sec="\#(fmt(off))""#
            } else {
                timeAttrs = ""
            }

            if stroke.points.count == 1 {
                let p = stroke.points[0]
                let r = max(0.8, baseW * (0.45 + 0.85 * p.p) * 0.5)
                lines.append(#"  <circle cx="\#(fmt(p.x * w))" cy="\#(fmt(p.y * h))" r="\#(fmt(r))" fill="\#(strokeColor)" opacity="\#(opacity)"\#(timeAttrs)/>"#)
                continue
            }

            if stroke.tool == .highlighter {
                let path = smoothPath(points: stroke.points, w: w, h: h)
                lines.append(#"  <path d="\#(path)" fill="none" stroke="\#(strokeColor)" stroke-width="\#(fmt(baseW * 3.8))" stroke-linecap="round" stroke-linejoin="round" opacity="\#(opacity)"\#(timeAttrs)/>"#)
            } else {
                // Segment-wise pressure-modulated strokes with smooth quadratic midpoints.
                lines.append(#"  <g fill="none" stroke="\#(strokeColor)" stroke-linecap="round" stroke-linejoin="round" opacity="\#(opacity)"\#(timeAttrs)>"#)
                let pts = stroke.points
                for i in 1..<pts.count {
                    let prev = pts[i - 1]
                    let curr = pts[i]
                    let avgP = (prev.p + curr.p) * 0.5
                    let segW = max(0.7, baseW * (0.35 + 1.05 * avgP))
                    lines.append(#"    <line x1="\#(fmt(prev.x * w))" y1="\#(fmt(prev.y * h))" x2="\#(fmt(curr.x * w))" y2="\#(fmt(curr.y * h))" stroke-width="\#(fmt(segW))"/>"#)
                }
                lines.append("  </g>")
            }
        }

        lines.append("</svg>")
        return lines.joined(separator: "\n")
    }

    private func smoothPath(points: [InkPoint], w: Double, h: Double) -> String {
        func fmt(_ v: Double) -> String { String(format: "%.2f", v) }
        guard let first = points.first else { return "" }
        var d = "M \(fmt(first.x * w)) \(fmt(first.y * h))"
        if points.count == 2 {
            d += " L \(fmt(points[1].x * w)) \(fmt(points[1].y * h))"
            return d
        }
        for i in 1..<(points.count - 1) {
            let c = points[i]
            let next = points[i + 1]
            let mx = (c.x + next.x) * 0.5 * w
            let my = (c.y + next.y) * 0.5 * h
            d += " Q \(fmt(c.x * w)) \(fmt(c.y * h)) \(fmt(mx)) \(fmt(my))"
        }
        if let last = points.last {
            d += " L \(fmt(last.x * w)) \(fmt(last.y * h))"
        }
        return d
    }

    public static func isNearWhite(_ hex: String) -> Bool {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")).lowercased()
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else { return false }
        let r = Double((value >> 16) & 0xFF)
        let g = Double((value >> 8) & 0xFF)
        let b = Double(value & 0xFF)
        return (r + g + b) / 3.0 > 215
    }
}
