import BedJetKit
import Foundation
import WatchConnectivity

/// How the watch reaches Lull on the iPhone, which reaches the BedJet. The watch has no Bluetooth link of its own to
/// the BedJet, so everything it does is an errand the iPhone runs.
@MainActor
protocol Phone: AnyObject {
    /// Whether Lull on the iPhone can be asked now. It's woken in the background if it isn't running.
    var isReachable: Bool { get }
    var onReachabilityChange: (() -> Void)? { get set }
    /// What the widgets show, handed over whenever it changes and with each reply.
    var onSnapshot: ((WidgetSnapshot) -> Void)? { get set }
    /// How an errand went, once the iPhone has done it.
    var onReply: ((WatchReply) -> Void)? { get set }
    func activate()
    /// Hands the iPhone an errand. Returns its answer when it refused at once, or nil once it's on it.
    func send(_ command: WatchCommand) async throws -> WatchReply?
}

/// Lull on the paired iPhone, over Watch Connectivity.
@MainActor
final class PhoneLink: NSObject, Phone {
    private let session = WCSession.default
    private(set) var isReachable = false
    var onReachabilityChange: (() -> Void)?
    var onSnapshot: ((WidgetSnapshot) -> Void)?
    var onReply: ((WatchReply) -> Void)?

    func activate() {
        guard session.delegate == nil else { return }
        session.delegate = self
        session.activate()
    }

    func send(_ command: WatchCommand) async throws -> WatchReply? {
        try await withCheckedThrowingContinuation { answered in
            session.sendMessage([WatchMessages.command: command.data], replyHandler: { answer in
                answered.resume(returning: (answer[WatchMessages.reply] as? Data).flatMap(WatchReply.init(data:)))
            }, errorHandler: { error in
                answered.resume(throwing: error)
            })
        }
    }

    /// Takes in what the iPhone sent while the watch app wasn't running, when the system wakes it to.
    func drain() async {
        activate()
        let deadline = Date().addingTimeInterval(10)
        while session.activationState != .activated || session.hasContentPending, Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// When the iPhone made the snapshot shown now.
    private var shownAt: Date?

    private func receive(_ message: [String: Any]) {
        if let data = message[WatchMessages.snapshot] as? Data, let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) {
            // A transfer queued while the watch was away can arrive after something newer.
            let madeAt = message[WatchMessages.snapshotAt] as? Date
            if let madeAt, let shownAt, madeAt < shownAt {
                // Older than what's shown: only its answer, if any, still counts.
            } else {
                shownAt = madeAt ?? shownAt
                onSnapshot?(snapshot)
            }
        }
        if let data = message[WatchMessages.reply] as? Data, let reply = WatchReply(data: data) {
            onReply?(reply)
        }
    }

    private func reachabilityChanged() {
        isReachable = session.activationState == .activated && session.isReachable
        onReachabilityChange?()
    }
}

extension PhoneLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        let context = session.receivedApplicationContext
        Task { @MainActor in
            self.reachabilityChanged()
            self.receive(context)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.reachabilityChanged() }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        Task { @MainActor in self.receive(context) }
    }

    /// What the complications show, sent to wake the watch when it changes.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { @MainActor in self.receive(userInfo) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in self.receive(message) }
    }
}

/// A pretend iPhone, for the simulator on its own, tests and screenshots (`-demo`). It does what it's asked a moment
/// later, as Lull on the iPhone does with a simulated BedJet.
@MainActor
final class DemoPhone: Phone {
    var isReachable = true { didSet { onReachabilityChange?() } }
    var onReachabilityChange: (() -> Void)?
    var onSnapshot: ((WidgetSnapshot) -> Void)?
    var onReply: ((WatchReply) -> Void)?
    private(set) var snapshot: WidgetSnapshot
    /// Every errand it was handed, oldest first.
    private(set) var received: [WatchCommand] = []
    /// How long it takes to do an errand. Nil holds every errand until `finish()`.
    var delay: TimeInterval? = 0.6
    /// What the next errand says went wrong, if anything.
    var failure: String?
    /// How far into the night a night it starts appears, as `-demoElapsedMinutes` makes it.
    var elapsedMinutes = 0
    /// Off, errands don't get through though it's reachable, as when the iPhone drops out between asking and sending.
    var delivers = true
    private var held: [WatchCommand] = []

    init(snapshot: WidgetSnapshot) {
        self.snapshot = snapshot
    }

    func activate() {
        onSnapshot?(snapshot)
    }

    func send(_ command: WatchCommand) async throws -> WatchReply? {
        guard isReachable, delivers else { throw WCError(.notReachable) }
        received.append(command)
        if let delay {
            Task {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                self.answer(command)
            }
        } else {
            held.append(command)
        }
        return nil
    }

    /// Does the errands it was holding, oldest first: all of them, or only so many.
    func finish(_ count: Int = .max) {
        let waiting = Array(held.prefix(count))
        held.removeFirst(waiting.count)
        waiting.forEach(answer)
    }

    private func answer(_ command: WatchCommand) {
        if let failure, command.isAnswered {
            self.failure = nil
            onReply?(.failed(failure))
            return
        }
        let now = Date()
        if let index = snapshot.bedJets.firstIndex(where: { $0.id == (command.bedJet ?? snapshot.onScreen) }) {
            var bedJet = snapshot.bedJets[index]
            switch command {
            case .startNight:
                // A night already under way is left running, as on the iPhone.
                let isRunning = if case .night? = bedJet.live(at: now) { true } else { false }
                if !isRunning, let tonight = bedJet.tonight {
                    let startedAt = now.addingTimeInterval(TimeInterval(-elapsedMinutes * 60))
                    // As the phone starts it: with a wake time, scaled to end at it.
                    bedJet.live = .night(ActiveRun(schedule: tonight.resolved(startingAt: Format.minuteOfDay(startedAt)), startedAt: startedAt))
                }
            case .endNight:
                bedJet.live = nil
            case let .remote(preset, _):
                let preset = preset.clamped
                bedJet.live = preset.mode == .standby ? nil : .air(
                    mode: preset.mode,
                    temperature: bedJet.generation.adjustsTemperature(preset.mode) ? preset.temperature : nil,
                    fanPercent: preset.fanPercent,
                    endsAt: now.addingTimeInterval(TimeInterval(preset.minutes * 60)))
            case .refresh:
                break
            }
            snapshot.bedJets[index] = bedJet
            if bedJet.id == snapshot.onScreen {
                snapshot.run = if case let .night(run)? = bedJet.live { run } else { nil }
            }
        }
        onSnapshot?(snapshot)
        if command.isAnswered { onReply?(.done) }
    }
}
