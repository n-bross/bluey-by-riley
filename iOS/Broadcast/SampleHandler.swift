import ReplayKit
import CoreImage
import UIKit

/// Screen sharing for Bluey calls. Keeps only the latest frame (about one a second, small JPEG)
/// in the shared app group; nothing is recorded or kept after the broadcast ends.
final class SampleHandler: RPBroadcastSampleHandler {
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private var lastFrame = Date.distantPast
    private var heartbeat: Timer?

    private var folder: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "BlueyAppGroup") as? String)
            .flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
    }

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        writeState(active: true)
    }

    override func broadcastFinished() {
        writeState(active: false)
        if let folder { try? FileManager.default.removeItem(at: folder.appendingPathComponent("screen.jpg")) }
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video, Date().timeIntervalSince(lastFrame) >= 0.9,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer), let folder else { return }
        lastFrame = Date()
        var image = CIImage(cvPixelBuffer: pixels)
        if let raw = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber,
           let orientation = CGImagePropertyOrientation(rawValue: raw.uint32Value) {
            image = image.oriented(orientation)
        }
        let longest = max(image.extent.width, image.extent.height)
        let scale = min(1, 1100 / max(longest, 1))
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let jpeg = context.jpegRepresentation(of: image, colorSpace: space,
                                                    options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.6]) else { return }
        try? jpeg.write(to: folder.appendingPathComponent("screen.jpg"), options: .atomic)
        writeState(active: true)
    }

    private func writeState(active: Bool) {
        guard let folder else { return }
        let state: [String: Any] = ["active": active, "updatedAt": Date().timeIntervalSince1970]
        if let data = try? JSONSerialization.data(withJSONObject: state) {
            try? data.write(to: folder.appendingPathComponent("screen-state.json"), options: .atomic)
        }
    }
}
