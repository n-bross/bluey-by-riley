import AVFoundation
import Foundation
import GooglyShared
import Speech
import Vision

// MARK: - Provider Enums

enum VoiceProvider: String, Codable, CaseIterable, Identifiable {
    case localHermes
    case geminiLive
    case openaiRealtime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .localHermes: return "Lokal + Hermes (0 €)"
        case .geminiLive: return "Google Gemini Live"
        case .openaiRealtime: return "OpenAI Realtime API"
        }
    }

    var detail: String {
        switch self {
        case .localHermes: return "STT über deinen Transkriptions-Service + Gehirn über Hermes/Standard-KI + wählbare Call-Stimme. Kein OpenAI-API-Verbrauch."
        case .geminiLive: return "Natives Echtzeit-Audio über Googles Gemini Live WebSocket API (eigener Gemini-Key)."
        case .openaiRealtime: return "OpenAI Realtime WebSocket (gpt-realtime-2.1, bezahlter OpenAI API-Key)."
        }
    }
}

enum TTSProvider: String, Codable, CaseIterable, Identifiable {
    case apple
    case elevenlabs
    case localMLX
    case openai

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: return "Apple Stimme (Lokal, 0 €)"
        case .elevenlabs: return "ElevenLabs"
        case .localMLX: return "Lokal (MLX / OpenAI-komp., 0 €)"
        case .openai: return "OpenAI TTS API"
        }
    }
}

enum TranscriptionProvider: String, Codable, CaseIterable, Identifiable {
    case appleLocal
    case localMLX
    case groq
    case custom
    case openai

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appleLocal: return "Apple On-Device (0 €)"
        case .localMLX: return "Lokal: MLX / Whisper-Server (0 €)"
        case .groq: return "Groq Whisper (Cloud)"
        case .custom: return "Custom OpenAI-kompatibel"
        case .openai: return "OpenAI API"
        }
    }

    var shortBadge: String {
        switch self {
        case .appleLocal: return "Apple On-Device (0 €)"
        case .localMLX: return "Lokal MLX/Whisper (0 €)"
        case .groq: return "Groq Whisper"
        case .custom: return "Custom STT"
        case .openai: return "OpenAI API"
        }
    }

    var requiresCloudKey: Bool {
        switch self {
        case .appleLocal, .localMLX: return false
        case .groq, .openai: return true
        case .custom: return false // optional for local/tailnet endpoints
        }
    }
}

enum LLMProvider: String, Codable, CaseIterable, Identifiable {
    case hermes
    case openAICompatible
    case openai

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hermes: return "Hermes (Subscription, 0 € API)"
        case .openAICompatible: return "Custom OpenAI-kompatibel"
        case .openai: return "OpenAI API"
        }
    }
}

enum FocusProvider: String, Codable, CaseIterable, Identifiable {
    case followLLM
    case hermes
    case openAICompatible
    case openai

    var id: String { rawValue }

    var title: String {
        switch self {
        case .followLLM: return "Wie Standard-KI"
        case .hermes: return "Hermes (Subscription, 0 € API)"
        case .openAICompatible: return "Custom OpenAI-kompatibel"
        case .openai: return "OpenAI API (gpt-6-luna)"
        }
    }

    func resolved(defaultLLM: LLMProvider) -> LLMProvider {
        switch self {
        case .followLLM: return defaultLLM
        case .hermes: return .hermes
        case .openAICompatible: return .openAICompatible
        case .openai: return .openai
        }
    }
}

struct CustomLLMPreset: Identifiable {
    let id: String
    let name: String
    let baseURL: String
    let model: String

    static let all: [CustomLLMPreset] = [
        CustomLLMPreset(id: "openrouter", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", model: "google/gemini-2.5-flash"),
        CustomLLMPreset(id: "gemini", name: "Google Gemini", baseURL: "https://generativelanguage.googleapis.com/v1beta/openai", model: "gemini-2.5-flash"),
        CustomLLMPreset(id: "groq", name: "Groq", baseURL: "https://api.groq.com/openai/v1", model: "llama-3.3-70b-versatile"),
        CustomLLMPreset(id: "ollama", name: "Ollama (Lokal)", baseURL: "http://127.0.0.1:11434/v1", model: "qwen2.5:14b"),
    ]
}

// MARK: - Central Service Wiring

@MainActor
enum AIServices {
    /// Shared Hermes gateway wired by AppDelegate so Chat, Focus, Meeting Q&A, WebResearch & Modular Voice can use the subscription.
    static weak var hermes: HermesGateway?

    static var effectiveFocusLLM: LLMProvider {
        Settings.shared.focusProvider.resolved(defaultLLM: Settings.shared.llmProvider)
    }

    static var isFocusConfigured: Bool {
        switch effectiveFocusLLM {
        case .hermes:
            return HermesGateway.config() != nil
        case .openAICompatible:
            let url = Settings.shared.customLLMBaseURL
            let isLocal = url.contains("127.0.0.1") || url.contains("localhost")
            return !url.isEmpty && (isLocal || Keychain.get(.customLLM) != nil || Keychain.get(.gemini) != nil)
        case .openai:
            return Keychain.get(.openai) != nil
        }
    }

    static var missingFocusMessage: String {
        switch effectiveFocusLLM {
        case .hermes:
            return "Verbinde Hermes in den Bluey-Einstellungen (oder wähle einen anderen KI-Service unter Services)."
        case .openAICompatible:
            return "Trage Base-URL und API-Key für deinen KI-Service unter Einstellungen → Services ein."
        case .openai:
            return "Füge deinen OpenAI-Schlüssel unter Einstellungen → Services hinzu (oder wechsle auf Hermes / Custom)."
        }
    }

    /// Resolves the API key for `openAICompatible`: uses `.customLLM`, or falls back to `.gemini` when pointing at Google's OpenAI-compat endpoint.
    static func customLLMKey(for baseURL: String = Settings.shared.customLLMBaseURL) -> String? {
        if let k = Keychain.get(.customLLM), !k.isEmpty { return k }
        if baseURL.lowercased().contains("generativelanguage.googleapis.com"),
           let g = Keychain.get(.gemini), !g.isEmpty {
            return g
        }
        return nil
    }
}

// MARK: - Audio Silence Detector

enum AudioSilenceDetector {
    struct Levels: Equatable {
        var rmsDB: Double
        var peakDB: Double
        var durationSeconds: Double

        var isSilent: Bool {
            // Typical room noise / muted mic / idle Mac system audio sits well below -38 dBFS peak & -52 dBFS RMS.
            peakDB < -36.0 || (rmsDB < -52.0 && peakDB < -28.0)
        }
    }

    /// Measures RMS and peak dBFS of an audio file (m4a, wav, mp3, caf, etc.). Returns nil only if unreadable.
    static func analyze(fileURL: URL) -> Levels? {
        guard let file = try? AVAudioFile(forReading: fileURL) else { return nil }
        let format = file.processingFormat
        let totalFrames = AVAudioFrameCount(file.length)
        guard totalFrames > 0, format.sampleRate > 0 else { return Levels(rmsDB: -120, peakDB: -120, durationSeconds: 0) }
        let duration = Double(totalFrames) / format.sampleRate
        let chunkFrames: AVAudioFrameCount = 32_768
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else { return nil }

        var sumSq: Double = 0
        var peak: Float = 0
        var sampleCount: Int = 0
        let channels = Int(format.channelCount)

        while file.framePosition < file.length {
            do {
                try file.read(into: buffer, frameCount: chunkFrames)
            } catch {
                break
            }
            let n = Int(buffer.frameLength)
            guard n > 0, let channelData = buffer.floatChannelData else { break }
            for ch in 0..<channels {
                let ptr = channelData[ch]
                for i in 0..<n {
                    let s = abs(ptr[i])
                    if s > peak { peak = s }
                    sumSq += Double(s * s)
                }
            }
            sampleCount += n * channels
        }
        guard sampleCount > 0 else { return Levels(rmsDB: -120, peakDB: -120, durationSeconds: duration) }
        let rms = sqrt(sumSq / Double(sampleCount))
        let rmsDB = rms > 1e-6 ? 20.0 * log10(rms) : -120.0
        let peakDB = peak > 1e-6 ? 20.0 * log10(Double(peak)) : -120.0
        return Levels(rmsDB: rmsDB, peakDB: peakDB, durationSeconds: duration)
    }

    /// Measures audio bytes by writing to a short-lived temp file.
    static func analyze(data: Data, fileExtension: String = "m4a") -> Levels? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bluey-vad-\(UUID().uuidString).\(fileExtension)")
        do {
            try data.write(to: tmp)
            defer { try? FileManager.default.removeItem(at: tmp) }
            return analyze(fileURL: tmp)
        } catch {
            return nil
        }
    }
}

// MARK: - Transcription Service (Multi-Provider + Silence Gate)

enum TranscriptionService {
    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
    }

    /// Validates whether the currently selected transcription provider can run right now.
    static func readinessError() -> String? {
        let s = Settings.shared
        switch s.transcriptionProvider {
        case .appleLocal:
            return nil
        case .localMLX:
            return URL(string: s.localSTTURL) == nil ? "Ungültige lokale STT-URL in Einstellungen → Services." : nil
        case .groq:
            return Keychain.get(.customSTT) == nil ? "Füge deinen Groq API-Key unter Einstellungen → Services (STT-Key) hinzu." : nil
        case .custom:
            return URL(string: s.customSTTURL) == nil ? "Trage eine gültige Custom-STT-URL unter Einstellungen → Services ein." : nil
        case .openai:
            return Keychain.get(.openai) == nil ? "Füge deinen OpenAI-Schlüssel unter Einstellungen → Services hinzu (oder wechsle auf Apple On-Device / MLX)." : nil
        }
    }

    /// Transcribes an audio file URL (or raw Data) with optional silence filtering and diarization.
    static func transcribe(audio: Data, fileExtension: String = "m4a", preferDiarize: Bool = false) async throws -> [MeetingNotes.Segment] {
        guard !audio.isEmpty else { return [] }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bluey-stt-\(UUID().uuidString).\(fileExtension)")
        try audio.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        return try await transcribe(fileURL: tmp, rawData: audio, fileExtension: fileExtension, preferDiarize: preferDiarize)
    }

    static func transcribe(fileURL: URL, rawData: Data? = nil, fileExtension: String? = nil, preferDiarize: Bool = false) async throws -> [MeetingNotes.Segment] {
        let settings = Settings.shared
        if settings.transcriptionSilenceFilter,
           let levels = AudioSilenceDetector.analyze(fileURL: fileURL),
           levels.isSilent {
            return []
        }

        let ext = fileExtension ?? (fileURL.pathExtension.isEmpty ? "m4a" : fileURL.pathExtension)
        switch settings.transcriptionProvider {
        case .appleLocal:
            let text = try await appleOnDeviceTranscribe(fileURL: fileURL, language: settings.transcriptionLanguage)
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? [] : [MeetingNotes.Segment(speaker: "?", start: 0, end: 0, text: clean)]

        case .localMLX:
            let data = try rawData ?? Data(contentsOf: fileURL)
            guard let url = URL(string: settings.localSTTURL) else {
                throw Failure.message("Ungültige lokale STT-URL.")
            }
            return try await openAICompatibleTranscribe(
                audio: data, filename: "chunk.\(ext)", mime: mimeType(for: ext),
                url: url, model: settings.localSTTModel, apiKey: Keychain.get(.customSTT),
                language: isoLanguage(settings.transcriptionLanguage), diarize: false
            )

        case .groq:
            let data = try rawData ?? Data(contentsOf: fileURL)
            guard let key = Keychain.get(.customSTT), !key.isEmpty else {
                throw Failure.message("Füge deinen Groq API-Key unter Einstellungen → Services (STT-Key) hinzu.")
            }
            return try await openAICompatibleTranscribe(
                audio: data, filename: "chunk.\(ext)", mime: mimeType(for: ext),
                url: URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!,
                model: settings.groqSTTModel, apiKey: key,
                language: isoLanguage(settings.transcriptionLanguage), diarize: false
            )

        case .custom:
            let data = try rawData ?? Data(contentsOf: fileURL)
            guard let url = URL(string: settings.customSTTURL), !settings.customSTTURL.isEmpty else {
                throw Failure.message("Trage eine Custom-STT-URL unter Einstellungen → Services ein.")
            }
            let model = settings.customSTTModel.isEmpty ? "whisper-1" : settings.customSTTModel
            return try await openAICompatibleTranscribe(
                audio: data, filename: "chunk.\(ext)", mime: mimeType(for: ext),
                url: url, model: model, apiKey: Keychain.get(.customSTT),
                language: isoLanguage(settings.transcriptionLanguage), diarize: false
            )

        case .openai:
            let data = try rawData ?? Data(contentsOf: fileURL)
            guard let key = Keychain.get(.openai), !key.isEmpty else {
                throw Failure.message("Füge deinen OpenAI-Schlüssel unter Einstellungen → Services hinzu.")
            }
            let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
            if preferDiarize {
                do {
                    return try await openAICompatibleTranscribe(
                        audio: data, filename: "chunk.\(ext)", mime: mimeType(for: ext),
                        url: endpoint, model: MeetingNotes.model, apiKey: key,
                        language: isoLanguage(settings.transcriptionLanguage), diarize: true
                    )
                } catch {
                    NSLog("Googly: diarized transcription failed (\(error)), falling back to \(settings.openAISTTModel)")
                }
            }
            return try await openAICompatibleTranscribe(
                audio: data, filename: "chunk.\(ext)", mime: mimeType(for: ext),
                url: endpoint, model: settings.openAISTTModel, apiKey: key,
                language: isoLanguage(settings.transcriptionLanguage), diarize: false
            )
        }
    }

    /// Apple On-Device Speech Recognition (0 €, works offline on macOS 14+).
    private static func appleOnDeviceTranscribe(fileURL: URL, language: String) async throws -> String {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else {
            throw Failure.message("Erlaube Bluey die Spracherkennung unter Systemeinstellungen → Datenschutz & Sicherheit → Spracherkennung.")
        }
        let locale = language.isEmpty ? Locale.current : Locale(identifier: language)
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else {
            throw Failure.message("Apple Spracherkennung ist für \(locale.identifier) gerade nicht verfügbar.")
        }
        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        request.shouldReportPartialResults = false
        request.addsPunctuation = true

        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            var task: SFSpeechRecognitionTask?
            task = recognizer.recognitionTask(with: request) { result, error in
                guard !resumed else { return }
                if let result, result.isFinal {
                    resumed = true
                    task?.cancel()
                    continuation.resume(returning: result.bestTranscription.formattedString)
                } else if let error {
                    resumed = true
                    task?.cancel()
                    let ns = error as NSError
                    // Apple Speech reports "No speech detected" (code 1110 / 203) for silent or quiet clips — treat as empty!
                    let msg = error.localizedDescription.lowercased()
                    if ns.code == 1110 || ns.code == 203 || msg.contains("no speech") || msg.contains("keine sprache") {
                        continuation.resume(returning: "")
                    } else {
                        continuation.resume(throwing: Failure.message("Lokale Transkription fehlgeschlagen: \(error.localizedDescription)"))
                    }
                }
            }
        }
    }

    private static func openAICompatibleTranscribe(
        audio: Data, filename: String, mime: String,
        url: URL, model: String, apiKey: String?,
        language: String?, diarize: Bool
    ) async throws -> [MeetingNotes.Segment] {
        let boundary = "googly-\(UUID().uuidString)"
        var fields: [(String, String)] = [
            ("model", model),
            ("response_format", diarize ? "diarized_json" : "json"),
        ]
        if diarize { fields.append(("chunking_strategy", "auto")) }
        if let language, !language.isEmpty { fields.append(("language", language)) }

        var body = Data()
        for (name, value) in fields {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
        body.append(audio)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let detail = String(data: data, encoding: .utf8)?.prefix(240) ?? ""
            throw Failure.message("Transkription HTTP \(code): \(detail)")
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if diarize, let segs = json["segments"] as? [[String: Any]] {
                let raw = segs.map {
                    MeetingNotes.Segment(
                        speaker: $0["speaker"] as? String ?? "?",
                        start: $0["start"] as? Double ?? 0,
                        end: $0["end"] as? Double ?? 0,
                        text: ($0["text"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                    )
                }
                var turns: [MeetingNotes.Segment] = []
                for segment in raw where !segment.text.isEmpty {
                    if var last = turns.last, last.speaker == segment.speaker, segment.start - last.end < 2.5 {
                        last.text += " " + segment.text
                        last.end = segment.end
                        turns[turns.count - 1] = last
                    } else {
                        turns.append(segment)
                    }
                }
                return turns
            }
            let text = (json["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [MeetingNotes.Segment(speaker: "?", start: 0, end: 0, text: text)]
        }
        let plain = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return plain.isEmpty ? [] : [MeetingNotes.Segment(speaker: "?", start: 0, end: 0, text: plain)]
    }

    private static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        case "ogg": return "audio/ogg"
        case "webm": return "audio/webm"
        default: return "audio/mp4"
        }
    }

    private static func isoLanguage(_ localeOrCode: String) -> String? {
        let trimmed = localeOrCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? Substring(trimmed)).lowercased()
    }
}

// MARK: - TTS Service (for Modular Phone Calls)

enum TTSService {
    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
    }

    /// Returns `(audioBytes, format)` when the Mac synthesizes audio, or `nil` when `ttsProvider == .apple`
    /// (meaning the iPhone speaks the text natively via AVSpeechSynthesizer at 0 €).
    static func synthesize(_ text: String) async throws -> (data: Data, format: String)? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let s = Settings.shared
        switch s.ttsProvider {
        case .apple:
            return nil

        case .elevenlabs:
            guard let key = Keychain.get(.elevenlabs), !key.isEmpty else {
                throw Failure.message("ElevenLabs API-Key fehlt (Einstellungen → Services).")
            }
            let voice = s.elevenLabsVoiceID
            guard let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voice)") else {
                throw Failure.message("Ungültige ElevenLabs Voice-ID.")
            }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 30
            req.setValue(key, forHTTPHeaderField: "xi-api-key")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "text": clean,
                "model_id": "eleven_multilingual_v2",
            ])
            let (data, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                throw Failure.message("ElevenLabs HTTP \(code)")
            }
            return (data, "mp3")

        case .localMLX:
            guard let url = URL(string: s.localTTSURL) else {
                throw Failure.message("Ungültige lokale TTS-URL.")
            }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 45
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": s.localTTSModel,
                "input": clean,
                "voice": s.localTTSVoice,
                "response_format": "mp3",
            ])
            let (data, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                throw Failure.message("Lokaler TTS-Server HTTP \(code)")
            }
            return (data, "mp3")

        case .openai:
            guard let key = Keychain.get(.openai), !key.isEmpty else {
                throw Failure.message("OpenAI API-Key fehlt.")
            }
            var req = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/speech")!)
            req.httpMethod = "POST"
            req.timeoutInterval = 30
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let voice = await MainActor.run { RealtimeHost.callVoice }
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": "gpt-4o-mini-tts",
                "input": clean,
                "voice": voice,
                "response_format": "mp3",
            ])
            let (data, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                throw Failure.message("OpenAI TTS HTTP \(code)")
            }
            return (data, "mp3")
        }
    }
}

// MARK: - Unified LLM Client (Hermes Subscription + OpenAI-Compatible + OpenAI)

enum LLMService {
    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
    }

    struct ToolCall {
        var id: String
        var name: String
        var arguments: String
    }

    struct ChatCompletionReply {
        var text: String
        var toolCalls: [ToolCall]
    }

    /// Runs a single prompt against the chosen LLM provider (Hermes Subscription, Custom OpenAI-compat, or OpenAI).
    static func complete(
        prompt: String,
        instructions: String,
        images: [(mime: String, data: Data)] = [],
        provider: LLMProvider? = nil,
        modelOverride: String? = nil,
        hermesSession: String = "bluey-helper",
        timeout: Double = 90
    ) async throws -> String {
        let active = provider ?? Settings.shared.llmProvider
        switch active {
        case .hermes:
            let gateway = await MainActor.run { AIServices.hermes }
            guard let gateway else {
                throw Failure.message("Hermes ist nicht verbunden. Prüfe Einstellungen → Hermes oder wähle einen anderen KI-Service.")
            }
            return try await gateway.runSync(prompt, instructions: instructions, session: hermesSession, timeoutSeconds: timeout)

        case .openAICompatible:
            let base = Settings.shared.customLLMBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            guard let url = URL(string: "\(base)/chat/completions") else {
                throw Failure.message("Ungültige Custom-KI Base-URL.")
            }
            let model = modelOverride ?? Settings.shared.customLLMModel
            let key = await MainActor.run { AIServices.customLLMKey(for: base) }
            var userContent: Any = prompt
            if !images.isEmpty {
                var parts: [[String: Any]] = [["type": "text", "text": prompt]]
                for img in images {
                    parts.append([
                        "type": "image_url",
                        "image_url": ["url": "data:\(img.mime);base64,\(img.data.base64EncodedString())"],
                    ])
                }
                userContent = parts
            }
            let messages: [[String: Any]] = [
                ["role": "system", "content": instructions],
                ["role": "user", "content": userContent],
            ]
            let reply = try await openAICompatibleChat(url: url, apiKey: key, model: model, messages: messages, tools: nil, timeout: timeout)
            return reply.text

        case .openai:
            guard let key = Keychain.get(.openai), !key.isEmpty else {
                throw Failure.message("Füge deinen OpenAI-Schlüssel unter Einstellungen → Services hinzu (oder wechsle auf Hermes).")
            }
            var content: [[String: Any]] = [["type": "input_text", "text": prompt]]
            for img in images {
                content.append(["type": "input_image", "image_url": "data:\(img.mime);base64,\(img.data.base64EncodedString())"])
            }
            var req = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
            req.httpMethod = "POST"
            req.timeoutInterval = timeout
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": modelOverride ?? ChatEngine.fallbackModel,
                "store": false,
                "instructions": instructions,
                "input": [["role": "user", "content": content]],
            ])
            let (data, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw Failure.message("OpenAI HTTP \(code)")
            }
            var text = ""
            for item in json["output"] as? [[String: Any]] ?? [] where item["type"] as? String == "message" {
                for part in item["content"] as? [[String: Any]] ?? [] { text += part["text"] as? String ?? "" }
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Standard OpenAI `/v1/chat/completions` call with optional function-calling tools (works with OpenRouter, Gemini, Groq, Ollama, etc.).
    static func openAICompatibleChat(
        url: URL, apiKey: String?, model: String,
        messages: [[String: Any]], tools: [[String: Any]]?, timeout: Double = 90
    ) async throws -> ChatCompletionReply {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        if let apiKey, !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if url.host?.contains("openrouter.ai") == true {
            req.setValue("Bluey", forHTTPHeaderField: "X-Title")
        }
        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": false,
        ]
        if let tools, !tools.isEmpty {
            body["tools"] = tools.map { tool -> [String: Any] in
                // Convert flat Realtime tool dict into Chat Completions `{"type":"function","function":{...}}`
                var fn: [String: Any] = [:]
                if let n = tool["name"] { fn["name"] = n }
                if let d = tool["description"] { fn["description"] = d }
                if let p = tool["parameters"] { fn["parameters"] = p }
                return ["type": "function", "function": fn]
            }
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let errMsg = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any])?["message"] as? String
            throw Failure.message("KI-Service HTTP \(code)" + (errMsg.map { ": \($0.prefix(200))" } ?? ""))
        }
        let choices = json["choices"] as? [[String: Any]] ?? []
        let msg = choices.first?["message"] as? [String: Any] ?? [:]
        let text: String
        if let s = msg["content"] as? String {
            text = s
        } else if let parts = msg["content"] as? [[String: Any]] {
            text = parts.compactMap { $0["text"] as? String }.joined()
        } else {
            text = ""
        }
        let rawCalls = msg["tool_calls"] as? [[String: Any]] ?? []
        let calls: [ToolCall] = rawCalls.compactMap { tc in
            guard let fn = tc["function"] as? [String: Any], let name = fn["name"] as? String else { return nil }
            let id = tc["id"] as? String ?? UUID().uuidString
            let args = fn["arguments"] as? String ?? "{}"
            return ToolCall(id: id, name: name, arguments: args)
        }
        return ChatCompletionReply(text: text.trimmingCharacters(in: .whitespacesAndNewlines), toolCalls: calls)
    }

    /// Streams SSE from an OpenAI-compatible `/chat/completions` endpoint (OpenRouter, Gemini, Groq, Ollama, etc.).
    static func streamOpenAICompatible(
        baseURL: String, apiKey: String?, model: String,
        messages: [[String: Any]], onText: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: "\(base)/chat/completions") else {
            throw Failure.message("Ungültige Base-URL für Custom-KI.")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        if let apiKey, !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if url.host?.contains("openrouter.ai") == true {
            req.setValue("Bluey", forHTTPHeaderField: "X-Title")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": messages,
            "stream": true,
        ])
        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            var data = Data()
            for try await byte in bytes { data.append(byte); if data.count > 64_000 { break } }
            let msg = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any])?["message"] as? String
            throw Failure.message("Custom-KI HTTP \(code)" + (msg.map { ": \($0.prefix(240))" } ?? ""))
        }
        var text = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]",
                  let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
            if let err = (json["error"] as? [String: Any])?["message"] as? String {
                throw Failure.message(err)
            }
            let choices = json["choices"] as? [[String: Any]] ?? []
            if let delta = (choices.first?["delta"] as? [String: Any])?["content"] as? String {
                text += delta
                let snapshot = text
                await onText(snapshot)
            }
        }
        return text
    }

    /// Lists models from a custom OpenAI-compatible `/models` endpoint (best-effort).
    static func listOpenAICompatibleModels(baseURL: String, apiKey: String?) async -> [ChatModelInfo] {
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: "\(base)/models") else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        if let apiKey, !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["data"] as? [[String: Any]] else { return [] }
        let ids = list.compactMap { $0["id"] as? String }.prefix(25)
        return ids.map { ChatModelInfo(id: "custom:\($0)", name: $0) }
    }

    /// Quick connectivity test for Settings → Services.
    static func testCustomConnection() async -> String {
        do {
            let reply = try await complete(
                prompt: "Antworte nur mit: OK",
                instructions: "Reply with OK.",
                provider: .openAICompatible,
                timeout: 20
            )
            return "Verbunden ✓ (\(reply.prefix(40)))"
        } catch {
            return "Fehler: \(error.localizedDescription)"
        }
    }
}

// MARK: - Local Apple Vision OCR (0 €)

enum LocalOCR {
    /// Extracts readable text from image bytes completely locally on macOS via Apple Vision.
    static func recognize(imageData: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["de-DE", "en-US"]
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        guard (try? handler.perform([request])) != nil else { return nil }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        let joined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }
}
