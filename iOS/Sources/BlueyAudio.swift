import AVFoundation

/// The app's one audio engine. iOS gives the microphone (with echo cancellation) to a single engine per app,
/// so Bluey's voice mode and the phone call share it instead of fighting over it.
enum BlueyAudio {
    nonisolated(unsafe) static let engine = AVAudioEngine()
    /// While a call runs it owns the audio session: voice mode and chirps keep their hands off.
    nonisolated(unsafe) static var callActive = false
}
