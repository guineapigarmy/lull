import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedTab = 0
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
        TabView(selection: $selectedTab) {
            Tab("Remote", systemImage: "dial.medium.fill", value: 0) { RemoteView() }
            Tab("Schedule", systemImage: "moon.stars.fill", value: 1) { ScheduleView() }
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
        .confirmationDialog("Your BedJet's three slots are full", isPresented: $model.needsSlotChoice, titleVisibility: .visible) {
            ForEach(Array(model.deviceSlots.enumerated()), id: \.offset) { index, program in
                Button("Replace “\(program?.name ?? "Slot \(index + 1)")”") {
                    Task { await model.startTonight(replacingSlot: index) }
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

struct ConnectionPill: View {
    @Environment(AppModel.self) private var model
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.isConnected ? Color.green : Theme.neutral)
                    .frame(width: 8, height: 8)
                    .symbolEffect(.pulse, isActive: !model.isConnected)
                Text(label).font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(Theme.raised, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.hairline))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("BedJet, \(label)")
    }

    private var label: String {
        // Invites a tap through to the things worth checking.
        if model.isSlowToFind { return "Not found" }
        switch model.linkState {
        case .ready: return model.demoMode && !AppModel.labelsDemoAsConnected ? "Demo" : "Connected"
        case .connecting: return "Connecting"
        case .searching: return "Searching"
        case .yielded: return "Other phone"
        case .bluetoothOff: return "Bluetooth off"
        case .unauthorized: return "No access"
        }
    }
}
