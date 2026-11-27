import XCTest
@testable import GooglyShared

final class VoiceConfigTests: XCTestCase {
    func testVoiceConfigEnvelopeRoundTripAndLegacyFallback() {
        let cfg = VoiceSessionConfig(
            provider: "geminiLive",
            token: "test-key",
            model: "gemini-2.5-flash-native-audio-preview",
            voice: "Aoede",
            instructions: "Be helpful",
            toolsJSON: "[{\"name\":\"focus_start\"}]",
            ttsMode: "apple",
            language: "de-DE"
        )
        let encoded = cfg.encodeEnvelope()
        XCTAssertNotNil(encoded)
        XCTAssertTrue(encoded?.hasPrefix(VoiceSessionConfig.envelopePrefix) == true)
        XCTAssertEqual(VoiceSessionConfig.decodeEnvelope(encoded!), cfg)

        // Legacy raw OpenAI token still decodes cleanly as openaiRealtime
        let legacy = VoiceSessionConfig.decodeEnvelope("ek_test_legacy_token")
        XCTAssertEqual(legacy.provider, "openaiRealtime")
        XCTAssertEqual(legacy.token, "ek_test_legacy_token")
    }

    func testWAVEncodingAndDownsampling() {
        // 2400 samples @ 24kHz = 100ms mono PCM16
        var pcm = Data(capacity: 2400 * 2)
        for i in 0..<2400 {
            let sample = Int16(sin(Double(i) * 2 * .pi * 440.0 / 24000.0) * 16000.0)
            var le = sample.littleEndian
            pcm.append(Data(bytes: &le, count: 2))
        }
        let wav = VoiceAudioCodec.wav(pcm16: pcm, sampleRate: 24000, channels: 1)
        XCTAssertEqual(wav.count, 44 + pcm.count)
        XCTAssertEqual(String(data: wav[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: wav[8..<12], encoding: .ascii), "WAVE")

        let downsampled = VoiceAudioCodec.downsample24kTo16k(pcm)
        XCTAssertEqual(downsampled.count, 1600 * 2)

        let levels = VoiceAudioCodec.levels(pcm16: pcm)
        XCTAssertGreaterThan(levels.peakDB, -10.0)
        XCTAssertGreaterThan(levels.rmsDB, -15.0)
    }

    func testGeminiFunctionDeclarationConversion() {
        let json = """
        [{"type":"function","name":"focus_start","description":"Start focus","parameters":{"type":"object","properties":{"task":{"type":"string"},"minutes":{"type":"number"}},"required":["task"]}}]
        """
        let decls = VoiceAudioCodec.geminiFunctionDeclarations(from: json)
        XCTAssertEqual(decls.count, 1)
        XCTAssertEqual(decls[0]["name"] as? String, "focus_start")
        let params = decls[0]["parameters"] as? [String: Any]
        XCTAssertEqual(params?["type"] as? String, "OBJECT")
        let props = params?["properties"] as? [String: [String: Any]]
        XCTAssertEqual(props?["task"]?["type"] as? String, "STRING")
        XCTAssertEqual(props?["minutes"]?["type"] as? String, "NUMBER")
    }
}
