import XCTest
@testable import GooglyShared

final class HuionProtocolTests: XCTestCase {
    func testChallengeResponseMatchesHardwareVerifiedVector() {
        // Real hardware vector confirmed in Reginleif86/huion-note-x10-ble docs/offline-note-protocol.md:
        // challenge (28, 63, 239) -> response (109, 188, 231) = cd 82 08 6d bc e7 00 ed
        let (r1, r2, r3) = HuionProtocol.verifyResponse(a: 28, b: 63, c: 239)
        XCTAssertEqual(r1, 109)
        XCTAssertEqual(r2, 188)
        XCTAssertEqual(r3, 231)

        let frame = HuionProtocol.buildVerifyResult(a: 28, b: 63, c: 239)
        XCTAssertEqual(frame, Data([0xCD, 0x82, 0x08, 0x6D, 0xBC, 0xE7, 0x00, 0xED]))
    }

    func testPinEncodingUsesHuionOffsetsAndRejectsInvalidPins() throws {
        let (f1, f2) = try HuionProtocol.buildVerifyPwdFrames(pin: "123456")
        // '1'=49 + 104=153(0x99), '2'=50 + 117=167(0xA7), '3'=51 + 105=156(0x9C)
        // '4'=52 + 111=163(0xA3), '5'=53 + 110=163(0xA3), '6'=54 + 35=89(0x59)
        XCTAssertEqual(f1, Data([0xCD, 0x83, 0x08, 0x01, 0x99, 0xA7, 0x9C, 0xED]))
        XCTAssertEqual(f2, Data([0xCD, 0x83, 0x08, 0x02, 0xA3, 0xA3, 0x59, 0xED]))

        XCTAssertThrowsError(try HuionProtocol.buildVerifyPwdFrames(pin: "1234"))
        XCTAssertThrowsError(try HuionProtocol.buildVerifyPwdFrames(pin: "12345a"))
    }

    func testParseMaxDataAndCounts() {
        // Real X10 packet: cd 95 0b 28 6e 00 18 92 00 ff 1f -> MAX_X=28200, MAX_Y=37400, MAX_PRESS=8191
        let maxPkt = Data([0xCD, 0x95, 0x0B, 0x28, 0x6E, 0x00, 0x18, 0x92, 0x00, 0xFF, 0x1F])
        let limits = HuionProtocol.parseMaxData(maxPkt)
        XCTAssertEqual(limits.maxX, 28200, accuracy: 0.01)
        XCTAssertEqual(limits.maxY, 37400, accuracy: 0.01)
        XCTAssertEqual(limits.maxPress, 8191, accuracy: 0.01)

        XCTAssertEqual(HuionProtocol.parseOfflineCount(Data([0xCD, 0x86, 0x05, 0x95, 0x02])), 661)
        XCTAssertEqual(HuionProtocol.parseCurrentPageCount(Data([0xCD, 0x85, 0x05, 0x0B, 0x00])), 11)
    }

    func testOfflinePacketDecodingBuildsStrokesAndValidSVG() {
        // Construct one 0x87 packet with 4 points: 2 pen-down, 1 pen-up, 2 pen-down (via second packet)
        func pointBytes(x: Int, y: Int, press: Int, status: UInt8) -> [UInt8] {
            let pLo = UInt8(press & 0xFF)
            let pHi = UInt8((press >> 8) & 0x1F) | ((status & 0x07) << 5)
            return [UInt8(x & 0xFF), UInt8((x >> 8) & 0xFF), UInt8(y & 0xFF), UInt8((y >> 8) & 0xFF), pLo, pHi]
        }

        var pkt1: [UInt8] = [0xCD, 0x87, 0x24, 0x01, 0x00]
        pkt1 += pointBytes(x: 1410, y: 1870, press: 4000, status: 1)
        pkt1 += pointBytes(x: 5640, y: 7480, press: 6000, status: 1)
        pkt1 += pointBytes(x: 5640, y: 7480, press: 0, status: 0) // pen up
        pkt1 += pointBytes(x: 14100, y: 18700, press: 3000, status: 1)
        pkt1 += pointBytes(x: 19740, y: 22440, press: 5000, status: 1)
        pkt1 += [0xAB] // trailing checksum byte (must be ignored)

        let drawing = HuionProtocol.decodeOfflinePage(packets: [Data(pkt1)], limits: .defaultOffline)
        XCTAssertEqual(drawing.strokes.count, 2)
        XCTAssertEqual(drawing.strokes[0].points.count, 2)
        XCTAssertEqual(drawing.strokes[1].points.count, 2)
        XCTAssertEqual(drawing.strokes[0].points[0].x, 1410.0 / 28200.0, accuracy: 0.001)
        XCTAssertEqual(drawing.strokes[0].points[0].y, 1870.0 / 37400.0, accuracy: 0.001)

        let svg = drawing.toSVG(width: 846)
        XCTAssertTrue(svg.contains("<svg"))
        XCTAssertTrue(svg.contains("<line"))
        XCTAssertTrue(svg.contains("</svg>"))
    }

    func testUSBHIDReport10AndBLELivePenParsing() {
        // USB Report ID 10: flags=0x41 (inRange + tip), X=16384 (~0.5), Y=8192 (~0.25), P=4096 (~0.5)
        let usbTouch = Data([0x0A, 0x41, 0x00, 0x40, 0x00, 0x20, 0x00, 0x10, 0x0A, 0xF6])
        let landscape = HuionProtocol.parseUSBHIDReport10(usbTouch, orientation: .landscape)
        XCTAssertNotNil(landscape)
        XCTAssertEqual(landscape?.touching, true)
        XCTAssertEqual(landscape?.hovering, true)
        XCTAssertEqual(landscape!.x, 16384.0 / 32767.0, accuracy: 0.002)
        XCTAssertEqual(landscape!.y, 8192.0 / 32767.0, accuracy: 0.002)
        XCTAssertEqual(landscape!.pressure, 4096.0 / 8191.0, accuracy: 0.002)

        // Portrait mapping rotates landscape (nx, ny) -> (ny, 1 - nx)
        let portrait = HuionProtocol.parseUSBHIDReport10(usbTouch, orientation: .portrait)
        XCTAssertEqual(portrait!.x, 8192.0 / 32767.0, accuracy: 0.002)
        XCTAssertEqual(portrait!.y, 1.0 - (16384.0 / 32767.0), accuracy: 0.002)

        // Out-of-range clears hover & touch
        let outOfRange = Data([0x0A, 0x00, 0x00, 0x40, 0x00, 0x20, 0x00, 0x00, 0x00, 0x00])
        let o = HuionProtocol.parseUSBHIDReport10(outOfRange, orientation: .landscape)
        XCTAssertEqual(o?.hovering, false)
        XCTAssertEqual(o?.touching, false)

        // BLE live pen report (55 54 81 ...): touching at center
        let bleTouch = Data([0x55, 0x54, 0x81, 0x0C, 0x49, 0x14, 0x37, 0xFF, 0x0F, 0x00, 0x00, 0x00, 0x00, 0x00])
        let bleSample = HuionProtocol.parseBLEPenReport(bleTouch, limits: .defaultLiveTablet, orientation: .landscape)
        XCTAssertEqual(bleSample?.touching, true)
        XCTAssertEqual(bleSample!.x, 0x490C / 37400.0, accuracy: 0.002)
        XCTAssertEqual(bleSample!.y, 0x3714 / 28200.0, accuracy: 0.002)
    }

    func testNoteItemWithDrawingRoundTripsAndKeepsBackwardsCompatibility() throws {
        let stroke = InkStroke(color: "#141820", width: 0.003, points: [
            InkPoint(x: 0.1, y: 0.2, p: 0.5),
            InkPoint(x: 0.4, y: 0.6, p: 0.8),
        ])
        let note = NoteItem(title: "Skizze", body: "Notiz", drawing: InkDrawing(strokes: [stroke]), hubNoteID: "abc123def456", source: "huion-offline")
        let encoded = try XCTUnwrap(WorkspaceCoding.string(note))
        let decoded = try XCTUnwrap(WorkspaceCoding.decode(NoteItem.self, encoded))
        XCTAssertEqual(decoded.drawing?.strokes.count, 1)
        XCTAssertEqual(decoded.hubNoteID, "abc123def456")
        XCTAssertEqual(decoded.source, "huion-offline")
        XCTAssertTrue(decoded.hasDrawing)

        // Old JSON without drawing/hubNoteID/source still decodes cleanly.
        let legacy = #"{"id":"\#(UUID().uuidString)","title":"Alt","body":"Text","pinned":false,"updatedAt":"2026-11-24T08:00:00.000Z"}"#
        let legacyNote = try XCTUnwrap(WorkspaceCoding.decode(NoteItem.self, legacy))
        XCTAssertNil(legacyNote.drawing)
        XCTAssertFalse(legacyNote.hasDrawing)
    }

    func testPhysicalButtonAndBLENoteOnlinePenParsing() {
        // BLE Note Mode NEXT_PAGE (0x8A)
        XCTAssertEqual(HuionProtocol.parseButtonEvent(Data([0xCD, 0x8A, 0x04, 0x01])), .nextPage)

        // BLE Pen Tablet Mode ExpressKey press & release (55 54 E0 ...)
        XCTAssertEqual(HuionProtocol.parseButtonEvent(Data([0x55, 0x54, 0xE0, 0x01, 0x01, 0x00, 0x00, 0x00])), .pressed)
        XCTAssertEqual(HuionProtocol.parseButtonEvent(Data([0x55, 0x54, 0xE0, 0x00, 0x00, 0x00, 0x00, 0x00])), .released)

        // USB HID Vendor Report ID 8 ExpressKey press & release (08 E0 ...)
        XCTAssertEqual(HuionProtocol.parseButtonEvent(Data([0x08, 0xE0, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])), .pressed)
        XCTAssertEqual(HuionProtocol.parseButtonEvent(Data([0x08, 0xE0, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])), .released)

        // Regular pen packet is NOT a button event
        XCTAssertNil(HuionProtocol.parseButtonEvent(Data([0x0A, 0x41, 0x00, 0x40, 0x00, 0x20, 0x00, 0x10, 0x00, 0x00])))

        // BLE Note-Taking Mode live pen packet: cd 8d 0b SS XX XX YY YY PP PP CC
        let onlinePkt = Data([0xCD, 0x8D, 0x0B, 0x02, 0x14, 0x37, 0x0C, 0x49, 0x00, 0x20, 0x00])
        let sample = HuionProtocol.parseBLENoteOnlinePen(onlinePkt, limits: .defaultOffline)
        XCTAssertEqual(sample?.touching, true)
        XCTAssertEqual(sample!.x, Double(0x3714) / 28200.0, accuracy: 0.002)
        XCTAssertEqual(sample!.y, Double(0x490C) / 37400.0, accuracy: 0.002)
    }

    func testVideoTimecodeFormattingAndSVGMetadata() throws {
        XCTAssertEqual(InkDrawing.formatVideoTime(0), "00:00")
        XCTAssertEqual(InkDrawing.formatVideoTime(252.8), "04:12")
        XCTAssertEqual(InkDrawing.formatVideoTime(3852), "1:04:12")
        XCTAssertEqual(InkDrawing.formatFileTime(252.8), "04m12s")
        XCTAssertEqual(InkDrawing.formatFileTime(3852), "1h04m12s")

        let s1 = InkStroke(color: "#141820", width: 0.003,
                           points: [InkPoint(x: 0.1, y: 0.1, p: 0.5), InkPoint(x: 0.3, y: 0.2, p: 0.6)],
                           createdAt: Date(timeIntervalSince1970: 1_800_000_100),
                           recordingOffsetSeconds: 100.5)
        let s2 = InkStroke(color: "#2563EB", width: 0.003,
                           points: [InkPoint(x: 0.4, y: 0.5, p: 0.7), InkPoint(x: 0.6, y: 0.7, p: 0.8)],
                           createdAt: Date(timeIntervalSince1970: 1_800_000_252),
                           recordingOffsetSeconds: 252.0)
        let drawing = InkDrawing(strokes: [s1, s2])
        let range = try XCTUnwrap(drawing.videoTimeRange)
        XCTAssertEqual(range.start, 100.5, accuracy: 0.01)
        XCTAssertEqual(range.end, 252.0, accuracy: 0.01)

        let svg = drawing.toSVG(width: 800)
        XCTAssertTrue(svg.contains(#"data-timecode="01:40""#))
        XCTAssertTrue(svg.contains(#"data-timecode="04:12""#))

        // Round-trip JSON preserves recordingOffsetSeconds
        let json = try XCTUnwrap(WorkspaceCoding.string(drawing))
        let back = try XCTUnwrap(WorkspaceCoding.decode(InkDrawing.self, json))
        XCTAssertEqual(back.strokes[0].recordingOffsetSeconds ?? -1, 100.5, accuracy: 0.01)
        XCTAssertEqual(back.strokes[1].recordingOffsetSeconds ?? -1, 252.0, accuracy: 0.01)
    }
}
