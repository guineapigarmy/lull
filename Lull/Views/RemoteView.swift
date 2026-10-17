import BedJetKit
import SwiftUI

/// Direct control, for when you want air right now rather than a schedule.
struct RemoteView: View {
    @Environment(AppModel.self) private var model
    @State private var temperature = 60
    @State private var fan = 40.0
    @State private var runtime = 60.0
    /// While a slider is in use, and briefly after, it leads and the BedJet's reports are not applied to it.
    @State private var followAfter = Date.distantPast
    @State private var pending: [String: Task<Void, Never>] = [:]
    /// The mode just tapped, shown as selected until the BedJet reports it.
    @State private var chosenMode: Mode?

    var body: some View {
        let status = model.status
        let mode = status?.mode ?? .standby
        Screen(title: "Remote") {
            ClimateOrb(status: status).frame(maxWidth: .infinity)

            if model.linkState == .yielded {
                Text("In use on another phone. Touch a control to take over.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity)
            }

            ModePicker(modes: Mode.remoteModes + [.standby], selection: chosenMode ?? status?.mode) { mode in
                chosenMode = mode
                Task {
                    await model.setMode(mode)
                    chosenMode = nil
                }
            }

            if let status, status.isRunning {
                Card(padding: 18) {
                    VStack(spacing: 16) {
                        if mode.usesTemperature {
                            TemperatureSlider(mode: mode, temperature: sending($temperature, "temperature") {
                                await model.setTemperature(temperature)
                            }, limits: status.minTemperature < status.maxTemperature ? status.minTemperature...status.maxTemperature : nil)
                        }
                        LabeledSlider(title: "Fan", valueText: "\(Int(fan))%", value: sending($fan, "fan") {
                            await model.setFan(percent: Int(fan))
                        }, range: 5...100, step: 5, tint: mode.tint)
                        if model.run == nil {
                            let limit = runtimeLimit(status)
                            LabeledSlider(title: "Turns off in", valueText: Format.duration(Int(runtime)), value: sending($runtime, "runtime") {
                                await model.setRuntime(minutes: Int(runtime))
                            }, range: limit.range, step: limit.step)
                        } else {
                            // A schedule sets its own timing, so this is read-only until it ends.
                            HStack {
                                Text("Phase ends in").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.secondary)
                                Spacer()
                                Text(Format.duration(minutesLeft(status)))
                                    .font(.system(size: 20, weight: .semibold))
                                    .monospacedDigit()
                            }
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if model.run != nil {
                Text("Choosing a mode here ends the schedule that's running.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.tertiary)
                    .frame(maxWidth: .infinity)
            }
        }
        .disabled(!model.canControl)
        .animation(.smooth(duration: 0.3), value: status?.isRunning)
        .onChange(of: status, initial: true) { _, status in
            // Follow the unit, which can also be changed from its own remote, but never
            // while a slider is being moved or its new value is still on the way there.
            guard let status, !model.isBusy, Date() > followAfter else { return }
            temperature = status.targetTemperature
            fan = Double(status.fanPercent)
            let limit = runtimeLimit(status)
            runtime = min(max(Double(minutesLeft(status)), limit.range.lowerBound), limit.range.upperBound)
        }
    }

    /// A binding that forwards what the person sets to the BedJet shortly after they stop moving the slider.
    /// Only their input passes through the setter, so values applied from the BedJet are never echoed back.
    private func sending<Value>(_ value: Binding<Value>, _ name: String, send: @escaping () async -> Void) -> Binding<Value> {
        Binding {
            value.wrappedValue
        } set: { newValue in
            value.wrappedValue = newValue
            followAfter = Date().addingTimeInterval(1.5)
            pending[name]?.cancel()
            pending[name] = Task {
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                await send()
            }
        }
    }

    private func minutesLeft(_ status: DeviceStatus) -> Int {
        max((status.remainingSeconds + 59) / 60, 1)
    }

    /// How long the current mode may run, as the BedJet reports it, with a step size that suits the span.
    private func runtimeLimit(_ status: DeviceStatus) -> (range: ClosedRange<Double>, step: Double) {
        let longest = status.maxRuntimeMinutes > 0 ? status.maxRuntimeMinutes : status.mode.maxMinutes
        let step = longest <= 15 ? 1 : longest <= 240 ? 5 : 15
        return (Double(step)...Double(max(longest / step * step, step * 2)), Double(step))
    }
}

/// The glowing live readout: what the BedJet is doing this second.
struct ClimateOrb: View {
    @Environment(AppModel.self) private var model
    let status: DeviceStatus?

    var body: some View {
        let mode = status?.mode ?? .standby
        let isOn = status?.isRunning ?? false
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [mode.tint.opacity(isOn ? 0.55 : 0.12), .clear], center: .center, startRadius: 20, endRadius: 112))
                .blur(radius: 24)
            Circle()
                .strokeBorder(
                    AngularGradient(colors: [mode.tint.opacity(0.9), mode.tint.opacity(0.15), mode.tint.opacity(0.9)], center: .center),
                    lineWidth: isOn ? 2.5 : 1
                )
                .padding(8)
            VStack(spacing: 4) {
                if let status {
                    Eyebrow(mode.activity)
                    Text(isOn && mode.usesTemperature ? model.degrees(status.targetTemperature) : isOn ? "\(status.fanPercent)%" : "Off")
                        .font(.system(size: 60, weight: .thin))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(isOn ? "Fan \(status.fanPercent)% · Air \(model.degrees(status.actualTemperature))"
                              : "Room \(model.degrees(status.ambientTemperature))")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                        .monospacedDigit()
                } else {
                    ProgressView()
                    Text("Looking for your BedJet")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                        .padding(.top, 8)
                }
            }
        }
        .frame(width: 204, height: 204)
        .animation(.smooth(duration: 0.6), value: mode)
        .accessibilityElement(children: .combine)
    }
}
