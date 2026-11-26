import AVFoundation
import Speech
import SwiftUI

@MainActor
final class MacChatDictation: ObservableObject {
    @Published private(set) var listening = false
    @Published private(set) var starting = false
    private let engine = AVAudioEngine()
    private var task: SFSpeechRecognitionTask?
    private var generation = UUID()
    private var hasTap = false

    func start(onText: @escaping (String) -> Void, onError: @escaping (String) -> Void) async {
        guard !listening, !starting else { return }
        starting = true
        let id = UUID()
        generation = id
        defer { if generation == id { starting = false } }
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard id == generation else { return }
        guard speech == .authorized else { onError("Erlaube die Spracherkennung in den macOS-Einstellungen."); return }
        let microphone = await AVCaptureDevice.requestAccess(for: .audio)
        guard id == generation else { return }
        guard microphone else { onError("Erlaube den Mikrofonzugriff für Bluey."); return }
        guard let recognizer = SFSpeechRecognizer(locale: .current),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            onError("Für deine Systemsprache ist gerade keine lokale Spracherkennung verfügbar.")
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            onError("Kein Mikrofon verfügbar.")
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        hasTap = true
        do {
            try engine.start()
            listening = true
        } catch {
            stop()
            onError(error.localizedDescription)
            return
        }
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let phrase = result?.bestTranscription.formattedString
            let complete = result?.isFinal == true
            let failure = error?.localizedDescription
            Task { @MainActor in
                guard let self, self.generation == id else { return }
                if let phrase { onText(phrase) }
                if let failure { onError(failure) }
                if complete || failure != nil { self.stop() }
            }
        }
    }

    func stop() {
        generation = UUID()
        starting = false
        listening = false
        engine.stop()
        if hasTap {
            engine.inputNode.removeTap(onBus: 0)
            hasTap = false
        }
        task?.cancel()
        task = nil
    }
}
