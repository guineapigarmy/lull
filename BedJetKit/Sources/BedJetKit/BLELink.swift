@preconcurrency import CoreBluetooth
import CryptoKit
import Foundation

/// CoreBluetooth transport for a BedJet 3. Connects to the remembered unit, or the first one found.
///
/// The BedJet accepts a single connection and stops advertising while it has one, so a second phone
/// cannot even see it. Two phones share it by handing over: the phone that wants the BedJet briefly
/// advertises a request, and the phone holding it disconnects when it sees that request.
@MainActor
public final class BLELink: NSObject, BedJetLink {
    public private(set) var state: LinkState = .searching {
        didSet {
            guard state != oldValue else { return }
            if state == .ready { stopRequesting() }
            onStateChange?(state)
        }
    }
    public var onStateChange: ((LinkState) -> Void)?
    public var onStatus: ((DeviceStatus) -> Void)?
    /// Return false to postpone a hand-over, for example while a schedule is being saved.
    public var canYield: () -> Bool = { true }
    public private(set) var lastConnection: ConnectionTiming?

    private static func uuid(_ short: String) -> CBUUID { CBUUID(string: "0000\(short)-BED0-0080-AA55-4265644A6574") }
    private static let service = uuid("1000")
    private static let statusUUID = uuid("2000")
    private static let nameUUID = uuid("2001")
    private static let commandUUID = uuid("2004")
    private static let replyUUID = uuid("2006")
    private static let rememberedKey = "BedJetKit.peripheral"
    private static let nameKey = "BedJetKit.deviceName"

    /// How long a phone that handed over stays out of the way before it quietly waits for the BedJet again.
    private static let courtesy: TimeInterval = 10
    /// How long a request is advertised. Shorter than `courtesy`, so one request is answered once.
    private static let requestDuration: TimeInterval = 8

    private var central: CBCentralManager?
    private var requester: CBPeripheralManager?
    private var peripheral: CBPeripheral?
    private var command: CBCharacteristic?
    private var reply: CBCharacteristic?
    private var wantsConnection = false
    private var yieldedUntil = Date.distantPast
    private var requestGeneration = 0
    private var pendingRequest: CBUUID?
    private var askedAt: Date?
    private var linkUpAfter: TimeInterval?
    private var radioOnAfter: TimeInterval = 0
    private var servicesAfter: TimeInterval = 0
    private var foundByScan = false

    private var statusCharacteristic: CBCharacteristic?
    private var lastHead: Data?
    private var lastRemainderRead = Date.distantPast
    private var lastExtra: DeviceStatus.Extra?
    private var tag: UInt8 = 0
    private var queue: Task<Void, Never>?
    private var pendingWrite: CheckedContinuation<Void, Error>?
    private var pendingRead: CheckedContinuation<Data, Error>?
    private var operation = 0

    public func start() {
        requestControl()
    }

    public func stop() {
        wantsConnection = false
        askedAt = nil
        stopRequesting()
        central?.stopScan()
        yieldedUntil = .distantPast
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        if state != .ready {
            // Nothing is connected, so no disconnect will arrive to tidy up.
            peripheral = nil
            state = .searching
        }
    }

    public func requestControl() {
        wantsConnection = true
        if state == .yielded {
            yieldedUntil = .distantPast
            state = .searching
        }
        if state != .ready, askedAt == nil {
            askedAt = Date()
            radioOnAfter = 0
        }
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        } else {
            connectIfPossible()
        }
        guard state != .ready, let request = handoffUUID else { return }
        // Ask straight away rather than waiting to see whether the BedJet answers: if it is free
        // nobody is listening, and if another phone has it every moment of waiting is wasted.
        requestGeneration += 1
        let generation = requestGeneration
        advertise(request)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.requestDuration * 1_000_000_000))
            if let self, self.requestGeneration == generation { self.stopRequesting() }
        }
    }

    /// Forgets the remembered unit so the next `start()` pairs with whichever BedJet is nearest.
    public func forget() {
        UserDefaults.standard.removeObject(forKey: Self.rememberedKey)
        UserDefaults.standard.removeObject(forKey: Self.nameKey)
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
    }

    public func send(_ data: Data) async throws {
        try await serially { try await self.write(data) }
    }

    public func query(_ request: UInt8) async throws -> Data {
        try await serially {
            // The reply characteristic keeps its previous contents until the unit has answered,
            // so retry until the echoed request and tag match.
            for attempt in 0..<4 {
                self.tag = self.tag == 255 ? 1 : self.tag + 1
                try await self.write(Codec.query(request, tag: self.tag))
                if attempt > 0 { try await Task.sleep(nanoseconds: 150_000_000) }
                let data = try await self.read()
                if data.count >= 2, data[data.startIndex] == request, data[data.startIndex + 1] == self.tag {
                    return data.dropFirst(2)
                }
            }
            throw BedJetError.badResponse
        }
    }

    // MARK: Connection

    private func connectIfPossible() {
        guard wantsConnection, let central, central.state == .poweredOn, peripheral == nil else { return }
        if state == .yielded, Date() < yieldedUntil { return }
        if let remembered = UserDefaults.standard.string(forKey: Self.rememberedKey).flatMap(UUID.init),
           let known = central.retrievePeripherals(withIdentifiers: [remembered]).first {
            // Going straight to the unit this phone already knows is several times quicker than scanning for it.
            foundByScan = false
            connect(known)
        } else {
            if state != .yielded { state = .searching }
            foundByScan = true
            central.scanForPeripherals(withServices: [Self.service])
        }
    }

    private func connect(_ target: CBPeripheral) {
        central?.stopScan()
        peripheral = target
        target.delegate = self
        // A phone that handed over keeps saying so while it waits; the connection completes
        // whenever the BedJet becomes free again.
        if state != .yielded { state = .connecting }
        central?.connect(target)
    }

    private func dropConnection() {
        peripheral = nil
        command = nil
        reply = nil
        statusCharacteristic = nil
        lastHead = nil
        lastExtra = nil
        pendingWrite?.resume(throwing: BedJetError.notConnected)
        pendingWrite = nil
        pendingRead?.resume(throwing: BedJetError.notConnected)
        pendingRead = nil
        central?.stopScan()
        if state != .yielded { state = .searching }
        connectIfPossible()
    }

    // MARK: Hand-over between phones

    /// Requests are specific to one BedJet, so a neighbour's phone looking for theirs is ignored.
    private var handoffUUID: CBUUID? {
        UserDefaults.standard.string(forKey: Self.nameKey).map(Self.handoffUUID(forDeviceNamed:))
    }

    static func handoffUUID(forDeviceNamed name: String) -> CBUUID {
        var bytes = Array(SHA256.hash(data: Data("lull.handoff.\(name)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return CBUUID(data: Data(bytes))
    }

    private func advertise(_ request: CBUUID) {
        if requester == nil { requester = CBPeripheralManager(delegate: self, queue: .main) }
        pendingRequest = request
        guard let requester, requester.state == .poweredOn else { return }
        requester.stopAdvertising()
        requester.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [request]])
    }

    private func stopRequesting() {
        requestGeneration += 1
        pendingRequest = nil
        if let requester, requester.state == .poweredOn { requester.stopAdvertising() }
    }

    /// While holding the BedJet, listen for another phone asking for it.
    private func watchForRequests() {
        guard state == .ready, let central, let request = handoffUUID else { return }
        central.stopScan()
        central.scanForPeripherals(withServices: [request])
    }

    private func handOver(attempt: Int = 0) {
        guard state == .ready, let peripheral else { return }
        guard canYield(), pendingWrite == nil, pendingRead == nil else {
            // Finish what is in flight first. If that takes too long, keep the BedJet and listen again.
            guard attempt < 15 else { return watchForRequests() }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 300_000_000)
                self?.handOver(attempt: attempt + 1)
            }
            return
        }
        yieldedUntil = Date().addingTimeInterval(Self.courtesy)
        state = .yielded
        central?.cancelPeripheralConnection(peripheral)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.courtesy * 1_000_000_000))
            self?.connectIfPossible()
        }
    }

    // MARK: Operations

    /// The unit handles one request at a time, so everything goes through a single queue.
    private func serially<T>(_ work: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = queue
        let task = Task { @MainActor () throws -> T in
            await previous?.value
            return try await work()
        }
        queue = Task { _ = try? await task.value }
        return try await task.value
    }

    private func write(_ data: Data) async throws {
        guard state == .ready, let peripheral, let command else { throw BedJetError.notConnected }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pendingWrite = continuation
            peripheral.writeValue(data, for: command, type: .withResponse)
            expire { if let pending = $0.pendingWrite { $0.pendingWrite = nil; pending.resume(throwing: BedJetError.timeout) } }
        }
    }

    private func read() async throws -> Data {
        guard state == .ready, let peripheral, let reply else { throw BedJetError.notConnected }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            pendingRead = continuation
            peripheral.readValue(for: reply)
            expire { if let pending = $0.pendingRead { $0.pendingRead = nil; pending.resume(throwing: BedJetError.timeout) } }
        }
    }

    private func expire(_ fail: @escaping @MainActor (BLELink) -> Void) {
        operation += 1
        let current = operation
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, self.operation == current else { return }
            fail(self)
        }
    }

    /// Notifications carry the live readings. When the link's packet size is too small for the whole
    /// status, the unit flags the notification as partial and serves the remainder (program progress,
    /// LED and beep settings) to a read of the same characteristic.
    private func receiveStatus(_ chunk: Data) {
        guard Codec.isStatusStart(chunk) else {
            if let head = lastHead, let extra = Codec.parseStatus(head + chunk)?.extra { lastExtra = extra }
            return
        }
        guard var status = Codec.parseStatus(chunk) else { return }
        if let extra = status.extra {
            lastExtra = extra
        } else {
            status.extra = lastExtra
            lastHead = chunk
            if let peripheral, let statusCharacteristic, Date().timeIntervalSince(lastRemainderRead) > 2 {
                lastRemainderRead = Date()
                peripheral.readValue(for: statusCharacteristic)
            }
        }
        onStatus?(status)
    }
}

extension BLELink: CBCentralManagerDelegate, CBPeripheralDelegate, CBPeripheralManagerDelegate {
    public nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn:
                radioOnAfter = askedAt.map { Date().timeIntervalSince($0) } ?? 0
                connectIfPossible()
            case .unauthorized: state = .unauthorized
            case .poweredOff, .unsupported: state = .bluetoothOff
            default: break
            }
        }
    }

    public nonisolated func peripheralManagerDidUpdateState(_ manager: CBPeripheralManager) {
        MainActor.assumeIsolated {
            if manager.state == .poweredOn, let request = pendingRequest { advertise(request) }
        }
    }

    public nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                           advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            if state == .ready {
                // The only thing scanned for while connected is another phone asking for this BedJet.
                let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
                if let request = handoffUUID, services.contains(request) { handOver() }
                return
            }
            guard self.peripheral == nil else { return }
            connect(peripheral)
        }
    }

    public nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.rememberedKey)
            linkUpAfter = askedAt.map { Date().timeIntervalSince($0) }
            peripheral.discoverServices([Self.service])
        }
    }

    public nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { dropConnection() }
    }

    public nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { dropConnection() }
    }

    public nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
                central?.cancelPeripheralConnection(peripheral)
                return
            }
            servicesAfter = askedAt.map { Date().timeIntervalSince($0) } ?? 0
            peripheral.discoverCharacteristics([Self.statusUUID, Self.nameUUID, Self.commandUUID, Self.replyUUID], for: service)
        }
    }

    public nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            for characteristic in service.characteristics ?? [] {
                switch characteristic.uuid {
                case Self.statusUUID:
                    statusCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                case Self.nameUUID: peripheral.readValue(for: characteristic)
                case Self.commandUUID: command = characteristic
                case Self.replyUUID: reply = characteristic
                default: break
                }
            }
            guard command != nil, reply != nil else {
                central?.cancelPeripheralConnection(peripheral)
                return
            }
            // Only connections somebody asked for are timed, not quiet reconnects after a hand-over.
            lastConnection = askedAt.flatMap { askedAt in
                linkUpAfter.map {
                    ConnectionTiming(radioOn: radioOnAfter, linkUp: $0, services: servicesAfter,
                                     usable: Date().timeIntervalSince(askedAt), knownUnit: !foundByScan)
                }
            }
            askedAt = nil
            linkUpAfter = nil
            state = .ready
            watchForRequests()
        }
    }

    public nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard let pending = pendingWrite else { return }
            pendingWrite = nil
            if let error { pending.resume(throwing: error) } else { pending.resume() }
        }
    }

    public nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            if characteristic.uuid == Self.statusUUID {
                if let value = characteristic.value { receiveStatus(value) }
            } else if characteristic.uuid == Self.nameUUID {
                // The unit's own name identifies it to the other phone during a hand-over.
                guard let value = characteristic.value, !value.isEmpty else { return }
                UserDefaults.standard.set(Codec.parseText(value), forKey: Self.nameKey)
                watchForRequests()
            } else if characteristic.uuid == Self.replyUUID, let pending = pendingRead {
                pendingRead = nil
                if let value = characteristic.value { pending.resume(returning: value) } else { pending.resume(throwing: error ?? BedJetError.badResponse) }
            }
        }
    }
}
