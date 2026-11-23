import AVFoundation
import ScreenCaptureKit

@available(macOS 15, *)
final class MeetingAudio: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    enum Source: String, Codable, CaseIterable {
        case system, microphone
        var title: String { self == .microphone ? "Mikrofon" : "Mac-Audio" }
    }

    struct Clip: Codable, Identifiable {
        var source: Source
        var filename: String
        var started: Date
        var transcript: String?
        var id: String { filename }
    }

    enum Failure: LocalizedError {
        case microphone, display, writer, droppedSamples
        var errorDescription: String? {
            switch self {
            case .microphone: return "Erlaube Bluey den Mikrofonzugriff in den Systemeinstellungen."
            case .display: return "Für die Aufnahme ist ein aktiver Bildschirm erforderlich."
            case .writer: return "Die Audiodatei konnte nicht geschrieben werden."
            case .droppedSamples: return "Die Aufnahme wurde unterbrochen, weil Audio nicht schnell genug gespeichert werden konnte."
            }
        }
    }

    private let queue = DispatchQueue(label: "bluey.meeting.audio")
    private let folder: URL
    private let onFailure: @Sendable (Error) -> Void
    @MainActor private var stream: SCStream?
    // The sample queue owns the writers until flush detaches them.
    private var writers: [Source: Track] = [:]
    private var accepting = false

    init(folder: URL, onFailure: @escaping @Sendable (Error) -> Void) {
        self.folder = folder
        self.onFailure = onFailure
    }

    @MainActor
    func start() async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw Failure.microphone }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw Failure.display }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 1
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        self.stream = stream
        queue.sync { accepting = true }
        try await stream.startCapture()
    }

    @MainActor
    func stop() async throws {
        let active = stream
        stream = nil
        try await active?.stopCapture()
    }

    func flush(stopping: Bool = false) async -> (clips: [Clip], errors: [String]) {
        let tracks = await withCheckedContinuation { continuation in
            queue.async {
                if stopping { self.accepting = false }
                let tracks = Array(self.writers.values)
                self.writers.removeAll()
                continuation.resume(returning: tracks)
            }
        }
        var clips: [Clip] = []
        var errors: [String] = []
        for track in tracks {
            do { clips.append(try await track.finish()) }
            catch { errors.append(error.localizedDescription) }
        }
        return (clips.sorted { $0.started < $1.started }, errors)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onFailure(error)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard accepting, buffer.isValid, buffer.numSamples > 0 else { return }
        let source: Source = type == .microphone ? .microphone : .system
        do {
            let track: Track
            if let current = writers[source] { track = current }
            else {
                track = try Track(folder: folder, source: source, firstBuffer: buffer)
                writers[source] = track
            }
            try track.append(buffer)
        } catch {
            accepting = false
            onFailure(error)
        }
    }

    // Used on the sample queue until detached by flush.
    final class Track: @unchecked Sendable {
        let clip: Clip
        private let writer: AVAssetWriter
        private let input: AVAssetWriterInput

        init(folder: URL, source: Source, firstBuffer: CMSampleBuffer) throws {
            clip = Clip(source: source, filename: "\(source.rawValue)-\(UUID().uuidString).m4a", started: Date())
            writer = try AVAssetWriter(outputURL: folder.appendingPathComponent(clip.filename), fileType: .m4a)
            guard let description = firstBuffer.formatDescription,
                  let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else {
                throw Failure.writer
            }
            input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: min(Int(format.mChannelsPerFrame), 2),
                AVEncoderBitRateKey: 64_000
            ], sourceFormatHint: description)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw Failure.writer }
            writer.add(input)
            guard writer.startWriting() else { throw writer.error ?? Failure.writer }
            writer.startSession(atSourceTime: firstBuffer.presentationTimeStamp)
        }

        func append(_ buffer: CMSampleBuffer) throws {
            guard input.isReadyForMoreMediaData else { throw writer.error ?? Failure.droppedSamples }
            guard input.append(buffer) else { throw writer.error ?? Failure.writer }
        }

        func finish() async throws -> Clip {
            if writer.status == .writing {
                input.markAsFinished()
                await writer.finishWriting()
            }
            guard writer.status == .completed else { throw writer.error ?? Failure.writer }
            return clip
        }
    }
}
