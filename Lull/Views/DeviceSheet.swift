import SwiftUI

struct DeviceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        let bedJet = model.bedJet
        NavigationStack {
            Form {
                if model.hasSeveralBedJets { bedJets }

                Section {
                    LabeledContent("Status", value: statusText)
                    if let name = bedJet.name { LabeledContent("Name", value: name) }
                    if let firmware = bedJet.firmware { LabeledContent("Firmware", value: firmware) }
                } header: {
                    if model.hasSeveralBedJets { Text(model.title(of: bedJet)) }
                } footer: {
                    Text(help)
                }

                if bedJet.isSlowToFind {
                    Section {
                        Label("Lull works with BedJet 3 and BedJet V2. The original BedJet isn't supported.", systemImage: "bed.double")
                        Label("Force-quit the BedJet app: swipe up from the bottom of the screen, then swipe the app away.", systemImage: "xmark.app")
                        Label("Close the BedJet app on any other phone or tablet nearby.", systemImage: "iphone")
                        Label("Unplug the BedJet for 10 seconds, then plug it back in.", systemImage: "powerplug")
                    } header: {
                        Text("Can't find your BedJet?")
                    } footer: {
                        Text("Lull keeps looking while it's open.")
                    }
                }

                if bedJet.isConnected, let extra = bedJet.status?.extra {
                    Section("BedJet") {
                        Toggle("Light ring", isOn: .init(get: { extra.ledEnabled }, set: { on in Task { await bedJet.setLED(on) } }))
                        Toggle("Mute beeps", isOn: .init(get: { extra.beepsMuted }, set: { muted in Task { await bedJet.setMuted(muted) } }))
                    }
                }

                if !bedJet.deviceSlots.isEmpty {
                    Section {
                        ForEach(Array(bedJet.deviceSlots.enumerated()), id: \.offset) { index, program in
                            LabeledContent("Slot \(index + 1)") {
                                Text(index == bedJet.slot ? "Lull · \(program?.name ?? "Empty")" : program?.name ?? "Empty")
                            }
                        }
                    } header: {
                        Text("Saved on the BedJet")
                    } footer: {
                        Text("Lull keeps tonight's schedule in one slot and leaves the others alone.")
                    }
                }

                if !model.hasSeveralBedJets {
                    Section {
                        addButton
                    } footer: {
                        Text("Have a BedJet on each side of the bed? Add both, then switch between them from the top of any screen.")
                    }
                }

                Section("App") {
                    Picker("Temperature", selection: $model.useFahrenheit) {
                        Text("°F").tag(true)
                        Text("°C").tag(false)
                    }
                    Toggle("Demo mode", isOn: $model.demoMode)
                    if !model.demoMode || model.hasSeveralBedJets {
                        Button("Forget This BedJet", role: .destructive) { model.forget(bedJet) }
                    }
                }
            }
            .tint(.green)
            .navigationTitle(model.hasSeveralBedJets ? "BedJets" : "BedJet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    /// Every BedJet, to switch between. The sections below are about the ticked one.
    private var bedJets: some View {
        Section {
            ForEach(model.bedJets) { bedJet in
                let isShown = bedJet === model.bedJet
                Button { model.select(bedJet.id) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.title(of: bedJet)).foregroundStyle(.white)
                            Text(bedJet.connectionLabel)
                                .font(.footnote)
                                .foregroundStyle(Theme.secondary)
                        }
                        Spacer()
                        if isShown { Image(systemName: "checkmark").font(.body.weight(.semibold)) }
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityAddTraits(isShown ? .isSelected : [])
            }
            addButton
        } header: {
            Text("Your BedJets")
        } footer: {
            Text("Every screen shows the ticked BedJet. Switch from the top of any screen too.")
        }
    }

    private var addButton: some View {
        Button("Add Another BedJet", systemImage: "plus") { model.addBedJet() }
    }

    private var statusText: String {
        switch model.bedJet.linkState {
        case .ready: return model.demoMode ? "Demo BedJet" : "Connected"
        case .connecting: return "Connecting…"
        case .searching: return "Searching…"
        case .yielded: return "In use on another phone"
        case .bluetoothOff: return "Bluetooth is off"
        case .unauthorized: return "Bluetooth not allowed"
        }
    }

    private var help: String {
        switch model.bedJet.linkState {
        case .ready: return model.demoMode ? "Demo mode uses a pretend BedJet so you can explore the app." : "Everything stays between this phone and your BedJet. No account, no cloud."
        case .connecting, .searching:
            if model.bedJet.unit == nil, model.hasSeveralBedJets, !model.demoMode {
                return "Turn on the BedJet you're adding and stand near it. Lull connects to the first one it finds that it doesn't already know."
            }
            return "Stand near your BedJet and force-quit the official BedJet app. The BedJet talks to one phone at a time; phones with Lull hand it over to each other automatically."
        case .yielded: return "The BedJet talks to one phone at a time, and another phone with Lull asked for it. Use any control here to take it back."
        case .bluetoothOff: return "Turn on Bluetooth in Control Center to connect."
        case .unauthorized: return "Allow Bluetooth for Lull in Settings to connect."
        }
    }
}
