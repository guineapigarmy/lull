import BedJetKit
import XCTest
@testable import Lull

/// How air started from the Remote is timed: as long as the BedJet allows, for a duration picked there, or until a time
/// picked there, which holds across modes. The Android app's `RemoteTimerTest` is the twin.
@MainActor
final class RemoteTimerTests: XCTestCase {
    private struct Missing: Error {}

    private let mine = NearbyBedJet(id: UUID(), name: "BEDJET_3", generation: .v3, rssi: -50)
    private var directory: URL!
    private var defaults: UserDefaults!
    private var units: [UUID: FakeLink] = [:]

    override func setUp() async throws {
        // A starter schedule's wake time can be more than 16 hours away, which would make starting a night depend on the time of day.
        AppModel.startsWithoutWakeTimes = true
        directory = FileManager.default.temporaryDirectory.appending(path: "RemoteTimerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "RemoteTimerTests-\(UUID().uuidString)")
        units = [:]
    }

    override func tearDown() async throws {
        AppModel.startsWithoutWakeTimes = ProcessInfo.processInfo.arguments.contains("-noWakeTimes")
        for unit in units.values { unit.stop() }
        try? FileManager.default.removeItem(at: directory)
    }

    private func launch() -> AppModel {
        AppModel(storage: Storage(directory: directory, defaults: defaults), demoMode: false,
                 makeLink: { [unowned self] bedJet in self.unit(bedJet.unit!) },
                 discovery: { _ in DemoDiscovery(units: [self.mine]) })
    }

    private func unit(_ id: UUID) -> FakeLink {
        if let unit = units[id] { return unit }
        let unit = FakeLink(name: "BEDJET_3")
        units[id] = unit
        return unit
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 6, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for \(what)")
                throw Missing()
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func chosen(_ unit: NearbyBedJet, in model: AppModel) async throws -> BedJet {
        model.choose(unit)
        let bedJet = try XCTUnwrap(model.bedJets.first { $0.unit == unit.id })
        try await waitUntil("\(unit.name) to connect") { bedJet.isConnected }
        try await waitUntil("its slots to be read") { bedJet.deviceSlots.count == 3 }
        return bedJet
    }

    /// Waits for the BedJet to count down from about `minutes`, give or take a minute and a half.
    private func waitForTimer(_ bedJet: BedJet, near minutes: Int, _ what: String) async throws {
        try await waitUntil(what) { abs((bedJet.status?.remainingSeconds ?? 0) - minutes * 60) <= 90 }
    }

    func testATimeRunsTheAirUntilThenWhateverTheMode() async throws {
        let model = launch()
        model.remoteTimerShowsTime = true
        let bedJet = try await chosen(mine, in: model)
        await bedJet.setMode(.cool)
        try await waitForTimer(bedJet, near: 720, "Cool to run as long as the simulated BedJet allows")

        await bedJet.setRuntime(until: Date().addingTimeInterval(3 * 3600))
        try await waitForTimer(bedJet, near: 180, "the timer to reach the time")
        // Another mode keeps the same end, where it would otherwise start over at its longest run.
        await bedJet.setMode(.heat)
        try await waitUntil("Heat to report") { bedJet.status?.mode == .heat }
        try await waitForTimer(bedJet, near: 180, "Heat to end at the same time")
        // As far as the mode allows: Heat runs for 4 hours at most.
        await bedJet.setRuntime(until: Date().addingTimeInterval(6 * 3600))
        try await waitForTimer(bedJet, near: 240, "Heat to stop at its limit")

        // Turned off, the next mode starts over at its longest run.
        await bedJet.setMode(.standby)
        XCTAssertEqual(bedJet.remoteTimer, .longest)
        await bedJet.setMode(.cool)
        try await waitForTimer(bedJet, near: 720, "Cool to run as long as it can again")
    }

    func testShownAsATimeTheEndOnScreenHoldsWhereverItCameFrom() async throws {
        let model = launch()
        model.remoteTimerShowsTime = true
        let bedJet = try await chosen(mine, in: model)
        await bedJet.setMode(.cool)
        try await waitForTimer(bedJet, near: 720, "Cool to run as long as it can")
        // A countdown Lull didn't set, as after it relaunches: it only knows what the BedJet says.
        try await unit(mine.id).send(Codec.setRuntime(minutes: 180))
        try await waitForTimer(bedJet, near: 180, "the BedJet to count down 3 hours")
        await bedJet.setMode(.heat)
        try await waitUntil("Heat to report") { bedJet.status?.mode == .heat }
        try await waitForTimer(bedJet, near: 180, "Heat to end when the screen said")
    }

    func testShownAsATimerAModeStartsOverAtItsLongestRun() async throws {
        let bedJet = try await chosen(mine, in: launch())
        await bedJet.setMode(.cool)
        await bedJet.setRuntime(until: Date().addingTimeInterval(3 * 3600))
        try await waitForTimer(bedJet, near: 180, "the timer to reach the time")
        // The Remote shows a duration, so a mode runs as long as it can, as the timer always has.
        await bedJet.setMode(.heat)
        try await waitUntil("Heat to report") { bedJet.status?.mode == .heat }
        try await waitForTimer(bedJet, near: 240, "Heat to run as long as it can")
        XCTAssertEqual(bedJet.remoteTimer, .longest)
    }

    func testAPickedDurationIsLeftAlone() async throws {
        let bedJet = try await chosen(mine, in: launch())
        await bedJet.setMode(.cool)
        try await waitForTimer(bedJet, near: 720, "Cool to run as long as it can")
        await bedJet.setRuntime(minutes: 30)
        await bedJet.setFan(percent: 60)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(bedJet.remoteTimer, .picked)
        XCTAssertEqual(Double(bedJet.status?.remainingSeconds ?? 0), 30 * 60, accuracy: 90)
    }

    func testAScheduleKeepsItsOwnTiming() async throws {
        let model = launch()
        let bedJet = try await chosen(mine, in: model)
        await bedJet.setMode(.cool)
        await bedJet.setRuntime(until: Date().addingTimeInterval(3 * 3600))
        XCTAssertTrue(bedJet.remoteTimer.isAhead)
        await bedJet.startTonight()
        XCTAssertNil(model.errorMessage)
        try await waitUntil("the night to start") { bedJet.run != nil }
        XCTAssertEqual(bedJet.remoteTimer, .longest)
    }
}
