import BedJetKit
import SwiftUI

struct DeviceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(BedJet.self) private var bedJet
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                if model.hasSeveralBedJets {
                    KnownBedJets(footer: "Every screen shows the ticked BedJet. Switch from the top of any screen too.")
                }

                Section {
                    LabeledContent("Nickname") {
                        // The example would clip at the largest text sizes, where the field is narrow.
                        TextField("Nickname", text: nickname, prompt: typeSize.isAccessibilitySize ? nil : Text("Such as My side"))
                            .multilineTextAlignment(.trailing)
                            .submitLabel(.done)
                    }
                    LabeledContent("Status", value: statusText)
                    if let name = bedJet.name { LabeledContent("Name", value: name) }
                    LabeledContent("Kind", value: bedJet.knownGeneration?.title ?? "Known once it connects")
                    if let firmware = bedJet.firmware { LabeledContent("Firmware", value: firmware) }
                } header: {
                    Text(model.title(of: bedJet))
                } footer: {
                    Text(help)
                }

                if bedJet.isSlowToFind {
                    Section {
                        Label("Lull works with BedJet 3 and BedJet V2. The original BedJet isn't supported.", systemImage: "bed.double")
                        Label("Force-quit the BedJet app: swipe up from the bottom of the screen, then swipe the app away.", systemImage: "xmark.app")
                        Label("Close the BedJet app on any other phone or tablet nearby.", systemImage: "iphone")
                        Label("Unplug the BedJet for 10 seconds, then plug it back in.", systemImage: "powerplug")
                        NavigationLink { NearbyBedJets() } label: { Label("Choose Another BedJet", systemImage: "list.bullet") }
                            .disabled(!model.canSwitch)
                    } header: {
                        Text("Can't find \(model.title(of: bedJet))?")
                    } footer: {
                        Text("Lull keeps looking for this BedJet while it's open, and never connects to a different one by itself.")
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
                                    .accessibilityLabel(index == bedJet.slot ? "Used by Lull, \(program?.name ?? "empty")" : program?.name ?? "Empty")
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
                        NavigationLink { NearbyBedJets() } label: { Label("Add Another BedJet", systemImage: "plus") }
                            .disabled(!model.canSwitch)
                    } footer: {
                        Text("Have a BedJet on each side of the bed? Add both, then switch between them from the top of any screen.")
                    }
                }

                Section {
                    Button("Forget This BedJet", role: .destructive) {
                        dismiss()
                        model.forget(bedJet)
                    }
                } footer: {
                    Text("The BedJet keeps running as it is, and its history stays on this phone in case you choose it again.")
                }

                Section("App") {
                    Picker("Temperature", selection: $model.useFahrenheit) {
                        Text("°F").tag(true).accessibilityLabel("Fahrenheit")
                        Text("°C").tag(false).accessibilityLabel("Celsius")
                    }
                    Toggle("Demo mode", isOn: $model.demoMode)
                }
            }
            .tint(.green)
            .navigationTitle(model.hasSeveralBedJets ? "BedJets" : "BedJet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    /// Kept on this phone only; the BedJet's own name is left alone.
    private var nickname: Binding<String> {
        Binding { bedJet.nickname ?? "" } set: { bedJet.nickname = $0.isEmpty ? nil : String($0.prefix(30)) }
    }

    private var statusText: String {
        switch bedJet.linkState {
        case .ready: return model.demoMode ? "Demo BedJet" : "Connected"
        case .connecting: return "Connecting…"
        case .searching: return bedJet.isSlowToFind ? "Not found" : "Searching…"
        case .yielded: return "In use on another phone"
        case .bluetoothOff: return "Bluetooth is off"
        case .unauthorized: return "Bluetooth not allowed"
        }
    }

    private var help: String {
        switch bedJet.linkState {
        case .ready: return model.demoMode ? "Demo mode uses a pretend BedJet so you can explore the app." : "Everything stays between this phone and your BedJet. No account, no cloud."
        case .connecting, .searching:
            return "Stand near your BedJet and force-quit the official BedJet app. The BedJet talks to one phone at a time; phones with Lull hand it over to each other automatically."
        case .yielded: return "The BedJet talks to one phone at a time, and another phone with Lull asked for it. Use any control here to take it back."
        case .bluetoothOff: return "Turn on Bluetooth in Control Center to connect."
        case .unauthorized: return "Allow Bluetooth for Lull in Settings to connect."
        }
    }
}

/// Every BedJet this phone knows, to switch between. Ticked is the one on screen; each says how it's connected.
struct KnownBedJets: View {
    @Environment(AppModel.self) private var model
    var footer: String
    var offersAdding = true

    var body: some View {
        Section {
            ForEach(model.bedJets) { bedJet in
                let isShown = bedJet.id == model.selectedID
                let title = model.title(of: bedJet)
                Button { model.select(bedJet.id) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title).foregroundStyle(.white)
                            Text([bedJet.knownGeneration?.title, bedJet.connectionLabel].compactMap { $0 }.joined(separator: " · "))
                                .font(.footnote)
                                .foregroundStyle(Theme.secondary)
                        }
                        Spacer()
                        if isShown { Image(systemName: "checkmark").font(.body.weight(.semibold)) }
                    }
                    .contentShape(Rectangle())
                }
                .disabled(!isShown && !model.canSwitch)
                .accessibilityLabel("\(title), \(bedJet.spokenConnectionLabel)")
                .accessibilityAddTraits(isShown ? .isSelected : [])
            }
            if offersAdding {
                NavigationLink { NearbyBedJets() } label: { Label("Add Another BedJet", systemImage: "plus") }
                    .disabled(!model.canSwitch)
            }
        } header: {
            Text("Your BedJets")
        } footer: {
            if !model.canSwitch, let bedJet = model.bedJet {
                Text("Switching waits until the schedule finishes saving to \(model.title(of: bedJet)).")
            } else {
                Text(footer)
            }
        }
    }
}

/// BedJets advertising nearby, to pick one. Looking never connects to any of them or changes anything.
struct NearbyBedJets: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Part of a larger list rather than a screen of its own.
    var embedded = false

    var body: some View {
        if embedded {
            nearby
        } else {
            Form { nearby }
                .tint(.green)
                .navigationTitle("Add a BedJet")
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var nearby: some View {
        Section {
            ForEach(model.nearby) { unit in
                let title = model.title(of: unit)
                Button {
                    model.choose(unit)
                    if !embedded { dismiss() }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title).foregroundStyle(.white)
                            Text("\(unit.generation?.title ?? "BedJet") · \(unit.signal.rawValue) signal")
                                .font(.footnote)
                                .foregroundStyle(Theme.secondary)
                        }
                        Spacer()
                        Image(systemName: "cellularbars", variableValue: unit.signal == .strong ? 1 : unit.signal == .fair ? 0.6 : 0.3)
                            .foregroundStyle(Theme.secondary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .disabled(!model.canSwitch)
                .accessibilityLabel("\(title), \(unit.generation?.title ?? "BedJet"), \(unit.signal.rawValue.lowercased()) signal")
                .accessibilityHint("Adds this BedJet and shows it")
            }
            looking
        } header: {
            Text("Nearby")
        } footer: {
            Text("A BedJet shows here while no phone is connected to it. If yours is missing, close the BedJet app, and Lull on other phones, then wait a moment. "
                 + "Signal is a hint, not proof: the strongest isn't always the closest. A code after a name tells apart BedJets with the same name; give yours a nickname in BedJet settings.")
        }
        .onAppear { model.startLooking() }
        .onDisappear { model.stopLooking() }
    }

    @ViewBuilder
    private var looking: some View {
        switch model.lookingState {
        case .bluetoothOff:
            Label("Turn on Bluetooth in Control Center to look for BedJets.", systemImage: "antenna.radiowaves.left.and.right.slash")
        case .unauthorized:
            Label("Allow Bluetooth for Lull in Settings to look for BedJets.", systemImage: "lock")
        default:
            HStack(spacing: 12) {
                ProgressView()
                Text(model.nearby.isEmpty ? "Looking for BedJets…" : "Looking for more…").foregroundStyle(Theme.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// Shown until a BedJet is chosen: on first launch, and after forgetting the one on screen.
struct ChooseBedJetView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    Text("Pick the BedJet this phone should control. Lull only ever connects to BedJets you pick, so a partner's stays theirs.")
                        .foregroundStyle(Theme.secondary)
                }
                if !model.bedJets.isEmpty {
                    KnownBedJets(footer: "Pick one to show, or add another below.", offersAdding: false)
                }
                NearbyBedJets(embedded: true)
                Section {
                    Toggle("Demo mode", isOn: $model.demoMode)
                } footer: {
                    Text("No BedJet nearby? Demo mode uses pretend ones so you can explore the app.")
                }
            }
            .tint(.green)
            .navigationTitle("Choose Your BedJet")
        }
    }
}

extension Generation {
    var title: String {
        switch self {
        case .v3: "BedJet 3"
        case .v2: "BedJet V2"
        }
    }
}
