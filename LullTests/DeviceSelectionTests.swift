import BedJetKit
import XCTest
@testable import Lull

/// Choosing, switching between and forgetting BedJets, against simulated units that connect only when allowed,
/// record every command they receive and can hold one in flight. Nothing here touches real hardware.
@MainActor
final class DeviceSelectionTests: XCTestCase {
    private struct Missing: Error {}

    // Two units share the default name, as real ones often do. The guest room's doesn't say what it is.
    private let mine = NearbyBedJet(id: UUID(), name: "BEDJET_3", generation: .v3, rssi: -50)
    private let partners = NearbyBedJet(id: UUID(), name: "BEDJET_3", generation: .v3, rssi: -70)
    private let guest = NearbyBedJet(id: UUID(), name: "BEDJET_GUEST", generation: nil, rssi: -85)

    private var directory: URL!
    private var defaults: UserDefaults!
    private var discovery: DemoDiscovery!
    /// The simulated units, by Bluetooth identity. Each keeps its state across connections, like a real one.
    private var units: [UUID: FakeLink] = [:]
    /// How each unit is set up when Lull first connects to it.
    private var setups: [UUID: (FakeLink) -> Void] = [:]

    override func setUp() async throws {
        // A starter schedule's wake time can be more than 16 hours away, which would make starting a night depend on the time of day.
        AppModel.startsWithoutWakeTimes = true
        directory = FileManager.default.temporaryDirectory.appending(path: "DeviceSelectionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "DeviceSelectionTests-\(UUID().uuidString)")
        discovery = DemoDiscovery(units: [mine, partners, guest])
        units = [:]
        setups = [:]
    }

    override func tearDown() async throws {
        AppModel.startsWithoutWakeTimes = ProcessInfo.processInfo.arguments.contains("-noWakeTimes")
        for unit in units.values { unit.stop() }
        try? FileManager.default.removeItem(at: directory)
    }

    /// Lull launched by the person, on screen. Off screen is a launch to run an action or list BedJets in Shortcuts.
    private func launch(demo: Bool = false, onScreen: Bool = true) -> AppModel {
        AppModel(storage: Storage(directory: directory, defaults: defaults), demoMode: demo,
                 makeLink: { [unowned self] bedJet in self.unit(bedJet.unit!) },
                 discovery: { [unowned self] _ in self.discovery }, onScreen: onScreen)
    }

    private func unit(_ id: UUID) -> FakeLink {
        if let unit = units[id] { return unit }
        let unit = FakeLink(name: [mine, partners, guest].first { $0.id == id }?.name ?? "BEDJET")
        setups[id]?(unit)
        units[id] = unit
        return unit
    }

    private func bedJet(_ unit: NearbyBedJet, in model: AppModel) throws -> BedJet {
        try XCTUnwrap(model.bedJets.first { $0.unit == unit.id })
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

    /// Waits for a BedJet to connect and finish reading what's saved on it, which Lull does on each new connection.
    private func connected(_ unit: NearbyBedJet, in model: AppModel) async throws -> BedJet {
        let bedJet = try bedJet(unit, in: model)
        try await waitUntil("\(unit.name) to connect") { bedJet.isConnected }
        if bedJet.generation == .v3 { try await waitUntil("\(unit.name)'s slots to be read") { bedJet.deviceSlots.count == 3 } }
        return bedJet
    }

    // MARK: Choosing

    func testNothingConnectsUntilABedJetIsChosen() async throws {
        let model = launch()
        XCTAssertNil(model.bedJet)
        model.startLooking()
        // Everything nearby is listed as soon as it's seen, and looking connects to none of it.
        XCTAssertEqual(model.nearby.map(\.id), [mine.id, partners.id, guest.id])
        XCTAssertTrue(units.isEmpty)

        model.choose(partners)
        XCTAssertEqual(model.bedJet?.unit, partners.id)
        XCTAssertEqual(Set(units.keys), [partners.id])
        _ = try await connected(partners, in: model)
        // Once chosen it's under Your BedJets, not Nearby.
        XCTAssertEqual(model.nearby.map(\.id), [mine.id, guest.id])
    }

    func testALoneBedJetNearbyIsListedAtOnce() {
        discovery.units = [guest]
        let model = launch()
        model.startLooking()
        XCTAssertEqual(model.nearby.map(\.id), [guest.id])
        model.stopLooking()
        XCTAssertTrue(model.nearby.isEmpty)
    }

    func testSameNamedBedJetsAreToldApartAndNicknamesStick() async throws {
        let model = launch()
        model.startLooking()
        XCTAssertEqual(model.title(of: mine), "BEDJET_3 · \(AppModel.code(of: mine.id))")
        XCTAssertEqual(model.title(of: guest), "BEDJET_GUEST")
        model.choose(mine)
        model.choose(partners)
        let first = try bedJet(mine, in: model), second = try bedJet(partners, in: model)
        XCTAssertEqual(model.title(of: first), "BEDJET_3 · \(AppModel.code(of: mine.id))")
        XCTAssertEqual(model.title(of: second), "BEDJET_3 · \(AppModel.code(of: partners.id))")
        XCTAssertNotEqual(model.title(of: first), model.title(of: second))

        second.nickname = "Partner's side"
        XCTAssertEqual(model.title(of: second), "Partner's side")
        XCTAssertEqual(model.title(of: first), "BEDJET_3")

        // Kept on this phone across launches; the BedJet itself isn't renamed.
        let relaunched = launch()
        XCTAssertEqual(try bedJet(partners, in: relaunched).nickname, "Partner's side")
        XCTAssertEqual(try bedJet(partners, in: relaunched).name, "BEDJET_3")
        XCTAssertEqual(relaunched.bedJet?.unit, partners.id)
    }

    func testReconnectsToTheChosenBedJetAfterRelaunch() async throws {
        let model = launch()
        model.choose(mine)
        _ = try await connected(mine, in: model)
        model.appMovedToBackground()

        units = [:]
        let relaunched = launch()
        XCTAssertEqual(relaunched.bedJet?.unit, mine.id)
        XCTAssertEqual(Set(units.keys), [mine.id])
        _ = try await connected(mine, in: relaunched)
    }

    func testAnAbsentBedJetIsNeverSwappedForAnotherNearby() async throws {
        setups[mine.id] = { $0.answers = false }
        let model = launch()
        model.choose(mine)
        model.startLooking()
        try await Task.sleep(nanoseconds: 2_000_000_000)
        // Still looking for the chosen one, with the partner's in range and free.
        XCTAssertEqual(model.bedJet?.unit, mine.id)
        XCTAssertEqual(model.bedJet?.linkState, .searching)
        XCTAssertEqual(Set(units.keys), [mine.id])
        // Over Bluetooth, a link only takes the unit it was made for.
        XCTAssertFalse(BLELink.takes(partners.id, boundTo: mine.id))
        XCTAssertTrue(BLELink.takes(mine.id, boundTo: mine.id))
    }

    // MARK: Switching

    func testSwitchingLeavesTheOtherBedJetRunning() async throws {
        let model = launch()
        model.choose(mine)
        let first = try await connected(mine, in: model)
        await first.startTonight()
        XCTAssertNotNil(first.run)
        await first.setTemperature(70)
        let sentBefore = unit(mine.id).sent

        model.choose(partners)
        XCTAssertEqual(model.bedJet?.unit, partners.id)
        _ = try await connected(partners, in: model)
        try await Task.sleep(nanoseconds: 1_500_000_000)

        // The first keeps its connection, its schedule and everything set on it; nothing more was sent to it.
        XCTAssertEqual(unit(mine.id).sent, sentBefore)
        XCTAssertEqual(unit(mine.id).stops, 0)
        XCTAssertNotNil(first.run)
        XCTAssertTrue(first.isConnected)
        XCTAssertGreaterThan(first.status?.extra?.programStep ?? 0, 0)
    }

    func testRapidSwitchingAndLateReportsStayWithTheirBedJet() async throws {
        let model = launch()
        model.choose(mine)
        model.choose(partners)
        model.choose(guest)
        let first = try await connected(mine, in: model)
        let last = try await connected(guest, in: model)
        for id in [first.id, last.id, first.id, last.id] { XCTAssertTrue(model.select(id)) }
        XCTAssertEqual(model.bedJet?.unit, guest.id)

        // A report from the first unit, arriving whenever it does, only ever updates the first.
        let before = last.status
        var report = try XCTUnwrap(first.status)
        report.mode = .turbo
        unit(mine.id).report(report)
        XCTAssertEqual(first.status?.mode, .turbo)
        XCTAssertEqual(last.status?.mode, before?.mode)
        XCTAssertEqual(model.bedJet?.unit, guest.id)
    }

    /// A real BedJet 3 sends each report in two halves, and right after reconnecting, such as after restarting to check
    /// for firmware, only the first half comes for a moment. Its settings stay shown meanwhile, so the sheet holds still.
    func testSettingsStayWhileAReportsSecondHalfIsLate() async throws {
        let model = launch()
        model.choose(mine)
        let bedJet = try await connected(mine, in: model)
        try await waitUntil("a full report") { bedJet.settings != nil }
        let settings = bedJet.settings
        var firstHalf = try XCTUnwrap(bedJet.status)
        firstHalf.extra = nil
        unit(mine.id).report(firstHalf)
        XCTAssertNil(bedJet.status?.extra)
        XCTAssertEqual(bedJet.settings, settings)
    }

    func testACommandMeantForOneBedJetNeverReachesAnother() async throws {
        let model = launch()
        model.choose(mine)
        model.choose(partners)
        let first = try await connected(mine, in: model)
        let second = try await connected(partners, in: model)
        XCTAssertTrue(model.select(first.id))

        unit(mine.id).holdsSends = true
        let sending = Task { await first.setMode(.heat) }
        try await waitUntil("the command to be in flight") { unit(mine.id).isHolding }
        XCTAssertTrue(model.select(second.id))
        unit(mine.id).release()
        await sending.value

        let heat = try XCTUnwrap(Codec.setMode(.heat))
        XCTAssertTrue(unit(mine.id).sent.contains(heat))
        XCTAssertFalse(unit(partners.id).sent.contains(heat))
        XCTAssertEqual(second.status?.mode, .standby)
    }

    func testSwitchingWaitsWhileAScheduleIsSaving() async throws {
        let model = launch()
        model.choose(partners)
        model.choose(mine)
        let first = try await connected(mine, in: model)
        let second = try await connected(partners, in: model)

        unit(mine.id).holdsSends = true
        let saving = Task { await first.startTonight() }
        try await waitUntil("the schedule to start saving") { unit(mine.id).isHolding && first.isSavingSchedule }
        XCTAssertFalse(model.canSwitch)
        XCTAssertFalse(model.select(second.id))
        model.choose(guest)
        XCTAssertEqual(model.bedJet?.unit, mine.id)
        XCTAssertEqual(model.bedJets.count, 2)

        unit(mine.id).release()
        await saving.value
        XCTAssertNotNil(first.run)
        XCTAssertTrue(model.select(second.id))
    }

    // MARK: What belongs to each BedJet

    func testSlotsRunsAndHistoryStayWithTheirBedJet() async throws {
        let theirs = StoredProgram(name: "Theirs", steps: [ProgramStep(mode: .cool, fanStep: 7, temperature: 40, hours: 2, minutes: 0)])
        setups[partners.id] = { $0.device = DemoLink(name: "BEDJET_3", slots: [theirs, nil, nil]) }
        let model = launch()
        model.choose(mine)
        let first = try await connected(mine, in: model)
        await first.startTonight()
        XCTAssertEqual(first.slot, 0)
        XCTAssertNotNil(first.run)
        XCTAssertTrue(first.history.contains { if case .scheduleStarted = $0.event { true } else { false } })

        model.choose(partners)
        let second = try await connected(partners, in: model)
        XCTAssertNil(second.slot)
        XCTAssertNil(second.run)
        XCTAssertTrue(second.history.isEmpty)
        // Its own slots are read before one is picked, so the program saved on it stays.
        await second.startTonight()
        XCTAssertEqual(second.slot, 1)
        XCTAssertEqual(unit(partners.id).device.slots[0], theirs)
        XCTAssertEqual(first.slot, 0)
        XCTAssertNotNil(first.run)
        XCTAssertNotEqual(first.history, second.history)
    }

    func testAV2RefusesModesItCantRunWithoutChangingTheSchedule() async throws {
        setups[mine.id] = { $0.generation = .v2 }
        let model = launch()
        let dryOut = Schedule(name: "Dry out", phases: [Phase(.cool, fan: 40, minutes: 60), Phase(.dry, fan: 50, minutes: 30)])
        model.save(dryOut)
        model.choose(mine)
        let first = try await connected(mine, in: model)
        XCTAssertEqual(first.knownGeneration, .v2)
        first.tonightID = dryOut.id
        XCTAssertEqual(first.unsupportedModes(in: dryOut), [.dry])
        XCTAssertNotNil(first.problem(running: dryOut))

        let sentBefore = unit(mine.id).sent
        await first.startTonight()
        XCTAssertEqual(unit(mine.id).sent, sentBefore)
        XCTAssertNil(first.run)
        XCTAssertTrue(model.errorMessage?.contains("can't run Dry") == true)
        XCTAssertEqual(model.schedules.first { $0.id == dryOut.id }, dryOut)

        // A BedJet 3 runs the same schedule as it is.
        model.choose(partners)
        let second = try await connected(partners, in: model)
        XCTAssertNil(second.problem(running: dryOut))
    }

    // MARK: Carrying over saved state

    private struct SingleBedJetSave: Codable {
        var schedules: [Schedule]
        var tonightID: Schedule.ID?
        var slot: Int?
    }

    private struct SeveralBedJetsSave: Codable {
        struct Fleet: Codable {
            var bedJets: [SavedBedJet]
            var selected: UUID?
        }
        var schedules: [Schedule]
        var fleet: Fleet
    }

    private struct HistoryFile: Codable { var entries: [HistoryEntry] }

    private func write(_ value: some Encodable, to name: String) throws {
        try JSONEncoder().encode(value).write(to: directory.appending(path: name))
    }

    private let aNight = [HistoryEntry(date: Date().addingTimeInterval(-3600), event: .scheduleStarted(name: "Cool Drift", phases: nil), room: 44)]

    func testCarriesOverTheBedJetAnEarlierVersionRemembered() async throws {
        defaults.set(mine.id.uuidString, forKey: "BedJetKit.peripheral")
        defaults.set("BEDJET_3", forKey: "BedJetKit.deviceName")
        defaults.set("v2", forKey: "generation")
        try write(SingleBedJetSave(schedules: Schedule.templates, tonightID: Schedule.templates[1].id, slot: 2), to: "lull.json")
        try write(HistoryFile(entries: aNight), to: "history.json")

        let model = launch()
        let first = try XCTUnwrap(model.bedJet)
        XCTAssertEqual(first.unit, mine.id)
        XCTAssertEqual(first.name, "BEDJET_3")
        XCTAssertEqual(first.knownGeneration, .v2)
        XCTAssertEqual(first.slot, 2)
        XCTAssertEqual(first.tonightID, Schedule.templates[1].id)
        XCTAssertEqual(first.history, aNight)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "history.json").path))

        // Carrying over happens once; launching again finds the same BedJet with the same nights.
        model.appMovedToBackground()
        let relaunched = launch()
        XCTAssertEqual(relaunched.bedJets.count, 1)
        XCTAssertEqual(relaunched.bedJet?.id, first.id)
        XCTAssertEqual(relaunched.bedJet?.history, aNight)
    }

    func testWithoutARememberedBedJetNothingIsAssumed() throws {
        try write(SingleBedJetSave(schedules: Schedule.templates, tonightID: nil, slot: 1), to: "lull.json")
        try write(HistoryFile(entries: aNight), to: "history.json")
        let model = launch()
        XCTAssertNil(model.bedJet)
        XCTAssertTrue(model.bedJets.isEmpty)
        // Nights of unknown origin stay where they were rather than being given to whichever BedJet is chosen next.
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appending(path: "history.json").path))
        model.choose(mine)
        XCTAssertTrue(model.bedJet?.history.isEmpty == true)
    }

    func testBedJetsSavedWithoutAUnitAreChosenAgain() throws {
        // Saved by the version that connected to whichever BedJet it found first.
        let unknown = SavedBedJet(name: "BEDJET_3"), known = SavedBedJet(unit: partners.id, name: "BEDJET_3")
        try write(SeveralBedJetsSave(schedules: Schedule.templates, fleet: .init(bedJets: [unknown, known], selected: unknown.id)), to: "lull.json")
        try write(HistoryFile(entries: aNight), to: "history-\(unknown.id.uuidString).json")

        let model = launch()
        XCTAssertEqual(model.bedJets.map(\.id), [known.id])
        XCTAssertNil(model.bedJet)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appending(path: "history-\(unknown.id.uuidString).json").path))
    }

    // MARK: Forgetting

    func testForgettingTheBedJetOnScreenAsksAgain() async throws {
        let model = launch()
        model.choose(partners)
        model.choose(mine)
        let first = try await connected(mine, in: model)
        await first.startTonight()
        let nights = first.history
        XCTAssertFalse(nights.isEmpty)

        model.forget(first)
        // Nothing is picked in its place, and the unit was left running as it was.
        XCTAssertNil(model.bedJet)
        XCTAssertEqual(model.bedJets.map(\.unit), [partners.id])
        XCTAssertFalse(unit(mine.id).sent.contains(try XCTUnwrap(Codec.setMode(.standby))))
        XCTAssertGreaterThan(unit(mine.id).device.programStep, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appending(path: "history-\(first.id.uuidString).json").path))

        model.appMovedToBackground()
        let relaunched = launch()
        XCTAssertNil(relaunched.bedJet)

        // Choosing it again brings its nights back.
        relaunched.choose(mine)
        XCTAssertEqual(relaunched.bedJet?.id, first.id)
        XCTAssertEqual(relaunched.bedJet?.history, nights)
    }

    func testDemoBedJetsStayApartFromRealOnes() async throws {
        let model = launch()
        model.choose(mine)
        model.demoMode = true
        XCTAssertTrue(model.bedJet?.isDemo == true)
        XCTAssertFalse(model.bedJets.contains { $0.unit == mine.id })
        model.demoMode = false
        XCTAssertEqual(model.bedJet?.unit, mine.id)
        XCTAssertEqual(model.bedJets.count, 1)
        XCTAssertFalse(model.bedJet?.isDemo ?? true)
    }

    // MARK: Turning off

    func testTurningOffStopsShowingTheBedJetBeforeItReports() async throws {
        let model = launch()
        model.choose(mine)
        let bedJet = try await connected(mine, in: model)
        await bedJet.setMode(.heat)
        XCTAssertNotNil(LiveStatus.of(run: bedJet.run, status: bedJet.status, reportedAt: bedJet.statusReceivedAt,
                                      generation: bedJet.generation))

        // Lull lets go of the BedJet once it leaves the screen, which can be before the BedJet says it's off. It took
        // the command, so it's no longer shown as running.
        unit(mine.id).reports = false
        await bedJet.setMode(.standby)
        XCTAssertEqual(bedJet.status?.mode, .standby)
        XCTAssertNil(LiveStatus.of(run: bedJet.run, status: bedJet.status, reportedAt: bedJet.statusReceivedAt,
                                   generation: bedJet.generation))
    }

    func testAReportSentBeforeOffDoesntTurnTheBedJetBackOn() async throws {
        let window = BedJet.staleReportWindow
        BedJet.staleReportWindow = 0.5
        defer { BedJet.staleReportWindow = window }
        let model = launch()
        model.choose(mine)
        let bedJet = try await connected(mine, in: model)
        await bedJet.setMode(.cool)
        let running = try XCTUnwrap(bedJet.status)
        XCTAssertTrue(running.isRunning)

        // The BedJet reports every second, so one it sent while still cooling can arrive just after it took Off.
        let link = unit(mine.id)
        link.reports = false
        let off = Task { await bedJet.setMode(.standby) }
        try await waitUntil("Off to be taken") { bedJet.status?.mode == .standby }
        link.onStatus?(running)
        XCTAssertEqual(bedJet.status?.mode, .standby)
        XCTAssertNil(LiveStatus.of(run: bedJet.run, status: bedJet.status, reportedAt: bedJet.statusReceivedAt,
                                   generation: bedJet.generation))

        // Later, a report that it's running is believed: someone turned it on again.
        await off.value
        try await Task.sleep(nanoseconds: 600_000_000)
        link.onStatus?(running)
        XCTAssertEqual(bedJet.status?.mode, .cool)
    }

    // MARK: Actions from Shortcuts

    /// Lull in the background with a BedJet it was using, as when an automation runs at bedtime.
    private func backgrounded(_ unit: NearbyBedJet) async throws -> (AppModel, BedJet) {
        let model = launch()
        model.choose(unit)
        let bedJet = try await connected(unit, in: model)
        model.appMovedToBackground()
        try await waitUntil("\(unit.name) to be let go") { !bedJet.isConnected }
        return (model, bedJet)
    }

    private func failure(_ action: () async throws -> String) async -> String? {
        do {
            _ = try await action()
            XCTFail("The action should have failed")
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func testALaunchOffScreenConnectsToNothing() async throws {
        let model = launch()
        model.choose(mine)
        _ = try await connected(mine, in: model)
        model.appMovedToBackground()

        units = [:]
        let relaunched = launch(onScreen: false)
        XCTAssertEqual(relaunched.bedJet?.unit, mine.id)
        XCTAssertFalse(relaunched.status(of: try XCTUnwrap(relaunched.bedJet)).nightRunning)
        // Its link is set up for later, but nothing connects, and no other phone is asked for the BedJet.
        XCTAssertEqual(unit(mine.id).starts + unit(mine.id).listens + unit(mine.id).requests, 0)
    }

    func testAnActionWaitsOutTheBedJetsWiFi() async throws {
        let model = launch()
        model.choose(mine)
        let bedJet = try await connected(mine, in: model)
        let joining = Task { await bedJet.joinWiFi(network: "Home", password: "password1") }
        try await waitUntil("the BedJet to start on its Wi-Fi") { bedJet.wifiActivity?.isRunning == true }
        let message = await failure { try await model.perform(.lightRing(on: false), on: bedJet) }
        XCTAssertEqual(message, AutomationError.updating.errorDescription)
        await joining.value
        XCTAssertEqual(bedJet.wifiActivity?.failed, false)
    }

    /// Lull in the background with a BedJet that began installing an update, as after updating it at bedtime.
    private func installingAnUpdate() async throws -> (AppModel, BedJet) {
        let model = launch()
        model.choose(mine)
        let bedJet = try await connected(mine, in: model)
        await bedJet.joinWiFi(network: "Home", password: "password1")
        unit(mine.id).device.hasUpdate = true
        await bedJet.updateFirmware()
        XCTAssertEqual(bedJet.wifiActivity?.awaitsRestart, true)
        model.appMovedToBackground()
        try await waitUntil("\(mine.name) to be let go") { !bedJet.isConnected }
        return (model, bedJet)
    }

    func testAnActionIsRefusedWhileTheBedJetInstallsAnUpdate() async throws {
        let (model, bedJet) = try await installingAnUpdate()
        let listens = unit(mine.id).listens
        let message = await failure { try await model.perform(.air(AirSettings(mode: .heat)), on: bedJet) }
        XCTAssertEqual(message, AutomationError.updating.errorDescription)
        // It doesn't wait to reach a BedJet that is installing, or offer to go on in Lull.
        XCTAssertEqual(unit(mine.id).listens, listens)
    }

    func testAnActionGoesAheadOnceTheBedJetShouldBeBackFromAnUpdate() async throws {
        let (model, bedJet) = try await installingAnUpdate()
        // As when Lull wakes for the action long after the install, before its own timer has caught up.
        let patience = BedJet.restartPatience
        BedJet.restartPatience = 0
        defer { BedJet.restartPatience = patience }
        let done = try await model.perform(.air(AirSettings(mode: .heat)), on: bedJet)
        XCTAssertEqual(done, "Turned on Heat on BEDJET_3.")
    }

    func testTheBedJetStaysBusyWhileAnyCommandIsUnderWay() async throws {
        let model = launch()
        model.choose(mine)
        let bedJet = try await connected(mine, in: model)
        unit(mine.id).holdsSends = true
        let lightRing = Task { await bedJet.setLED(false) }
        try await waitUntil("the light ring to be on its way") { unit(mine.id).isHolding }
        // An action that sends nothing finishes while the light ring is still on its way, which keeps the BedJet busy.
        let done = try await model.perform(.turnOff, on: bedJet)
        XCTAssertEqual(done, "BEDJET_3 is already off.")
        XCTAssertTrue(bedJet.isBusy)
        unit(mine.id).release()
        await lightRing.value
        XCTAssertFalse(bedJet.isBusy)
    }

    func testStartNightSetToADeletedScheduleSaysSo() async throws {
        let (model, bedJet) = try await backgrounded(mine)
        let message = await failure { try await model.perform(.startNight(schedule: UUID()), on: bedJet) }
        XCTAssertEqual(message, AutomationError.forgottenSchedule.errorDescription)
    }

    func testAnActionSetToAForgottenBedJetSaysSo() async throws {
        let (model, bedJet) = try await backgrounded(mine)
        model.forget(bedJet)
        XCTAssertThrowsError(try model.automationTarget(bedJet.id)) { error in
            XCTAssertEqual(error as? AutomationError, .forgottenBedJet)
        }
        // Lull never picks another in its place.
        XCTAssertThrowsError(try model.automationTarget(nil)) { error in
            XCTAssertEqual(error as? AutomationError, .noBedJet)
        }
    }

    func testAnActionOffScreenReachesAFreeBedJetAndLetsGo() async throws {
        let model = launch()
        model.choose(mine)
        _ = try await connected(mine, in: model)
        model.appMovedToBackground()

        units = [:]
        let relaunched = launch(onScreen: false)
        let target = try relaunched.automationTarget(nil)
        let done = try await relaunched.perform(.startNight(schedule: nil), on: target)
        XCTAssertEqual(done, "Started “Cool Drift” on BEDJET_3.")
        XCTAssertNotNil(target.run)
        XCTAssertTrue(relaunched.status(of: target).nightRunning)
        // It never asked another phone for the BedJet, and let go of it once done.
        XCTAssertEqual(unit(mine.id).starts, 0)
        XCTAssertEqual(unit(mine.id).requests, 0)
        XCTAssertGreaterThan(unit(mine.id).listens, 0)
        XCTAssertGreaterThan(unit(mine.id).stops, 0)
        XCTAssertFalse(target.isConnected)
        XCTAssertNil(relaunched.errorMessage)
    }

    func testAnActionOffScreenGivesUpOnABedJetThatIsntFree() async throws {
        let (model, bedJet) = try await backgrounded(mine)
        let sentBefore = unit(mine.id).sent
        unit(mine.id).answers = false
        model.reachPatience = 1
        do {
            _ = try await model.perform(.air(AirSettings(mode: .heat)), on: bedJet)
            XCTFail("The action should have asked to go on in Lull")
        } catch {
            XCTAssertEqual(error as? AutomationError, .needsLull)
        }
        XCTAssertEqual(unit(mine.id).sent, sentBefore)
        XCTAssertEqual(unit(mine.id).requests, 0)
        XCTAssertNil(model.errorMessage)
    }

    func testComingOnScreenDuringAnActionKeepsTheBedJet() async throws {
        let (model, bedJet) = try await backgrounded(mine)
        let stopsBefore = unit(mine.id).stops
        unit(mine.id).holdsSends = true
        let action = Task { try await model.perform(.lightRing(on: false), on: bedJet) }
        try await waitUntil("the action to be in flight") { unit(mine.id).isHolding }
        model.appBecameActive()
        unit(mine.id).release()
        let done = try await action.value
        XCTAssertEqual(done, "Turned off the light ring on BEDJET_3.")
        XCTAssertTrue(bedJet.isConnected)
        XCTAssertEqual(unit(mine.id).stops, stopsBefore)
    }

    func testStartNightLeavesARunningNightAlone() async throws {
        let model = launch()
        model.choose(mine)
        let first = try await connected(mine, in: model)
        await first.startTonight()
        model.appMovedToBackground()

        let sentBefore = unit(mine.id).sent
        let done = try await model.perform(.startNight(schedule: model.schedules[2].id), on: first)
        XCTAssertEqual(done, "“Cool Drift” is already running on BEDJET_3.")
        XCTAssertEqual(unit(mine.id).sent, sentBefore)
        XCTAssertEqual(first.run?.schedule.name, "Cool Drift")
    }

    func testFullSlotsAreAnErrorForAnAction() async throws {
        let theirs = StoredProgram(name: "Theirs", steps: [ProgramStep(mode: .cool, fanStep: 7, temperature: 40, hours: 2, minutes: 0)])
        setups[mine.id] = { $0.device = DemoLink(name: "BEDJET_3", slots: [theirs, theirs, theirs]) }
        let (model, bedJet) = try await backgrounded(mine)
        let message = await failure { try await model.perform(.startNight(schedule: nil), on: bedJet) }
        XCTAssertEqual(message, AutomationError.slotsFull.errorDescription)
        // Nobody is there to pick a slot, so none is asked for or replaced.
        XCTAssertFalse(bedJet.needsSlotChoice)
        XCTAssertNil(bedJet.run)
        XCTAssertEqual(unit(mine.id).device.slots, [theirs, theirs, theirs])
        XCTAssertNil(model.errorMessage)
    }

    func testFullSlotsAreAskedAboutOnceAnActionGoesOnInLull() async throws {
        let theirs = StoredProgram(name: "Theirs", steps: [ProgramStep(mode: .cool, fanStep: 7, temperature: 40, hours: 2, minutes: 0)])
        setups[mine.id] = { $0.device = DemoLink(name: "BEDJET_3", slots: [theirs, theirs, theirs]) }
        let (model, bedJet) = try await backgrounded(mine)
        let done = try await model.perform(.startNight(schedule: nil), on: bedJet, mayAsk: true)
        XCTAssertEqual(done, "Your BedJet's three slots are full. Pick one to reuse in Lull.")
        XCTAssertTrue(bedJet.needsSlotChoice)
        XCTAssertNil(bedJet.run)
    }

    func testActionsOneAfterAnotherEachReachTheBedJet() async throws {
        let (model, bedJet) = try await backgrounded(mine)
        // Over Bluetooth, the connection one action lets go of takes a moment to drop, while the next starts at once.
        unit(mine.id).dropsSlowly = true
        _ = try await model.perform(.air(AirSettings(mode: .heat)), on: bedJet)
        let fan = try await model.perform(.air(AirSettings(fanPercent: 70)), on: bedJet)
        XCTAssertEqual(fan, "Set the fan on BEDJET_3 to 70%.")
        let runTime = try await model.perform(.air(AirSettings(minutes: 55)), on: bedJet)
        XCTAssertEqual(runTime, "BEDJET_3 turns off in 55 min.")
        XCTAssertTrue(unit(mine.id).sent.contains(Codec.setFan(step: 13)))
    }

    func testTurnOffEndsTheNightOrStopsTheAir() async throws {
        let (model, bedJet) = try await backgrounded(mine)
        _ = try await model.perform(.startNight(schedule: nil), on: bedJet)
        var done = try await model.perform(.turnOff, on: bedJet)
        XCTAssertEqual(done, "Ended “Cool Drift” on BEDJET_3.")
        XCTAssertNil(bedJet.run)
        done = try await model.perform(.turnOff, on: bedJet)
        XCTAssertEqual(done, "BEDJET_3 is already off.")
        let airOff = await failure { try await model.perform(.air(AirSettings(fanPercent: 50)), on: bedJet) }
        XCTAssertEqual(airOff, AutomationError.airOff.errorDescription)

        done = try await model.perform(.air(AirSettings(mode: .cool)), on: bedJet)
        XCTAssertEqual(done, "Turned on Cool on BEDJET_3.")
        done = try await model.perform(.air(AirSettings(fanPercent: 52)), on: bedJet)
        XCTAssertEqual(done, "Set the fan on BEDJET_3 to 50%.")
        XCTAssertTrue(unit(mine.id).sent.contains(Codec.setFan(step: 9)))
        done = try await model.perform(.turnOff, on: bedJet)
        XCTAssertEqual(done, "Turned off BEDJET_3.")
        XCTAssertTrue(unit(mine.id).sent.contains(try XCTUnwrap(Codec.setMode(.standby))))
        XCTAssertNil(model.errorMessage)
    }

    func testAV2RefusesAModeItCantRunFromAnAction() async throws {
        setups[mine.id] = { $0.generation = .v2 }
        let (model, bedJet) = try await backgrounded(mine)
        let sentBefore = unit(mine.id).sent
        let message = await failure { try await model.perform(.air(AirSettings(mode: .dry)), on: bedJet) }
        XCTAssertEqual(message, "BEDJET_3 is a BedJet V2, which can't run Dry.")
        XCTAssertEqual(unit(mine.id).sent, sentBefore)
    }

    func testTurnOnRunsAsLongAsAllowedRatherThanToATimePickedEarlier() async throws {
        let model = launch()
        model.remoteTimerShowsTime = true
        model.choose(mine)
        let bedJet = try await connected(mine, in: model)
        await bedJet.setMode(.cool)
        await bedJet.setRuntime(until: Date().addingTimeInterval(30 * 60))
        XCTAssertTrue(bedJet.remoteTimer.isAhead)
        model.appMovedToBackground()
        try await waitUntil("\(mine.name) to be let go") { !bedJet.isConnected }

        _ = try await model.perform(.air(AirSettings(mode: .heat)), on: bedJet)
        XCTAssertEqual(bedJet.remoteTimer, .longest)
    }

    func testTheRunTimeIsLeftToARunningSchedule() async throws {
        let (model, bedJet) = try await backgrounded(mine)
        _ = try await model.perform(.startNight(schedule: nil), on: bedJet)
        let sentBefore = unit(mine.id).sent
        let message = await failure { try await model.perform(.air(AirSettings(minutes: 30)), on: bedJet) }
        XCTAssertEqual(message, AutomationError.scheduleSetsTiming.errorDescription)
        XCTAssertEqual(unit(mine.id).sent, sentBefore)
        XCTAssertNotNil(bedJet.run)
        XCTAssertNil(model.errorMessage)
    }
}
