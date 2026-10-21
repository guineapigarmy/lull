import BedJetKit
import SwiftUI

/// What the BedJet did each night, so the morning after you can see what you picked at 3 a.m. and whether it helped.
struct HistoryView: View {
    @Environment(AppModel.self) private var model

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
            ForEach(nights) { night in NightCard(night: night) }
        }
    }
}

private struct NightCard: View {
    @Environment(AppModel.self) private var model
    let night: Night

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow(night.relativeName() ?? night.evening.formatted(.dateTime.weekday(.wide)))
                    Text(night.evening.formatted(.dateTime.month(.wide).day())).font(.system(size: 26, weight: .semibold))
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(night.entries.enumerated()), id: \.element.id) { index, entry in
                        EntryRow(entry: entry, isLast: index == night.entries.count - 1)
                    }
                }
                ReviewEditor(review: .init(get: { model.review(of: night) }, set: { model.setReview($0, of: night) }))
            }
        }
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
                // Joins the entries into one line through the night.
                if !isLast {
                    Rectangle().fill(Theme.hairline).frame(width: 1).frame(minHeight: 14)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16, weight: .semibold))
                if let detail { Text(detail).font(.system(size: 13)).foregroundStyle(Theme.secondary) }
            }
            .padding(.top, 4)
            .padding(.bottom, isLast ? 0 : 14)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch entry.event {
        case let .air(mode, temperature, fan):
            return mode.usesTemperature ? "\(mode.title) · \(model.degrees(temperature)) · fan \(fan)%" : "\(mode.title) · fan \(fan)%"
        case .off: return "Turned off"
        case let .scheduleStarted(name): return "Started \(name ?? "a schedule")"
        case let .scheduleEnded(name, ending):
            let name = name ?? "Schedule"
            switch ending {
            case .byYou: return "Ended \(name)"
            case .finished: return "\(name) finished"
            case .early(let minutes): return "\(name) stopped \(Format.duration(minutes)) early"
            }
        }
    }

    private var detail: String? {
        var parts: [String] = []
        if case .off(timerRanOut: true) = entry.event { parts.append("Timer ran out") }
        if let room = entry.room { parts.append("Room \(model.degrees(room))") }
        if entry.noticedLater { parts.append("Seen when Lull reopened") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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

/// A quick verdict on the night, plus a note for what to try next time.
private struct ReviewEditor: View {
    @Binding var review: NightReview

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How did you sleep?").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.secondary)
            HStack(spacing: 10) {
                choice(.good, "Slept well", symbol: "hand.thumbsup")
                choice(.bad, "Not great", symbol: "hand.thumbsdown")
            }
            TextField("What would you change?", text: $review.note, axis: .vertical)
                .font(.system(size: 15))
                .lineLimit(1...4)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline))
        }
        .padding(.top, 4)
    }

    private func choice(_ rating: NightReview.Rating, _ title: String, symbol: String) -> some View {
        let isSelected = review.rating == rating
        return Button {
            review.rating = isSelected ? nil : rating
        } label: {
            Label(title, systemImage: isSelected ? "\(symbol).fill" : symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isSelected ? Color.black : Color.white)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(isSelected ? Color.white : Theme.raised, in: Capsule())
                .overlay(Capsule().strokeBorder(isSelected ? Color.clear : Theme.hairline))
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
