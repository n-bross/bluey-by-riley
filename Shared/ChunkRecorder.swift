import AVFoundation
import Foundation

/// Records everything the mic hears during a session to small AAC files, five minutes each,
/// so an all-day session never builds one giant file and each piece can be transcribed as soon as it's done.
public final class ChunkRecorder {
    public init() {}
    public struct Chunk {
        public let sessionID: UUID
        public let index: Int
        public let url: URL
        /// When this chunk started, so its transcript lines get real times.
        public let started: Date
    }

    public static let chunkLength: TimeInterval = 300

    /// Called on the main queue each time a chunk is finished.
    public var onChunk: ((Chunk) -> Void)?

    private let queue = DispatchQueue(label: "googly.recorder")
    private var sessionID: UUID?
    private var file: AVAudioFile?
    private var fileFormat: AVAudioFormat?
    private var chunkStarted = Date()
    private var chunkIndex = 0
    private var chunkURL: URL?

    public static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("audio", isDirectory: true)
    }

    public func start(session: UUID) {
        queue.async {
            self.closeChunk()
            self.sessionID = session
            self.chunkIndex = 0
        }
    }

    /// Feeds one buffer from the mic tap (any thread).
    public func append(_ buffer: AVAudioPCMBuffer) {
        guard let copy = buffer.copy() as? AVAudioPCMBuffer else { return }
        queue.async { self.write(copy) }
    }

    public func finish() {
        queue.async {
            self.closeChunk()
            self.sessionID = nil
        }
    }

    private func write(_ buffer: AVAudioPCMBuffer) {
        guard let sessionID else { return }
        if file != nil, Date().timeIntervalSince(chunkStarted) >= Self.chunkLength { closeChunk() }
        if file == nil || fileFormat != buffer.format {
            closeChunk()
            openChunk(sessionID: sessionID, format: buffer.format)
        }
        try? file?.write(from: buffer)
    }

    private func openChunk(sessionID: UUID, format: AVAudioFormat) {
        let folder = Self.folder.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        chunkIndex += 1
        let url = folder.appendingPathComponent(String(format: "chunk-%03d.m4a", chunkIndex))
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: min(format.channelCount, 2),
            AVEncoderBitRateKey: 48_000,
        ]
        file = try? AVAudioFile(forWriting: url, settings: settings,
                                commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        fileFormat = format
        chunkURL = url
        chunkStarted = Date()
    }

    private func closeChunk() {
        guard file != nil, let url = chunkURL, let sessionID else { file = nil; return }
        file = nil  // closing the file finishes writing it
        let chunk = Chunk(sessionID: sessionID, index: chunkIndex, url: url, started: chunkStarted)
        chunkURL = nil
        DispatchQueue.main.async { self.onChunk?(chunk) }
    }
}

