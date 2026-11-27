import XCTest
import GooglyShared
@testable import GooglyMac

final class ServiceProvidersTests: XCTestCase {
    func testAudioSilenceDetectorDistinguishesSilenceFromSpeech() {
        // Pure silence WAV
        let silentPCM = Data(count: 24000 * 2) // 1s of zeros
        let silentWAV = VoiceAudioCodec.wav(pcm16: silentPCM, sampleRate: 24000, channels: 1)
        let silentLevels = AudioSilenceDetector.analyze(data: silentWAV, fileExtension: "wav")
        XCTAssertNotNil(silentLevels)
        XCTAssertTrue(silentLevels?.isSilent == true)

        // Loud 440Hz tone WAV
        var tonePCM = Data(capacity: 24000 * 2)
        for i in 0..<24000 {
            let sample = Int16(sin(Double(i) * 2 * .pi * 440.0 / 24000.0) * 12000.0)
            var le = sample.littleEndian
            tonePCM.append(Data(bytes: &le, count: 2))
        }
        let toneWAV = VoiceAudioCodec.wav(pcm16: tonePCM, sampleRate: 24000, channels: 1)
        let toneLevels = AudioSilenceDetector.analyze(data: toneWAV, fileExtension: "wav")
        XCTAssertNotNil(toneLevels)
        XCTAssertFalse(toneLevels?.isSilent == true)
    }

    @MainActor
    func testBlueyToolDirectiveExtraction() {
        let raw = """
        BLUEY_TOOL:{"tool":"focus_start","args":{"task":"Präsentation schreiben","minutes":45}}
        Los geht's! 45 Minuten Fokus auf deine Präsentation.
        """
        let extracted = RealtimeHost.extractBlueyToolDirective(from: raw)
        XCTAssertEqual(extracted.tool?.name, "focus_start")
        XCTAssertTrue(extracted.tool?.argumentsJSON.contains("Präsentation schreiben") == true)
        XCTAssertEqual(extracted.reply, "Los geht's! 45 Minuten Fokus auf deine Präsentation.")

        let plain = RealtimeHost.extractBlueyToolDirective(from: "Alles klar, ich bin bereit!")
        XCTAssertNil(plain.tool)
        XCTAssertEqual(plain.reply, "Alles klar, ich bin bereit!")
    }

    func testFocusAPIJSONDecisionParsing() throws {
        let json = """
        Here is the verdict:
        {"activity":"off_task","probability":0.91,"confidence":0.87,"visible_activity":"social_feed"}
        """
        let decision = try FocusAPI.parseJSONDecision(json)
        XCTAssertEqual(decision.activity, .offTask)
        XCTAssertEqual(decision.probability, 0.91, accuracy: 0.001)
        XCTAssertEqual(decision.confidence, 0.87, accuracy: 0.001)
        XCTAssertEqual(decision.distraction, .socialFeed)
    }

    func testZeroOpenAIDefaultsWhenUnset() {
        let keys = ["voiceProvider", "ttsProvider", "transcriptionProvider", "transcriptionSilenceFilter",
                    "meetingChunkSeconds", "llmProvider", "focusProvider", "focusSkipUnchanged"]
        let saved = Dictionary(uniqueKeysWithValues: keys.map { ($0, UserDefaults.standard.object(forKey: $0)) })
        defer {
            for (k, v) in saved {
                if let v { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) }
            }
        }
        for k in keys { UserDefaults.standard.removeObject(forKey: k) }

        let s = Settings.shared
        XCTAssertEqual(s.voiceProvider, .localHermes)
        XCTAssertEqual(s.ttsProvider, .apple)
        XCTAssertEqual(s.transcriptionProvider, .appleLocal)
        XCTAssertTrue(s.transcriptionSilenceFilter)
        XCTAssertEqual(s.meetingChunkSeconds, 30)
        XCTAssertEqual(s.llmProvider, .hermes)
        XCTAssertEqual(s.focusProvider, .followLLM)
        XCTAssertTrue(s.focusSkipUnchanged)
    }
}
