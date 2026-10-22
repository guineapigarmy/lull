import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedTab = 0
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
        @Bindable var bedJet = model.bedJet
        TabView(selection: $selectedTab) {
            Tab("Remote", systemImage: "dial.medium.fill", value: 0) { RemoteView() }
            Tab("Schedule", systemImage: "moon.stars.fill", value: 1) { ScheduleView() }
            Tab("History", systemImage: "clock.arrow.circlepath", value: 2) { HistoryView() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: model.appMovedToBackground()
            case .active: model.appBecameActive()
            default: break
            }
        }
        .alert("Something went wrong", isPresented: .init(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .confirmationDialog("Your BedJet's three slots are full", isPresented: $bedJet.needsSlotChoice, titleVisibility: .visible) {
            ForEach(Array(bedJet.deviceSlots.enumerated()), id: \.offset) { index, program in
                Button("Replace “\(program?.name ?? "Slot \(index + 1)")”") {
                    Task { await bedJet.startTonight(replacingSlot: index) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Lull keeps tonight's schedule in one slot on the BedJet. Pick one to reuse. Everything on the BedJet is already copied into your schedules.")
        }
    }
}

/// Screen scaffold shared by the tabs: large title on the left, BedJet connection on the right.
struct Screen<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content
    @State private var showsDevice = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let subtitle { Eyebrow(subtitle) }
                        Text(title).font(.system(size: 34, weight: .bold))
                    }
                    // A long BedJet name is shortened rather than the screen's title.
                    .layoutPriority(1)
                    Spacer()
                    ConnectionPill { showsDevice = true }
                }
                .padding(.top, 8)
                content
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(Theme.background)
        .sheet(isPresented: $showsDevice) { DeviceSheet() }
    }
}

/// Shows the BedJet's connection and opens its settings. With several BedJets it names the one on
/// screen and switches between them.
struct ConnectionPill: View {
    @Environment(AppModel.self) private var model
    let action: () -> Void

    var body: some View {
        let bedJet = model.bedJet
        if model.hasSeveralBedJets {
            Menu {
                Picker("BedJets", selection: Binding(get: { model.bedJet.id }, set: { model.select($0) })) {
                    ForEach(model.bedJets) { bedJet in
                        Text(model.title(of: bedJet)).tag(bedJet.id)
                    }
                }
                .pickerStyle(.inline)
                Section {
                    Button("Add Another BedJet", systemImage: "plus") { model.addBedJet() }
                    Button("BedJet Settings", systemImage: "gearshape") { action() }
                }
            } label: {
                pill(model.title(of: bedJet), isConnected: bedJet.isConnected, switches: true)
            }
            .menuOrder(.fixed)
            .sensoryFeedback(.selection, trigger: bedJet.id)
            .accessibilityLabel("BedJet, \(model.title(of: bedJet)), \(bedJet.connectionLabel)")
            .accessibilityHint("Switches BedJet")
        } else {
            let label = bedJet.connectionLabel
            Button(action: action) { pill(label, isConnected: bedJet.isConnected) }
                .buttonStyle(.plain)
                .accessibilityLabel("BedJet, \(label)")
        }
    }

    private func pill(_ text: String, isConnected: Bool, switches: Bool = false) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isConnected ? Color.green : Theme.neutral)
                .frame(width: 8, height: 8)
                .symbolEffect(.pulse, isActive: !isConnected)
            Text(text).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            if switches {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.secondary)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(Theme.raised, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline))
    }
}

extension BedJet {
    /// A word or two on how the connection is going, short enough for the pill.
    var connectionLabel: String {
        // Invites a tap through to the things worth checking.
        if isSlowToFind { return "Not found" }
        switch linkState {
        case .ready: return isDemo && !AppModel.labelsDemoAsConnected ? "Demo" : "Connected"
        case .connecting: return "Connecting"
        case .searching: return "Searching"
        case .yielded: return "Other phone"
        case .bluetoothOff: return "Bluetooth off"
        case .unauthorized: return "No access"
        }
    }
}
