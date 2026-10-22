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
    /// Every BedJet Lull connects to, in the order they were added. Never empty once loaded.
    private(set) var bedJets: [BedJet] = []
    private var selectedID: BedJet.ID?
    /// The BedJet every screen shows and controls.
    var bedJet: BedJet { bedJets.first { $0.id == selectedID } ?? bedJets[0] }
    var hasSeveralBedJets: Bool { bedJets.count > 1 }

    var schedules: [Schedule] = [] { didSet { save() } }

    var useFahrenheit: Bool { didSet { UserDefaults.standard.set(useFahrenheit, forKey: "useFahrenheit") } }
    var demoMode: Bool {
        didSet {
            UserDefaults.standard.set(demoMode, forKey: "demoMode")
            let leaving = fleet
            show(otherFleet)
            otherFleet = leaving
            save()
        }
    }

    var errorMessage: String?

    private var isLoaded = false
    /// The BedJets of the mode not in use, kept as they were saved.
    private var otherFleet: Fleet?

    init() {
        let defaults = UserDefaults.standard
        useFahrenheit = defaults.object(forKey: "useFahrenheit") as? Bool ?? (Locale.current.measurementSystem == .us)
        #if targetEnvironment(simulator)
        demoMode = true
        #else
        demoMode = defaults.bool(forKey: "demoMode")
        #endif
        load()
    }

    // MARK: BedJets

    func select(_ id: BedJet.ID) {
        guard id != bedJet.id else { return }
        selectedID = id
        save()
    }

    /// Adds a BedJet and shows it, so the person can watch it being looked for.
    func addBedJet() {
        var saved = SavedBedJet()
        saved.tonightID = bedJet.tonightID
        if demoMode { saved.name = "\(DemoLink.defaultName)-\(bedJets.count + 1)" }
        let added = BedJet(saved, isDemo: demoMode, app: self)
        bedJets.append(added)
        selectedID = added.id
        added.connect(asking: true)
        save()
    }

    /// With one BedJet, forgetting it lets Lull pair with whichever is nearest. With several, it is removed.
    func forget(_ bedJet: BedJet) {
        guard hasSeveralBedJets else { return bedJet.forgetUnit() }
        bedJet.pause()
        bedJet.deleteHistory()
        bedJets.removeAll { $0 === bedJet }
        if selectedID == bedJet.id { selectedID = bedJets.first?.id }
        save()
    }

    /// Whether a unit found nearby may connect for `bedJet`. Two BedJets never take the same unit, and one
    /// that already has a unit keeps to it, unless it is the only one and its unit may have been replaced.
    func accepts(_ unit: UUID, for bedJet: BedJet) -> Bool {
        let others = bedJets.filter { $0 !== bedJet }
        guard !others.contains(where: { $0.unit == unit || $0.unitInUse == unit }) else { return false }
        return bedJet.unit == nil || bedJet.unit == unit || others.isEmpty
    }

    /// What a BedJet is called on screen: its own name, numbered when two share one.
    func title(of bedJet: BedJet) -> String {
        let name = bedJet.name ?? "New BedJet"
        let twins = bedJets.filter { ($0.name ?? "New BedJet") == name }
        guard twins.count > 1, let index = twins.firstIndex(where: { $0 === bedJet }) else { return name }
        return "\(name) \(index + 1)"
    }

    func report(_ message: String, from bedJet: BedJet) {
        errorMessage = hasSeveralBedJets ? "\(title(of: bedJet)): \(message)" : message
    }

    func appMovedToBackground() {
        for bedJet in bedJets { bedJet.pause() }
    }

    func appBecameActive() {
        for bedJet in bedJets { bedJet.resume(asking: bedJet === self.bedJet) }
    }

    private func show(_ fleet: Fleet?) {
        for bedJet in bedJets { bedJet.pause() }
        var saved = fleet?.bedJets ?? []
        if saved.isEmpty { saved = [firstBedJet(demo: demoMode)] }
        bedJets = saved.map { BedJet($0, isDemo: demoMode, app: self) }
        selectedID = fleet?.selected
        for bedJet in bedJets { bedJet.connect(asking: bedJet === self.bedJet) }
    }

    /// The BedJet a mode starts out with. One an earlier version of Lull knew, with its history, carries over.
    private func firstBedJet(demo: Bool, legacy: Saved? = nil) -> SavedBedJet {
        var first = SavedBedJet(tonightID: legacy?.tonightID ?? schedules.first?.id, run: legacy?.run, slot: legacy?.slot)
        if demo {
            first.name = DemoLink.defaultName
        } else if let legacy = BLELink.legacyUnit {
            first.unit = legacy.unit
            first.name = legacy.name
        }
        if !demo, let generation = UserDefaults.standard.string(forKey: "generation").flatMap(Generation.init) {
            first.generation = generation
        }
        if !Self.isEphemeral {
            let history = URL.applicationSupportDirectory.appending(path: demo ? "history-demo.json" : "history.json")
            try? FileManager.default.moveItem(at: history, to: BedJet.historyFile(for: first.id))
        }
        return first
    }

    // MARK: Schedules

    /// Keeps a copy of a program made elsewhere, so reusing its slot never loses it.
    func keepCopy(of program: StoredProgram) {
        let imported = Schedule(importing: program)
        if !schedules.contains(where: { $0.phases.map(\.step) == imported.phases.map(\.step) }) {
            schedules.append(imported)
        }
    }

    func save(_ schedule: Schedule) {
        if let index = schedules.firstIndex(where: { $0.id == schedule.id }) {
            schedules[index] = schedule
        } else {
            schedules.append(schedule)
        }
    }

    func delete(_ schedule: Schedule) {
        schedules.removeAll { $0.id == schedule.id }
        for bedJet in bedJets where bedJet.tonightID == schedule.id { bedJet.tonightID = schedules.first?.id }
    }

    func degrees(_ halfCelsius: Int) -> String {
        "\(Format.degrees(halfCelsius, fahrenheit: useFahrenheit))°"
    }

    /// A phase in words for VoiceOver, such as "Heat, 75°, fan 40%, 30 minutes".
    func spokenSummary(of phase: Phase) -> String {
        var parts = [phase.mode.title]
        if bedJet.adjustsTemperature(phase.mode) { parts.append(degrees(phase.temperature)) }
        if phase.mode.usesFan { parts.append("fan \(phase.fanPercent)%") }
        parts.append(Format.spokenDuration(phase.minutes))
        return parts.joined(separator: ", ")
    }

    // MARK: Persistence

    /// The BedJets known in one mode. Demo mode keeps its own, so pretend units never mix with real ones.
    private struct Fleet: Codable {
        var bedJets: [SavedBedJet]
        var selected: BedJet.ID?
    }

    private struct Saved: Codable {
        var schedules: [Schedule]
        var fleet: Fleet?
        var demoFleet: Fleet?
        // Kept by versions that knew a single BedJet.
        var tonightID: Schedule.ID?
        var run: ActiveRun?
        var slot: Int?
    }

    private var fleet: Fleet { Fleet(bedJets: bedJets.map(\.saved), selected: selectedID) }

    private static let file = URL.applicationSupportDirectory.appending(path: "lull.json")
    /// Launching with `-demoLabelConnected` shows the simulated BedJet as connected, for listing screenshots.
    static let labelsDemoAsConnected = ProcessInfo.processInfo.arguments.contains("-demoLabelConnected")
    /// Launching with `-demoElapsedMinutes 200` makes a night started in demo mode appear that far along.
    static let demoElapsedMinutes = UserDefaults.standard.integer(forKey: "demoElapsedMinutes")
    /// Launching with `-demoHistory` fills an empty History with a few sample nights, for listing screenshots.
    static let seedsDemoHistory = ProcessInfo.processInfo.arguments.contains("-demoHistory")
    /// UI tests launch with this flag so every run starts from the built-in schedules.
    static let isEphemeral = ProcessInfo.processInfo.arguments.contains("-ephemeral")

    private func load() {
        let saved = Self.isEphemeral ? nil : (try? Data(contentsOf: Self.file)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        schedules = saved?.schedules ?? Schedule.templates
        otherFleet = demoMode ? saved?.fleet : saved?.demoFleet
        if let fleet = demoMode ? saved?.demoFleet : saved?.fleet {
            show(fleet)
        } else {
            // Before Lull knew several BedJets, what it kept belonged to the one in use.
            show(Fleet(bedJets: [firstBedJet(demo: demoMode, legacy: saved)], selected: nil))
        }
        isLoaded = true
        save()
    }

    func save() {
        guard isLoaded, !Self.isEphemeral else { return }
        let saved = Saved(schedules: schedules, fleet: demoMode ? otherFleet : fleet, demoFleet: demoMode ? fleet : otherFleet)
        try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(saved).write(to: Self.file, options: .atomic)
    }
}
