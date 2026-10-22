import BedJetKit
import SwiftUI

struct ScheduleEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var schedule: Schedule
    @State private var selection: Phase.ID?
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    TextField("Name", text: $schedule.name)
                        .font(.system(size: 30, weight: .bold))
                        .focused($nameFocused)
                        .submitLabel(.done)
                        .onChange(of: schedule.name) { _, name in
                            // The BedJet stores 15 characters.
                            if name.count > Limits.nameLength { schedule.name = String(name.prefix(Limits.nameLength)) }
                        }

                    Card {
                        NightTimeline(schedule: schedule, selection: selection, height: 170)
                            .animation(.smooth(duration: 0.35), value: schedule.phases)
                    }

                    bedtimeRow

                    Eyebrow("Phases")
                    VStack(spacing: 10) {
                        ForEach($schedule.phases) { $phase in
                            PhaseRow(phase: phase, startsAt: schedule.startMinute(of: phase)) { selection = phase.id }
                        }
                    }
                    if schedule.phases.count < Limits.stepsPerProgram {
                        Button {
                            let phase = Phase(.cool, fan: 30, minutes: 60)
                            schedule.phases.append(phase)
                            selection = phase.id
                        } label: {
                            Label("Add Phase", systemImage: "plus")
                        }
                        .buttonStyle(PrimaryButtonStyle(prominent: false))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 120)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.immediately)
            .background(Theme.background)
            .safeAreaInset(edge: .bottom) {
                Button("Use Tonight") {
                    model.save(schedule)
                    model.bedJet.tonightID = schedule.id
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!isValid)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.save(schedule)
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
            .sheet(isPresented: .init(get: { selectedIndex != nil }, set: { if !$0 { selection = nil } })) {
                if let index = selectedIndex {
                    PhaseEditor(phase: $schedule.phases[index], canDelete: schedule.phases.count > 1) {
                        schedule.phases.remove(at: index)
                    }
                }
            }
        }
    }

    private var isValid: Bool {
        !schedule.name.trimmingCharacters(in: .whitespaces).isEmpty && !schedule.phases.isEmpty
    }

    private var bedtimeRow: some View {
        Card(padding: 16) {
            DatePicker(selection: bedtime, displayedComponents: .hourAndMinute) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Usual bedtime").font(.system(size: 17, weight: .medium))
                    Text("Wake around \(Format.clock(schedule.bedtime + schedule.totalMinutes))")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondary)
                }
            }
        }
    }

    private var bedtime: Binding<Date> {
        Binding {
            Calendar.current.date(bySettingHour: schedule.bedtime / 60, minute: schedule.bedtime % 60, second: 0, of: Date()) ?? Date()
        } set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            schedule.bedtime = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        }
    }

    private var selectedIndex: Int? {
        schedule.phases.firstIndex { $0.id == selection }
    }
}

private struct PhaseRow: View {
    @Environment(AppModel.self) private var model
    let phase: Phase
    let startsAt: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: phase.mode.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(phase.mode.tint)
                    .frame(width: 40, height: 40)
                    .background(phase.mode.tint.opacity(0.16), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(phase.mode.title).font(.system(size: 17, weight: .semibold))
                    Text(detail).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(Format.duration(phase.minutes)).font(.system(size: 15, weight: .medium))
                    Text(Format.clock(startsAt)).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
                .monospacedDigit()
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.tertiary)
            }
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.hairline))
        }
        .buttonStyle(.plain)
    }

    private var detail: String {
        var parts: [String] = []
        if model.bedJet.adjustsTemperature(phase.mode) { parts.append(model.degrees(phase.temperature)) }
        if phase.mode.usesFan { parts.append("Fan \(phase.fanPercent)%") }
        return parts.isEmpty ? "Air off" : parts.joined(separator: " · ")
    }
}

private struct PhaseEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Binding var phase: Phase
    let canDelete: Bool
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text("Phase").font(.system(size: 22, weight: .bold))
                Spacer()
                Button("Done") { dismiss() }.font(.system(size: 17, weight: .semibold))
            }
            ModePicker(modes: model.bedJet.phaseModes, selection: phase.mode) { mode in
                phase.mode = mode
                if !mode.temperatureRange.contains(phase.temperature) { phase.temperature = mode.defaultTemperature }
            }
            if model.bedJet.adjustsTemperature(phase.mode) {
                TemperatureSlider(mode: phase.mode, temperature: $phase.temperature)
            }
            if phase.mode.usesFan {
                LabeledSlider(title: "Fan", valueText: "\(phase.fanPercent)%", value: fan, range: 5...100, step: 5, tint: phase.mode.tint)
            }
            LabeledSlider(title: "Duration", valueText: Format.duration(phase.minutes), value: minutes,
                          range: 5...Double(phase.maxMinutes / 5 * 5), step: 5, tint: .white)
            if isHeatLimited {
                Text("At this temperature and fan, BedJet heats for up to \(Format.duration(phase.maxMinutes)) before its safety cut-off."
                     + (model.bedJet.generation.supports(.extendedHeat) ? " Use Gentle heat to run longer." : ""))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if canDelete {
                Button("Remove Phase", role: .destructive) {
                    onDelete()
                }
                .font(.system(size: 17, weight: .medium))
                .frame(maxWidth: .infinity)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .padding(.top, 8)
        .presentationDetents([.height((model.bedJet.adjustsTemperature(phase.mode) ? 530 : 450) + (isHeatLimited ? 50 : 0))])
        .presentationBackground(Theme.surface)
        .animation(.smooth(duration: 0.25), value: phase.mode)
        .onChange(of: phase.maxMinutes, initial: true) { _, longest in
            phase.minutes = min(phase.minutes, longest)
        }
    }

    private var isHeatLimited: Bool { phase.maxMinutes < phase.mode.maxMinutes }

    private var fan: Binding<Double> {
        Binding { Double(phase.fanPercent) } set: { phase.fanPercent = Int($0) }
    }

    private var minutes: Binding<Double> {
        Binding { Double(phase.minutes) } set: { phase.minutes = Int($0) }
    }
}

struct TemperatureSlider: View {
    @Environment(AppModel.self) private var model
    let mode: Mode
    @Binding var temperature: Int
    /// Limits in half-degrees Celsius. The Remote passes what the BedJet reports for the mode it is in,
    /// which can be narrower than the mode's general range.
    var limits: ClosedRange<Int>?

    var body: some View {
        let low = Format.degrees(bounds.lowerBound, fahrenheit: model.useFahrenheit)
        let high = max(Format.degrees(bounds.upperBound, fahrenheit: model.useFahrenheit), low + 1)
        LabeledSlider(title: "Temperature", valueText: model.degrees(temperature), value: degrees,
                      range: Double(low)...Double(high), tint: mode.tint)
    }

    private var bounds: ClosedRange<Int> { limits ?? mode.temperatureRange }

    private var degrees: Binding<Double> {
        Binding {
            Double(Format.degrees(temperature, fahrenheit: model.useFahrenheit))
        } set: { value in
            let halves = Format.halfCelsius(fromDegrees: Int(value), fahrenheit: model.useFahrenheit)
            temperature = min(max(halves, bounds.lowerBound), bounds.upperBound)
        }
    }
}

struct ModePicker: View {
    let modes: [Mode]
    let selection: Mode?
    let onSelect: (Mode) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            ForEach(modes, id: \.self) { mode in
                let isSelected = mode == selection
                Button { onSelect(mode) } label: {
                    VStack(spacing: 6) {
                        Image(systemName: mode.symbol).font(.system(size: 18, weight: .semibold))
                        Text(mode.title).font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(isSelected ? Color.black : mode.tint)
                    .frame(maxWidth: .infinity, minHeight: 62)
                    .background(isSelected ? mode.tint : Theme.raised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
    }
}
