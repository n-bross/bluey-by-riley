import Foundation
import CoreBluetooth
import IOKit
import IOKit.hid
import GooglyShared

/// Connects to a Huion Note X10 over USB-HID (instant live pen input) and Bluetooth Low Energy
/// (offline page sync + wireless live pen + battery), without the Huion app or cloud.
@MainActor
final class HuionBridge: NSObject, ObservableObject {
    enum BLEState: Equatable {
        case idle
        case unavailable(String)
        case scanning
        case connecting(String)
        case connected(String)
        case syncing(String)
        case error(String)

        var label: String {
            switch self {
            case .idle: return "BLE bereit"
            case .unavailable(let s): return s
            case .scanning: return "Suche Huion Note…"
            case .connecting(let n): return "Verbinde \(n)…"
            case .connected(let n): return n
            case .syncing(let s): return s
            case .error(let s): return s
            }
        }

        var isConnected: Bool {
            switch self {
            case .connected, .syncing: return true
            default: return false
            }
        }
    }

    @Published private(set) var usbConnected = false
    @Published private(set) var usbDeviceName: String?
    @Published private(set) var bleState: BLEState = .idle
    @Published private(set) var batteryPercent: Int?
    @Published private(set) var liveSample: HuionProtocol.PenSample?
    @Published private(set) var syncSummary: String?
    @Published var pinRequired = false
    @Published var isSyncingOffline = false

    @Published var orientation: HuionProtocol.Orientation {
        didSet { UserDefaults.standard.set(orientation.rawValue, forKey: "huion.orientation") }
    }
    /// Safe default: keep pages on the notebook until the user opts in to auto-clearing after export.
    @Published var deleteAfterOfflineSync: Bool {
        didSet { UserDefaults.standard.set(deleteAfterOfflineSync, forKey: "huion.deleteAfterSync") }
    }

    /// Active route when the screen annotation overlay is open (takes priority over note canvas).
    var screenAnnotatorActive = false
    var onScreenPenSample: ((HuionProtocol.PenSample) -> Void)?
    var onNotePenSample: ((HuionProtocol.PenSample) -> Void)?
    /// Fired when the physical "New Page" / notebook button is pressed (BLE `0x8A`, BLE `E0/E2/E3`, or USB Report 8).
    var onNewPageRequested: (() -> Void)?
    /// Called for each non-empty page pulled from the notebook's offline memory.
    /// Return true once safely persisted locally (gates optional device-side delete).
    var onOfflinePageImported: ((Int, InkDrawing) async -> Bool)?

    var isAnyDeviceConnected: Bool { usbConnected || bleState.isConnected }

    var statusHeadline: String {
        var parts: [String] = []
        if usbConnected { parts.append("USB") }
        if bleState.isConnected {
            if let bat = batteryPercent { parts.append("BLE \(bat)%") }
            else { parts.append("BLE") }
        }
        return parts.isEmpty ? "Kein Huion verbunden" : "Huion (\(parts.joined(separator: " + ")))"
    }

    // MARK: - Private USB HID state

    private var hidManager: IOHIDManager?
    private var reportBuffers: [UnsafeMutableRawPointer] = []
    private var connectedUSBDevices = 0
    private var hardwareButtonDown = false
    private var lastNewPageAt = Date.distantPast
    private var noteLimits = HuionProtocol.Limits.defaultOffline

    // MARK: - Private BLE state

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var dataChar: CBCharacteristic?
    private var cmdChar: CBCharacteristic?
    private var bleLimits = HuionProtocol.Limits.defaultLiveTablet
    private var keepaliveTask: Task<Void, Never>?
    private var pendingBLEAction: (() -> Void)?
    private var notifyQueue: [Data] = []
    private var notifyWaiters: [CheckedContinuation<Data, Error>] = []
    private var bleDisconnectedError: Error?
    private var writeWaiter: CheckedContinuation<Void, Error>?
    private var bleReadyWaiter: CheckedContinuation<Void, Error>?

    private static let lastPeripheralKey = "huion.lastBLEPeripheralUUID"
    private let serviceCBUUID = CBUUID(string: HuionProtocol.BLE.serviceUUID)
    private let dataCBUUID = CBUUID(string: HuionProtocol.BLE.dataCharUUID)
    private let cmdCBUUID = CBUUID(string: HuionProtocol.BLE.commandCharUUID)

    override init() {
        let savedOrient = UserDefaults.standard.string(forKey: "huion.orientation").flatMap(HuionProtocol.Orientation.init(rawValue:))
        self.orientation = savedOrient ?? .portrait
        self.deleteAfterOfflineSync = UserDefaults.standard.bool(forKey: "huion.deleteAfterSync")
        super.init()
    }

    func start() {
        startUSBHID()
    }

    func stop() {
        stopUSBHID()
        disconnectBLE()
    }

    // MARK: - USB HID (Live Pen Input on Mac)

    private func startUSBHID() {
        guard hidManager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // Match ALL HID interfaces of Huion Tablet_X10 (both Digitizer Pen 13:2 and Vendor 0xFF00 for buttons).
        let match: [String: Any] = [
            kIOHIDVendorIDKey as String: HuionProtocol.usbVendorID,
            kIOHIDProductIDKey as String: HuionProtocol.usbProductID,
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()

        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            let bridge = Unmanaged<HuionBridge>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in bridge.handleUSBConnected(device) }
        }, ctx)

        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            let bridge = Unmanaged<HuionBridge>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in bridge.handleUSBRemoved(device) }
        }, ctx)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let ret = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if ret == kIOReturnSuccess {
            self.hidManager = manager
            if let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !set.isEmpty {
                for dev in set { handleUSBConnected(dev) }
            }
        }
    }

    private func stopUSBHID() {
        if let manager = hidManager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            hidManager = nil
        }
        for ptr in reportBuffers { ptr.deallocate() }
        reportBuffers.removeAll()
        connectedUSBDevices = 0
        usbConnected = false
        usbDeviceName = nil
    }

    private func handleUSBConnected(_ device: IOHIDDevice) {
        let name = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "Huion Tablet_X10"
        connectedUSBDevices += 1
        usbConnected = true
        usbDeviceName = name

        let reportSize = 64
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: reportSize, alignment: 1)
        reportBuffers.append(buffer)
        let ctx = Unmanaged.passUnretained(self).toOpaque()

        IOHIDDeviceRegisterInputReportCallback(
            device,
            buffer.assumingMemoryBound(to: UInt8.self),
            reportSize,
            { context, _, _, _, reportID, report, reportLength in
                guard let context, reportLength > 0 else { return }
                var data = Data(bytes: report, count: reportLength)
                // Normalize leading report ID byte when macOS omits it.
                if reportID != 0, data.first != UInt8(reportID & 0xFF) {
                    data.insert(UInt8(reportID & 0xFF), at: 0)
                }
                let bridge = Unmanaged<HuionBridge>.fromOpaque(context).takeUnretainedValue()
                Task { @MainActor in bridge.handleUSBReport(data) }
            },
            ctx
        )
    }

    private func handleUSBRemoved(_ device: IOHIDDevice) {
        connectedUSBDevices = max(0, connectedUSBDevices - 1)
        if connectedUSBDevices == 0 {
            usbConnected = false
            usbDeviceName = nil
            liveSample = nil
            hardwareButtonDown = false
        }
    }

    private func handleUSBReport(_ data: Data) {
        if let btn = HuionProtocol.parseButtonEvent(data) {
            handleButtonEvent(btn)
            return
        }
        // Screen annotation naturally maps the tablet in landscape to match a monitor;
        // notes use the user's chosen notebook orientation (portrait by default).
        let effectiveOrient: HuionProtocol.Orientation = screenAnnotatorActive ? .landscape : orientation
        if let sample = HuionProtocol.parseUSBHIDReport10(data, orientation: effectiveOrient) {
            dispatchLiveSample(sample)
            return
        }
        if let sample = HuionProtocol.parseUSBHIDReport8Pen(data, limits: bleLimits, orientation: effectiveOrient) {
            dispatchLiveSample(sample)
            return
        }
        logNonPenPacket("USB", data)
    }

    private func handleButtonEvent(_ event: HuionProtocol.ButtonEvent) {
        switch event {
        case .nextPage:
            triggerNewPageDebounced()
        case .pressed:
            if !hardwareButtonDown {
                hardwareButtonDown = true
                triggerNewPageDebounced()
            }
        case .released:
            hardwareButtonDown = false
        }
    }

    private func triggerNewPageDebounced() {
        let now = Date()
        guard now.timeIntervalSince(lastNewPageAt) >= 0.35 else { return }
        lastNewPageAt = now
        onNewPageRequested?()
    }

    private func logNonPenPacket(_ transport: String, _ data: Data) {
        let hex = data.map { String(format: "%02x", $0) }.joined(separator: " ")
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Googly/huion-debug.log")
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(transport) (\(data.count)B): \(hex)\n"
        if let fh = try? FileHandle(forWritingTo: url) {
            _ = try? fh.seekToEnd()
            try? fh.write(contentsOf: Data(line.utf8))
            try? fh.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func dispatchLiveSample(_ sample: HuionProtocol.PenSample) {
        liveSample = sample.hovering ? sample : nil
        if screenAnnotatorActive {
            onScreenPenSample?(sample)
        } else {
            onNotePenSample?(sample)
        }
    }

    // MARK: - Bluetooth LE (Offline Sync & Wireless Live Pen)

    private func ensureCentral() {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: nil)
        }
    }

    func connectBLE() {
        ensureCentral()
        guard let central else { return }
        bleDisconnectedError = nil
        if central.state == .poweredOn {
            startBLEScanOrReconnect(central)
        } else {
            bleState = .scanning
            pendingBLEAction = { [weak self] in
                guard let self, let c = self.central else { return }
                self.startBLEScanOrReconnect(c)
            }
        }
    }

    func disconnectBLE() {
        keepaliveTask?.cancel()
        keepaliveTask = nil
        if let central, let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        dataChar = nil
        cmdChar = nil
        bleState = .idle
        batteryPercent = nil
        failAllWaiters(BLEError.disconnected)
    }

    private func startBLEScanOrReconnect(_ central: CBCentralManager) {
        // 1. Check already-connected peripherals exposing FFE0.
        let alreadyConnected = central.retrieveConnectedPeripherals(withServices: [serviceCBUUID])
        if let p = alreadyConnected.first {
            connectPeripheral(p, via: central)
            return
        }
        // 2. Try remembered UUID if available.
        if let saved = UserDefaults.standard.string(forKey: Self.lastPeripheralKey),
           let uuid = UUID(uuidString: saved),
           let p = central.retrievePeripherals(withIdentifiers: [uuid]).first {
            connectPeripheral(p, via: central)
            return
        }
        // 3. Scan for FFE0 or Huion advertisements.
        bleState = .scanning
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self, case .scanning = self.bleState else { return }
            self.central?.stopScan()
            self.bleState = .error("Kein Huion Note-X10 per Bluetooth gefunden (aufgeklappt & USB abgesteckt?).")
            self.failReadyWaiter(BLEError.notFound)
        }
    }

    private func connectPeripheral(_ p: CBPeripheral, via central: CBCentralManager) {
        central.stopScan()
        peripheral = p
        p.delegate = self
        bleState = .connecting(p.name ?? "Huion Note-X10")
        central.connect(p, options: nil)
    }

    /// Enables wireless live pen + physical "New Page" button (`0x8A`) over BLE.
    /// Sends both Note-mode online enable (`0x8D`) and Pen Tablet Mode handshake (`0xC9/0xC8/0xCA`)
    /// so live drawing works regardless of which mode the X10 is currently in.
    func startBLELivePen() {
        Task {
            do {
                try await ensureBLEConnected()
                // Note-taking mode live pen + button events (0x8D + 0x8A)
                try await writeCmd(HuionProtocol.requestMaxInfo())
                let (d1, d2) = HuionProtocol.requestSetManyPacketDistance()
                try await writeCmd(d1)
                try await writeCmd(d2)
                try await writeCmd(HuionProtocol.requestOnlineMode(enabled: true))
                // Pen Tablet Mode handshake (for tablets switched to wireless tablet mode)
                try await writeCmd(HuionProtocol.buildTabletCommand(HuionProtocol.OrderCode.version))
                try await writeCmd(HuionProtocol.buildTabletCommand(HuionProtocol.OrderCode.tabletInfo))
                try await writeCmd(HuionProtocol.buildTabletCommand(HuionProtocol.OrderCode.tabletVerify))
                startKeepalive(tabletMode: false)
                syncSummary = "BLE Live-Stift & Seiten-Knopf aktiv"
            } catch {
                bleState = .error(error.localizedDescription)
            }
        }
    }

    /// Pulls all stored offline handwritten pages from the Huion Note X10 over BLE,
    /// without using the Huion app or cloud.
    func syncOfflinePages(pin: String? = nil) {
        guard !isSyncingOffline else { return }
        isSyncingOffline = true
        pinRequired = false
        syncSummary = nil

        Task {
            defer { isSyncingOffline = false }
            do {
                bleState = .syncing("Verbinde Huion Note…")
                try await ensureBLEConnected()
                keepaliveTask?.cancel()
                notifyQueue.removeAll()
                startKeepalive(tabletMode: false)

                // 1. Challenge-response auth (protocol §6)
                bleState = .syncing("Authentifiziere…")
                try await writeCmd(HuionProtocol.requestVerifyConnect())
                let challenge = try await recvOp(HuionProtocol.OrderCode.verifyConnect, timeoutSeconds: 8)
                let chBytes = Array(challenge.raw)
                guard chBytes.count >= 6 else { throw BLEError.protocolError("Ungültige Challenge vom Gerät.") }
                try await writeCmd(HuionProtocol.buildVerifyResult(a: chBytes[3], b: chBytes[4], c: chBytes[5]))

                var authResp = try await recvOp(HuionProtocol.OrderCode.verifyResult, timeoutSeconds: 8)
                var authStatus = authResp.raw.count > 3 ? authResp.raw[3] : 0
                if authStatus == 2 {
                    guard let pin, !pin.isEmpty else {
                        pinRequired = true
                        bleState = .connected(peripheral?.name ?? "Huion Note-X10")
                        syncSummary = "Geräte-PIN (6 Ziffern) erforderlich."
                        return
                    }
                    let (f1, f2) = try HuionProtocol.buildVerifyPwdFrames(pin: pin)
                    try await writeCmd(f1)
                    try await writeCmd(f2)
                    authResp = try await recvOp(HuionProtocol.OrderCode.verifyResult, timeoutSeconds: 8)
                    authStatus = authResp.raw.count > 3 ? authResp.raw[3] : 0
                }
                guard authStatus == 1 else { throw BLEError.protocolError("Auth abgelehnt (Status \(authStatus)).") }

                // 2. Device limits, battery & packet pacing
                try await writeCmd(HuionProtocol.requestMaxInfo())
                let limits: HuionProtocol.Limits
                if let maxFrame = try? await recvOp(HuionProtocol.OrderCode.maxData, timeoutSeconds: 3) {
                    limits = HuionProtocol.parseMaxData(maxFrame.raw)
                } else {
                    limits = .defaultOffline
                }

                try await writeCmd(HuionProtocol.requestElectricity())
                if let batFrame = try? await recvOp(HuionProtocol.OrderCode.electricity, timeoutSeconds: 2), batFrame.raw.count >= 4 {
                    batteryPercent = Int(batFrame.raw[3])
                }

                let (d1, d2) = HuionProtocol.requestSetManyPacketDistance()
                try await writeCmd(d1)
                try await writeCmd(d2)

                // 3. Query logic-page count (robust against empty page 0 firmware quirk)
                try await writeCmd(HuionProtocol.requestCurrentPage())
                let logicCount: Int
                if let pageFrame = try? await recvOp(HuionProtocol.OrderCode.currentPage, timeoutSeconds: 3),
                   let c = HuionProtocol.parseCurrentPageCount(pageFrame.raw) {
                    logicCount = c
                } else {
                    logicCount = 0
                }
                let upperBound = min(max(logicCount, 8), 64)

                var imported = 0
                var deletedPages = 0
                var consecutiveEmptyAfterCount = 0

                for page in 0...upperBound {
                    bleState = .syncing("Prüfe Seite \(page + 1)…")
                    try await writeCmd(HuionProtocol.requestPageData(page: page, sub: 0))
                    let countFrame = try await recvOp(HuionProtocol.OrderCode.requestOfflineData, timeoutSeconds: 8)
                    let expected = HuionProtocol.parseOfflineCount(countFrame.raw) ?? 0

                    if expected == 0 {
                        if page > logicCount {
                            consecutiveEmptyAfterCount += 1
                            if consecutiveEmptyAfterCount >= 2 { break }
                        }
                        continue
                    }
                    consecutiveEmptyAfterCount = 0

                    // Collect 0x87 stream packets
                    var packets: [Int: Data] = [:]
                    packets.reserveCapacity(expected)

                    while packets.count < expected {
                        guard let raw = try? await recvNext(timeoutSeconds: 4.5) else { break }
                        guard let fr = HuionProtocol.parseFrame(raw), fr.op == HuionProtocol.OrderCode.returnOfflineData else { continue }
                        let seq = HuionProtocol.packetSeq(raw)
                        if seq >= 1 && seq <= expected {
                            packets[seq] = raw
                            if packets.count % 25 == 0 || seq == expected {
                                let pct = Int(Double(packets.count) / Double(expected) * 100)
                                bleState = .syncing("Seite \(page + 1): \(pct)% (\(packets.count)/\(expected))")
                            }
                            if seq == expected { break }
                        }
                    }

                    // Gap-fill missing packets via 0x88 (up to 5 rounds)
                    for _ in 0..<5 {
                        let missing = (1...expected).filter { packets[$0] == nil }
                        if missing.isEmpty { break }
                        bleState = .syncing("Seite \(page + 1): hole \(missing.count) fehlende Pakete…")
                        for idx in missing {
                            try await writeCmd(HuionProtocol.buildGetPagePackage(page: page, index: idx))
                        }
                        let roundEnd = Date().addingTimeInterval(4.5)
                        while Date() < roundEnd && packets.count < expected {
                            let remaining = max(0.2, roundEnd.timeIntervalSinceNow)
                            guard let raw = try? await recvNext(timeoutSeconds: remaining) else { break }
                            guard let fr = HuionProtocol.parseFrame(raw),
                                  fr.op == HuionProtocol.OrderCode.getPagePackage,
                                  raw.count >= 6, raw[2] == 0x7E else { continue }
                            let idx = HuionProtocol.packetSeq(raw)
                            if idx >= 1 && idx <= expected {
                                packets[idx] = raw
                            }
                        }
                    }

                    let ordered = packets.keys.sorted().compactMap { packets[$0] }
                    let drawing = HuionProtocol.decodeOfflinePage(packets: ordered, limits: limits)
                    if !drawing.isEmpty {
                        let saved = await onOfflinePageImported?(page, drawing) ?? true
                        if saved {
                            imported += 1
                            if deleteAfterOfflineSync && packets.count == expected {
                                try await writeCmd(HuionProtocol.buildDeletePage(page: page))
                                if let delResp = try? await recvOp(HuionProtocol.OrderCode.deletePage, timeoutSeconds: 4),
                                   delResp.raw.count > 3, delResp.raw[3] == 1 {
                                    deletedPages += 1
                                }
                            }
                        }
                    }
                }

                if deleteAfterOfflineSync && deletedPages > 0 {
                    try? await writeCmd(HuionProtocol.buildClearCache())
                    _ = try? await recvOp(HuionProtocol.OrderCode.clearCache, timeoutSeconds: 3)
                }

                bleState = .connected(peripheral?.name ?? "Huion Note-X10")
                if imported == 0 {
                    syncSummary = "Keine gespeicherten Offline-Seiten auf dem Gerät."
                } else if deletedPages > 0 {
                    syncSummary = "\(imported) Seite\(imported == 1 ? "" : "n") importiert (\(deletedPages) vom Gerät gelöscht)."
                } else {
                    syncSummary = "\(imported) Seite\(imported == 1 ? "" : "n") importiert."
                }
            } catch {
                bleState = .error(error.localizedDescription)
                syncSummary = error.localizedDescription
            }
        }
    }

    // MARK: - BLE Async Helpers

    enum BLEError: LocalizedError {
        case notFound, disconnected, timeout, missingCharacteristics, protocolError(String)
        var errorDescription: String? {
            switch self {
            case .notFound: return "Kein Huion Note-X10 gefunden. Ist es aufgeklappt und per Bluetooth erreichbar?"
            case .disconnected: return "Bluetooth-Verbindung zum Huion Note wurde getrennt."
            case .timeout: return "Zeitüberschreitung bei der Antwort vom Huion Note."
            case .missingCharacteristics: return "Huion GATT-Service (FFE0/FFE1/FFE2) nicht gefunden."
            case .protocolError(let s): return s
            }
        }
    }

    private func ensureBLEConnected() async throws {
        if let peripheral, peripheral.state == .connected, dataChar != nil, cmdChar != nil {
            return
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            bleReadyWaiter = cont
            connectBLE()
        }
    }

    private func startKeepalive(tabletMode: Bool) {
        keepaliveTask?.cancel()
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, self.peripheral?.state == .connected else { break }
                let pkt = tabletMode
                    ? HuionProtocol.buildTabletCommand(HuionProtocol.OrderCode.tabletBattery)
                    : HuionProtocol.heartBeat()
                try? await self.writeCmd(pkt)
            }
        }
    }

    private func writeCmd(_ data: Data) async throws {
        guard let peripheral, let cmdChar, peripheral.state == .connected else { throw BLEError.disconnected }
        let writeType: CBCharacteristicWriteType = cmdChar.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        if writeType == .withoutResponse {
            peripheral.writeValue(data, for: cmdChar, type: .withoutResponse)
            try? await Task.sleep(for: .milliseconds(15))
        } else {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                writeWaiter = cont
                peripheral.writeValue(data, for: cmdChar, type: .withResponse)
            }
        }
    }

    private func recvNext(timeoutSeconds: Double) async throws -> Data {
        if !notifyQueue.isEmpty {
            return notifyQueue.removeFirst()
        }
        if let err = bleDisconnectedError { throw err }
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { @MainActor in
                try await withCheckedThrowingContinuation { cont in
                    self.notifyWaiters.append(cont)
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                throw BLEError.timeout
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    private func recvOp(_ op: UInt8, timeoutSeconds: Double) async throws -> HuionProtocol.Frame {
        let deadline = Date().addingTimeInterval(timeoutSeconds * 2.5)
        while Date() < deadline {
            let remaining = max(0.2, min(timeoutSeconds, deadline.timeIntervalSinceNow))
            let raw = try await recvNext(timeoutSeconds: remaining)
            if let fr = HuionProtocol.parseFrame(raw), fr.op == op {
                return fr
            }
        }
        throw BLEError.timeout
    }

    private func enqueueNotification(_ data: Data) {
        if !notifyWaiters.isEmpty {
            let waiter = notifyWaiters.removeFirst()
            waiter.resume(returning: data)
        } else {
            notifyQueue.append(data)
            if notifyQueue.count > 4096 { notifyQueue.removeFirst(notifyQueue.count - 4096) }
        }
    }

    private func failReadyWaiter(_ error: Error) {
        if let w = bleReadyWaiter {
            bleReadyWaiter = nil
            w.resume(throwing: error)
        }
    }

    private func failAllWaiters(_ error: Error) {
        bleDisconnectedError = error
        failReadyWaiter(error)
        if let w = writeWaiter {
            writeWaiter = nil
            w.resume(throwing: error)
        }
        let waiters = notifyWaiters
        notifyWaiters.removeAll()
        for w in waiters { w.resume(throwing: error) }
    }
}

// MARK: - CoreBluetooth Delegates

extension HuionBridge: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                if let action = self.pendingBLEAction {
                    self.pendingBLEAction = nil
                    action()
                }
            case .unauthorized:
                self.bleState = .unavailable("Bluetooth-Berechtigung in Systemeinstellungen erlauben.")
                self.failReadyWaiter(BLEError.protocolError("Bluetooth nicht erlaubt."))
            case .poweredOff:
                self.bleState = .unavailable("Bluetooth ist ausgeschaltet.")
                self.failReadyWaiter(BLEError.protocolError("Bluetooth ist aus."))
            default:
                break
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let isHuion = name.localizedCaseInsensitiveContains("huion")
            || name.localizedCaseInsensitiveContains("x10")
            || services.contains(CBUUID(string: HuionProtocol.BLE.serviceUUID))
        guard isHuion else { return }
        Task { @MainActor in
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.lastPeripheralKey)
            self.connectPeripheral(peripheral, via: central)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.bleDisconnectedError = nil
            peripheral.discoverServices([self.serviceCBUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            let err = error ?? BLEError.disconnected
            self.bleState = .error("Verbindung fehlgeschlagen: \(err.localizedDescription)")
            self.failAllWaiters(err)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            self.keepaliveTask?.cancel()
            self.keepaliveTask = nil
            self.dataChar = nil
            self.cmdChar = nil
            self.bleState = .idle
            self.failAllWaiters(error ?? BLEError.disconnected)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == self.serviceCBUUID }) else {
                self.bleState = .error("Huion GATT-Service FFE0 nicht gefunden.")
                self.failReadyWaiter(BLEError.missingCharacteristics)
                return
            }
            peripheral.discoverCharacteristics([self.dataCBUUID, self.cmdCBUUID], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            guard error == nil, let chars = service.characteristics else {
                self.failReadyWaiter(error ?? BLEError.missingCharacteristics)
                return
            }
            self.dataChar = chars.first { $0.uuid == self.dataCBUUID }
            self.cmdChar = chars.first { $0.uuid == self.cmdCBUUID }
            guard let dataChar = self.dataChar, let cmdChar = self.cmdChar else {
                self.failReadyWaiter(BLEError.missingCharacteristics)
                return
            }
            peripheral.setNotifyValue(true, for: dataChar)
            peripheral.setNotifyValue(true, for: cmdChar)
            self.bleState = .connected(peripheral.name ?? "Huion Note-X10")
            if let waiter = self.bleReadyWaiter {
                self.bleReadyWaiter = nil
                waiter.resume()
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            if let w = self.writeWaiter {
                self.writeWaiter = nil
                if let error { w.resume(throwing: error) } else { w.resume() }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value, !data.isEmpty else { return }
        Task { @MainActor in
            // 1. Hardware "New Page" / ExpressKey button events (BLE 0x8A or 55 54 E0/E2/E3)
            if let btn = HuionProtocol.parseButtonEvent(data) {
                self.handleButtonEvent(btn)
                return
            }
            // 2. Live BLE Pen Tablet packets (55 54 ...)
            let effectiveOrient: HuionProtocol.Orientation = self.screenAnnotatorActive ? .landscape : self.orientation
            if let sample = HuionProtocol.parseBLEPenReport(data, limits: self.bleLimits, orientation: effectiveOrient) {
                self.dispatchLiveSample(sample)
                return
            }
            // 3. Live BLE Note-Taking Mode packets (cd 8d 0b ...)
            if let sample = HuionProtocol.parseBLENoteOnlinePen(data, limits: self.noteLimits) {
                self.dispatchLiveSample(sample)
                return
            }
            // 4. Note-Mode MAX_DATA response (cd 95 ...)
            if let fr = HuionProtocol.parseFrame(data), fr.op == HuionProtocol.OrderCode.maxData {
                self.noteLimits = HuionProtocol.parseMaxData(data)
            }
            // 5. Pen Tablet Mode info response (cmd 0xC8)
            if data.count >= 10, Int(data[0]) == data.count, data[1] == HuionProtocol.OrderCode.tabletInfo {
                self.bleLimits = HuionProtocol.parseTabletDeviceInfo(data.dropFirst(2))
            }
            // 6. Pen Tablet Mode battery response (cmd 0xD1)
            if data.count >= 3, Int(data[0]) == data.count, data[1] == HuionProtocol.OrderCode.tabletBattery {
                self.batteryPercent = Int(data[2])
            }
            // 7. Queue Note-protocol frames (0xCD ...) for offline sync engine
            self.enqueueNotification(data)
        }
    }
}
