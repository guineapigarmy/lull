import BedJetKit
import SwiftUI

/// What the BedJet did each night, so the morning after you can see what you picked at 3 a.m.
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var expanded: Set<Night.ID> = []

    var body: some View {
        Screen(title: "History") {
            let nights = model.nights
            if nights.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No nights yet").font(.system(size: 22, weight: .semibold))
                        Text("Every change to your BedJet shows up here with the time and room temperature, so in the morning you can see what you picked overnight.")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.secondary)
                    }
                }
            }
            VStack(spacing: 10) {
                ForEach(nights) { night in
                    NightRow(night: night, isExpanded: expanded.contains(night.id)) {
                        if expanded.remove(night.id) == nil { expanded.insert(night.id) }
                    }
                }
            }
        }
        .animation(.smooth(duration: 0.35), value: expanded)
    }
}

/// One night at a glance, opening up to everything that happened in it.
private struct NightRow: View {
    let night: Night
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 20) {
                Button(action: toggle) {
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(title).font(.system(size: 19, weight: .semibold)).lineLimit(1)
                            Text(summary(through: "–"))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.secondary)
                                .monospacedDigit()
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        NightCurve(phases: night.phases, lineWidth: 2).frame(width: 88, height: 40)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title), \(summary(through: "to"))")
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                .accessibilityHint(isExpanded ? "Hides this night" : "Shows everything that happened this night")
                .accessibilityIdentifier("Night")

                if isExpanded {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(night.entries.enumerated()), id: \.element.id) { index, entry in
                            EntryRow(entry: entry, isLast: index == night.entries.count - 1)
                        }
                    }
                    .transition(.opacity)
                }
            }
        }
    }

    private var title: String {
        night.evening.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    /// The schedule that ran, or else when the first and last changes happened.
    private func summary(through separator: String) -> String {
        let names = night.scheduleNames
        if !names.isEmpty { return names.joined(separator: ", ") }
        guard let first = night.entries.first?.date, let last = night.entries.last?.date else { return "" }
        let start = first.formatted(date: .omitted, time: .shortened), end = last.formatted(date: .omitted, time: .shortened)
        return start == end ? start : "\(start) \(separator) \(end)"
    }
}

private struct EntryRow: View {
    @Environment(AppModel.self) private var model
    let entry: HistoryEntry
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(entry.date.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.secondary)
                .frame(width: 64, alignment: .trailing)
                .padding(.top, 6)
            VStack(spacing: 0) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(tint.opacity(0.16), in: Circle())
                    .accessibilityHidden(true)
                // Joins the entries into one line through the night.
                if !isLast {
                    Rectangle().fill(Theme.hairline).frame(width: 1).frame(minHeight: 14)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title(spoken: false)).font(.system(size: 16, weight: .semibold)).accessibilityLabel(title(spoken: true))
                if let detail = detail(spoken: false) {
                    Text(detail).font(.system(size: 13)).foregroundStyle(Theme.secondary).accessibilityLabel(self.detail(spoken: true) ?? detail)
                }
            }
            .padding(.top, 4)
            .padding(.bottom, isLast ? 0 : 14)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// Parts are joined with a dot on screen; VoiceOver gets commas and durations in words.
    private func title(spoken: Bool) -> String {
        switch entry.event {
        case let .air(mode, temperature, fan):
            let parts = model.adjustsTemperature(mode) ? [mode.title, model.degrees(temperature), "fan \(fan)%"] : [mode.title, "fan \(fan)%"]
            return parts.joined(separator: spoken ? ", " : " · ")
        case .off: return "Turned off"
        case let .scheduleStarted(name, _): return "Started \(name ?? "a schedule")"
        case let .scheduleEnded(name, ending):
            let name = name ?? "Schedule"
            switch ending {
            case .byYou: return "Ended \(name)"
            case .finished: return "\(name) finished"
            case .early(let minutes):
                return "\(name) stopped \(spoken ? Format.spokenDuration(minutes) : Format.duration(minutes)) early"
            }
        }
    }

    private func detail(spoken: Bool) -> String? {
        var parts: [String] = []
        if case .off(timerRanOut: true) = entry.event { parts.append("Timer ran out") }
        if let room = entry.room { parts.append("Room \(model.degrees(room))") }
        if entry.noticedLater { parts.append("Seen when Lull reopened") }
        return parts.isEmpty ? nil : parts.joined(separator: spoken ? ", " : " · ")
    }

    private var symbol: String {
        switch entry.event {
        case let .air(mode, _, _): return mode.symbol
        case .off: return "power"
        case .scheduleStarted: return "moon.stars.fill"
        case .scheduleEnded(_, .early): return "exclamationmark"
        case .scheduleEnded: return "sunrise.fill"
        }
    }

    private var tint: Color {
        switch entry.event {
        case let .air(mode, _, _): return mode.tint
        case .scheduleEnded(_, .early): return Theme.warm
        case .off: return Theme.neutral
        case .scheduleStarted, .scheduleEnded: return .white
        }
    }
}
