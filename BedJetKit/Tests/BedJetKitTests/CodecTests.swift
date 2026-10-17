import XCTest
@testable import BedJetKit

/// Byte fixtures below were captured from a BedJet 3 running firmware V1.20.
final class CodecTests: XCTestCase {
    private func data(_ hex: String) -> Data {
        Data(hex.split(separator: " ").map { UInt8($0, radix: 16)! })
    }

    func testParsesStatusCapturedFromDevice() throws {
        let packet = data("01 56 1b 01 00 00 00 2e 4f 00 13 00 00 14 50 00 00 2d 00 12 01 9a 01 10 10 00 15 35 00 01 53")
        let status = try XCTUnwrap(Codec.parseStatus(packet))
        XCTAssertEqual(status.mode, .standby)
        XCTAssertEqual(status.actualTemperature, 46)
        XCTAssertEqual(status.targetTemperature, 79)
        XCTAssertEqual(status.fanPercent, 100)
        XCTAssertEqual(status.ambientTemperature, 45)
        XCTAssertEqual(status.extra?.programStep, 0)
        XCTAssertEqual(status.extra?.ledEnabled, true)
        XCTAssertEqual(status.extra?.beepsMuted, true)
    }

    func testFirstChunkAloneStillParses() throws {
        let head = data("01 56 1b 01 00 00 00 2e 4f 00 13 00 00 14 50 00 00 2d 00 12")
        XCTAssertTrue(Codec.isStatusStart(head))
        XCTAssertNil(try XCTUnwrap(Codec.parseStatus(head)).extra)
    }

    func testParsesProgramCapturedFromDevice() throws {
        let reply = data("07 08 04 04 09 2c 01 00 04 0d 31 03 00 04 09 2e 01 0f 01 04 2f 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00")
        let fragment = try XCTUnwrap(Codec.parseFragment(reply.dropFirst(2), index: 0))
        XCTAssertEqual(fragment.total, 4)
        XCTAssertEqual(fragment.steps, [
            ProgramStep(mode: .cool, fanStep: 9, temperature: 44, hours: 1, minutes: 0),
            ProgramStep(mode: .cool, fanStep: 13, temperature: 49, hours: 3, minutes: 0),
            ProgramStep(mode: .cool, fanStep: 9, temperature: 46, hours: 1, minutes: 15),
            ProgramStep(mode: .heat, fanStep: 4, temperature: 47, hours: 1, minutes: 0),
        ])
    }

    func testWritingReproducesTheBytesTheDeviceReturned() {
        let reply = data("07 08 04 04 09 2c 01 00 04 0d 31 03 00 04 09 2e 01 0f 01 04 2f 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00")
        let steps = Codec.parseFragment(reply.dropFirst(2), index: 0)!.steps
        let commands = Codec.writeProgram(slot: 0, steps: steps)
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].prefix(2), Data([0x40, 0x07]))
        XCTAssertEqual(commands[0].dropFirst(2), reply.dropFirst(2))
    }

    func testParsesNamesCapturedFromDevice() {
        let reply = data("04 05 63 68 6f 74 65 20 6d 6f 74 65 7a 00 00 00 00 00 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 73 6c 65 65 65 65 70 00 00 00 00 00 00 00 00 00")
        XCTAssertEqual(Codec.parseNames(reply.dropFirst(2)), ["chote motez", nil, "sleeeep"])
    }

    func testLongProgramsSplitIntoFragments() {
        let steps = (0..<19).map { ProgramStep(mode: .cool, fanStep: $0, temperature: 40, hours: 0, minutes: 30) }
        let commands = Codec.writeProgram(slot: 2, steps: steps)
        XCTAssertEqual(commands.map { $0[1] }, [15, 16, 17])
        XCTAssertTrue(commands.allSatisfy { $0.count == 43 && $0[2] == 19 })
        XCTAssertEqual(Codec.parseFragment(commands[2].dropFirst(2), index: 2)?.steps, Array(steps[16...]))
    }

    func testClockTimeFlagSharesTheHoursByte() {
        let step = ProgramStep(mode: .cool, fanStep: 14, temperature: 36, hours: 6, minutes: 30, endsAtClockTime: true)
        let command = Codec.writeProgram(slot: 0, steps: [step])[0]
        XCTAssertEqual([UInt8](command[3..<8]), [0x04, 0x0e, 0x24, 0x86, 0x1e])
        XCTAssertEqual(Codec.parseFragment(command.dropFirst(2), index: 0)?.steps, [step])
    }

    func testNameCommandIsPaddedAndTrimmed() {
        let command = Codec.nameProgram(slot: 1, name: "A very long schedule name ✨")
        XCTAssertEqual(command.count, 19)
        XCTAssertEqual([UInt8](command.prefix(3)), [0x40, 0x05, 0x10])
        XCTAssertEqual(Codec.parseText(command.dropFirst(3)), "A very long sch")
    }

    @MainActor
    func testHandOverRequestsAreSpecificToOneBedJet() {
        let mine = BLELink.handoffUUID(forDeviceNamed: "BEDJET-3B04")
        XCTAssertEqual(mine, BLELink.handoffUUID(forDeviceNamed: "BEDJET-3B04"))
        XCTAssertNotEqual(mine, BLELink.handoffUUID(forDeviceNamed: "BEDJET-3B05"))
        XCTAssertEqual(mine.data.count, 16)
    }

    func testRuntimeCommandSplitsHoursAndMinutes() {
        XCTAssertEqual([UInt8](Codec.setRuntime(minutes: 150)), [0x02, 2, 30])
    }

    @MainActor
    func testRuntimeChangesTheShutOffTimeAndStopsAtTheModeLimit() async throws {
        let link = DemoLink()
        var latest: DeviceStatus?
        link.onStatus = { latest = $0 }
        try await link.setMode(.heat)
        XCTAssertEqual(latest?.remainingSeconds, 60 * 60)
        try await link.send(Codec.setRuntime(minutes: 150))
        XCTAssertEqual(latest?.remainingSeconds, 150 * 60)
        try await link.send(Codec.setRuntime(minutes: 600))
        XCTAssertEqual(latest?.remainingSeconds, 240 * 60)
    }

    @MainActor
    func testStoreAndReadBackThroughSimulatedDevice() async throws {
        let link = DemoLink(slots: [StoredProgram(name: "old", steps: [ProgramStep(mode: .dry, fanStep: 1, temperature: 60, hours: 1, minutes: 0)]), nil, nil])
        let steps = (0..<11).map { ProgramStep(mode: $0 % 2 == 0 ? .cool : .heat, fanStep: $0, temperature: 50, hours: 0, minutes: 20 + $0) }
        try await link.store(StoredProgram(name: "Deep Sleep", steps: steps), slot: 1)
        let stored = try await link.storedPrograms()
        XCTAssertEqual(stored[0]?.name, "old")
        XCTAssertEqual(stored[1], StoredProgram(name: "Deep Sleep", steps: steps))
        XCTAssertNil(stored[2])
    }

    @MainActor
    func testStartingAProgramSyncsTheClockAndRunsTheFirstStep() async throws {
        let link = DemoLink()
        var latest: DeviceStatus?
        link.onStatus = { latest = $0 }
        try await link.store(StoredProgram(name: "Night", steps: [ProgramStep(mode: .cool, fanStep: 5, temperature: 44, hours: 2, minutes: 0)]), slot: 0)
        try await link.startProgram(slot: 0)
        XCTAssertNotNil(link.clock)
        XCTAssertEqual(latest?.mode, .cool)
        XCTAssertEqual(latest?.fanStep, 5)
        XCTAssertEqual(latest?.extra?.programStep, 1)
    }
}
