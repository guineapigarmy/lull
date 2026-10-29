import BedJetKit
import XCTest
@testable import Lull

/// Errands from the watch, which reach the BedJet through Lull on the phone. Off screen, Lull connects for each one and
/// lets go again, so another phone can still take the BedJet over. The Android app's `WatchErrandTest` is the twin.
@MainActor
final class WatchErrandTests: XCTestCase {
    private struct Missing: Error {}

    private let mine = NearbyBedJet(id: UUID(), name: "BEDJET_3", generation: .v3, rssi: -50)
    private let partners = NearbyBedJet(id: UUID(), name: "BEDJET_3", generation: .v3, rssi: -70)
    private var directory: URL!
    private var defaults: UserDefaults!
    private var units: [UUID: FakeLink] = [:]

    override func setUp() async throws {
        // A starter schedule's wake time can be more than 16 hours away, which would make starting a night depend on the time of day.
        AppModel.startsWithoutWakeTimes = true
        directory = FileManager.default.temporaryDirectory.appending(path: "WatchErrandTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "WatchErrandTests-\(UUID().uuidString)")
        units = [:]
        AppModel.errandPatience = 2
    }

    override func tearDown() async throws {
        AppModel.startsWithoutWakeTimes = ProcessInfo.processInfo.arguments.contains("-noWakeTimes")
        for unit in units.values { unit.stop() }
        try? FileManager.default.removeItem(at: directory)
        AppModel.errandPatience = 8
    }

    private func launch(onScreen: Bool = true) -> AppModel {
        AppModel(storage: Storage(directory: directory, defaults: defaults), demoMode: false,
                 makeLink: { [unowned self] bedJet in self.unit(bedJet.unit!) },
                 discovery: { _ in DemoDiscovery(units: [self.mine, self.partners]) }, onScreen: onScreen)
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

    /// A BedJet chosen and connected, with what's saved on it read, as after using Lull for a while.
    private func chosen(_ unit: NearbyBedJet, in model: AppModel) async throws -> BedJet {
        model.choose(unit)
        let bedJet = try XCTUnwrap(model.bedJets.first { $0.unit == unit.id })
        try await waitUntil("\(unit.name) to connect") { bedJet.isConnected }
        try await waitUntil("its slots to be read") { bedJet.deviceSlots.count == 3 }
        return bedJet
    }

    func testOffScreenAnErrandStartsTheNightThenLetsGo() async throws {
        let model = launch()
        let bedJet = try await chosen(mine, in: model)
        model.appMovedToBackground()
        XCTAssertFalse(bedJet.isConnected)
        let stops = unit(mine.id).stops

        let reply = await model.runErrand(.startNight(bedJet.id))
        XCTAssertEqual(reply, .done)
        XCTAssertEqual(bedJet.run?.schedule.id, bedJet.tonight?.id)
        // Let go again, so another phone can take the BedJet over.
        XCTAssertGreaterThan(unit(mine.id).stops, stops)
        XCTAssertFalse(bedJet.isConnected)
    }

    func testANightWithAWakeTimeEndsAtIt() async throws {
        let model = launch()
        let bedJet = try await chosen(mine, in: model)
        // Two hours of cooling, ending three hours from now whatever the usual bedtime is: each hour stretches to an hour and a half.
        let wake = (Format.minuteOfDay(Date()) + 180) % 1440
        let schedule = Schedule(name: "Wake", phases: [Phase(.cool, minutes: 60), Phase(.cool, fan: 20, minutes: 60)], wakeTime: wake)
        model.save(schedule)
        bedJet.tonightID = schedule.id

        let reply = await model.runErrand(.startNight(bedJet.id))
        XCTAssertEqual(reply, .done)
        let run = try XCTUnwrap(bedJet.run)
        XCTAssertEqual(run.schedule.totalMinutes, run.schedule.minutesToWake(startingAt: Format.minuteOfDay(run.startedAt)))
        XCTAssertTrue((179...180).contains(run.schedule.totalMinutes), "three hours from the start, a minute either way")
        // The BedJet is given tonight's lengths, and keeps to the wake time itself.
        let slot = try XCTUnwrap(bedJet.slot)
        XCTAssertEqual(bedJet.deviceSlots[slot]?.steps.first, run.schedule.phases.first?.step)
        XCTAssertEqual(bedJet.deviceSlots[slot]?.steps.last, schedule.phases.last?.step(endingAt: wake))
    }

    func testWokenOffScreenNothingConnectsUntilAnErrandNeedsIt() async throws {
        let chosen = launch()
        _ = try await self.chosen(mine, in: chosen)
        chosen.appMovedToBackground()
        units = [:]

        // Woken by the watch: no BedJet is connected, and none is asked for, so another phone keeps its night.
        let model = launch(onScreen: false)
        let bedJet = try XCTUnwrap(model.bedJet)
        try await Task.sleep(nanoseconds: 500_000_000)
        // The link is set up, ready for an errand, and left idle.
        let link = try XCTUnwrap(units[mine.id])
        XCTAssertEqual(link.state, .searching)
        XCTAssertFalse(bedJet.isConnected)

        let reply = await model.runErrand(.startNight(bedJet.id))
        XCTAssertEqual(reply, .done)
        XCTAssertNotNil(bedJet.run)
        XCTAssertFalse(bedJet.isConnected)

        // Opened later, it talks to the BedJet as usual.
        model.appBecameActive()
        try await waitUntil("it to connect") { bedJet.isConnected }
    }

    func testARefreshDoesntCutOffAnErrandOnTheSameBedJet() async throws {
        let model = launch()
        let bedJet = try await chosen(mine, in: model)
        model.appMovedToBackground()

        async let refreshed = model.runErrand(.refresh)
        async let started = model.runErrand(.startNight(bedJet.id))
        let (refresh, start) = await (refreshed, started)
        XCTAssertEqual(refresh, .done)
        XCTAssertEqual(start, .done)
        XCTAssertNotNil(bedJet.run)
        XCTAssertFalse(bedJet.isConnected)
    }

    func testOnScreenTheBedJetStaysConnected() async throws {
        let model = launch()
        let bedJet = try await chosen(mine, in: model)
        let stops = unit(mine.id).stops

        let reply = await model.runErrand(.startNight(nil))
        XCTAssertEqual(reply, .done)
        XCTAssertNotNil(bedJet.run)
        XCTAssertEqual(unit(mine.id).stops, stops)
        XCTAssertTrue(bedJet.isConnected)
    }

    func testTheRemoteFromTheWatchSetsAndLetsGo() async throws {
        let model = launch()
        let bedJet = try await chosen(mine, in: model)
        model.appMovedToBackground()

        let preset = RemotePreset(mode: .heat, minutes: 20, temperature: 70, fanPercent: 35)
        let reply = await model.runErrand(.remote(preset, bedJet.id))
        XCTAssertEqual(reply, .done)
        // What the BedJet last said is kept once Lull lets go.
        XCTAssertEqual(bedJet.status?.mode, .heat)
        XCTAssertEqual(bedJet.status?.targetTemperature, 70)
        XCTAssertEqual(bedJet.status?.fanPercent, 35)
        XCTAssertFalse(bedJet.isConnected)
    }

    func testWhatWentWrongGoesBackToTheWatchNotIntoAnAlert() async throws {
        let model = launch()
        let bedJet = try await chosen(mine, in: model)
        model.appMovedToBackground()
        // Unplugged since.
        unit(mine.id).answers = false

        let reply = await model.runErrand(.startNight(bedJet.id))
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.message, BedJetError.notConnected.errorDescription)
        XCTAssertNil(bedJet.run)
        XCTAssertNil(model.errorMessage)
    }

    func testAnErrandForAForgottenBedJetNeverReachesAnother() async throws {
        let model = launch()
        let bedJet = try await chosen(mine, in: model)
        let forgotten = UUID()

        let reply = await model.runErrand(.startNight(forgotten))
        XCTAssertFalse(reply.ok)
        XCTAssertNil(bedJet.run)
    }

    func testARefreshHearsEachBedJetThenLetsGo() async throws {
        let model = launch()
        let first = try await chosen(mine, in: model)
        let second = try await chosen(partners, in: model)
        model.appMovedToBackground()
        let asked = Date()

        let reply = await model.runErrand(.refresh)
        XCTAssertEqual(reply, .done)
        XCTAssertTrue(first.hasReported(since: asked))
        XCTAssertTrue(second.hasReported(since: asked))
        XCTAssertFalse(first.isConnected)
        XCTAssertFalse(second.isConnected)
    }
}
