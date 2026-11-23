import AVFoundation
import XCTest
@testable import GooglyMac

@available(macOS 15, *)
final class MeetingAudioTests: XCTestCase {
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
