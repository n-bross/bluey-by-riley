import AVFoundation
import CoreVideo
import XCTest
@testable import GooglyMac

@available(macOS 15, *)
final class MeetingAudioTests: XCTestCase {
    @MainActor
    func testTeamsWindowTitlesSeparateMeetingsFromRegularChats() {
        XCTAssertTrue(TeamsMeetingDetector.isMeetingTitle("Meeting | Microsoft Teams"))
        XCTAssertTrue(TeamsMeetingDetector.isMeetingTitle("Besprechung | Microsoft Teams - Google Chrome"))
        XCTAssertTrue(TeamsMeetingDetector.isMeetingTitle("Besprechung | Microsoft Teams - Helium"))
        XCTAssertTrue(TeamsMeetingDetector.isMeetingTitle("Microsoft Teams Meeting"))
        XCTAssertFalse(TeamsMeetingDetector.isMeetingTitle("Chat | Microsoft Teams"))
        XCTAssertFalse(TeamsMeetingDetector.isMeetingTitle("Meeting agenda | Microsoft Teams"))
        XCTAssertFalse(TeamsMeetingDetector.isMeetingTitle("Calendar | Microsoft Teams"))
    }

    @MainActor
    func testSupportedBrowserBundlesIncludeHelium() {
        XCTAssertTrue(TeamsMeetingDetector.supportedBrowserBundles.contains("net.imput.helium"))
        XCTAssertTrue(TeamsMeetingDetector.supportedBrowserBundles.contains("com.google.Chrome"))
        XCTAssertTrue(TeamsMeetingDetector.supportedBrowserBundles.contains("com.apple.Safari"))
    }

    func testSlideChangeDetectorSkipsBlankAndRequiresSettledChange() {
        var detector = SlideChangeDetector()
        let t0 = Date(timeIntervalSince1970: 1_000)
        let black = [UInt8](repeating: 0, count: SlideChangeDetector.gridWidth * SlideChangeDetector.gridHeight)
        let slideA = [UInt8](repeating: 40, count: SlideChangeDetector.gridWidth * SlideChangeDetector.gridHeight)
        var slideB = [UInt8](repeating: 210, count: SlideChangeDetector.gridWidth * SlideChangeDetector.gridHeight)
        slideB[0] = 200
        let slideC = [UInt8](repeating: 120, count: SlideChangeDetector.gridWidth * SlideChangeDetector.gridHeight)

        // Ignore blank frames before a real slide appears.
        XCTAssertFalse(detector.shouldCapture(fingerprint: black, now: t0))
        // Capture initial real slide immediately.
        XCTAssertTrue(detector.shouldCapture(fingerprint: slideA, now: t0.addingTimeInterval(1)))
        // Identical frame does not trigger again.
        XCTAssertFalse(detector.shouldCapture(fingerprint: slideA, now: t0.addingTimeInterval(10)))
        // Changed slide before minInterval does not capture yet, but starts settling.
        XCTAssertFalse(detector.shouldCapture(fingerprint: slideB, now: t0.addingTimeInterval(4)))
        // Once minInterval has elapsed and slideB stayed steady, it captures.
        XCTAssertTrue(detector.shouldCapture(fingerprint: slideB, now: t0.addingTimeInterval(8)))
        // Stays quiet once captured.
        XCTAssertFalse(detector.shouldCapture(fingerprint: slideB, now: t0.addingTimeInterval(15)))
        // Fresh slide past minInterval requires two steady observations before capturing.
        XCTAssertFalse(detector.shouldCapture(fingerprint: slideC, now: t0.addingTimeInterval(20)))
        XCTAssertTrue(detector.shouldCapture(fingerprint: slideC, now: t0.addingTimeInterval(21)))
    }

    func testVideoTrackFittedSizeIsEvenAndBounded() {
        let fitted = MeetingAudio.VideoTrack.fittedSize(width: 3024, height: 1964, maxWidth: 1280, maxHeight: 720)
        XCTAssertLessThanOrEqual(fitted.width, 1280)
        XCTAssertLessThanOrEqual(fitted.height, 720)
        XCTAssertEqual(fitted.width % 2, 0)
        XCTAssertEqual(fitted.height % 2, 0)
    }

    func testVideoTrackWritesPlayableMP4() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let width = 320
        let height = 180
        let start = CMTime(value: 0, timescale: 5)
        let track = try MeetingAudio.VideoTrack(sessionFolder: directory, width: width, height: height, fps: 5, startTime: start)

        for frame in 0..<6 {
            var pb: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_32BGRA,
                [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
                &pb
            )
            XCTAssertEqual(status, kCVReturnSuccess)
            let buffer = try XCTUnwrap(pb)
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, Int32((frame * 40) % 255), CVPixelBufferGetBytesPerRow(buffer) * height)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            XCTAssertTrue(track.append(buffer, presentationTime: CMTime(value: CMTimeValue(frame), timescale: 5)))
            try await Task.sleep(for: .milliseconds(40))
        }

        let filename = try await track.finish()
        XCTAssertEqual(filename, "video.mp4")
        let asset = AVURLAsset(url: directory.appendingPathComponent("video.mp4"))
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(videoTracks.count, 1)
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThan(duration.seconds, 0.8)
    }

    func testMeetingNotesMarkdownIncludesVideoAndScreenshots() {
        let started = Date(timeIntervalSince1970: 1_795_505_880)
        let json: [String: Any] = [
            "id": "abc12345",
            "started": started.timeIntervalSince1970,
            "video": "video.mp4",
            "captureTarget": "Helium · KI- Verantworten",
            "entries": [
                ["kind": "transcript", "speaker": "Mac-Audio", "text": "Hier sind die Zahlen.", "time": started.timeIntervalSince1970 + 10],
                ["kind": "screenshot", "path": "screenshots/slide-001-08-40-15.jpg", "manual": false, "text": "Folie / Bildschirmänderung", "time": started.timeIntervalSince1970 + 15],
                ["kind": "screenshot", "path": "screenshots/manual-001-08-41-00.jpg", "manual": true, "text": "Screenshot", "time": started.timeIntervalSince1970 + 60]
            ]
        ]
        let md = MeetingNotes.markdown(json, started: started)
        XCTAssertTrue(md.contains("Video: [video.mp4](video.mp4)"))
        XCTAssertTrue(md.contains("Screen source: Helium · KI- Verantworten."))
        XCTAssertTrue(md.contains("![Folie / Bildschirmänderung](screenshots/slide-001-08-40-15.jpg)"))
        XCTAssertTrue(md.contains("![Screenshot](screenshots/manual-001-08-41-00.jpg)"))
    }

    @MainActor
    func testLegacySessionJSONDecodesWithoutVisualFields() throws {
        let legacy = #"{"id":"01390EA9-E832-4AE0-B502-28D4F88144EA","started":817198725.96,"clips":[],"messages":[]}"#
        let decoded = try JSONDecoder().decode(MeetingWindow.Session.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.screenshots, [])
        XCTAssertNil(decoded.videoFilename)
        XCTAssertNil(decoded.captureTargetName)
    }

    @MainActor
    func testSessionRoundTripsDrawingsAndScreenshotsTogether() throws {
        let drawing = MeetingWindow.DrawingEvent(videoOffsetSeconds: 12, source: "Notiz", svgFilename: "note.svg", strokeCount: 1)
        let shot = MeetingAudio.Screenshot(filename: "slide.jpg", captured: Date(), manual: false)
        let session = MeetingWindow.Session(drawings: [drawing], screenshots: [shot], videoFilename: "video.mp4")

        let decoded = try JSONDecoder().decode(MeetingWindow.Session.self, from: JSONEncoder().encode(session))

        XCTAssertEqual(decoded.drawings, [drawing])
        XCTAssertEqual(decoded.screenshots, [shot])
        XCTAssertEqual(decoded.videoFilename, "video.mp4")
    }

    @MainActor
    func testCaptureBuffersProducePlayableAudioForBothSources() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = directory.appendingPathComponent("sample.aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", fixture.path, "The launch code for the test is forty two."]
        try say.run()
        say.waitUntilExit()
        XCTAssertEqual(say.terminationStatus, 0)

        let asset = AVURLAsset(url: fixture)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: try XCTUnwrap(tracks.first), outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())

        let first = try XCTUnwrap(output.copyNextSampleBuffer())
        let writers = try MeetingAudio.Source.allCases.map {
            try MeetingAudio.Track(folder: directory, source: $0, firstBuffer: first)
        }
        var buffer: CMSampleBuffer? = first
        while let sample = buffer {
            for writer in writers { try writer.append(sample) }
            buffer = output.copyNextSampleBuffer()
        }
        for writer in writers {
            let clip = try await writer.finish()
            let url = directory.appendingPathComponent(clip.filename)
            let recorded = AVURLAsset(url: url)
            let duration = try await recorded.load(.duration)
            XCTAssertGreaterThan(duration.seconds, 1)
        }
    }
}
