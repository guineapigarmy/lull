import SwiftUI

struct DeviceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Status", value: statusText)
                    if let name = model.deviceName { LabeledContent("Name", value: name) }
                    if let firmware = model.firmware { LabeledContent("Firmware", value: firmware) }
                } footer: {
                    Text(help)
                }

                if model.isConnected, let extra = model.status?.extra {
                    Section("BedJet") {
                        Toggle("Light ring", isOn: .init(get: { extra.ledEnabled }, set: { on in Task { await model.setLED(on) } }))
                        Toggle("Mute beeps", isOn: .init(get: { extra.beepsMuted }, set: { muted in Task { await model.setMuted(muted) } }))
                    }
                }

                if !model.deviceSlots.isEmpty {
                    Section {
                        ForEach(Array(model.deviceSlots.enumerated()), id: \.offset) { index, program in
                            LabeledContent("Slot \(index + 1)") {
                                Text(index == model.slot ? "Lull · \(program?.name ?? "Empty")" : program?.name ?? "Empty")
                            }
                        }
                    } header: {
                        Text("Saved on the BedJet")
                    } footer: {
                        Text("Lull keeps tonight's schedule in one slot and leaves the others alone.")
                    }
                }

                Section("App") {
                    Picker("Temperature", selection: $model.useFahrenheit) {
                        Text("°F").tag(true)
                        Text("°C").tag(false)
                    }
                    Toggle("Demo mode", isOn: $model.demoMode)
                    if !model.demoMode {
                        Button("Forget This BedJet", role: .destructive) { model.forgetDevice() }
                    }
                }
            }
            .tint(.green)
            .navigationTitle("BedJet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private var statusText: String {
        switch model.linkState {
        case .ready: return model.demoMode ? "Demo BedJet" : "Connected"
        case .connecting: return "Connecting…"
        case .searching: return "Searching…"
        case .yielded: return "In use on another phone"
        case .bluetoothOff: return "Bluetooth is off"
        case .unauthorized: return "Bluetooth not allowed"
        }
    }

    private var help: String {
        switch model.linkState {
        case .ready: return model.demoMode ? "Demo mode uses a pretend BedJet so you can explore the app." : "Everything stays between this phone and your BedJet. No account, no cloud."
        case .connecting, .searching: return "Stand near your BedJet and close the official BedJet app. The BedJet talks to one phone at a time; phones with Lull hand it over to each other automatically."
        case .yielded: return "The BedJet talks to one phone at a time, and another phone with Lull asked for it. Use any control here to take it back."
        case .bluetoothOff: return "Turn on Bluetooth in Control Center to connect."
        case .unauthorized: return "Allow Bluetooth for Lull in Settings to connect."
        }
    }
}
