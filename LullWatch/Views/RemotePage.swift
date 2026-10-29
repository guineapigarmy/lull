import BedJetKit
import SwiftUI

/// Air right now rather than a schedule, as the iPhone's Remote: a mode, and the temperature, fan and timer to run it
/// at, sent together once they're set.
struct RemotePage: View {
    @Environment(WatchModel.self) private var model
    @State private var mode = Mode.cool
    @State private var temperature = Mode.cool.defaultTemperature
    @State private var fan = 40
    @State private var minutes = 30
    /// When the air turns off, as a minute of the day, while the page shows it as a time.
    @State private var endMinute = 0
    @FocusState private var focused: RemoteSetting?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let bedJet = model.bedJet {
                    controls(bedJet)
                } else {
                    EmptyMessage(symbol: "bed.double", title: "No BedJet yet", message: "Choose your BedJet in Lull on your iPhone.")
                }
                if let unavailable = model.unavailable { Footnote(text: unavailable) }
            }
        }
        .navigationTitle("Remote")
        // Starts from what the BedJet is doing, and again for another BedJet.
        .task(id: model.bedJet?.id) { follow(model.bedJet) }
    }

    @ViewBuilder
    private func controls(_ bedJet: WidgetBedJet) -> some View {
        let modes = Mode.remoteModes.filter(bedJet.generation.supports) + [.standby]
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
            ForEach(modes, id: \.self) { option in
                modeButton(option)
            }
        }
        if mode != .standby {
            if bedJet.generation.adjustsTemperature(mode) {
                CrownRow(title: "Temperature", valueText: model.snapshot.degrees(temperature), value: degrees,
                         range: degreeRange, tint: mode.tint, focus: $focused, setting: .temperature)
            }
            if mode.usesFan {
                CrownRow(title: "Fan", valueText: "\(fan)%", value: Binding { Double(fan) } set: { fan = Int($0) },
                         range: 5...100, step: 5, tint: mode.tint, focus: $focused, setting: .fan)
            }
            timerChoice
            let limit = runtimeLimit
            if model.remoteShowsTime {
                // The crown moves the end a step at a time: 6:30, 6:45.
                CrownRow(title: "Turns off at", valueText: Format.clock(endMinute),
                         value: Binding { Double(Format.minutes(until: endMinute, from: Date())) } set: { setEnd(minutes: Int($0)) },
                         range: limit.range, step: limit.step, focus: $focused, setting: .time)
            } else {
                CrownRow(title: "Turns off in", valueText: Format.duration(minutes), spokenValue: Format.spokenDuration(minutes),
                         value: Binding { Double(minutes) } set: { minutes = Int($0) }, range: limit.range, step: limit.step,
                         focus: $focused, setting: .time)
            }
        }
        // Redrawn each minute, so a time is sent as the minutes left until it when Apply is pressed.
        TimelineView(.everyMinute) { _ in
            let runs = model.remoteShowsTime && mode != .standby ? Format.minutes(until: endMinute, from: Date()) : minutes
            let preset = RemotePreset(mode: mode, minutes: runs, temperature: temperature, fanPercent: fan).clamped
            ErrandButton(title: mode == .standby ? "Turn Off" : "Apply", busyTitle: "Sending…", command: .remote(preset, bedJet.id))
        }
        if case .night? = bedJet.live(at: Date()) {
            Footnote(text: "Choosing a mode here ends the schedule that's running.")
        }
    }

    private func modeButton(_ option: Mode) -> some View {
        let isSelected = option == mode
        return Button {
            choose(option)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: option.symbol).scaledFont(15, .semibold)
                Text(option.title).scaledFont(10, .semibold).lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.8)
            }
            .foregroundStyle(isSelected ? Color.black : option.tint)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(isSelected ? option.tint : Theme.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Timer or Time: whether the row below sets how long the air runs or when it turns off. Remembered on the watch.
    private var timerChoice: some View {
        HStack(spacing: 6) {
            ForEach([false, true], id: \.self) { showsTime in
                let isSelected = model.remoteShowsTime == showsTime
                Button {
                    guard !isSelected else { return }
                    if showsTime { setEnd(minutes: minutes) } else { minutes = clamped(Format.minutes(until: endMinute, from: Date())) }
                    model.remoteShowsTime = showsTime
                } label: {
                    Text(showsTime ? "Time" : "Timer")
                        .scaledFont(13, .semibold)
                        .foregroundStyle(isSelected ? Color.black : Color.white)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(isSelected ? Color.white : Theme.raised, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }

    private func choose(_ option: Mode) {
        guard option != mode else { return }
        mode = option
        temperature = option.defaultTemperature
        minutes = clamped(minutes)
        if model.remoteShowsTime { setEnd(minutes: Format.minutes(until: endMinute, from: Date())) }
    }

    /// Within what the mode allows at this temperature and fan.
    private func clamped(_ minutes: Int) -> Int {
        let limit = runtimeLimit
        return min(max(minutes, Int(limit.range.lowerBound)), Int(limit.range.upperBound))
    }

    /// Turns off about `minutes` from now, on the row's step, within what the mode allows.
    private func setEnd(minutes: Int) {
        let step = Int(runtimeLimit.step), now = Date()
        var lasting = Format.minutesEndingOnStep(clamped(minutes), step: step, from: now)
        if lasting > Int(runtimeLimit.range.upperBound) { lasting -= step }
        endMinute = (Format.minuteOfDay(now) + lasting) % 1440
    }

    /// What the BedJet is doing from the Remote, or the Quick Remote's first button: Cool for 30 minutes.
    private func follow(_ bedJet: WidgetBedJet?) {
        if case let .air(liveMode, liveTemperature, liveFan, endsAt)? = bedJet?.live(at: Date()) {
            mode = liveMode
            temperature = liveTemperature ?? liveMode.defaultTemperature
            fan = liveFan
            let step = Int(runtimeLimit.step)
            minutes = max(Int(endsAt.timeIntervalSinceNow / 60) / step * step, step)
            endMinute = Format.endMinute(after: Int(endsAt.timeIntervalSinceNow), from: Date())
        } else {
            let first = PresetChoice.defaults[0].preset(fahrenheit: model.snapshot.useFahrenheit)
            mode = first.mode
            temperature = first.temperature
            fan = first.fanPercent
            minutes = first.minutes
            setEnd(minutes: minutes)
        }
    }

    /// The temperature in the degrees Lull shows, whole degrees at a time, as on the iPhone.
    private var degrees: Binding<Double> {
        let fahrenheit = model.snapshot.useFahrenheit
        return Binding {
            Double(Format.degrees(temperature, fahrenheit: fahrenheit))
        } set: { value in
            let halves = Format.halfCelsius(fromDegrees: Int(value.rounded()), fahrenheit: fahrenheit)
            temperature = min(max(halves, mode.temperatureRange.lowerBound), mode.temperatureRange.upperBound)
        }
    }

    private var degreeRange: ClosedRange<Double> {
        let fahrenheit = model.snapshot.useFahrenheit
        let low = Format.degrees(mode.temperatureRange.lowerBound, fahrenheit: fahrenheit)
        let high = max(Format.degrees(mode.temperatureRange.upperBound, fahrenheit: fahrenheit), low + 1)
        return Double(low)...Double(high)
    }

    /// How long the mode may run at this temperature and fan, with a step that suits the span, as on the iPhone.
    private var runtimeLimit: (range: ClosedRange<Double>, step: Double) {
        let longest = Phase(mode, temperature: temperature, fan: fan, minutes: 1).maxMinutes
        let step = longest <= 15 ? 1 : longest <= 240 ? 5 : 15
        return (Double(step)...Double(max(longest / step * step, step * 2)), Double(step))
    }
}
