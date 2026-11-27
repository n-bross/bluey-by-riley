import Foundation
import GooglyShared

/// User choices from the menu bar, kept between launches.
final class Settings {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    var onChange: (() -> Void)?

    /// Cursor size in points (the design's default is 72).
    var cursorSize: Double {
        get { defaults.object(forKey: "cursorSize") as? Double ?? 72 }
        set { defaults.set(newValue, forKey: "cursorSize"); onChange?() }
    }

    var showCursor: Bool {
        get { defaults.object(forKey: "showCursor") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showCursor"); onChange?() }
    }

    /// Where the phone sits under the screen, 0 = left edge, 1 = right edge.
    var phonePosition: Double {
        get { defaults.object(forKey: "phonePosition") as? Double ?? 0.5 }
        set { defaults.set(newValue, forKey: "phonePosition"); onChange?() }
    }

    /// When idle, hide the big cursor and let the phone's eyes follow your own mouse.
    var followMouse: Bool {
        get { defaults.object(forKey: "followMouse") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "followMouse"); onChange?() }
    }

    var captions: Bool {
        get { defaults.object(forKey: "captions") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "captions"); onChange?() }
    }

    /// Lets him click, type, press keys and open things when you ask.
    var computerControl: Bool {
        get { defaults.object(forKey: "computerControl") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "computerControl"); onChange?() }
    }

    /// Bluey lives in the MacBook's notch and works without the phone (voice and focus run on the Mac).
    var notchMode: Bool {
        get { defaults.object(forKey: "notchMode") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "notchMode"); onChange?() }
    }

    /// Keep a daily journal of what you worked on (~/Documents/Bluey Journal).
    var journalEnabled: Bool {
        get { defaults.object(forKey: "journalEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "journalEnabled"); onChange?() }
    }

    /// Send each day's journal to Hermes, so it knows your days.
    var journalToHermes: Bool {
        get { defaults.object(forKey: "journalToHermes") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "journalToHermes"); onChange?() }
    }

    /// From this hour, today's journal goes to Hermes (finished days go the next time Bluey runs).
    var journalHour: Int {
        get { defaults.object(forKey: "journalHour") as? Int ?? 18 }
        set { defaults.set(min(23, max(0, newValue)), forKey: "journalHour"); onChange?() }
    }

    /// Hidden with the hide shortcut: no notch, pointer or avatar until shown again.
    var hidden: Bool {
        get { defaults.bool(forKey: "hidden") }
        set { defaults.set(newValue, forKey: "hidden"); onChange?() }
    }

    /// What his pointer looks like (the Keramik drone by default).
    var pointerStyle: PointerStyle {
        get { PointerStyle(rawValue: defaults.string(forKey: "pointerStyle") ?? "") ?? .drone }
        set { defaults.set(newValue.rawValue, forKey: "pointerStyle"); onChange?() }
    }

    /// How the cursor's path shows while it flies.
    var trail: PointerTrail {
        get { PointerTrail(rawValue: defaults.string(forKey: "trail") ?? "") ?? .comet }
        set { defaults.set(newValue.rawValue, forKey: "trail"); onChange?() }
    }

    /// Shows the user's Keramik avatar in a small floating window.
    var showAvatarWindow: Bool {
        get { defaults.object(forKey: "showAvatarWindow") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showAvatarWindow"); onChange?() }
    }

    /// The mood picked by hand in the menu.
    var mood: Mood {
        get { Mood(rawValue: defaults.string(forKey: "mood") ?? "") ?? .listening }
        set { defaults.set(newValue.rawValue, forKey: "mood"); onChange?() }
    }

    // MARK: AI & Voice Service Providers (0 € / Subscription defaults)

    /// Live Voice backend (Notch, Push-to-Talk & iPhone calls). Default: local STT + Hermes (Subscription).
    var voiceProvider: VoiceProvider {
        get { VoiceProvider(rawValue: defaults.string(forKey: "voiceProvider") ?? "") ?? .localHermes }
        set { defaults.set(newValue.rawValue, forKey: "voiceProvider"); onChange?() }
    }

    /// Spoken voice output for iPhone calls in modular (`localHermes`) mode.
    var ttsProvider: TTSProvider {
        get { TTSProvider(rawValue: defaults.string(forKey: "ttsProvider") ?? "") ?? .apple }
        set { defaults.set(newValue.rawValue, forKey: "ttsProvider"); onChange?() }
    }

    var geminiLiveModel: String {
        get {
            let v = defaults.string(forKey: "geminiLiveModel")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return v.isEmpty ? "gemini-2.5-flash-native-audio-preview" : v
        }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "geminiLiveModel"); onChange?() }
    }

    var geminiLiveVoice: String {
        get {
            let v = defaults.string(forKey: "geminiLiveVoice")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return v.isEmpty ? "Aoede" : v
        }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "geminiLiveVoice"); onChange?() }
    }

    var elevenLabsVoiceID: String {
        get {
            let v = defaults.string(forKey: "elevenLabsVoiceID")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return v.isEmpty ? "21m00Tcm4TlvDq8ikWAM" : v
        }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "elevenLabsVoiceID"); onChange?() }
    }

    var localTTSURL: String {
        get {
            let v = defaults.string(forKey: "localTTSURL")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return v.isEmpty ? "http://127.0.0.1:8000/v1/audio/speech" : v
        }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "localTTSURL"); onChange?() }
    }

    var localTTSModel: String {
        get {
            let v = defaults.string(forKey: "localTTSModel")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return v.isEmpty ? "mlx-community/Kokoro-82M-bf16" : v
        }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "localTTSModel"); onChange?() }
    }

    var localTTSVoice: String {
        get {
            let v = defaults.string(forKey: "localTTSVoice")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return v.isEmpty ? "af_heart" : v
        }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "localTTSVoice"); onChange?() }
    }

    /// Transcription backend for Call-Notizen & modular voice. Default: Apple On-Device (0 €).
    var transcriptionProvider: TranscriptionProvider {
        get { TranscriptionProvider(rawValue: defaults.string(forKey: "transcriptionProvider") ?? "") ?? .appleLocal }
        set { defaults.set(newValue.rawValue, forKey: "transcriptionProvider"); onChange?() }
    }

    /// Preferred transcription locale / ISO language (empty = system/auto, e.g. "de-DE", "en-US").
    var transcriptionLanguage: String {
        get { defaults.string(forKey: "transcriptionLanguage") ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "transcriptionLanguage"); onChange?() }
    }

    /// Skip silent audio chunks before transcribing (saves >50% of calls & CPU).
    var transcriptionSilenceFilter: Bool {
        get { defaults.object(forKey: "transcriptionSilenceFilter") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "transcriptionSilenceFilter"); onChange?() }
    }

    /// Meeting audio flush interval in seconds (default 30s instead of 18s).
    var meetingChunkSeconds: Int {
        get {
            let v = defaults.object(forKey: "meetingChunkSeconds") as? Int ?? 30
            return min(120, max(15, v))
        }
        set { defaults.set(min(120, max(15, newValue)), forKey: "meetingChunkSeconds"); onChange?() }
    }

    /// Automatically stop meeting recording after N minutes of continuous silence (0 = disabled).
    var meetingAutoStopSilentMinutes: Int {
        get { defaults.object(forKey: "meetingAutoStopSilentMinutes") as? Int ?? 15 }
        set { defaults.set(max(0, newValue), forKey: "meetingAutoStopSilentMinutes"); onChange?() }
    }

    var localSTTURL: String {
        get {
            let v = defaults.string(forKey: "localSTTURL")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return v.isEmpty ? "http://127.0.0.1:8000/v1/audio/transcriptions" : v
        }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "localSTTURL"); onChange?() }
    }

    var localSTTModel: String {
        get {
            let v = defaults.string(forKey: "localSTTModel")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return v.isEmpty ? "mlx-community/whisper-large-v3-turbo" : v
        }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "localSTTModel"); onChange?() }
    }

    var groqSTTModel: String {
        get {
            let v = defaults.string(forKey: "groqSTTModel")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return v.isEmpty ? "whisper-large-v3-turbo" : v
        }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "groqSTTModel"); onChange?() }
    }

    var customSTTURL: String {
        get { defaults.string(forKey: "customSTTURL") ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "customSTTURL"); onChange?() }
    }

    var customSTTModel: String {
        get { defaults.string(forKey: "customSTTModel") ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "customSTTModel"); onChange?() }
    }

    var openAISTTModel: String {
        get {
            let v = defaults.string(forKey: "openAISTTModel")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return v.isEmpty ? "gpt-4o-mini-transcribe" : v
        }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "openAISTTModel"); onChange?() }
    }

    /// Standard AI backend for Chat, Meeting Q&A, Web Research & Modular Voice brain. Default: Hermes (Subscription).
    var llmProvider: LLMProvider {
        get { LLMProvider(rawValue: defaults.string(forKey: "llmProvider") ?? "") ?? .hermes }
        set { defaults.set(newValue.rawValue, forKey: "llmProvider"); onChange?() }
    }

    var customLLMBaseURL: String {
        get {
            let v = defaults.string(forKey: "customLLMBaseURL")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return v.isEmpty ? "https://openrouter.ai/api/v1" : v
        }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "customLLMBaseURL"); onChange?() }
    }

    var customLLMModel: String {
        get {
            let v = defaults.string(forKey: "customLLMModel")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return v.isEmpty ? "google/gemini-2.5-flash" : v
        }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "customLLMModel"); onChange?() }
    }

    /// Backend for Focus screen checks. Default: follow `llmProvider` (Hermes Subscription).
    var focusProvider: FocusProvider {
        get { FocusProvider(rawValue: defaults.string(forKey: "focusProvider") ?? "") ?? .followLLM }
        set { defaults.set(newValue.rawValue, forKey: "focusProvider"); onChange?() }
    }

    /// Skip focus check API call when the frontmost app and visible OCR text haven't changed.
    var focusSkipUnchanged: Bool {
        get { defaults.object(forKey: "focusSkipUnchanged") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "focusSkipUnchanged"); onChange?() }
    }
}
