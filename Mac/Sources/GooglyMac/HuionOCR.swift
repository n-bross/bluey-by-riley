import AppKit
import Foundation
import GooglyShared

/// Renders `InkDrawing` pages to crisp PNGs, archives SVG/PNG locally, runs OpenAI Vision OCR
/// for handwriting-to-Markdown + todo extraction, and syncs recognized notes to Bluey Hub.
enum InkRenderer {
    /// Renders an `InkDrawing` to PNG bytes (high contrast light paper by default for OCR & export).
    static func pngData(for drawing: InkDrawing, width: Int = 1500, forceLightPaper: Bool = true) -> Data? {
        let w = max(320, width)
        let h = max(320, Int((Double(w) / drawing.aspectRatio).rounded()))
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Flip to top-left origin so coordinates match normalized canvas coordinates.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)

        let light = forceLightPaper || drawing.paper.isLight
        let bg = light ? NSColor(hex: 0xFAF8F3) : NSColor(hex: 0x11161F)
        ctx.setFillColor(bg.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // Subtle lines/grid guides when not forcing OCR-clean paper.
        if !forceLightPaper && (drawing.paper == .grid || drawing.paper == .lined) {
            let step = CGFloat(w) / 28.0
            ctx.setStrokeColor((light ? NSColor(hex: 0xE4DFD3) : NSColor(hex: 0x222B3B)).cgColor)
            ctx.setLineWidth(1.0)
            var y = step
            while y < CGFloat(h) {
                ctx.move(to: CGPoint(x: 0, y: y))
                ctx.addLine(to: CGPoint(x: CGFloat(w), y: y))
                y += step
            }
            if drawing.paper == .grid {
                var x = step
                while x < CGFloat(w) {
                    ctx.move(to: CGPoint(x: x, y: 0))
                    ctx.addLine(to: CGPoint(x: x, y: CGFloat(h)))
                    x += step
                }
            }
            ctx.strokePath()
        }

        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        let fw = CGFloat(w)
        let fh = CGFloat(h)
        for stroke in drawing.strokes where !stroke.points.isEmpty {
            let hexString = (forceLightPaper && InkDrawing.isNearWhite(stroke.color)) ? "#141820" : stroke.color
            let color = nsColor(hexString: hexString).withAlphaComponent(stroke.tool == .highlighter ? 0.34 : 1.0)
            let baseW = max(1.4, CGFloat(stroke.width) * fw)

            if stroke.points.count == 1 {
                let p = stroke.points[0]
                let r = max(1.0, baseW * CGFloat(0.45 + 0.85 * p.p) * 0.5)
                ctx.setFillColor(color.cgColor)
                ctx.fillEllipse(in: CGRect(x: CGFloat(p.x) * fw - r, y: CGFloat(p.y) * fh - r, width: r * 2, height: r * 2))
                continue
            }

            ctx.setStrokeColor(color.cgColor)
            if stroke.tool == .highlighter {
                ctx.setLineWidth(baseW * 3.8)
                let pts = stroke.points
                ctx.move(to: CGPoint(x: CGFloat(pts[0].x) * fw, y: CGFloat(pts[0].y) * fh))
                for i in 1..<pts.count {
                    ctx.addLine(to: CGPoint(x: CGFloat(pts[i].x) * fw, y: CGFloat(pts[i].y) * fh))
                }
                ctx.strokePath()
            } else {
                let pts = stroke.points
                for i in 1..<pts.count {
                    let prev = pts[i - 1]
                    let curr = pts[i]
                    let avgP = (prev.p + curr.p) * 0.5
                    ctx.setLineWidth(max(1.0, baseW * CGFloat(0.35 + 1.05 * avgP)))
                    ctx.move(to: CGPoint(x: CGFloat(prev.x) * fw, y: CGFloat(prev.y) * fh))
                    ctx.addLine(to: CGPoint(x: CGFloat(curr.x) * fw, y: CGFloat(curr.y) * fh))
                    ctx.strokePath()
                }
            }
        }

        guard let image = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }

    static func nsColor(hexString: String) -> NSColor {
        let cleaned = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard cleaned.count == 6, let val = UInt32(cleaned, radix: 16) else { return .black }
        return NSColor(hex: val)
    }
}

/// Saves local open-format copies (SVG + PNG) to `~/Documents/Bluey Notes/Huion` so notes never depend on Huion.
enum HuionArchive {
    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bluey Notes/Huion", isDirectory: true)
    }

    @discardableResult
    static func save(drawing: InkDrawing, namePrefix: String) -> (svg: URL, png: URL?)? {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let clean = namePrefix.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression)
        let stem = "\(f.string(from: Date()))_\(clean.prefix(32))"
        let svgURL = folder.appendingPathComponent(stem + ".svg")
        let pngURL = folder.appendingPathComponent(stem + ".png")
        let svg = drawing.toSVG(width: 846, forceLightPaper: false)
        do {
            try svg.write(to: svgURL, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        var savedPNG: URL?
        if let png = InkRenderer.pngData(for: drawing, width: 1500, forceLightPaper: false) {
            if (try? png.write(to: pngURL, options: .atomic)) != nil {
                savedPNG = pngURL
            }
        }
        return (svgURL, savedPNG)
    }
}

/// OpenAI Vision handwriting transcription -> Markdown + extracted Todos, plus Bluey Hub sync.
enum HuionOCR {
    struct Result: Codable, Equatable, Sendable {
        var title: String
        var markdown: String
        var todos: [String]
    }

    enum Failure: LocalizedError {
        case noKey, renderFailed, apiError(String)
        var errorDescription: String? {
            switch self {
            case .noKey: return "Füge deinen OpenAI-Schlüssel im Bluey-Menü hinzu, um Handschrift zu erkennen."
            case .renderFailed: return "Die Zeichnung konnte nicht gerendert werden."
            case .apiError(let s): return s
            }
        }
    }

    /// Transcribes a handwritten `InkDrawing` using the configured LLM provider
    /// (Hermes Subscription + Apple Vision local OCR, Custom OpenAI-compatible Vision, or OpenAI Responses).
    static func transcribe(_ drawing: InkDrawing, model: String = ChatEngine.fallbackModel) async throws -> Result {
        guard let png = InkRenderer.pngData(for: drawing, width: 1600, forceLightPaper: true) else {
            throw Failure.renderFailed
        }

        let prompt = """
        Transkribiere diese handgeschriebene Notizseite exakt und sauber in Markdown (in der Originalsprache, meist Deutsch).
        - Behalte Struktur, Überschriften, Aufzählungen, Pfeile und kleine Skizzen (kurz als [Skizze: …] beschreiben) bei.
        - Korrigiere offensichtliche Schreibfehler vorsichtig, aber erfinde nichts hinzu.
        - Gib einen kurzen, prägnanten Titel zurück.
        - Extrahiere alle klar erkennbaren Aufgaben / Checkboxen / Action-Items zusätzlich als kurze Strings im Feld `todos` (leer lassen, wenn es keine Aufgaben sind).
        """

        let provider = Settings.shared.llmProvider
        if provider != .openai {
            let jsonInstructions = """
            Antworte AUSSCHLIESSLICH mit einem gültigen JSON-Objekt (ohne Markdown-Codeblock):
            {"title":"...","markdown":"...","todos":["..."]}
            """
            if provider == .hermes {
                // Local Apple Vision OCR (0 €) -> Hermes (Subscription, 0 € API) structures title, Markdown & todos.
                let rawText = LocalOCR.recognize(imageData: png) ?? ""
                guard !rawText.isEmpty else {
                    return Result(title: "Handschrift-Notiz", markdown: "_Kein lesbarer Text erkannt._", todos: [])
                }
                if let structured = try? await LLMService.complete(
                    prompt: "\(prompt)\n\nLokal erkannter Text (Apple Vision OCR):\n\(rawText)",
                    instructions: jsonInstructions,
                    provider: .hermes,
                    hermesSession: "bluey-ocr",
                    timeout: 45
                ), let parsed = decodeJSONResult(structured) {
                    return parsed
                }
                let firstLine = rawText.split(separator: "\n").first.map(String.init) ?? "Handschrift-Notiz"
                return Result(title: String(firstLine.prefix(60)), markdown: rawText, todos: [])
            } else {
                let raw = try await LLMService.complete(
                    prompt: prompt,
                    instructions: jsonInstructions,
                    images: [("image/png", png)],
                    provider: .openAICompatible,
                    timeout: 90
                )
                guard let parsed = decodeJSONResult(raw) else {
                    throw Failure.apiError("OCR-Antwort konnte nicht gelesen werden.")
                }
                return parsed
            }
        }

        guard let key = Keychain.get(.openai), !key.isEmpty else { throw Failure.noKey }

        let schema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "title": ["type": "string"],
                "markdown": ["type": "string"],
                "todos": ["type": "array", "items": ["type": "string"]],
            ],
            "required": ["title", "markdown", "todos"],
        ]

        let body: [String: Any] = [
            "model": model,
            "store": false,
            "input": [[
                "role": "user",
                "content": [
                    ["type": "input_text", "text": prompt],
                    ["type": "input_image", "image_url": "data:image/png;base64,\(png.base64EncodedString())"],
                ],
            ]],
            "text": [
                "format": [
                    "type": "json_schema",
                    "name": "handwriting_ocr",
                    "strict": true,
                    "schema": schema,
                ],
            ],
        ]

        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 90
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let msg = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any])?["message"] as? String
            throw Failure.apiError("OpenAI OCR Fehler \(code)" + (msg.map { ": \($0)" } ?? ""))
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let outputText = extractOutputText(from: json)
        guard let outputText, let parsed = try? JSONDecoder().decode(Result.self, from: Data(outputText.utf8)) else {
            throw Failure.apiError("OCR-Antwort konnte nicht gelesen werden.")
        }
        return parsed
    }

    private static func decodeJSONResult(_ raw: String) -> Result? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}") else { return nil }
        let slice = String(raw[start...end])
        return try? JSONDecoder().decode(Result.self, from: Data(slice.utf8))
    }

    private static func extractOutputText(from json: [String: Any]?) -> String? {
        if let direct = json?["output_text"] as? String, !direct.isEmpty { return direct }
        guard let output = json?["output"] as? [[String: Any]] else { return nil }
        for item in output {
            guard let content = item["content"] as? [[String: Any]] else { continue }
            for block in content {
                if let text = block["text"] as? String, !text.isEmpty { return text }
            }
        }
        return nil
    }

    /// Pushes or updates a Bluey Workspace note in Bluey Hub (`~/bluey-hub/notes/*.md`) so iPhone & Hermes see it.
    static func syncToHub(note: NoteItem) async throws -> String {
        guard HubSettings.configured else {
            throw HubNotesAPI.Failure.notSetUp
        }
        let header = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let markdown: String
        if header.isEmpty {
            markdown = body.isEmpty ? "# \(note.displayTitle)" : body
        } else if body.isEmpty {
            markdown = "# \(header)"
        } else if body.hasPrefix("# \(header)") || body.hasPrefix(header + "\n") {
            markdown = body
        } else {
            markdown = "# \(header)\n\n\(body)"
        }

        if let existingID = note.hubNoteID, !existingID.isEmpty {
            do {
                try await HubNotesAPI.save(existingID, body: markdown, pinned: note.pinned)
                return existingID
            } catch {
                // If deleted remotely on the hub, recreate cleanly.
            }
        }
        let created = try await HubNotesAPI.create(markdown)
        if note.pinned {
            try? await HubNotesAPI.save(created.id, pinned: true)
        }
        return created.id
    }
}
