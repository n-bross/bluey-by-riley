import Foundation

/// Wire configuration sent from the Mac to LiveVoice (Notch / iPhone) and CallSession (iPhone)
/// so voice sessions can run via Modular Local+Hermes, Google Gemini Live, or OpenAI Realtime.
public struct VoiceSessionConfig: Codable, Equatable, Sendable {
    public static let envelopePrefix = "BLUEY_VOICE_CFG:"

    public var provider: String          // "localHermes" | "geminiLive" | "openaiRealtime"
    public var token: String?            // ephemeral OpenAI secret or Gemini API key
    public var model: String?
    public var voice: String?
    public var instructions: String?
    public var toolsJSON: String?        // JSON array of OpenAI-style tool definitions
    public var ttsMode: String?          // "apple" | "mac" (for localHermes calls)
    public var language: String?         // e.g. "de-DE", "en-US", ""

    public init(provider: String, token: String? = nil, model: String? = nil, voice: String? = nil,
                instructions: String? = nil, toolsJSON: String? = nil, ttsMode: String? = nil, language: String? = nil) {
        self.provider = provider
        self.token = token
        self.model = model
        self.voice = voice
        self.instructions = instructions
        self.toolsJSON = toolsJSON
        self.ttsMode = ttsMode
        self.language = language
    }

    public func encodeEnvelope() -> String? {
        guard let data = try? JSONEncoder().encode(self),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return Self.envelopePrefix + json
    }

    /// Parses either a `BLUEY_VOICE_CFG:{...}` envelope or a legacy raw OpenAI ephemeral token.
    public static func decodeEnvelope(_ raw: String) -> VoiceSessionConfig {
        if raw.hasPrefix(envelopePrefix) {
            let body = String(raw.dropFirst(envelopePrefix.count))
            if let data = body.data(using: .utf8),
               let cfg = try? JSONDecoder().decode(VoiceSessionConfig.self, from: data) {
                return cfg
            }
        }
        return VoiceSessionConfig(provider: "openaiRealtime", token: raw)
    }
}

/// Result of one modular voice/call turn executed on the Mac (STT -> LLM/Hermes + Tools -> optional TTS).
public struct VoiceTurnReply: Codable, Equatable, Sendable {
    public var heard: String?
    public var reply: String
    public var sleep: Bool
    public var report: String?
    /// "apple" (speak locally with AVSpeechSynthesizer) or "audio" (audio bytes attached in Packet.audio).
    public var ttsMode: String?
    public var audioFormat: String?
    public var error: String?

    public init(heard: String? = nil, reply: String = "", sleep: Bool = false, report: String? = nil,
                ttsMode: String? = nil, audioFormat: String? = nil, error: String? = nil) {
        self.heard = heard
        self.reply = reply
        self.sleep = sleep
        self.report = report
        self.ttsMode = ttsMode
        self.audioFormat = audioFormat
        self.error = error
    }
}

/// Minimal WAV / PCM helpers shared by Mac and iPhone voice pipelines.
public enum VoiceAudioCodec {
    /// Wraps mono 16-bit signed little-endian PCM into a valid RIFF/WAVE container.
    public static func wav(pcm16: Data, sampleRate: Int = 24000, channels: Int = 1) -> Data {
        var out = Data(capacity: 44 + pcm16.count)
        let bitsPerSample = 16
        let byteRate = UInt32(sampleRate * channels * (bitsPerSample / 8))
        let blockAlign = UInt16(channels * (bitsPerSample / 8))
        let dataSize = UInt32(pcm16.count)
        let chunkSize = UInt32(36) &+ dataSize

        func appendU32(_ v: UInt32) { var le = v.littleEndian; out.append(Data(bytes: &le, count: 4)) }
        func appendU16(_ v: UInt16) { var le = v.littleEndian; out.append(Data(bytes: &le, count: 2)) }

        out.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        appendU32(chunkSize)
        out.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
        out.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        appendU32(16)                                     // PCM chunk size
        appendU16(1)                                      // PCM format
        appendU16(UInt16(channels))
        appendU32(UInt32(sampleRate))
        appendU32(byteRate)
        appendU16(blockAlign)
        appendU16(UInt16(bitsPerSample))
        out.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        appendU32(dataSize)
        out.append(pcm16)
        return out
    }

    /// Downsamples mono 16-bit PCM from 24 kHz to 16 kHz (required by Gemini Live input) using linear interpolation.
    public static func downsample24kTo16k(_ pcm24k: Data) -> Data {
        let inCount = pcm24k.count / 2
        guard inCount >= 2 else { return pcm24k }
        let outCount = (inCount * 2) / 3
        guard outCount > 0 else { return Data() }
        var out = Data(count: outCount * 2)
        pcm24k.withUnsafeBytes { rawIn in
            out.withUnsafeMutableBytes { rawOut in
                let src = rawIn.bindMemory(to: Int16.self)
                let dst = rawOut.bindMemory(to: Int16.self)
                for i in 0..<outCount {
                    let pos = Double(i) * 1.5
                    let idx = Int(pos)
                    let frac = pos - Double(idx)
                    let a = Double(Int16(littleEndian: src[min(idx, inCount - 1)]))
                    let b = Double(Int16(littleEndian: src[min(idx + 1, inCount - 1)]))
                    let sample = Int16(max(-32768, min(32767, Int((a + (b - a) * frac).rounded()))))
                    dst[i] = sample.littleEndian
                }
            }
        }
        return out
    }

    /// Computes RMS and peak dBFS of mono 16-bit PCM samples.
    public static func levels(pcm16: Data) -> (rmsDB: Double, peakDB: Double) {
        let count = pcm16.count / 2
        guard count > 0 else { return (-120, -120) }
        var sumSq = 0.0
        var peak = 0.0
        pcm16.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<count {
                let v = abs(Double(Int16(littleEndian: samples[i])) / 32768.0)
                sumSq += v * v
                if v > peak { peak = v }
            }
        }
        let rms = sqrt(sumSq / Double(count))
        let rmsDB = rms > 1e-6 ? 20.0 * log10(rms) : -120.0
        let peakDB = peak > 1e-6 ? 20.0 * log10(peak) : -120.0
        return (rmsDB, peakDB)
    }

    /// Converts OpenAI-style tool definitions into Gemini Live `functionDeclarations` (stripping unsupported keys).
    public static func geminiFunctionDeclarations(from toolsJSON: String?) -> [[String: Any]] {
        guard let toolsJSON, let data = toolsJSON.data(using: .utf8),
              let tools = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return tools.compactMap { tool -> [String: Any]? in
            guard let name = tool["name"] as? String else { return nil }
            var decl: [String: Any] = ["name": name]
            if let desc = tool["description"] as? String { decl["description"] = desc }
            if let params = tool["parameters"] as? [String: Any] {
                decl["parameters"] = sanitizeGeminiSchema(params)
            }
            return decl
        }
    }

    private static func sanitizeGeminiSchema(_ schema: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        if let type = schema["type"] as? String { out["type"] = type.uppercased() }
        if let desc = schema["description"] as? String { out["description"] = desc }
        if let en = schema["enum"] as? [String] { out["enum"] = en }
        if let req = schema["required"] as? [String], !req.isEmpty { out["required"] = req }
        if let props = schema["properties"] as? [String: [String: Any]], !props.isEmpty {
            var mapped: [String: Any] = [:]
            for (k, v) in props { mapped[k] = sanitizeGeminiSchema(v) }
            out["properties"] = mapped
        }
        if let items = schema["items"] as? [String: Any] {
            out["items"] = sanitizeGeminiSchema(items)
        }
        return out
    }
}
