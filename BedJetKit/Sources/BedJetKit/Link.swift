import Foundation

/// A connection to one BedJet. `BLELink` talks to real hardware; `DemoLink` simulates a unit.
@MainActor
public protocol BedJetLink: AnyObject {
    var state: LinkState { get }
    var onStateChange: ((LinkState) -> Void)? { get set }
    var onStatus: ((DeviceStatus) -> Void)? { get set }

    func start()
    func stop()
    /// Asks for the BedJet on the person's behalf. It accepts one phone at a time, so this also asks
    /// another phone that is holding it to hand it over.
    func requestControl()
    /// Writes a command and waits for the unit to acknowledge it.
    func send(_ command: Data) async throws
    /// Asks the unit for stored data and returns the reply payload.
    func query(_ request: UInt8) async throws -> Data
}

extension BedJetLink {
    public func requestControl() {}

    public func setMode(_ mode: Mode) async throws {
        guard let command = Codec.setMode(mode) else { return }
        try await send(command)
    }

    public func syncClock(to date: Date = Date()) async throws {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        try await send(Codec.setClock(hour: parts.hour ?? 0, minute: parts.minute ?? 0))
    }

    public func deviceName() async throws -> String {
        Codec.parseText(try await query(Codec.Query.deviceName))
    }

    public func firmwareVersion() async throws -> String {
        Codec.parseText(try await query(Codec.Query.firmware))
    }

    /// Everything saved on the unit, one entry per slot; `nil` where the slot is empty.
    public func storedPrograms() async throws -> [StoredProgram?] {
        let names = Codec.parseNames(try await query(Codec.Query.programNames))
        var programs: [StoredProgram?] = []
        for slot in 0..<Limits.slots {
            guard slot < names.count, let name = names[slot] else {
                programs.append(nil)
                continue
            }
            let steps = try await programSteps(slot: slot)
            programs.append(steps.isEmpty ? nil : StoredProgram(name: name, steps: steps))
        }
        return programs
    }

    public func programSteps(slot: Int) async throws -> [ProgramStep] {
        var steps: [ProgramStep] = []
        var index = 0
        while true {
            let payload = try await query(Codec.Query.fragment(slot: slot, index: index))
            guard let fragment = Codec.parseFragment(payload, index: index) else { throw BedJetError.badResponse }
            steps += fragment.steps
            index += 1
            if steps.count >= fragment.total || fragment.steps.isEmpty { return steps }
        }
    }

    /// Saves a program into a slot, replacing whatever was there, and confirms the unit kept it.
    public func store(_ program: StoredProgram, slot: Int) async throws {
        guard !program.steps.isEmpty else { throw BedJetError.invalidProgram("Add at least one phase first.") }
        guard program.steps.count <= Limits.stepsPerProgram else {
            throw BedJetError.invalidProgram("A BedJet schedule can hold up to \(Limits.stepsPerProgram) phases.")
        }
        guard program.steps.allSatisfy(\.fitsUnitLimits) else { throw BedJetError.programTooLong }
        for command in Codec.writeProgram(slot: slot, steps: program.steps) {
            try await send(command)
        }
        try await send(Codec.nameProgram(slot: slot, name: program.name))
        guard try await programSteps(slot: slot) == program.steps else { throw BedJetError.verifyFailed }
    }

    public func startProgram(slot: Int) async throws {
        try await syncClock()
        try await send(Codec.startProgram(slot: slot))
    }
}
