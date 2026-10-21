import BedJetKit
import Foundation

/// One thing the BedJet did, kept so the morning after can be checked against how the night felt.
struct HistoryEntry: Identifiable, Codable, Hashable {
    var id = UUID()
    var date: Date
    var event: Event
    /// What the BedJet measured in the room at the time, in half-degrees Celsius.
    var room: Int?
    /// Lull lets go of the BedJet when it leaves the screen, so a change made meanwhile, on the BedJet's
    /// own remote or another phone, is only seen when Lull is opened again and is dated then.
    var noticedLater = false

    enum Event: Codable, Hashable {
        /// The air the BedJet settled on, whichever phone or remote chose it.
        case air(mode: Mode, temperature: Int, fanPercent: Int)
        case off(timerRanOut: Bool)
        /// Names are missing for schedules started from another phone.
        case scheduleStarted(name: String?)
        case scheduleEnded(name: String?, ending: Ending)
    }

    enum Ending: Codable, Hashable {
        case byYou
        case finished
        case early(minutes: Int)
    }
}

/// How a night went, in the sleeper's own words.
struct NightReview: Codable, Hashable {
    var rating: Rating?
    var note = ""

    enum Rating: String, Codable { case good, bad }

    var isEmpty: Bool { rating == nil && note.isEmpty }
}

/// Everything recorded between one noon and the next, so 3 a.m. belongs with the evening before.
struct Night: Identifiable {
    /// The evening the night began, as `yyyy-MM-dd`.
    let id: String
    let evening: Date
    /// Oldest first, so the night reads in the order it happened.
    var entries: [HistoryEntry]

    static func group(_ entries: [HistoryEntry]) -> [Night] {
        Dictionary(grouping: entries) { evening(of: $0.date) }
            .map { evening, entries in Night(id: id(for: evening), evening: evening, entries: entries.sorted { $0.date < $1.date }) }
            .sorted { $0.evening > $1.evening }
    }

    static func evening(of date: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: date.addingTimeInterval(-12 * 3600))
    }

    static func id(for evening: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: evening)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// "Tonight" or "Last night" for the nights people look back on most; nil for older ones.
    func relativeName(now: Date = Date(), calendar: Calendar = .current) -> String? {
        let current = Self.evening(of: now, calendar: calendar)
        let isMorning = calendar.component(.hour, from: now) < 12
        if evening == current { return isMorning ? "Last night" : "Tonight" }
        if !isMorning, let yesterday = calendar.date(byAdding: .day, value: -1, to: current), evening == yesterday { return "Last night" }
        return nil
    }
}
