import BedJetKit
import SwiftUI

struct ScheduleEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var schedule: Schedule
    @State private var selection: Phase.ID?
    @FocusState private var nameFocused: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Wraps rather than clipping a long name at large text sizes; Return still finishes editing.
                    TextField("Name", text: $schedule.name, axis: .vertical)
                        .scaledFont(30, .bold)
                        .focused($nameFocused)
                        .submitLabel(.done)
                        .accessibilityLabel("Schedule name")
                        .accessibilityHint("Up to \(Limits.nameLength) characters")
                        .onChange(of: schedule.name) { _, name in
                            if name.contains("\n") {
                                schedule.name = name.replacingOccurrences(of: "\n", with: "")
                                nameFocused = false
                                return
                            }
                            // The BedJet stores 15 characters.
                            if name.count > Limits.nameLength { schedule.name = String(name.prefix(Limits.nameLength)) }
                        }

                    Card {
                        NightTimeline(schedule: schedule, selection: selection, height: 170)
                            .animation(.smooth(duration: 0.35), value: schedule.phases)
                    }

                    bedtimeRow

                    Eyebrow("Phases").accessibilityAddTraits(.isHeader)
                    VStack(spacing: 10) {
                        ForEach(Array(schedule.phases.enumerated()), id: \.element.id) { index, phase in
                            PhaseRow(phase: phase, number: index + 1, startsAt: schedule.startMinute(of: phase),
                                     onDelete: schedule.phases.count > 1 ? { schedule.phases.removeAll { $0.id == phase.id } } : nil) {
                                selection = phase.id
                            }
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
                    model.tonightID = schedule.id
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
        // At the largest text sizes the time goes under its label rather than squeezing it into a sliver.
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout())
        return Card(padding: 16) {
            layout {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Usual bedtime").scaledFont(17, .medium)
                    Text("Wake around \(Format.clock(schedule.bedtime + schedule.totalMinutes))")
                        .scaledFont(13)
                        .foregroundStyle(Theme.secondary)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)
                DatePicker("Bedtime", selection: bedtime, displayedComponents: .hourAndMinute)
                    .labelsHidden()
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
    let number: Int
    let startsAt: Int
    /// Nil when this is the only phase, which can't be removed.
    let onDelete: (() -> Void)?
    let action: () -> Void
    @ScaledMetric(relativeTo: .body) private var badge: CGFloat = 40
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // At the largest text sizes the timing moves under the mode instead of beside it.
        let large = typeSize.isAccessibilitySize
        let content = large ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 14))
        Button(action: action) {
            HStack(spacing: 14) {
                content {
                    HStack(spacing: 14) {
                        Image(systemName: phase.mode.symbol)
                            .scaledFont(16, .semibold)
                            .foregroundStyle(phase.mode.tint)
                            .frame(width: min(badge, 56), height: min(badge, 56))
                            .background(phase.mode.tint.opacity(0.16), in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text(phase.mode.title).scaledFont(17, .semibold)
                            Text(detail).scaledFont(13).foregroundStyle(Theme.secondary)
                        }
                    }
                    if !large { Spacer() }
                    VStack(alignment: large ? .leading : .trailing, spacing: 3) {
                        Text(Format.duration(phase.minutes)).scaledFont(15, .medium)
                        Text(Format.clock(startsAt)).scaledFont(13).foregroundStyle(Theme.secondary)
                    }
                    .monospacedDigit()
                }
                if large { Spacer(minLength: 0) }
                Image(systemName: "chevron.right").scaledFont(12, .semibold).foregroundStyle(Theme.tertiary)
            }
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.hairline))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Phase \(number), \(model.spokenSummary(of: phase)), starts \(Format.clock(startsAt))")
        .accessibilityHint("Edits this phase")
        .accessibilityActions {
            if let onDelete { Button("Remove Phase", role: .destructive, action: onDelete) }
        }
    }

    private var detail: String {
        var parts: [String] = []
        if model.adjustsTemperature(phase.mode) { parts.append(model.degrees(phase.temperature)) }
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
    @State private var contentHeight: CGFloat = 450

    var body: some View {
        // The sheet fits what's in it at any text size, scrolling once that's taller than the screen.
        ScrollView {
            content
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        // A sheet shorter than the screen doesn't hold VoiceOver by itself; this keeps it off the editor beneath.
        .accessibilityAddTraits(.isModal)
        .presentationDetents([.height(contentHeight)])
        .presentationBackground(Theme.surface)
        .animation(.smooth(duration: 0.25), value: phase.mode)
        .onChange(of: phase.maxMinutes, initial: true) { _, longest in
            phase.minutes = min(phase.minutes, longest)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text("Phase").scaledFont(22, .bold).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done") { dismiss() }.scaledFont(17, .semibold)
            }
            ModePicker(modes: model.phaseModes, selection: phase.mode) { mode in
                phase.mode = mode
                if !mode.temperatureRange.contains(phase.temperature) { phase.temperature = mode.defaultTemperature }
            }
            if model.adjustsTemperature(phase.mode) {
                TemperatureSlider(mode: phase.mode, temperature: $phase.temperature)
            }
            if phase.mode.usesFan {
                LabeledSlider(title: "Fan", valueText: "\(phase.fanPercent)%", value: fan, range: 5...100, step: 5, tint: phase.mode.tint)
            }
            LabeledSlider(title: "Duration", valueText: Format.duration(phase.minutes), spokenValue: Format.spokenDuration(phase.minutes), value: minutes,
                          range: 5...Double(phase.maxMinutes / 5 * 5), step: 5, tint: .white)
            if isHeatLimited {
                Text("At this temperature and fan, BedJet heats for up to \(Format.duration(phase.maxMinutes)) before its safety cut-off."
                     + (model.generation.supports(.extendedHeat) ? " Use Gentle heat to run longer." : ""))
                    .scaledFont(13)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if canDelete {
                Button("Remove Phase", role: .destructive) {
                    onDelete()
                }
                .scaledFont(17, .medium)
                .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
        .padding(24)
        .padding(.top, 8)
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
    var hint: String?
    let onSelect: (Mode) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // Large text gets a column of full-width buttons with the icon beside the name.
        let large = typeSize.isAccessibilitySize
        let label = large ? AnyLayout(HStackLayout(spacing: 12)) : AnyLayout(VStackLayout(spacing: 6))
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: large ? 1 : 3), spacing: 10) {
            ForEach(modes, id: \.self) { mode in
                let isSelected = mode == selection
                Button { onSelect(mode) } label: {
                    label {
                        Image(systemName: mode.symbol).scaledFont(18, .semibold)
                        Text(mode.title).scaledFont(13, .semibold)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 8)
                    .foregroundStyle(isSelected ? Color.black : mode.tint)
                    .frame(maxWidth: .infinity, minHeight: 62)
                    .background(isSelected ? mode.tint : Theme.raised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(mode.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityHint(isSelected ? "" : hint ?? "")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mode")
        .sensoryFeedback(.selection, trigger: selection)
    }
}
