import BedJetKit
import Foundation
import Observation

/// What is kept of a BedJet between launches.
struct SavedBedJet: Codable {
    var id = UUID()
    /// The Bluetooth identity of the unit this BedJet always connects to.
    var unit: UUID?
    var name: String?
    var nickname: String?
    /// Nil until the unit has said what it is.
    var generation: Generation?
    var tonightID: Schedule.ID?
    var run: ActiveRun?
    var slot: Int?
    /// The Wi-Fi network Lull last gave a BedJet 3. Never the password.
    var wifiNetwork: String?
}

/// A BedJet 3 using its Wi-Fi because Lull asked: to join a network, or to check for newer firmware.
struct WiFiActivity: Equatable {
    enum Purpose { case joining, updating }

    var purpose: Purpose
    /// What the BedJet is doing, until it's over.
    var step = "Asking your BedJet…"
    /// How it went, once it's over.
    var outcome: String?
    var failed = false
    /// Installing new firmware, so the version is read again once the BedJet is back.
    var awaitsRestart = false
    /// Not back ten minutes after it began installing, so no longer said to be restarting.
    var restartOverdue = false
    /// When the BedJet was asked, which tells this activity from a later one.
    let startedAt = Date()

    var isRunning: Bool { outcome == nil }
}

/// One BedJet Lull knows: its connection, what it reports, the schedule running on it and what it did.
@MainActor
@Observable
final class BedJet: Identifiable {
    let id: UUID
    let isDemo: Bool
    /// The Bluetooth identity of the unit picked for this BedJet. Lull never connects it to another.
    let unit: UUID?
    /// The name the BedJet gives itself, kept so it can be shown while the BedJet is away.
    private(set) var name: String?
    /// A name given on this phone, such as "My side". The BedJet itself isn't renamed.
    var nickname: String? { didSet { app?.save() } }
    var displayName: String {
        if let nickname = nickname?.trimmingCharacters(in: .whitespaces), !nickname.isEmpty { return nickname }
        return name ?? "BedJet"
    }
    private(set) var linkState: LinkState = .searching
    private(set) var status: DeviceStatus?
    /// When `status` arrived. It is kept while another phone has the BedJet or Lull is off screen, so it ages.
    private(set) var statusReceivedAt: Date?
    /// The BedJet's own settings from its latest full report: light ring, beeps, a running program. A report's
    /// second half arrives separately, and not at all for a moment after reconnecting, so this keeps the last one
    /// rather than letting what's shown from it flicker away.
    private(set) var settings: DeviceStatus.Extra?
    private(set) var firmware: String?
    /// The kind of BedJet, kept so schedules can be edited for it while it is away. Nil until it has said.
    private(set) var knownGeneration: Generation?
    var generation: Generation { knownGeneration ?? .v3 }
    /// What is saved in the BedJet's three program slots.
    private(set) var deviceSlots: [StoredProgram?] = []

    var tonightID: Schedule.ID? { didSet { app?.save() } }
    private(set) var run: ActiveRun? { didSet { app?.save() } }
    /// The BedJet slot this app keeps tonight's schedule in.
    private(set) var slot: Int? { didSet { app?.save() } }

    /// What the BedJet did, oldest first, so the morning after can be checked against how the night felt.
    private(set) var history: [HistoryEntry] = []
    var nights: [Night] { Night.group(history) }

    /// Set once Lull has looked for the BedJet for a while without reaching it, to suggest what to check.
    private(set) var isSlowToFind = false
    /// Commands under way. More than one can be, such as a Remote change while an action from Shortcuts runs.
    private var commandsUnderWay = 0
    var isBusy: Bool { commandsUnderWay > 0 }
    /// Set as Lull lets go of a connected BedJet, until the link says it has. Over Bluetooth that takes a moment, and until
    /// then the link still says it's ready, though nothing sent on it arrives.
    @ObservationIgnored private var isLettingGo = false
    /// A schedule is being written to the BedJet, which takes several steps.
    /// Its Live Activity holds still while this is set, and moves on to the night as soon as it clears.
    private(set) var isSavingSchedule = false { didSet { app?.publishLiveActivities() } }
    /// Set when every slot on the BedJet is taken and the user has to pick one to reuse.
    var needsSlotChoice = false
    /// The BedJet using its Wi-Fi because Lull asked, and how that went. One at a time.
    private(set) var wifiActivity: WiFiActivity?
    /// Set when the BedJet says newer firmware is available, until it has been asked to check.
    private(set) var updateAvailable = false
    /// The Wi-Fi network Lull last gave the BedJet, kept to show it: a BedJet can't be asked which network it has.
    private(set) var wifiNetwork: String? { didSet { app?.save() } }

    @ObservationIgnored private weak var app: AppModel?
    private var link: BedJetLink?
    private var lastRefresh = Date.distantPast
    /// How air from the Remote is timed. Schedules keep their own timing.
    private(set) var remoteTimer = RemoteTimer.longest
    private var searchTimer: Task<Void, Never>?
    /// What the history last recorded the BedJet doing, kept across launches to notice what changed while Lull was closed.
    private var lastSeen: Seen?
    /// The latest report, waiting to settle before it is compared with `lastSeen`.
    private var observed: Seen?
    private var settling: Task<Void, Never>?
    private var connectedAt = Date.distantPast
    private var lastCommandAt = Date.distantPast
    /// When this phone last turned the BedJet off, to tell a report sent just before that from one sent after.
    private var turnedOffAt: Date?
    /// How long after Off a report saying the BedJet is still running is taken to have been sent before it.
    static var staleReportWindow: TimeInterval = 2
    /// How long a BedJet installing an update is expected back from restarting. Tests wait less.
    static var restartPatience: TimeInterval = 600
    private var acknowledgingUpdate = false

    var saved: SavedBedJet {
        SavedBedJet(id: id, unit: unit, name: name, nickname: nickname, generation: knownGeneration, tonightID: tonightID, run: run, slot: slot,
                    wifiNetwork: wifiNetwork)
    }

    var tonight: Schedule? {
        guard let schedules = app?.schedules else { return nil }
        return schedules.first { $0.id == tonightID } ?? schedules.first
    }

    var isConnected: Bool { linkState == .ready }
    /// Controls stay live while connecting or while another phone has the BedJet: what is tapped
    /// is sent the moment the connection is up.
    var canControl: Bool { linkState != .bluetoothOff && linkState != .unauthorized }
    /// A schedule is running on the BedJet that this phone didn't start, for example from a partner's phone.
    var runningElsewhereStep: Int? {
        guard run == nil, let step = status?.extra?.programStep, step > 0 else { return nil }
        return step
    }

    init(_ saved: SavedBedJet, isDemo: Bool, app: AppModel) {
        id = saved.id
        self.isDemo = isDemo
        unit = saved.unit
        name = saved.name
        nickname = saved.nickname
        knownGeneration = saved.generation
        tonightID = saved.tonightID
        run = saved.run.flatMap { $0.endsAt > Date() ? $0 : nil }
        slot = saved.slot
        wifiNetwork = saved.wifiNetwork
        self.app = app
        loadHistory()
        if let ended = saved.run, run == nil {
            record(.scheduleEnded(name: ended.schedule.name, ending: .finished), at: ended.endsAt)
        }
    }

    // MARK: Connection

    /// Starts talking to the BedJet. Only the one on screen asks another phone to hand it over;
    /// the rest connect whenever they are free. Off screen (`resuming: false`) the link is only set up, to start once
    /// Lull comes on screen or an errand from the watch needs it.
    func connect(asking: Bool, resuming: Bool = true) {
        link?.stop()
        status = nil
        settings = nil
        firmware = nil
        deviceSlots = []
        guard let app else { return }
        let link = app.makeLink(for: self)
        // Never hand the BedJet to another phone halfway through saving a schedule, or while it uses its Wi-Fi.
        (link as? BLELink)?.canYield = { [weak self] in self?.isBusy != true && self?.wifiActivity?.isRunning != true }
        link.onStateChange = { [weak self] state in self?.linkStateChanged(state) }
        link.onStatus = { [weak self] status in self?.statusChanged(status) }
        self.link = link
        linkState = link.state
        lastRefresh = .distantPast
        if resuming { resume(asking: asking) }
    }

    /// The BedJet talks to one phone at a time, so it is released whenever Lull leaves the screen, and as soon as
    /// an errand or action that reached it from the background is done. Holding on to it would make coming back
    /// instant, but a phone that is off screen cannot be relied on to hear another phone asking for the BedJet.
    func pause() {
        if linkState == .ready { isLettingGo = true }
        link?.stop()
        // A change still settling would otherwise wait until Lull is opened again.
        if settling != nil { commitObserved() }
        saveHistory()
    }

    func resume(asking: Bool) {
        if asking { link?.start() } else { link?.listen() }
        restartSearchTimer()
    }

    private func restartSearchTimer() {
        searchTimer?.cancel()
        searchTimer = nil
        isSlowToFind = false
        timeSearch()
    }

    /// Whether the BedJet has reported everything it does since `date`, both halves of its report, so what it's doing
    /// now is known rather than what Lull last saw.
    func hasReported(since date: Date) -> Bool {
        guard let statusReceivedAt, statusReceivedAt >= date else { return false }
        return status?.extra != nil
    }

    /// Waits for the BedJet to say what it's doing, so an errand from the watch acts on that. Gives up after `timeout`,
    /// leaving the errand's own commands to say what's wrong.
    func awaitReport(since date: Date, timeout: TimeInterval = 10) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !hasReported(since: date) {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Counts how long Lull has been looking, across searching and connecting, but not while
    /// another phone has the BedJet or Bluetooth is unavailable, which already say what is wrong.
    private func timeSearch() {
        guard linkState == .searching || linkState == .connecting else {
            searchTimer?.cancel()
            searchTimer = nil
            isSlowToFind = false
            return
        }
        guard searchTimer == nil else { return }
        searchTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            // A BedJet restarts to check for firmware and again to install it, which takes a while, and the tips would
            // suggest unplugging it, so they wait longer.
            if self?.expectsRestart == true { try? await Task.sleep(for: .seconds(165)) }
            guard !Task.isCancelled else { return }
            self?.isSlowToFind = true
        }
    }

    private func linkStateChanged(_ state: LinkState) {
        linkState = state
        if state != .ready { isLettingGo = false }
        timeSearch()
        guard state == .ready, let link else { return }
        connectedAt = Date()
        knownGeneration = link.generation
        app?.save()
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
                name = try await link.deviceName()
                app?.save()
                let previous = firmware
                firmware = try await link.firmwareVersion()
                if wifiActivity?.awaitsRestart == true, let firmware {
                    // Worded as when the update is over before the link is lost, if the version did change.
                    wifiActivity?.outcome = previous != nil && firmware != previous
                        ? "Your BedJet updated its firmware to \(firmware)."
                        : "Your BedJet restarted with firmware \(firmware)."
                    wifiActivity?.awaitsRestart = false
                }
                try await refreshSlots()
                lastRefresh = Date()
            } catch {
                // Status keeps streaming without these; they are retried on the next connection.
            }
        }
    }

    private func statusChanged(_ status: DeviceStatus) {
        // The BedJet reports every second, so a report it sent just before it took Off can arrive just after. Shown, it
        // would put the air back on outside Lull, where it stays if Lull lets go of the BedJet before the next report.
        if let turnedOffAt, status.isRunning, Date().timeIntervalSince(turnedOffAt) < Self.staleReportWindow { return }
        turnedOffAt = nil
        self.status = status
        statusReceivedAt = Date()
        if let extra = status.extra { settings = extra }
        observe(status)
        app?.publishLiveActivities()
        app?.publishWidgets()
        noticeUpdate(status)
        guard let run else { return }
        let settled = Date().timeIntervalSince(run.startedAt) > 15
        let programStopped = status.mode == .standby && status.extra?.programStep == 0
        guard Date() >= run.endsAt || (settled && programStopped) else { return }
        self.run = nil
        // Lull lets go of the BedJet overnight, so it only learns about an early stop on the next connection.
        // Nothing on this phone asked for it, so say so and keep the unit's reason code for diagnosis.
        let minutesEarly = Int(run.endsAt.timeIntervalSinceNow / 60)
        guard !isBusy else { return }
        if minutesEarly > 2 {
            record(.scheduleEnded(name: run.schedule.name, ending: .early(minutes: minutesEarly)), noticedLater: isJustConnected)
        } else {
            record(.scheduleEnded(name: run.schedule.name, ending: .finished), at: min(run.endsAt, Date()))
        }
        if minutesEarly > 2 {
            app?.report("Your BedJet turned off \(Format.duration(minutesEarly)) before tonight's schedule ended "
                + "(BedJet reason \(status.lastShutdownReason)).", from: self)
        }
    }

    private func refreshSlots() async throws {
        guard let link else { return }
        deviceSlots = try await link.storedPrograms()
        // Keep a copy of programs made elsewhere so reusing a slot never loses them.
        for (index, program) in deviceSlots.enumerated() where index != slot {
            guard let program else { continue }
            app?.keepCopy(of: program)
        }
    }

    // MARK: Tonight

    func startTonight() async {
        guard let schedule = tonight, link != nil else { return }
        isSavingSchedule = true
        defer { isSavingSchedule = false }
        await perform { try await self.startSchedule(schedule, choosingSlot: true) }
    }

    /// Saves a schedule into Lull's slot on the BedJet and starts it. When every slot is taken, the person picks
    /// one to reuse; without anyone there to pick, as in an automation, that is an error instead.
    private func startSchedule(_ schedule: Schedule, choosingSlot: Bool) async throws {
        let link = try connectedLink()
        // Demos that show a night in progress pretend it started earlier.
        let elapsed = link is DemoLink ? AppModel.demoElapsedMinutes : 0
        let startedAt = Date().addingTimeInterval(TimeInterval(-elapsed * 60))
        // Known for certain once connected, which `carryOut` waited for; checked before anything is written.
        if let problem = problem(running: schedule, at: startedAt) { throw BedJetError.invalidProgram(problem) }
        // With a wake time, every phase is scaled to end at it from now. A BedJet 3 is still given the wake time itself for
        // the last step, so it keeps to it by its own clock.
        let tonight = schedule.resolved(startingAt: Format.minuteOfDay(startedAt))
        // A V2 holds just the one sequence, which Lull always replaces.
        let slot: Int
        if link.generation == .v2 {
            slot = 0
        } else {
            if deviceSlots.isEmpty { try await refreshSlots() }
            guard let free = self.slot ?? deviceSlots.firstIndex(of: nil) else {
                guard choosingSlot else { throw AutomationError.slotsFull }
                needsSlotChoice = true
                return
            }
            slot = free
            self.slot = slot
        }
        try await link.store(tonight.program, slot: slot)
        try await link.startProgram(slot: slot)
        try await confirmStarted()
        run = ActiveRun(schedule: tonight, startedAt: startedAt)
        remoteTimer = .longest
        record(.scheduleStarted(name: schedule.name, phases: tonight.phases))
        if elapsed > 0, let demo = link as? DemoLink { demo.skipAhead(minutes: elapsed) }
        try? await refreshSlots()
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
        guard link != nil else { return }
        await perform { try await self.stopNight() }
    }

    private func stopNight() async throws {
        let link = try connectedLink()
        let name = run?.schedule.name
        try await link.setMode(.standby)
        run = nil
        record(.scheduleEnded(name: name, ending: .byYou))
    }

    // MARK: Remote

    func setMode(_ mode: Mode) async {
        guard link != nil else { return }
        // Shown as a time, the end on screen holds across modes: a time picked here, or the BedJet's own countdown, as
        // after Lull relaunches and no longer knows a time was picked.
        if app?.remoteTimerShowsTime == true, mode != .standby, !remoteTimer.isAhead, run == nil, runningElsewhereStep == nil,
           let status, status.isRunning, status.remainingSeconds > 60 {
            remoteTimer = .until(Date().addingTimeInterval(TimeInterval(status.remainingSeconds)))
        }
        await perform { try await self.changeMode(to: mode) }
    }

    func setTemperature(_ halfCelsius: Int) async {
        guard link != nil else { return }
        await perform { try await self.changeTemperature(to: halfCelsius) }
    }

    func setFan(percent: Int) async {
        guard link != nil else { return }
        await perform { try await self.changeFan(to: percent) }
    }

    func setRuntime(minutes: Int) async {
        guard link != nil else { return }
        await perform { try await self.changeRuntime(to: minutes) }
    }

    private func changeMode(to mode: Mode) async throws {
        let link = try connectedLink()
        // Captured first: the BedJet's report that the schedule stopped can clear `run` before this returns.
        let endingSchedule = run?.schedule.name
        try await link.setMode(mode)
        // The BedJet only says it's off in its next report, and Lull may have let go of it by then, leaving it shown
        // as running outside Lull. The BedJet took the command, so it is off already; setting `run` publishes it.
        if mode == .standby { status?.mode = .standby }
        turnedOffAt = mode == .standby ? Date() : nil
        run = nil
        if let endingSchedule { record(.scheduleEnded(name: endingSchedule, ending: .byYou)) }
        // A time picked on the Remote holds across modes until it passes, while the Remote shows the time. Otherwise each
        // mode starts at its longest run, as the timer always has.
        if mode == .standby || !remoteTimer.isAhead || app?.remoteTimerShowsTime != true { remoteTimer = .longest }
        try await extendRuntime(entering: mode)
    }

    private func changeTemperature(to halfCelsius: Int) async throws {
        try await connectedLink().setTemperature(halfCelsius)
        try await extendRuntime()
    }

    private func changeFan(to percent: Int) async throws {
        try await connectedLink().setFan(step: percent / 5 - 1)
        try await extendRuntime()
    }

    private func changeRuntime(to minutes: Int) async throws {
        remoteTimer = .picked
        try await connectedLink().setRuntime(minutes: minutes)
    }

    /// Turns the air off at `end`, or as near it as the mode allows. Lull keeps aiming at it as the temperature and fan
    /// change, since each changes how long the BedJet lets the air run, and as the mode changes while the Remote shows
    /// the time.
    func setRuntime(until end: Date) async {
        guard let link else { return }
        remoteTimer = .until(end)
        let limit = status.map { $0.maxRuntimeMinutes > 0 ? $0.maxRuntimeMinutes : $0.mode.maxMinutes } ?? Limits.maxStepMinutes
        await perform { try await link.setRuntime(minutes: self.minutes(until: end, limit: limit)) }
    }

    /// Minutes from now until `end`, to the nearest minute, as far as `limit` allows.
    private func minutes(until end: Date, limit: Int) -> Int {
        min(max(Int((end.timeIntervalSinceNow / 60).rounded()), 1), limit)
    }

    /// Air started from the Remote runs for as long as the BedJet allows, or until the time picked there, until a
    /// duration is picked instead. Schedules keep their own timing.
    private func extendRuntime(entering mode: Mode? = nil) async throws {
        // A schedule started from another phone times its own phases; leave its timer alone. Off has no timer.
        guard remoteTimer != .picked, run == nil, runningElsewhereStep == nil, mode != .standby, let link else { return }
        // The limit depends on mode, temperature and fan, and the unit keeps the previous timer when
        // the mode changes, so wait for it to report the new state before reading the limit.
        try await Task.sleep(nanoseconds: 600_000_000)
        for _ in 0..<20 {
            if let status, status.isRunning, status.maxRuntimeMinutes > 0, mode == nil || status.mode == mode {
                if case .until(let end) = remoteTimer, remoteTimer.isAhead {
                    let minutes = minutes(until: end, limit: status.maxRuntimeMinutes)
                    if abs(status.remainingSeconds - minutes * 60) > 60 { try await link.setRuntime(minutes: minutes) }
                } else if status.remainingSeconds <= (status.maxRuntimeMinutes - 1) * 60 {
                    try await link.setRuntime(minutes: status.maxRuntimeMinutes)
                }
                return
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    func setLED(_ on: Bool) async {
        guard link != nil else { return }
        await perform { try await self.connectedLink().setLED(on) }
    }

    func setMuted(_ muted: Bool) async {
        guard link != nil else { return }
        await perform { try await self.connectedLink().setMuted(muted) }
    }

    /// Does what a control asked for, showing anything that goes wrong.
    private func perform(_ work: () async throws -> Void) async {
        do {
            try await carryOut(work)
        } catch is CancellationError {
            // A newer slider move replaced this one; nothing went wrong.
        } catch {
            app?.report(error.localizedDescription, from: self)
        }
    }

    /// Takes control of the BedJet and does the work, one thing at a time. What goes wrong is thrown to the caller.
    private func carryOut<Result>(_ work: () async throws -> Result) async throws -> Result {
        commandsUnderWay += 1
        defer {
            commandsUnderWay -= 1
            lastCommandAt = Date()
        }
        try await takeControl()
        return try await work()
    }

    private func connectedLink() throws -> BedJetLink {
        guard let link else { throw BedJetError.notConnected }
        return link
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

    // MARK: Automation

    /// Restarting into new firmware, going by the clock too: until `restartPatience` after the BedJet was asked to check,
    /// which installs it. The timer that stops expecting the BedJet back only runs while Lull does, so an action that
    /// wakes Lull long after would otherwise find it restarting.
    var isInstallingUpdate: Bool {
        guard isRestarting, let startedAt = wifiActivity?.startedAt else { return false }
        return Date().timeIntervalSince(startedAt) < Self.restartPatience
    }

    /// Reaches the BedJet for an action while Lull is off screen, but only if it is free: an iPhone can't ask another
    /// phone for it from the background, and an automation nobody is watching shouldn't take it from a partner
    /// anyway. Gives up before the link would scan for the unit, which finds nothing in the background.
    /// Waits, for up to `patience`, until a BedJet Lull just let go of has dropped the connection. Shortcuts runs an
    /// action straight after the one before, which let go of the BedJet as it finished; reaching for it before the
    /// connection drops would find the link still ready, and what's sent on it would be lost.
    func waitUntilLetGo(within patience: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(patience)
        while isLettingGo, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
    }

    func reachIfFree(within patience: TimeInterval) async throws {
        resume(asking: false)
        let deadline = Date().addingTimeInterval(patience)
        while Date() < deadline {
            switch linkState {
            case .ready: return
            case .yielded, .bluetoothOff, .unauthorized: throw AutomationError.needsLull
            case .searching, .connecting: try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        throw AutomationError.needsLull
    }

    /// Starts a schedule for an action. A night already under way, from this phone or another, is left running. With every
    /// slot taken, an action that went on in Lull asks which to reuse (`choosingSlot`), as Start Night there does.
    func start(_ schedule: Schedule, choosingSlot: Bool = false) async throws -> Started {
        isSavingSchedule = true
        defer { isSavingSchedule = false }
        return try await carryOutAction {
            if let run = self.run { return .alreadyRunning(run.schedule.name) }
            if self.runningElsewhereStep != nil { return .alreadyRunning(nil) }
            try await self.startSchedule(schedule, choosingSlot: choosingSlot)
            // Not started yet: Lull is asking which slot to reuse.
            return self.run == nil ? .choosingSlot : .now
        }
    }

    /// Sets the air as the Remote would. With a mode it turns the air on in that mode, ending a schedule that is
    /// running; without one it changes the air that is already on. Everything is checked before anything is sent.
    func apply(_ air: AirSettings, fahrenheit: Bool) async throws -> AppliedAir {
        try await carryOutAction {
            let mode = air.mode ?? self.status?.mode ?? .standby
            if let problem = air.mode.flatMap(self.problem(using:)) { throw AutomationError.unsupportedMode(problem) }
            if air.mode == nil {
                guard mode != .standby else { throw AutomationError.airOff }
                if air.degrees != nil, let refusal = Automation.temperatureRefusal(mode: mode, generation: self.generation) { throw refusal }
                // The Remote hides its timer while a schedule runs, since the schedule times its own phases.
                if air.minutes != nil, self.run != nil || self.runningElsewhereStep != nil { throw AutomationError.scheduleSetsTiming }
            }
            var applied = AppliedAir(mode: mode)
            if let wanted = air.mode {
                // Without a run time, Turn On runs as long as the BedJet allows, not until a time once picked on the Remote.
                if air.minutes == nil { self.remoteTimer = .longest }
                try await self.changeMode(to: wanted)
            }
            if let degrees = air.degrees, self.adjustsTemperature(mode) {
                let halfCelsius = Automation.halfCelsius(degrees: degrees, fahrenheit: fahrenheit, mode: mode, status: self.status)
                try await self.changeTemperature(to: halfCelsius)
                applied.temperature = halfCelsius
            }
            if let fan = air.fanPercent {
                let percent = Automation.fanPercent(fan)
                try await self.changeFan(to: percent)
                applied.fanPercent = percent
            }
            if let minutes = air.minutes {
                let runTime = Automation.runTimeMinutes(minutes, mode: mode, status: self.status)
                try await self.changeRuntime(to: runTime)
                applied.minutes = runTime
            }
            return applied
        }
    }

    /// Ends the night if a schedule is running, otherwise turns the air off.
    func turnOff() async throws -> TurnedOff {
        try await carryOutAction {
            if let run = self.run {
                try await self.stopNight()
                return .endedNight(run.schedule.name)
            }
            if self.runningElsewhereStep != nil {
                try await self.stopNight()
                return .endedNight(nil)
            }
            guard self.status?.isRunning == true else { return .alreadyOff }
            try await self.changeMode(to: .standby)
            return .stoppedAir
        }
    }

    func turnLightRing(on: Bool) async throws {
        // A V2 sets the light and the beeps together, so it needs to know the other one first, which the status says.
        try await carryOutAction { try await self.connectedLink().setLED(on) }
    }

    func muteBeeps(_ muted: Bool) async throws {
        try await carryOutAction { try await self.connectedLink().setMuted(muted) }
    }

    /// Does an action's work once the BedJet has said what it is doing now. Its commands would go in among the Wi-Fi
    /// setup's or the update's, so it is refused while those run. That is checked once it holds the BedJet, since one may
    /// have started while it was reaching it, and none starts after. Once the BedJet is installing and away, the action
    /// finds it unreachable as usual, and an update that finished while Lull was closed doesn't hold it up.
    private func carryOutAction<Result>(_ work: () async throws -> Result) async throws -> Result {
        try await carryOut {
            if self.wifiActivity?.isRunning == true { throw AutomationError.updating }
            try await self.awaitStatus()
            return try await work()
        }
    }

    /// Waits for the BedJet's first full report since it connected, which says what it is doing now rather than what Lull
    /// last saw before it let go.
    private func awaitStatus() async throws {
        for _ in 0..<30 {
            if hasReported(since: connectedAt) { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw BedJetError.timeout
    }

    /// What the BedJet is doing as far as Lull knows: live while connected, otherwise as it was last seen.
    var reading: AirReading? {
        if isConnected, let status, let step = status.extra?.programStep {
            return AirReading(mode: status.mode, temperature: status.targetTemperature, fanPercent: status.fanPercent,
                              programStep: step, remainingSeconds: status.remainingSeconds, at: Date())
        }
        return lastSeen.map {
            AirReading(mode: $0.mode, temperature: $0.temperature, fanPercent: $0.fanPercent,
                       programStep: $0.programStep, remainingSeconds: $0.remainingSeconds, at: $0.at)
        }
    }

    // MARK: Wi-Fi and firmware

    /// Updating restarts the BedJet, which would end a schedule partway through the night, or one being saved.
    var updateWaitsForSchedule: Bool { isSavingSchedule || run != nil || runningElsewhereStep != nil }
    var canUpdateFirmware: Bool { canJoinWiFi && !updateWaitsForSchedule }
    var canJoinWiFi: Bool { isConnected && wifiActivity?.isRunning != true }
    /// The BedJet is away because it's checking for or installing firmware, and will be back.
    var expectsRestart: Bool {
        guard let wifiActivity else { return false }
        return wifiActivity.isRunning || (wifiActivity.awaitsRestart && !wifiActivity.restartOverdue)
    }
    /// Away while it restarts, and only that: Bluetooth being off or another phone having it still say so.
    var isRestarting: Bool { expectsRestart && (linkState == .searching || linkState == .connecting) }

    /// Gives the BedJet the Wi-Fi network it fetches firmware over. Lull keeps neither the name nor the password.
    func joinWiFi(network: String, password: String) async {
        await useWiFi(.joining) { link, progress in
            try await link.joinWiFi(network: network, password: password, progress: progress)
            self.wifiNetwork = network
            return "Your BedJet joined “\(network)” and can now check for firmware updates."
        }
    }

    /// Asks the BedJet to check for newer firmware, which it installs straight away.
    func updateFirmware() async {
        // A schedule may have started while the person was confirming.
        guard canUpdateFirmware else { return }
        await useWiFi(.updating) { link, progress in
            switch try await link.updateFirmware(progress: progress) {
            case .upToDate:
                return "Your BedJet's firmware is up to date."
            case .installing:
                // Read again once it's back, to show the new version.
                self.lastRefresh = .distantPast
                self.wifiActivity?.awaitsRestart = true
                self.stopExpectingRestartLater()
                return "Your BedJet is installing the update and restarts when it's done. Keep it plugged in."
            case .updated(let version):
                self.firmware = version
                return "Your BedJet updated its firmware to \(version)."
            }
        }
    }

    private func useWiFi(_ purpose: WiFiActivity.Purpose, _ work: (BedJetLink, (Int) -> Void) async throws -> String) async {
        guard let link, wifiActivity?.isRunning != true else { return }
        wifiActivity = WiFiActivity(purpose: purpose, step: purpose == .updating ? "Asking your BedJet to check…" : "Asking your BedJet…")
        // A command already on its way, such as one from a Shortcuts action, finishes first so the two don't interleave.
        // Actions that come after are refused while this runs.
        while isBusy { try? await Task.sleep(nanoseconds: 200_000_000) }
        do {
            let outcome = try await work(link) { phase in
                if let step = Self.step(phase) { self.wifiActivity?.step = step }
            }
            wifiActivity?.outcome = outcome
            if purpose == .updating { updateAvailable = false }
        } catch {
            wifiActivity?.outcome = error.localizedDescription
            wifiActivity?.failed = true
            wifiActivity?.awaitsRestart = false
        }
    }

    /// A BedJet not back ten minutes after it began installing isn't restarting any more, so from then on it's
    /// said to be away like any other, with the tips for finding it. Its version is still read if it does come back.
    private func stopExpectingRestartLater() {
        guard let startedAt = wifiActivity?.startedAt else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.restartPatience))
            guard let self, wifiActivity?.startedAt == startedAt, wifiActivity?.awaitsRestart == true else { return }
            wifiActivity?.restartOverdue = true
        }
    }

    /// What the BedJet is doing at each step it reports while it uses its Wi-Fi.
    private static func step(_ phase: Int) -> String? {
        switch phase {
        case Codec.WiFiPhase.starting: "Starting…"
        case Codec.WiFiPhase.joining: "Joining Wi-Fi…"
        case Codec.WiFiPhase.joined: "Connected to Wi-Fi…"
        case Codec.WiFiPhase.testing: "Testing the connection…"
        case Codec.WiFiPhase.checking: "Checking for an update…"
        case Codec.WiFiPhase.updating: "Installing the update…"
        case Codec.WiFiPhase.restarting: "Restarting your BedJet to check…"
        default: nil
        }
    }

    /// A BedJet 3 on Wi-Fi checks for firmware by itself now and then, and says when there's newer firmware until
    /// that's acknowledged, as the official app does once it has shown it.
    private func noticeUpdate(_ status: DeviceStatus) {
        guard status.extra?.notification == Codec.Notification.updateAvailable, !acknowledgingUpdate, let link else { return }
        updateAvailable = true
        acknowledgingUpdate = true
        Task {
            try? await link.acknowledgeNotification()
            acknowledgingUpdate = false
        }
    }

    /// Launching with `-logConnections` keeps a record of connection times, so they can be measured on a real phone.
    private static let logsConnections = ProcessInfo.processInfo.arguments.contains("-logConnections")

    private func logConnection() {
        guard Self.logsConnections, let timing = (link as? BLELink)?.lastConnection else { return }
        let line = String(format: "new connection: radio %.0f, link %.0f, services %.0f, usable %.0f ms, %@ (%@)\n",
                          timing.radioOn * 1000, timing.linkUp * 1000, timing.services * 1000, timing.usable * 1000,
                          timing.knownUnit ? "known unit" : "scanned", name ?? "unnamed")
        log(line)
    }

    private func log(_ line: String) {
        let file = URL.documentsDirectory.appending(path: "connections.txt")
        let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        try? (existing + Date().formatted(date: .omitted, time: .standard) + " " + line).write(to: file, atomically: true, encoding: .utf8)
    }

    // MARK: History

    /// The settings worth remembering from a status report. The timer is carried along to tell when it ran out.
    private struct Seen: Codable, Equatable {
        var mode: Mode
        var temperature: Int
        var fanPercent: Int
        var programStep: Int
        var remainingSeconds: Int
        var at: Date

        init(_ status: DeviceStatus, programStep: Int) {
            mode = status.mode
            temperature = status.targetTemperature
            fanPercent = status.fanPercent
            self.programStep = programStep
            remainingSeconds = status.remainingSeconds
            at = Date()
        }

        func sameSettings(as other: Seen) -> Bool {
            mode == other.mode && fanPercent == other.fanPercent && programStep == other.programStep
                && (!mode.usesTemperature || temperature == other.temperature)
        }
    }

    /// The first reports after connecting describe the BedJet as it was left, not something that just happened.
    private var isJustConnected: Bool { Date().timeIntervalSince(connectedAt) < 10 }

    /// Waits for the BedJet to hold a setting for a few seconds, so dragging a slider is one entry, not twenty.
    private func observe(_ status: DeviceStatus) {
        // Whether a schedule is running arrives in the second half of the report; without it a phase
        // change can't be told from a change someone made.
        guard let step = status.extra?.programStep else { return }
        let seen = Seen(status, programStep: step)
        let isNew = observed.map { !seen.sameSettings(as: $0) } ?? true
        observed = seen
        if let lastSeen, seen.sameSettings(as: lastSeen) {
            settling?.cancel()
            settling = nil
            self.lastSeen = seen
            return
        }
        guard isNew || settling == nil else { return }
        settling?.cancel()
        settling = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.commitObserved()
        }
    }

    private func commitObserved() {
        settling?.cancel()
        settling = nil
        guard let now = observed else { return }
        // The first report ever only sets where the history starts from.
        guard let before = lastSeen else {
            lastSeen = now
            return
        }
        lastSeen = now
        let wasAway = before.at < connectedAt && isJustConnected
        switch (before.programStep, now.programStep) {
        case (0, 1...):
            // Started from this phone, it is recorded once the BedJet confirms it.
            if run == nil, !isBusy { record(.scheduleStarted(name: nil, phases: nil), noticedLater: wasAway) }
            return
        // The schedule moved on to its next phase, or ended; its start and end are recorded on their own.
        case (1..., 1...) where before.programStep != now.programStep: return
        case (1..., 0) where now.mode == .standby: return
        default: break
        }
        if now.mode == .standby {
            guard before.mode != .standby else { return }
            let timerEnds = before.at.addingTimeInterval(TimeInterval(before.remainingSeconds))
            let ranOut = lastCommandAt < before.at && (before.remainingSeconds < 120 || (wasAway && timerEnds < Date()))
            record(.off(timerRanOut: ranOut), at: ranOut ? min(timerEnds, Date()) : Date(), noticedLater: wasAway && !ranOut)
        } else {
            record(.air(mode: now.mode, temperature: now.temperature, fanPercent: now.fanPercent), noticedLater: wasAway)
        }
    }

    private func record(_ event: HistoryEntry.Event, at date: Date = Date(), noticedLater: Bool = false) {
        history.append(HistoryEntry(date: date, event: event, room: status?.ambientTemperature, noticedLater: noticedLater))
        if let previous = history.dropLast().last, previous.date > date { history.sort { $0.date < $1.date } }
        // Two months is plenty to compare one season's nights with the next.
        let cutoff = Date().addingTimeInterval(-60 * 86400)
        history.removeAll { $0.date < cutoff }
        saveHistory()
    }

    private struct SavedHistory: Codable {
        var entries: [HistoryEntry]
        var lastSeen: Seen?
    }

    /// Each BedJet keeps its own history, and demo BedJets are separate ones, so pretend nights never mix with real ones.
    private var historyFile: URL? { app?.storage.historyFile(for: id) }

    private func loadHistory() {
        let saved = historyFile.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(SavedHistory.self, from: $0) }
        history = saved?.entries ?? (AppModel.seedsDemoHistory ? HistoryEntry.samples() : [])
        lastSeen = saved?.lastSeen
    }

    private func saveHistory() {
        app?.publishWidgets()
        guard let file = historyFile else { return }
        let saved = SavedHistory(entries: history, lastSeen: lastSeen)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(saved).write(to: file, options: .atomic)
    }

    // MARK: Schedules

    /// Modes the Remote and the phase editor offer for this kind of BedJet.
    var remoteModes: [Mode] { Mode.remoteModes.filter(generation.supports) }
    var phaseModes: [Mode] { Mode.phaseModes.filter(generation.supports) }

    func adjustsTemperature(_ mode: Mode) -> Bool { generation.adjustsTemperature(mode) }

    /// Modes in a schedule that this BedJet can't run. Schedules are shared between BedJets, so one made for a
    /// BedJet 3 may not suit a V2; it is never changed to fit, only refused.
    func unsupportedModes(in schedule: Schedule) -> [Mode] {
        var modes: [Mode] = []
        for phase in schedule.phases where !generation.supports(phase.mode) && !modes.contains(phase.mode) { modes.append(phase.mode) }
        return modes
    }

    /// Why this BedJet can't use a mode, if it can't.
    func problem(using mode: Mode) -> String? {
        guard !generation.supports(mode) else { return nil }
        return "\(displayName) is a BedJet V2, which can't run \(mode.title)."
    }

    /// Why a schedule can't run on this BedJet when started at `date`, if it can't.
    func problem(running schedule: Schedule, at date: Date = Date()) -> String? {
        let modes = unsupportedModes(in: schedule)
        if !modes.isEmpty {
            let names = ListFormatter.localizedString(byJoining: modes.map(\.title))
            return "\(displayName) is a BedJet V2, which can't run \(names). Edit “\(schedule.name)” or pick another schedule for it."
        }
        // Started then, the last phase has to reach the wake time within what BedJet lets it run.
        return schedule.wakeProblem(startingAt: Format.minuteOfDay(date))
    }
}

/// How air started from the Remote is timed.
enum RemoteTimer: Equatable {
    /// As long as the BedJet allows, which depends on the mode, temperature and fan.
    case longest
    /// For a duration picked on the Remote.
    case picked
    /// Until a time picked on the Remote, as far as the mode allows.
    case until(Date)

    /// A time picked on the Remote that hasn't come yet.
    var isAhead: Bool {
        if case .until(let end) = self { return end > Date() }
        return false
    }
}
