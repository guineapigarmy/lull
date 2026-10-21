import BedJetKit
import Foundation
import Observation

/// A schedule that is running on the BedJet right now.
struct ActiveRun: Codable, Equatable {
    var schedule: Schedule
    var startedAt: Date

    var endsAt: Date { startedAt.addingTimeInterval(TimeInterval(schedule.totalMinutes * 60)) }

    func progress(at date: Date) -> Double {
        min(max(date.timeIntervalSince(startedAt) / max(endsAt.timeIntervalSince(startedAt), 1), 0), 1)
    }

    func phase(at date: Date) -> (phase: Phase, index: Int, minutesLeft: Int)? {
        var elapsed = Int(date.timeIntervalSince(startedAt) / 60)
        for (index, phase) in schedule.phases.enumerated() {
            if elapsed < phase.minutes { return (phase, index, phase.minutes - elapsed) }
            elapsed -= phase.minutes
        }
        return nil
    }
}

@MainActor
@Observable
final class AppModel {
    private(set) var linkState: LinkState = .searching
    private(set) var status: DeviceStatus?
    private(set) var deviceName: String?
    private(set) var firmware: String?
    /// The kind of BedJet last connected, remembered so schedules can be edited for it while it is away.
    private(set) var generation: Generation {
        didSet { UserDefaults.standard.set(generation.rawValue, forKey: "generation") }
    }
    /// What is saved in the BedJet's three program slots.
    private(set) var deviceSlots: [StoredProgram?] = []

    var schedules: [Schedule] = [] { didSet { save() } }
    var tonightID: Schedule.ID? { didSet { save() } }
    private(set) var run: ActiveRun? { didSet { save() } }
    /// The BedJet slot this app keeps tonight's schedule in.
    private(set) var slot: Int? { didSet { save() } }

    var useFahrenheit: Bool { didSet { UserDefaults.standard.set(useFahrenheit, forKey: "useFahrenheit") } }
    var demoMode: Bool { didSet { UserDefaults.standard.set(demoMode, forKey: "demoMode"); reconnect() } }

    /// Set once Lull has looked for the BedJet for a while without reaching it, to suggest what to check.
    private(set) var isSlowToFind = false
    private(set) var isBusy = false
    var errorMessage: String?
    /// Set when every slot on the BedJet is taken and the user has to pick one to reuse.
    var needsSlotChoice = false

    private var link: BedJetLink?
    private var lastRefresh = Date.distantPast
    private var keepsLongestRuntime = true
    private var isLoaded = false
    private var searchTimer: Task<Void, Never>?

    var tonight: Schedule? { schedules.first { $0.id == tonightID } ?? schedules.first }
    var isConnected: Bool { linkState == .ready }
    /// Controls stay live while connecting or while another phone has the BedJet: what is tapped
    /// is sent the moment the connection is up.
    var canControl: Bool { linkState != .bluetoothOff && linkState != .unauthorized }
    /// A schedule is running on the BedJet that this phone didn't start, for example from a partner's phone.
    var runningElsewhereStep: Int? {
        guard run == nil, let step = status?.extra?.programStep, step > 0 else { return nil }
        return step
    }

    init() {
        let defaults = UserDefaults.standard
        useFahrenheit = defaults.object(forKey: "useFahrenheit") as? Bool ?? (Locale.current.measurementSystem == .us)
        generation = defaults.string(forKey: "generation").flatMap(Generation.init) ?? .v3
        #if targetEnvironment(simulator)
        demoMode = true
        #else
        demoMode = defaults.bool(forKey: "demoMode")
        #endif
        load()
        reconnect()
    }

    // MARK: Connection

    private func reconnect() {
        link?.stop()
        status = nil
        deviceName = nil
        firmware = nil
        deviceSlots = []
        let link: BedJetLink = demoMode
            ? DemoLink(slots: [StoredProgram(name: "Summer nights", steps: Schedule.templates[2].program.steps), nil, nil])
            : BLELink()
        link.onStateChange = { [weak self] state in self?.linkStateChanged(state) }
        link.onStatus = { [weak self] status in self?.statusChanged(status) }
        // Never hand the BedJet to another phone halfway through saving a schedule.
        (link as? BLELink)?.canYield = { [weak self] in self?.isBusy != true }
        self.link = link
        linkState = link.state
        lastRefresh = .distantPast
        link.start()
        restartSearchTimer()
    }

    private func restartSearchTimer() {
        searchTimer?.cancel()
        searchTimer = nil
        isSlowToFind = false
        timeSearch()
    }

    /// Counts how long Lull has been looking, across searching and connecting, but not while
    /// another phone has the BedJet or Bluetooth is unavailable, which already say what is wrong.
    private func timeSearch() {
        guard !demoMode, linkState == .searching || linkState == .connecting else {
            searchTimer?.cancel()
            searchTimer = nil
            isSlowToFind = false
            return
        }
        guard searchTimer == nil else { return }
        searchTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            self?.isSlowToFind = true
        }
    }

    /// The BedJet talks to one phone at a time, so it is released whenever Lull leaves the screen.
    /// Holding on to it would make coming back instant, but a phone that is off screen cannot be
    /// relied on to hear another phone asking for the BedJet.
    func appMovedToBackground() {
        link?.stop()
    }

    func appBecameActive() {
        link?.start()
        restartSearchTimer()
    }

    func forgetDevice() {
        (link as? BLELink)?.forget()
        slot = nil
    }

    private func linkStateChanged(_ state: LinkState) {
        linkState = state
        timeSearch()
        guard state == .ready, let link else { return }
        generation = link.generation
        logConnection()
        // Phones take turns with the BedJet, so reconnecting is routine; what is saved on it
        // only needs re-reading now and then.
        guard Date().timeIntervalSince(lastRefresh) > 300 else { return }
        Task {
            // Anything the person tapped while connecting goes first.
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            while isBusy { try? await Task.sleep(nanoseconds: 200_000_000) }
            guard link.state == .ready else { return }
            do {
                try await link.syncClock()
                deviceName = try await link.deviceName()
                firmware = try await link.firmwareVersion()
                try await refreshSlots()
                lastRefresh = Date()
            } catch {
                // Status keeps streaming without these; they are retried on the next connection.
            }
        }
    }

    private func statusChanged(_ status: DeviceStatus) {
        self.status = status
        guard let run else { return }
        let settled = Date().timeIntervalSince(run.startedAt) > 15
        let programStopped = status.mode == .standby && status.extra?.programStep == 0
        guard Date() >= run.endsAt || (settled && programStopped) else { return }
        self.run = nil
        // Lull lets go of the BedJet overnight, so it only learns about an early stop on the next connection.
        // Nothing on this phone asked for it, so say so and keep the unit's reason code for diagnosis.
        let minutesEarly = Int(run.endsAt.timeIntervalSinceNow / 60)
        if !isBusy, minutesEarly > 2 {
            errorMessage = "Your BedJet turned off \(Format.duration(minutesEarly)) before tonight's schedule ended "
                + "(BedJet reason \(status.lastShutdownReason))."
        }
    }

    private func refreshSlots() async throws {
        guard let link else { return }
        deviceSlots = try await link.storedPrograms()
        // Keep a copy of programs made elsewhere so reusing a slot never loses them.
        for (index, program) in deviceSlots.enumerated() where index != slot {
            guard let program else { continue }
            let imported = Schedule(importing: program)
            if !schedules.contains(where: { $0.phases.map(\.step) == imported.phases.map(\.step) }) {
                schedules.append(imported)
            }
        }
    }

    // MARK: Tonight

    func startTonight() async {
        guard let schedule = tonight, let link else { return }
        await perform {
            // A V2 holds just the one sequence, which Lull always replaces.
            let slot: Int
            if link.generation == .v2 {
                slot = 0
            } else {
                if self.deviceSlots.isEmpty { try await self.refreshSlots() }
                guard let free = self.slot ?? self.deviceSlots.firstIndex(of: nil) else {
                    self.needsSlotChoice = true
                    return
                }
                slot = free
                self.slot = slot
            }
            try await link.store(schedule.program, slot: slot)
            try await link.startProgram(slot: slot)
            try await self.confirmStarted()
            self.run = ActiveRun(schedule: schedule, startedAt: Date())
            if let demo = link as? DemoLink, Self.demoElapsedMinutes > 0 {
                demo.skipAhead(minutes: Self.demoElapsedMinutes)
                self.run?.startedAt = Date().addingTimeInterval(TimeInterval(-Self.demoElapsedMinutes * 60))
            }
            try? await self.refreshSlots()
        }
    }

    /// A BedJet that can't run a schedule stays off and raises a notification instead of starting it.
    private func confirmStarted() async throws {
        guard let link else { return }
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 200_000_000)
            guard let extra = status?.extra else { continue }
            if extra.programStep > 0 { return }
            let refusal: BedJetError? = switch extra.notification {
            case Codec.Notification.programNeedsClock: .clockNotSet
            case Codec.Notification.programTooLong: .programTooLong
            default: nil
            }
            if let refusal {
                try? await link.acknowledgeNotification()
                throw refusal
            }
        }
    }

    func startTonight(replacingSlot slot: Int) async {
        self.slot = slot
        await startTonight()
    }

    func endNight() async {
        guard let link else { return }
        await perform {
            try await link.setMode(.standby)
            self.run = nil
        }
    }

    // MARK: Remote

    func setMode(_ mode: Mode) async {
        guard let link else { return }
        await perform {
            try await link.setMode(mode)
            self.run = nil
            self.keepsLongestRuntime = true
            try await self.extendRuntime(entering: mode)
        }
    }

    func setTemperature(_ halfCelsius: Int) async {
        guard let link else { return }
        await perform {
            try await link.setTemperature(halfCelsius)
            try await self.extendRuntime()
        }
    }

    func setFan(percent: Int) async {
        guard let link else { return }
        await perform {
            try await link.setFan(step: percent / 5 - 1)
            try await self.extendRuntime()
        }
    }

    func setRuntime(minutes: Int) async {
        guard let link else { return }
        keepsLongestRuntime = false
        await perform { try await link.setRuntime(minutes: minutes) }
    }

    /// Air started from the Remote runs for as long as the BedJet allows, until a shorter time is
    /// picked there. Schedules keep their own timing.
    private func extendRuntime(entering mode: Mode? = nil) async throws {
        // A schedule started from another phone times its own phases; leave its timer alone.
        guard keepsLongestRuntime, run == nil, runningElsewhereStep == nil, let link else { return }
        // The limit depends on mode, temperature and fan, and the unit keeps the previous timer when
        // the mode changes, so wait for it to report the new state before reading the limit.
        try await Task.sleep(nanoseconds: 600_000_000)
        for _ in 0..<20 {
            if let status, status.isRunning, status.maxRuntimeMinutes > 0, mode == nil || status.mode == mode {
                if status.remainingSeconds <= (status.maxRuntimeMinutes - 1) * 60 {
                    try await link.setRuntime(minutes: status.maxRuntimeMinutes)
                }
                return
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    func setLED(_ on: Bool) async {
        guard let link else { return }
        await perform { try await link.setLED(on) }
    }

    func setMuted(_ muted: Bool) async {
        guard let link else { return }
        await perform { try await link.setMuted(muted) }
    }

    private func perform(_ work: () async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await takeControl()
            try await work()
        } catch is CancellationError {
            // A newer slider move replaced this one; nothing went wrong.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Using a control while another phone has the BedJet asks that phone to hand it over first.
    private func takeControl() async throws {
        guard let link, link.state != .ready else { return }
        let wasElsewhere = link.state == .yielded
        link.requestControl()
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
            if link.state == .ready { return }
        }
        throw wasElsewhere ? BedJetError.inUseElsewhere : BedJetError.notConnected
    }

    /// Launching with `-logConnections` keeps a record of connection times, so they can be measured on a real phone.
    private static let logsConnections = ProcessInfo.processInfo.arguments.contains("-logConnections")

    private func logConnection() {
        guard Self.logsConnections, let timing = (link as? BLELink)?.lastConnection else { return }
        let line = String(format: "new connection: radio %.0f, link %.0f, services %.0f, usable %.0f ms, %@\n",
                          timing.radioOn * 1000, timing.linkUp * 1000, timing.services * 1000, timing.usable * 1000,
                          timing.knownUnit ? "known unit" : "scanned")
        log(line)
    }

    private func log(_ line: String) {
        let file = URL.documentsDirectory.appending(path: "connections.txt")
        let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        try? (existing + Date().formatted(date: .omitted, time: .standard) + " " + line).write(to: file, atomically: true, encoding: .utf8)
    }

    // MARK: Schedules

    /// Modes the Remote and the phase editor offer for this kind of BedJet.
    var remoteModes: [Mode] { Mode.remoteModes.filter(generation.supports) }
    var phaseModes: [Mode] { Mode.phaseModes.filter(generation.supports) }

    func adjustsTemperature(_ mode: Mode) -> Bool { generation.adjustsTemperature(mode) }

    func save(_ schedule: Schedule) {
        if let index = schedules.firstIndex(where: { $0.id == schedule.id }) {
            schedules[index] = schedule
        } else {
            schedules.append(schedule)
        }
    }

    func delete(_ schedule: Schedule) {
        schedules.removeAll { $0.id == schedule.id }
        if tonightID == schedule.id { tonightID = schedules.first?.id }
    }

    func degrees(_ halfCelsius: Int) -> String {
        "\(Format.degrees(halfCelsius, fahrenheit: useFahrenheit))°"
    }

    // MARK: Persistence

    private struct Saved: Codable {
        var schedules: [Schedule]
        var tonightID: Schedule.ID?
        var run: ActiveRun?
        var slot: Int?
    }

    private static let file = URL.applicationSupportDirectory.appending(path: "lull.json")
    /// Launching with `-demoLabelConnected` shows the simulated BedJet as connected, for listing screenshots.
    static let labelsDemoAsConnected = ProcessInfo.processInfo.arguments.contains("-demoLabelConnected")
    /// Launching with `-demoElapsedMinutes 200` makes a night started in demo mode appear that far along.
    private static let demoElapsedMinutes = UserDefaults.standard.integer(forKey: "demoElapsedMinutes")
    /// UI tests launch with this flag so every run starts from the built-in schedules.
    private static let isEphemeral = ProcessInfo.processInfo.arguments.contains("-ephemeral")

    private func load() {
        if !Self.isEphemeral, let data = try? Data(contentsOf: Self.file), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            schedules = saved.schedules
            tonightID = saved.tonightID
            run = saved.run.flatMap { $0.endsAt > Date() ? $0 : nil }
            slot = saved.slot
        } else {
            schedules = Schedule.templates
            tonightID = schedules.first?.id
        }
        isLoaded = true
    }

    private func save() {
        guard isLoaded, !Self.isEphemeral else { return }
        let saved = Saved(schedules: schedules, tonightID: tonightID, run: run, slot: slot)
        try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(saved).write(to: Self.file, options: .atomic)
    }
}
