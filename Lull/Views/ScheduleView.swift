import BedJetKit
import SwiftUI

/// Plan the night and run it: tonight's schedule on top, the rest of the library below.
struct ScheduleView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: Schedule?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Screen(title: "Schedule", subtitle: Date().formatted(.dateTime.weekday(.wide).month().day())) {
            if let run = model.run {
                TimelineView(.periodic(from: .now, by: 30)) { timeline in
                    running(run, now: timeline.date)
                }
            } else if let step = model.runningElsewhereStep {
                runningElsewhere(step: step)
            } else if let schedule = model.tonight {
                planned(schedule)
            } else {
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No schedules yet").scaledFont(22, .semibold)
                        Text("Create one to plan how your night feels.").scaledFont(15).foregroundStyle(Theme.secondary)
                    }
                }
            }

            let others = model.schedules.filter { $0.id != featuredID }
            if !others.isEmpty {
                Eyebrow("More schedules").padding(.top, 8).accessibilityAddTraits(.isHeader)
                ForEach(others) { schedule in row(schedule) }
            }
            Button {
                editing = Schedule(name: "New schedule", phases: [Phase(.cool, fan: 40, minutes: 240)])
            } label: {
                Label("New Schedule", systemImage: "plus")
            }
            .buttonStyle(PrimaryButtonStyle(prominent: false))
        }
        .fullScreenCover(item: $editing) { ScheduleEditor(schedule: $0) }
        .animation(.smooth(duration: 0.35), value: featuredID)
    }

    /// The schedule shown in the large card: the one running, otherwise the one picked for tonight.
    private var featuredID: Schedule.ID? {
        model.run?.schedule.id ?? model.tonight?.id
    }

    private func planned(_ schedule: Schedule) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Eyebrow("Tonight")
                        Text(schedule.name).scaledFont(26, .semibold)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button("Edit") { editing = schedule }
                        .scaledFont(15, .semibold)
                        .foregroundStyle(Theme.secondary)
                        // A full-size target without moving the text.
                        .padding(12)
                        .contentShape(Rectangle())
                        .padding(-12)
                        .accessibilityLabel("Edit \(schedule.name)")
                        .accessibilityActions { moreActions(schedule) }
                }
                NightTimeline(schedule: schedule, startMinute: minuteOfDay(Date()))
                Button {
                    Task { await model.startTonight() }
                } label: {
                    if model.isBusy { ProgressView().tint(.black) } else { Text("Start Night") }
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityLabel("Start Night")
                .accessibilityValue(model.isBusy ? "Starting" : "")
                .disabled(!model.canControl || model.isBusy)

                Text(startHint)
                    .scaledFont(13)
                    .foregroundStyle(Theme.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
        .contextMenu { menu(schedule) }
    }

    private var startHint: String {
        switch model.linkState {
        case .ready: return "Saved to your BedJet, which runs it all night. Your phone can sleep too."
        case .yielded: return "Your BedJet is in use on another phone. Starting here takes over."
        default: return "Waiting for your BedJet. Keep your phone within a few feet of it."
        }
    }

    /// Shown instead of the planned card when the BedJet is already running a schedule this phone didn't start.
    private func runningElsewhere(step: Int) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow("Running now")
                    Text("Phase \(step)").scaledFont(26, .semibold).accessibilityAddTraits(.isHeader)
                    if let status = model.status {
                        let minutes = max((status.remainingSeconds + 59) / 60, 1)
                        Label("\(status.mode.activity) · \(Format.duration(minutes)) left in this phase", systemImage: status.mode.symbol)
                            .scaledFont(15, .medium)
                            .foregroundStyle(status.mode.tint)
                            .accessibilityLabel("\(status.mode.activity), \(Format.spokenDuration(minutes)) left in this phase")
                    }
                    Text("This schedule was started from another phone or the BedJet's own remote.")
                        .scaledFont(13)
                        .foregroundStyle(Theme.tertiary)
                }
                Button("End Night") { Task { await model.endNight() } }
                    .buttonStyle(PrimaryButtonStyle(prominent: false))
                    .disabled(model.isBusy)
            }
        }
    }

    private func running(_ run: ActiveRun, now: Date) -> some View {
        let current = run.phase(at: now)
        return Card {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow(current.map { "Phase \($0.index + 1) of \(run.schedule.phases.count)" } ?? "Finishing")
                    Text(run.schedule.name).scaledFont(26, .semibold).accessibilityAddTraits(.isHeader)
                    if let current {
                        Label("\(current.phase.mode.activity) · \(Format.duration(current.minutesLeft)) left", systemImage: current.phase.mode.symbol)
                            .scaledFont(15, .medium)
                            .foregroundStyle(current.phase.mode.tint)
                            .accessibilityLabel("\(current.phase.mode.activity), \(Format.spokenDuration(current.minutesLeft)) left")
                    }
                }
                NightTimeline(schedule: run.schedule, startMinute: minuteOfDay(run.startedAt), progress: run.progress(at: now))
                Button("End Night") { Task { await model.endNight() } }
                    .buttonStyle(PrimaryButtonStyle(prominent: false))
                    .disabled(model.isBusy)
            }
        }
    }

    private func row(_ schedule: Schedule) -> some View {
        // Swapping schedules waits until the one that is running has ended.
        let canSwap = model.run == nil
        // At the largest text sizes Use Tonight goes under the card rather than over its corner.
        let beneath = typeSize.isAccessibilitySize
        return VStack(alignment: .trailing, spacing: 8) {
            Button { editing = schedule } label: { ScheduleRow(schedule: schedule, reservesCorner: canSwap && !beneath) }
                .buttonStyle(.plain)
                .accessibilityLabel("\(schedule.name), \(Format.spokenDuration(schedule.totalMinutes)), \(schedule.phases.count) \(schedule.phases.count == 1 ? "phase" : "phases")")
                .accessibilityHint("Edits this schedule")
                .accessibilityActions { moreActions(schedule) }
                .overlay(alignment: .topTrailing) {
                    if canSwap && !beneath { useTonight(schedule).padding(4) }
                }
                .contextMenu { menu(schedule) }
            if canSwap && beneath { useTonight(schedule) }
        }
    }

    private func useTonight(_ schedule: Schedule) -> some View {
        Button { model.tonightID = schedule.id } label: {
            Text("Use Tonight")
                .scaledFont(13, .semibold)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .frame(minHeight: 32)
                .background(Theme.raised, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.hairline))
                .padding(10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Use \(schedule.name) tonight")
    }

    @ViewBuilder
    private func menu(_ schedule: Schedule) -> some View {
        Button("Edit", systemImage: "slider.horizontal.3") { editing = schedule }
        moreActions(schedule)
    }

    /// The menu's other choices, also offered to VoiceOver as actions on the schedule.
    @ViewBuilder
    private func moreActions(_ schedule: Schedule) -> some View {
        Button("Duplicate", systemImage: "plus.square.on.square") {
            var copy = schedule
            copy.id = UUID()
            copy.name = Codec.sanitize("\(schedule.name) copy")
            model.save(copy)
        }
        Button("Delete", systemImage: "trash", role: .destructive) { model.delete(schedule) }
    }

    private func minuteOfDay(_ date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}

private struct ScheduleRow: View {
    let schedule: Schedule
    /// Leaves room for the Use Tonight button laid over the top corner.
    var reservesCorner = true
    @ScaledMetric(relativeTo: .footnote) private var corner: CGFloat = 116

    var body: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                Text(schedule.name)
                    .scaledFont(19, .semibold)
                    .padding(.trailing, reservesCorner ? corner : 0)
                NightCurve(phases: schedule.phases, lineWidth: 2.5).frame(height: 64)
                Text("\(Format.duration(schedule.totalMinutes)) · \(schedule.phases.count) \(schedule.phases.count == 1 ? "phase" : "phases")")
                    .scaledFont(13, .medium)
                    .foregroundStyle(Theme.secondary)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 28))
    }
}
