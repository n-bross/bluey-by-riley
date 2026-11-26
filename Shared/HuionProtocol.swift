import Foundation

/// Pure Swift implementation of the Huion Note X10 BLE & USB-HID protocols.
///
/// Protocol framing, local challenge-response auth, and offline stroke decoding follow
/// the MIT-licensed reverse-engineered specification from Reginleif86/huion-note-x10-ble.
public enum HuionProtocol {
    // MARK: - Hardware Identifiers

    public static let usbVendorID: Int = 0x256C   // 9580 ("HUION")
    public static let usbProductID: Int = 0x006D  // 109  ("Huion Tablet_X10")

    /// BLE GATT UUIDs for Huion Note X10 (Service FFE0, Data notify FFE1, Command write/indicate FFE2).
    public enum BLE {
        public static let serviceUUID = "FFE0"
        public static let fullServiceUUID = "0000FFE0-0000-1000-8000-00805F9B34FB"
        public static let dataCharUUID = "FFE1"
        public static let fullDataCharUUID = "0000FFE1-0000-1000-8000-00805F9B34FB"
        public static let commandCharUUID = "FFE2"
        public static let fullCommandCharUUID = "0000FFE2-0000-1000-8000-00805F9B34FB"
    }

    public static let frameStart: UInt8 = 0xCD
    public static let frameEnd: UInt8 = 0xED

    /// Opcodes from Huion's Note protocol (`OrderCode`).
    public enum OrderCode {
        public static let heartBeat: UInt8 = 0x80
        public static let verifyConnect: UInt8 = 0x81
        public static let verifyResult: UInt8 = 0x82
        public static let verifyPwd: UInt8 = 0x83
        public static let mode: UInt8 = 0x84
        public static let currentPage: UInt8 = 0x85
        public static let requestOfflineData: UInt8 = 0x86
        public static let returnOfflineData: UInt8 = 0x87
        public static let getPagePackage: UInt8 = 0x88
        public static let nextPage: UInt8 = 0x8A
        public static let deletePage: UInt8 = 0x8B
        public static let clearCache: UInt8 = 0x8C
        public static let onlineData: UInt8 = 0x8D
        public static let electricity: UInt8 = 0x8E
        public static let rom: UInt8 = 0x8F
        public static let deviceName: UInt8 = 0x91
        public static let getPwd: UInt8 = 0x93
        public static let maxData: UInt8 = 0x95
        public static let setManyPacketDistance: UInt8 = 0x96

        // Pen Tablet Mode commands (live BLE drawing mode)
        public static let tabletInfo: UInt8 = 0xC8
        public static let version: UInt8 = 0xC9
        public static let tabletVerify: UInt8 = 0xCA
        public static let tabletBattery: UInt8 = 0xD1
    }

    // MARK: - Orientation

    public enum Orientation: String, Codable, CaseIterable, Sendable {
        case portrait          // A5 notebook upright (short edge X, long edge Y)
        case landscape         // Long edge X, short edge Y
        case portraitInverted  // 180° rotated portrait
        case landscapeInverted // 180° rotated landscape

        public var title: String {
            switch self {
            case .portrait: return "Hochformat"
            case .landscape: return "Querformat"
            case .portraitInverted: return "Hochformat (180°)"
            case .landscapeInverted: return "Querformat (180°)"
            }
        }
    }

    // MARK: - Frames

    public struct Frame: Equatable, Sendable {
        public let op: UInt8
        public let length: UInt8
        public let payload: Data
        public let raw: Data
    }

    public static func parseFrame(_ data: Data) -> Frame? {
        guard data.count >= 3, data[data.startIndex] == frameStart else { return nil }
        let bytes = Array(data)
        return Frame(op: bytes[1], length: bytes[2], payload: Data(bytes.dropFirst(3)), raw: data)
    }

    /// Standard 8-byte Note-mode command: `cd <op> 08 <a> <b> <c> <d> ed`.
    public static func buildCommand(_ op: UInt8, _ a: UInt8 = 0, _ b: UInt8 = 0, _ c: UInt8 = 0, _ d: UInt8 = 0) -> Data {
        Data([frameStart, op, 0x08, a, b, c, d, frameEnd])
    }

    /// Pen Tablet Mode command: `cd <cmd> 00 00 00 00 00 00`.
    public static func buildTabletCommand(_ cmd: UInt8) -> Data {
        Data([frameStart, cmd, 0, 0, 0, 0, 0, 0])
    }

    public static func heartBeat() -> Data { buildCommand(OrderCode.heartBeat) }
    public static func requestVerifyConnect() -> Data { buildCommand(OrderCode.verifyConnect) }
    public static func requestCurrentPage() -> Data { buildCommand(OrderCode.currentPage) }
    public static func requestMaxInfo() -> Data { buildCommand(OrderCode.maxData) }
    public static func requestElectricity() -> Data { buildCommand(OrderCode.electricity) }
    public static func requestOnlineMode(enabled: Bool) -> Data {
        buildCommand(OrderCode.onlineData, enabled ? 0x01 : 0x00, 0, 0, 0)
    }

    public static func requestSetManyPacketDistance() -> (Data, Data) {
        (
            buildCommand(OrderCode.setManyPacketDistance, 1, 3, 0, 0),
            buildCommand(OrderCode.setManyPacketDistance, 3, 2, 0, 0)
        )
    }

    public static func requestPageData(page: Int, sub: UInt8 = 0) -> Data {
        buildCommand(OrderCode.requestOfflineData, UInt8(page & 0xFF), UInt8((page >> 8) & 0xFF), sub, 0)
    }

    public static func buildGetPagePackage(page: Int, index: Int) -> Data {
        Data([
            frameStart, OrderCode.getPagePackage, 0x08,
            UInt8(page & 0xFF), UInt8((page >> 8) & 0xFF),
            UInt8(index & 0xFF), UInt8((index >> 8) & 0xFF),
            frameEnd,
        ])
    }

    /// Destructive: call only after a page has been saved locally.
    public static func buildDeletePage(page: Int) -> Data {
        Data([
            frameStart, OrderCode.deletePage, 0x08,
            UInt8(page & 0xFF), UInt8((page >> 8) & 0xFF),
            0x00, 0x00, frameEnd,
        ])
    }

    /// Destructive: clears offline cache after pages have been deleted.
    public static func buildClearCache() -> Data {
        buildCommand(OrderCode.clearCache)
    }

    /// Parses `cd 86 05 <count_lo> <count_hi>` -> packet count (u16 LE).
    public static func parseOfflineCount(_ data: Data) -> Int? {
        let b = Array(data)
        guard b.count >= 5, b[0] == frameStart, b[1] == OrderCode.requestOfflineData, b[2] == 0x05 else { return nil }
        return Int(b[3]) | (Int(b[4]) << 8)
    }

    /// Parses `cd 85 05 <count_lo> <count_hi>` -> logic-page count (u16 LE).
    public static func parseCurrentPageCount(_ data: Data) -> Int? {
        let b = Array(data)
        guard b.count >= 5, b[0] == frameStart, b[1] == OrderCode.currentPage else { return nil }
        return Int(b[3]) | (Int(b[4]) << 8)
    }

    // MARK: - Local Keyless Auth

    private static let pinOffsets: [UInt8] = [104, 117, 105, 111, 110, 35] // "huion#"

    public static func verifyResponse(a: UInt8, b: UInt8, c: UInt8) -> (UInt8, UInt8, UInt8) {
        let ia = Int(a), ib = Int(b), ic = Int(c)
        let r1 = UInt8(((ia + ib) << 2) % 255)
        let r2 = UInt8(((ib + ic) << 2) % 255)
        let r3 = UInt8(((ic + 10) << 2) % 255)
        return (r1, r2, r3)
    }

    public static func buildVerifyResult(a: UInt8, b: UInt8, c: UInt8) -> Data {
        let (r1, r2, r3) = verifyResponse(a: a, b: b, c: c)
        return buildCommand(OrderCode.verifyResult, r1, r2, r3, 0)
    }

    public enum AuthError: LocalizedError, Equatable {
        case invalidPIN
        public var errorDescription: String? { "Die Geräte-PIN muss genau 6 Ziffern haben." }
    }

    public static func encodePIN(_ pin: String) throws -> [UInt8] {
        let scalars = Array(pin.unicodeScalars)
        guard scalars.count == 6, scalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }) else {
            throw AuthError.invalidPIN
        }
        return zip(scalars, pinOffsets).map { UInt8((Int($0.value) + Int($1)) & 0xFF) }
    }

    public static func buildVerifyPwdFrames(pin: String) throws -> (Data, Data) {
        let e = try encodePIN(pin)
        return (
            buildCommand(OrderCode.verifyPwd, 0x01, e[0], e[1], e[2]),
            buildCommand(OrderCode.verifyPwd, 0x02, e[3], e[4], e[5])
        )
    }

    // MARK: - Limits & Offline Stroke Decoding

    public struct Limits: Equatable, Sendable {
        public var maxX: Double
        public var maxY: Double
        public var maxPress: Double

        public static let defaultOffline = Limits(maxX: 28200, maxY: 37400, maxPress: 8191)
        public static let defaultLiveTablet = Limits(maxX: 37400, maxY: 28200, maxPress: 8191)

        public init(maxX: Double, maxY: Double, maxPress: Double) {
            self.maxX = maxX > 0 ? maxX : 28200
            self.maxY = maxY > 0 ? maxY : 37400
            self.maxPress = maxPress > 0 ? maxPress : 8191
        }
    }

    public struct RawPoint: Equatable, Sendable {
        public let x: Int
        public let y: Int
        public let pressure: Int
        public let penDown: Bool
    }

    /// Parses `cd 95 0b <x0 x1 x2> <y0 y1 y2> <p0 p1>` -> Limits.
    public static func parseMaxData(_ data: Data) -> Limits {
        let b = Array(data)
        guard b.count >= 11, b[1] == OrderCode.maxData else { return .defaultOffline }
        let maxX = Double(Int(b[3]) | (Int(b[4]) << 8) | (Int(b[5]) << 16))
        let maxY = Double(Int(b[6]) | (Int(b[7]) << 8) | (Int(b[8]) << 16))
        let maxP = Double(Int(b[9]) | (Int(b[10]) << 8))
        return Limits(maxX: maxX, maxY: maxY, maxPress: maxP)
    }

    /// Parses Pen Tablet Mode device info payload from cmd `0xC8`.
    public static func parseTabletDeviceInfo(_ payload: Data) -> Limits {
        let b = Array(payload)
        guard b.count >= 8 else { return .defaultLiveTablet }
        let maxX = Double(Int(b[0]) | (Int(b[1]) << 8) | (Int(b[2]) << 16))
        let maxY = Double(Int(b[3]) | (Int(b[4]) << 8) | (Int(b[5]) << 16))
        let maxP = Double(Int(b[6]) | (Int(b[7]) << 8))
        return Limits(maxX: maxX, maxY: maxY, maxPress: maxP)
    }

    /// Sequence / index number at bytes [3..4] (u16 LE) of `0x87` or `0x88` packets.
    public static func packetSeq(_ data: Data) -> Int {
        let b = Array(data)
        guard b.count >= 5 else { return 0 }
        return Int(b[3]) | (Int(b[4]) << 8)
    }

    /// Decodes one 6-byte `BluePoint` record.
    public static func decodeOfflinePoint(_ bytes: ArraySlice<UInt8>) -> RawPoint {
        let i = bytes.startIndex
        let x = Int(bytes[i]) | (Int(bytes[i + 1]) << 8)
        let y = Int(bytes[i + 2]) | (Int(bytes[i + 3]) << 8)
        let press = Int(bytes[i + 4]) | ((Int(bytes[i + 5]) & 0x1F) << 8)
        let status = bytes[i + 5] >> 5
        return RawPoint(x: x, y: y, pressure: press, penDown: status != 0)
    }

    /// Decodes all 6-byte points within one `0x87` or `0x88` packet (per-packet, trailing checksum dropped).
    public static func decodeOfflinePacket(_ data: Data) -> [RawPoint] {
        let b = Array(data)
        guard b.count >= 11 else { return [] }
        let count = (b.count - 5) / 6
        var out: [RawPoint] = []
        out.reserveCapacity(count)
        for k in 0..<count {
            let start = 5 + k * 6
            out.append(decodeOfflinePoint(b[start..<(start + 6)]))
        }
        return out
    }

    /// Converts raw offline points into an `InkDrawing` with smooth pressure-preserving strokes.
    public static func decodeOfflinePage(packets: [Data],
                                         limits: Limits = .defaultOffline,
                                         color: String = "#141820",
                                         paper: InkPaperStyle = .paper) -> InkDrawing {
        var allPoints: [RawPoint] = []
        for pkt in packets {
            allPoints.append(contentsOf: decodeOfflinePacket(pkt))
        }
        return pointsToInkDrawing(allPoints, limits: limits, color: color, paper: paper)
    }

    public static func pointsToInkDrawing(_ points: [RawPoint],
                                          limits: Limits = .defaultOffline,
                                          color: String = "#141820",
                                          paper: InkPaperStyle = .paper) -> InkDrawing {
        var strokes: [InkStroke] = []
        var current: [InkPoint] = []

        func flush() {
            if current.count > 1 {
                let stroke = InkStroke(color: color, width: 0.0032, tool: .pen, points: current).simplified(minDistance: 0.001)
                strokes.append(stroke)
            }
            current.removeAll(keepingCapacity: true)
        }

        for p in points {
            if !p.penDown || p.pressure <= 0 {
                flush()
            } else {
                let nx = Double(p.x) / limits.maxX
                let ny = Double(p.y) / limits.maxY
                let np = Double(p.pressure) / limits.maxPress
                current.append(InkPoint(x: nx, y: ny, p: np))
            }
        }
        flush()

        let ratio = limits.maxX / limits.maxY
        return InkDrawing(aspectRatio: ratio, paper: paper, strokes: strokes)
    }

    // MARK: - Live Pen Samples (BLE & USB HID)

    public struct PenSample: Equatable, Sendable {
        /// Normalized coordinates (0...1, top-left origin) after orientation mapping.
        public var x: Double
        public var y: Double
        /// Normalized pressure (0...1).
        public var pressure: Double
        public var touching: Bool
        public var hovering: Bool
        public var barrelButton: Bool
        public var eraser: Bool
        public var tiltX: Double
        public var tiltY: Double

        public init(x: Double, y: Double, pressure: Double, touching: Bool, hovering: Bool,
                    barrelButton: Bool = false, eraser: Bool = false, tiltX: Double = 0, tiltY: Double = 0) {
            self.x = min(max(x, 0), 1)
            self.y = min(max(y, 0), 1)
            self.pressure = min(max(pressure, 0), 1)
            self.touching = touching
            self.hovering = hovering
            self.barrelButton = barrelButton
            self.eraser = eraser
            self.tiltX = tiltX
            self.tiltY = tiltY
        }
    }

    /// Maps a native landscape tablet ratio `(nx, ny)` to the chosen orientation.
    /// Huion X10 hardware raw frame in Pen Tablet / USB mode is landscape (long edge X, short edge Y).
    public static func mapLandscapeRatio(nx: Double, ny: Double, orientation: Orientation) -> (Double, Double) {
        switch orientation {
        case .landscape:
            return (nx, ny)
        case .landscapeInverted:
            return (1.0 - nx, 1.0 - ny)
        case .portrait:
            // Clockwise 270° rotation matches holding the X10 notebook upright with spine on left.
            return (ny, 1.0 - nx)
        case .portraitInverted:
            return (1.0 - ny, nx)
        }
    }

    /// Parses 14-byte BLE Pen Tablet Mode notifications (`55 54 <status> ...`).
    public static func parseBLEPenReport(_ data: Data,
                                         limits: Limits = .defaultLiveTablet,
                                         orientation: Orientation = .portrait) -> PenSample? {
        let b = Array(data)
        guard b.count >= 13, b[0] == 0x55, b[1] == 0x54 else { return nil }
        let status = b[2]
        guard status == 0x00 || status == 0x80 || status == 0x81 else { return nil }
        if status == 0x00 {
            return PenSample(x: 0, y: 0, pressure: 0, touching: false, hovering: false)
        }
        let rawX = Int(b[3]) | (Int(b[4]) << 8) | (Int(b[9]) << 16)
        let rawY = Int(b[5]) | (Int(b[6]) << 8) | (Int(b[10]) << 16)
        let rawPress = Int(b[7]) | (Int(b[8]) << 8)
        let tiltX = Double(Int8(bitPattern: b[11])) / 127.0
        let tiltY = Double(Int8(bitPattern: b[12])) / 127.0

        let touching = (status & 0x01) != 0 && rawPress > 0
        let (mx, my) = mapLandscapeRatio(nx: Double(rawX) / limits.maxX,
                                         ny: Double(rawY) / limits.maxY,
                                         orientation: orientation)
        return PenSample(
            x: mx,
            y: my,
            pressure: touching ? Double(rawPress) / limits.maxPress : 0,
            touching: touching,
            hovering: true,
            tiltX: tiltX,
            tiltY: tiltY
        )
    }

    /// Parses standard USB HID Digitizer Pen Report ID 10 from Huion Tablet_X10 (10 bytes):
    /// `[0]=0x0A, [1]=flags (bit0=tip, bit1=barrel, bit2=eraser, bit3=invert, bit6=inRange),
    ///  [2..3]=X (0..32767 LE), [4..5]=Y (0..32767 LE), [6..7]=Pressure (0..8191 LE), [8]=tiltX, [9]=tiltY`.
    public static func parseUSBHIDReport10(_ data: Data,
                                           orientation: Orientation = .portrait) -> PenSample? {
        let b = Array(data)
        guard b.count >= 10, b[0] == 0x0A else { return nil }
        let flags = b[1]
        let tip = (flags & 0x01) != 0
        let barrel = (flags & 0x02) != 0
        let eraser = (flags & 0x04) != 0 || (flags & 0x08) != 0
        let inRange = (flags & 0x40) != 0
        if !inRange {
            return PenSample(x: 0, y: 0, pressure: 0, touching: false, hovering: false)
        }
        let rawX = Int(b[2]) | (Int(b[3]) << 8)
        let rawY = Int(b[4]) | (Int(b[5]) << 8)
        let rawPress = Int(b[6]) | (Int(b[7]) << 8)
        let tiltX = Double(Int8(bitPattern: b[8])) / 127.0
        let tiltY = Double(Int8(bitPattern: b[9])) / 127.0

        let (mx, my) = mapLandscapeRatio(nx: Double(rawX) / 32767.0,
                                         ny: Double(rawY) / 32767.0,
                                         orientation: orientation)
        let touching = tip && rawPress > 0
        return PenSample(
            x: mx,
            y: my,
            pressure: touching ? Double(rawPress) / 8191.0 : 0,
            touching: touching,
            hovering: inRange,
            barrelButton: barrel,
            eraser: eraser,
            tiltX: tiltX,
            tiltY: tiltY
        )
    }

    // MARK: - Hardware Button & BLE Note-Mode Live Pen

    public enum ButtonEvent: Equatable, Sendable {
        /// One-shot "New Page" notice from firmware (e.g. BLE `NEXT_PAGE 0x8A`).
        case nextPage
        /// Hardware ExpressKey / cover button pressed down.
        case pressed
        /// Hardware button released.
        case released
    }

    /// Recognizes hardware button / "New Page" packets across BLE Note Mode (`0x8A`),
    /// BLE Pen Tablet Mode (`55 54 E0/E2/E3`), and USB HID Vendor Report ID 8 (`08 E0/E2/E3/A0`).
    public static func parseButtonEvent(_ data: Data) -> ButtonEvent? {
        let b = Array(data)
        guard b.count >= 3 else { return nil }

        // 1. BLE Note Mode: NEXT_PAGE (cd 8a ...)
        if b[0] == frameStart && b[1] == OrderCode.nextPage {
            return .nextPage
        }

        // 2. BLE Pen Tablet Mode button frames: 55 54 <0xE0|0xE2|0xE3|0xA0> <payload...>
        if b[0] == 0x55 && b[1] == 0x54 && (b[2] == 0xE0 || b[2] == 0xE2 || b[2] == 0xE3 || b[2] == 0xA0) {
            let end = min(b.count, 8)
            let anyDown = b.count > 3 && b[3..<end].contains(where: { $0 != 0 })
            return anyDown ? .pressed : .released
        }

        // 3. USB HID Vendor Report ID 8 button frames: 08 <0xE0|0xE2|0xE3|0xA0> ...
        if b[0] == 0x08 && (b[1] == 0xE0 || b[1] == 0xE2 || b[1] == 0xE3 || b[1] == 0xA0) {
            let start = min(4, b.count)
            let end = min(8, b.count)
            let anyDown = start < end && b[start..<end].contains(where: { $0 != 0 })
            // Some firmware variants place a key code at byte 2 or 3 when bytes 4..7 are zero.
            let altDown = !anyDown && b.count >= 4 && (b[2] != 0 || b[3] != 0) && b[1] != 0xE0
            return (anyDown || altDown) ? .pressed : .released
        }

        return nil
    }

    /// Parses 11-byte BLE Note-Taking Mode live pen packets (`cd 8d 0b SS XX XX YY YY PP PP CC`).
    public static func parseBLENoteOnlinePen(_ data: Data,
                                             limits: Limits = .defaultOffline) -> PenSample? {
        let b = Array(data)
        guard b.count >= 10, b[0] == frameStart, b[1] == OrderCode.onlineData, b[2] == 0x0B else { return nil }
        let status = b[3]
        if status == 0 {
            return PenSample(x: 0, y: 0, pressure: 0, touching: false, hovering: false)
        }
        let rawX = Int(b[4]) | (Int(b[5]) << 8)
        let rawY = Int(b[6]) | (Int(b[7]) << 8)
        let rawPress = Int(b[8]) | (Int(b[9]) << 8)
        // Note-mode online pressure is reported in 14-bit (0..16383) or 13-bit (0..8191).
        let pressMax = rawPress > Int(limits.maxPress) ? 16383.0 : limits.maxPress
        let touching = rawPress > 0
        return PenSample(
            x: Double(rawX) / limits.maxX,
            y: Double(rawY) / limits.maxY,
            pressure: touching ? Double(rawPress) / pressMax : 0,
            touching: touching,
            hovering: true
        )
    }

    /// Parses 12-byte USB HID Vendor Report ID 8 pen reports (`08 <status> xLo xHi yLo yHi pLo pHi xHi2 yHi2 tiltX tiltY`).
    public static func parseUSBHIDReport8Pen(_ data: Data,
                                             limits: Limits = .defaultLiveTablet,
                                             orientation: Orientation = .portrait) -> PenSample? {
        let b = Array(data)
        guard b.count >= 10, b[0] == 0x08 else { return nil }
        let status = b[1]
        // 0x80 = hover, 0x81 = tip touch, 0x82/0x84 = barrel buttons, 0x00 = pen leave.
        if status == 0x00 {
            return PenSample(x: 0, y: 0, pressure: 0, touching: false, hovering: false)
        }
        guard (status & 0xC0) == 0x80 else { return nil }
        let xHi = b.count > 8 ? Int(b[8]) << 16 : 0
        let yHi = b.count > 9 ? Int(b[9]) << 16 : 0
        let rawX = Int(b[2]) | (Int(b[3]) << 8) | xHi
        let rawY = Int(b[4]) | (Int(b[5]) << 8) | yHi
        let rawPress = Int(b[6]) | (Int(b[7]) << 8)
        let tiltX = b.count > 10 ? Double(Int8(bitPattern: b[10])) / 127.0 : 0
        let tiltY = b.count > 11 ? Double(Int8(bitPattern: b[11])) / 127.0 : 0
        let touching = (status & 0x01) != 0 && rawPress > 0
        let (mx, my) = mapLandscapeRatio(nx: Double(rawX) / limits.maxX,
                                         ny: Double(rawY) / limits.maxY,
                                         orientation: orientation)
        return PenSample(
            x: mx,
            y: my,
            pressure: touching ? Double(rawPress) / limits.maxPress : 0,
            touching: touching,
            hovering: true,
            barrelButton: (status & 0x02) != 0,
            eraser: (status & 0x04) != 0,
            tiltX: tiltX,
            tiltY: tiltY
        )
    }
}
