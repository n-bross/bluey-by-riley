import AppKit
import AVFoundation
import CoreGraphics
import CoreVideo
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

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

    struct Screenshot: Codable, Identifiable, Equatable, Sendable {
        var filename: String
        var captured: Date
        var manual: Bool
        var label: String?
        var id: String { filename }
    }

    enum CaptureTarget: Hashable, Codable, Identifiable, Sendable {
        case display
        case window(id: UInt32, title: String, appName: String)

        var id: String {
            switch self {
            case .display: return "display"
            case .window(let id, _, _): return "window-\(id)"
            }
        }

        var displayName: String {
            switch self {
            case .display:
                return "Gesamter Bildschirm"
            case .window(_, let title, let appName):
                let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                let cleanApp = appName.trimmingCharacters(in: .whitespacesAndNewlines)
                if cleanTitle.isEmpty { return cleanApp.isEmpty ? "Fenster" : cleanApp }
                if cleanApp.isEmpty { return String(cleanTitle.prefix(56)) }
                return "\(cleanApp) · \(String(cleanTitle.prefix(46)))"
            }
        }

        var windowID: CGWindowID? {
            if case .window(let id, _, _) = self { return CGWindowID(id) }
            return nil
        }
    }

    struct VisualConfig: Sendable {
        var recordVideo: Bool
        var autoScreenshots: Bool
        var target: CaptureTarget
        var videoFPS: Int = 5
        var maxWidth: Int = 1280
        var maxHeight: Int = 720

        var enabled: Bool { recordVideo || autoScreenshots }
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

    static let preferredMeetingApps: Set<String> = [
        "com.microsoft.teams2", "com.microsoft.teams",
        "net.imput.helium", "com.apple.Safari", "com.google.Chrome",
        "com.microsoft.edgemac", "org.mozilla.firefox", "company.thebrowser.Browser",
        "app.zen-browser.zen", "us.zoom.xos", "com.cisco.webexmeetingsapp",
        "com.hnc.Discord"
    ]

    static func availableTargets() async -> [CaptureTarget] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else {
            return [.display]
        }
        let ownBundle = Bundle.main.bundleIdentifier
        let candidates: [(priority: Int, target: CaptureTarget)] = content.windows.compactMap { window in
            guard window.isOnScreen, window.frame.width >= 200, window.frame.height >= 150 else { return nil }
            let bundle = window.owningApplication?.bundleIdentifier ?? ""
            if let ownBundle, bundle == ownBundle { return nil }
            let appName = window.owningApplication?.applicationName ?? ""
            let title = (window.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty || !appName.isEmpty else { return nil }
            let lowerTitle = title.lowercased()
            let priority: Int
            if lowerTitle.contains("teams") || lowerTitle.contains("meet") || lowerTitle.contains("zoom") || lowerTitle.contains("webex") {
                priority = 0
            } else if preferredMeetingApps.contains(bundle) {
                priority = 1
            } else {
                priority = 2
            }
            return (priority, .window(id: UInt32(window.windowID), title: title, appName: appName))
        }
        let sorted = candidates
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
                return lhs.target.displayName.localizedCaseInsensitiveCompare(rhs.target.displayName) == .orderedAscending
            }
            .map(\.target)
        return [.display] + sorted
    }

    private let queue = DispatchQueue(label: "bluey.meeting.audio")
    private let videoQueue = DispatchQueue(label: "bluey.meeting.video")
    private let imageQueue = DispatchQueue(label: "bluey.meeting.screenshots", qos: .utility)
    private let folder: URL
    private let sessionFolder: URL
    private let visual: VisualConfig?
    private let onScreenshot: (@Sendable (Screenshot) -> Void)?
    private let onVisualWarning: (@Sendable (String) -> Void)?
    private let onFailure: @Sendable (Error) -> Void

    @MainActor private var stream: SCStream?
    @MainActor private var videoStream: SCStream?
    @MainActor private(set) var resolvedTargetName: String?

    // The sample queue owns the audio writers until flush detaches them.
    private var writers: [Source: Track] = [:]
    private var accepting = false

    // Owned by videoQueue.
    private var acceptingVideo = false
    private var videoTrack: VideoTrack?
    private var slideDetector = SlideChangeDetector()
    private var lastSlideCheck = Date.distantPast
    private var slideCounter = 0
    private var manualCounter = 0
    private var latestImage: (image: CGImage, captured: Date)?

    init(
        folder: URL,
        sessionFolder: URL? = nil,
        visual: VisualConfig? = nil,
        onScreenshot: (@Sendable (Screenshot) -> Void)? = nil,
        onVisualWarning: (@Sendable (String) -> Void)? = nil,
        onFailure: @escaping @Sendable (Error) -> Void
    ) {
        self.folder = folder
        self.sessionFolder = sessionFolder ?? folder.deletingLastPathComponent()
        self.visual = visual
        self.onScreenshot = onScreenshot
        self.onVisualWarning = onVisualWarning
        self.onFailure = onFailure
    }

    @MainActor
    func start() async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw Failure.microphone }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw Failure.display }

        // Always capture full system audio + microphone on a dedicated lightweight stream so
        // window-level video capture or multi-process browser audio helpers never drop audio.
        let audioFilter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let audioConfig = SCStreamConfiguration()
        audioConfig.width = 2
        audioConfig.height = 2
        audioConfig.capturesAudio = true
        audioConfig.excludesCurrentProcessAudio = true
        audioConfig.captureMicrophone = true
        audioConfig.sampleRate = 48_000
        audioConfig.channelCount = 1
        let audioStream = SCStream(filter: audioFilter, configuration: audioConfig, delegate: self)
        try audioStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try audioStream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        self.stream = audioStream
        queue.sync { accepting = true }
        try await audioStream.startCapture()

        if let visual, visual.enabled {
            await startVisualStream(visual: visual, content: content, fallbackDisplay: display)
        }
    }

    @MainActor
    private func startVisualStream(visual: VisualConfig, content: SCShareableContent, fallbackDisplay: SCDisplay) async {
        let (filter, sourceSize, targetName, warning) = resolveVisualFilter(
            target: visual.target,
            content: content,
            fallbackDisplay: fallbackDisplay
        )
        resolvedTargetName = targetName
        if let warning { onVisualWarning?(warning) }

        let fitted = VideoTrack.fittedSize(
            width: max(Int(sourceSize.width), 2),
            height: max(Int(sourceSize.height), 2),
            maxWidth: visual.maxWidth,
            maxHeight: visual.maxHeight
        )
        let config = SCStreamConfiguration()
        config.width = fitted.width
        config.height = fitted.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(visual.videoFPS, 1)))
        config.queueDepth = 3
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.capturesAudio = false
        config.captureMicrophone = false

        let vStream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try vStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
            videoQueue.sync {
                self.acceptingVideo = true
                self.slideDetector = SlideChangeDetector()
                self.lastSlideCheck = .distantPast
                self.latestImage = nil
            }
            self.videoStream = vStream
            try await vStream.startCapture()
        } catch {
            videoQueue.sync { self.acceptingVideo = false }
            self.videoStream = nil
            onVisualWarning?("Video/Screenshots konnten nicht starten (Audio läuft weiter): \(error.localizedDescription)")
        }
    }

    private func resolveVisualFilter(
        target: CaptureTarget,
        content: SCShareableContent,
        fallbackDisplay: SCDisplay
    ) -> (filter: SCContentFilter, size: CGSize, name: String, warning: String?) {
        let ownBundle = Bundle.main.bundleIdentifier
        let ownApps = content.applications.filter { $0.bundleIdentifier == ownBundle }
        switch target {
        case .window(let id, _, _):
            if let window = content.windows.first(where: { UInt32($0.windowID) == id }) {
                let scale = NSScreen.main?.backingScaleFactor ?? 2
                let size = CGSize(width: window.frame.width * scale, height: window.frame.height * scale)
                return (SCContentFilter(desktopIndependentWindow: window), size, target.displayName, nil)
            }
            let size = CGSize(width: fallbackDisplay.width, height: fallbackDisplay.height)
            return (
                SCContentFilter(display: fallbackDisplay, excludingApplications: ownApps, exceptingWindows: []),
                size,
                CaptureTarget.display.displayName,
                "Gewähltes Fenster wurde nicht mehr gefunden – nehme stattdessen den Bildschirm auf."
            )
        case .display:
            let size = CGSize(width: fallbackDisplay.width, height: fallbackDisplay.height)
            return (
                SCContentFilter(display: fallbackDisplay, excludingApplications: ownApps, exceptingWindows: []),
                size,
                CaptureTarget.display.displayName,
                nil
            )
        }
    }

    @MainActor
    func stop() async throws -> String? {
        let activeAudio = stream
        stream = nil
        let activeVideo = videoStream
        videoStream = nil

        var audioStopError: Error?
        do { try await activeAudio?.stopCapture() }
        catch { audioStopError = error }

        if let activeVideo {
            try? await activeVideo.stopCapture()
        }

        let videoFilename = await finishVideo()
        if let audioStopError { throw audioStopError }
        return videoFilename
    }

    func finishVideo() async -> String? {
        let track: VideoTrack? = await withCheckedContinuation { continuation in
            videoQueue.async {
                self.acceptingVideo = false
                let current = self.videoTrack
                self.videoTrack = nil
                continuation.resume(returning: current)
            }
        }
        guard let track else { return nil }
        do {
            return try await track.finish()
        } catch {
            onVisualWarning?("Video konnte nicht vollständig abgeschlossen werden: \(error.localizedDescription)")
            return nil
        }
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

    /// Captures a manual screenshot immediately (using the freshest stream frame when available,
    /// otherwise taking a one-shot SCScreenshotManager capture of the configured target).
    func captureManualScreenshot() async -> Screenshot? {
        let cached: (image: CGImage, index: Int)? = await withCheckedContinuation { continuation in
            videoQueue.async {
                if let latest = self.latestImage, Date().timeIntervalSince(latest.captured) < 3.0 {
                    self.manualCounter += 1
                    continuation.resume(returning: (latest.image, self.manualCounter))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
        if let cached {
            return await persistScreenshot(image: cached.image, manual: true, index: cached.index, captured: Date())
        }

        // One-shot capture (works even when recording audio-only or while the window is idle).
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first else {
            return nil
        }
        let target = visual?.target ?? .display
        let (filter, size, _, _) = resolveVisualFilter(target: target, content: content, fallbackDisplay: display)
        let fitted = VideoTrack.fittedSize(
            width: max(Int(size.width), 2),
            height: max(Int(size.height), 2),
            maxWidth: visual?.maxWidth ?? 1600,
            maxHeight: visual?.maxHeight ?? 1000
        )
        let config = SCStreamConfiguration()
        config.width = fitted.width
        config.height = fitted.height
        config.showsCursor = false
        guard let cgImage = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else {
            return nil
        }
        let index: Int = await withCheckedContinuation { continuation in
            videoQueue.async {
                self.manualCounter += 1
                continuation.resume(returning: self.manualCounter)
            }
        }
        return await persistScreenshot(image: cgImage, manual: true, index: index, captured: Date())
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            if self.videoStream === stream {
                self.videoStream = nil
                _ = await self.finishVideo()
                self.onVisualWarning?("Videoaufnahme beendet (Audio läuft weiter): \(error.localizedDescription)")
            } else {
                self.onFailure(error)
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .screen {
            handleVideoBuffer(buffer)
            return
        }
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

    private func handleVideoBuffer(_ buffer: CMSampleBuffer) {
        guard acceptingVideo, buffer.isValid else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let rawStatus = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: rawStatus),
           status != .complete {
            return
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        guard pts.isValid, pts.isNumeric else { return }

        if visual?.recordVideo == true {
            do {
                let track: VideoTrack
                if let existing = videoTrack {
                    track = existing
                } else {
                    track = try VideoTrack(
                        sessionFolder: sessionFolder,
                        width: CVPixelBufferGetWidth(pixelBuffer),
                        height: CVPixelBufferGetHeight(pixelBuffer),
                        fps: visual?.videoFPS ?? 5,
                        startTime: pts
                    )
                    videoTrack = track
                }
                track.append(pixelBuffer, presentationTime: pts)
            } catch {
                // Keep audio and screenshots alive even if video encoding hits a snag.
                videoTrack = nil
                onVisualWarning?("Video-Encoder-Fehler (Audio läuft weiter): \(error.localizedDescription)")
            }
        }

        let now = Date()
        if now.timeIntervalSince(lastSlideCheck) >= 1.0 {
            lastSlideCheck = now
            if let cgImage = Self.makeCGImage(from: pixelBuffer) {
                latestImage = (cgImage, now)
                if visual?.autoScreenshots == true,
                   let fingerprint = SlideChangeDetector.fingerprint(from: pixelBuffer),
                   slideDetector.shouldCapture(fingerprint: fingerprint, now: now) {
                    slideCounter += 1
                    let index = slideCounter
                    imageQueue.async { [weak self] in
                        guard let self else { return }
                        if let shot = self.writeJPEG(image: cgImage, manual: false, index: index, captured: now) {
                            self.onScreenshot?(shot)
                        }
                    }
                }
            }
        }
    }

    private func persistScreenshot(image: CGImage, manual: Bool, index: Int, captured: Date) async -> Screenshot? {
        await withCheckedContinuation { continuation in
            imageQueue.async {
                continuation.resume(returning: self.writeJPEG(image: image, manual: manual, index: index, captured: captured))
            }
        }
    }

    private func writeJPEG(image: CGImage, manual: Bool, index: Int, captured: Date) -> Screenshot? {
        let dir = sessionFolder.appendingPathComponent("screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let prefix = manual ? "manual" : "slide"
        let stamp = Self.shotTimestamp.string(from: captured)
        let name = String(format: "%@-%03d-%@.jpg", prefix, index, stamp)
        let url = dir.appendingPathComponent(name)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        let options = [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary
        CGImageDestinationAddImage(dest, image, options)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return Screenshot(
            filename: "screenshots/\(name)",
            captured: captured,
            manual: manual,
            label: manual ? "Screenshot" : "Folie / Bildschirmänderung"
        )
    }

    private static let shotTimestamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH-mm-ss"
        return f
    }()

    private static func makeCGImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        return context.makeImage()
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

    // Used on videoQueue until detached by finishVideo().
    final class VideoTrack: @unchecked Sendable {
        let filename: String
        private let writer: AVAssetWriter
        private let input: AVAssetWriterInput
        private let adaptor: AVAssetWriterInputPixelBufferAdaptor
        private var lastPTS: CMTime = .invalid
        private var frameCount = 0

        static func fittedSize(width: Int, height: Int, maxWidth: Int = 1280, maxHeight: Int = 720) -> (width: Int, height: Int) {
            let safeW = max(width, 2)
            let safeH = max(height, 2)
            let scale = min(1.0, min(Double(maxWidth) / Double(safeW), Double(maxHeight) / Double(safeH)))
            let evenW = max(64, (Int((Double(safeW) * scale).rounded()) / 2) * 2)
            let evenH = max(64, (Int((Double(safeH) * scale).rounded()) / 2) * 2)
            return (evenW, evenH)
        }

        init(sessionFolder: URL, filename: String = "video.mp4", width: Int, height: Int, fps: Int = 5, startTime: CMTime) throws {
            self.filename = filename
            let outputURL = sessionFolder.appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: outputURL)
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
            let evenW = max(64, (width / 2) * 2)
            let evenH = max(64, (height / 2) * 2)
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: evenW,
                AVVideoHeightKey: evenH,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 900_000,
                    AVVideoExpectedSourceFrameRateKey: max(fps, 1),
                    AVVideoMaxKeyFrameIntervalKey: max(fps * 5, 5),
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ]
            ]
            input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: evenW,
                    kCVPixelBufferHeightKey as String: evenH
                ]
            )
            guard writer.canAdd(input) else { throw Failure.writer }
            writer.add(input)
            guard writer.startWriting() else { throw writer.error ?? Failure.writer }
            writer.startSession(atSourceTime: startTime)
        }

        @discardableResult
        func append(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) -> Bool {
            guard writer.status == .writing, input.isReadyForMoreMediaData else { return false }
            if lastPTS.isValid, CMTimeCompare(presentationTime, lastPTS) <= 0 { return false }
            guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else { return false }
            lastPTS = presentationTime
            frameCount += 1
            return true
        }

        func finish() async throws -> String? {
            if writer.status == .writing {
                input.markAsFinished()
                await writer.finishWriting()
            }
            guard frameCount > 0 else { return nil }
            guard writer.status == .completed else { throw writer.error ?? Failure.writer }
            return filename
        }
    }
}

/// Lightweight slide/screen change detector using a 32×18 luma grid fingerprint.
struct SlideChangeDetector: Sendable {
    static let gridWidth = 32
    static let gridHeight = 18

    private(set) var lastSaved: [UInt8]?
    private(set) var lastSavedAt: Date = .distantPast
    private var pending: [UInt8]?

    static func fingerprint(from pixelBuffer: CVPixelBuffer) -> [UInt8]? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0 else { return nil }

        let ptr = base.assumingMemoryBound(to: UInt8.self)
        var grid = [UInt8](repeating: 0, count: gridWidth * gridHeight)
        for gy in 0..<gridHeight {
            let y = min(height - 1, (gy * height) / gridHeight + height / (gridHeight * 2))
            let row = y * bytesPerRow
            for gx in 0..<gridWidth {
                let x = min(width - 1, (gx * width) / gridWidth + width / (gridWidth * 2))
                let offset = row + x * 4
                let b = Int(ptr[offset])
                let g = Int(ptr[offset + 1])
                let r = Int(ptr[offset + 2])
                grid[gy * gridWidth + gx] = UInt8((299 * r + 587 * g + 114 * b) / 1000)
            }
        }
        return grid
    }

    static func isLikelyBlank(_ grid: [UInt8]) -> Bool {
        guard !grid.isEmpty else { return true }
        var minVal: UInt8 = 255
        var maxVal: UInt8 = 0
        for v in grid {
            if v < minVal { minVal = v }
            if v > maxVal { maxVal = v }
        }
        return Int(maxVal) - Int(minVal) < 6 && maxVal < 16
    }

    static func diff(_ a: [UInt8], _ b: [UInt8]) -> (mad: Double, changedRatio: Double) {
        let count = min(a.count, b.count)
        guard count > 0 else { return (0, 0) }
        var totalDiff = 0
        var changed = 0
        for i in 0..<count {
            let d = abs(Int(a[i]) - Int(b[i]))
            totalDiff += d
            if d >= 18 { changed += 1 }
        }
        return (Double(totalDiff) / (Double(count) * 255.0), Double(changed) / Double(count))
    }

    mutating func shouldCapture(
        fingerprint: [UInt8],
        now: Date,
        minInterval: TimeInterval = 6.0,
        madThreshold: Double = 0.055,
        changedRatioThreshold: Double = 0.14
    ) -> Bool {
        guard !Self.isLikelyBlank(fingerprint) else { return false }
        guard let lastSaved else {
            self.lastSaved = fingerprint
            self.lastSavedAt = now
            self.pending = nil
            return true
        }
        let delta = Self.diff(fingerprint, lastSaved)
        let significant = delta.mad >= madThreshold || delta.changedRatio >= changedRatioThreshold
        guard significant else {
            pending = nil
            return false
        }
        guard now.timeIntervalSince(lastSavedAt) >= minInterval else {
            pending = fingerprint
            return false
        }
        if let pending {
            let settle = Self.diff(fingerprint, pending)
            if settle.mad < 0.025 {
                self.lastSaved = fingerprint
                self.lastSavedAt = now
                self.pending = nil
                return true
            }
        }
        pending = fingerprint
        return false
    }
}
