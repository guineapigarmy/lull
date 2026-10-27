import BedJetKit
import Foundation

/// What the watch asks the phone to do. The watch never reaches the BedJet itself: Lull on the phone holds the
/// Bluetooth link, so it connects, does the errand, lets go again, and hands back what the widgets show.
///
/// Sent as JSON with its keys in order, the same bytes as the Android apps send, so one test pins both.
enum WatchCommand: Equatable {
    /// Starts tonight's schedule on a BedJet, or on the one on screen on the phone when none is named.
    case startNight(UUID?)
    /// Ends the schedule running on a BedJet, turning it off.
    case endNight(UUID?)
    /// Sets a BedJet as the Remote does: a mode, and the temperature, fan and timer to run it at.
    case remote(RemotePreset, UUID?)
    /// Asks what the BedJets are doing now, for a watch that hasn't heard in a while.
    case refresh

    /// The BedJet it's for, or nil for the one on screen on the phone.
    var bedJet: UUID? {
        switch self {
        case let .startNight(id), let .endNight(id), let .remote(_, id): id
        case .refresh: nil
        }
    }

    /// Whether the phone says how it went. A refresh only hands over what the widgets show: the watch waits on one
    /// errand at a time and takes any reply as that errand's, so a refresh's would end an errand sent while it ran.
    var isAnswered: Bool { self != .refresh }

    var data: Data { (try? WatchMessages.encoder.encode(self)) ?? Data() }

    init?(data: Data) {
        guard let command = try? JSONDecoder().decode(WatchCommand.self, from: data) else { return nil }
        self = command
    }
}

extension WatchCommand: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, bedJet, mode, minutes, temperature, fanPercent
    }

    private enum Kind: String, Codable {
        case startNight, endNight, remote, refresh
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // One named but unreadable is refused rather than taken as none named, which would mean the one on screen.
        let named = try values.decodeIfPresent(String.self, forKey: .bedJet)
        let bedJet = named.flatMap(UUID.init)
        if named != nil, bedJet == nil {
            throw DecodingError.dataCorruptedError(forKey: .bedJet, in: values, debugDescription: "Unreadable BedJet")
        }
        switch try values.decode(Kind.self, forKey: .kind) {
        case .startNight: self = .startNight(bedJet)
        case .endNight: self = .endNight(bedJet)
        case .refresh: self = .refresh
        case .remote:
            // Named as the Quick Remote names them, so a mode the BedJet adds later can't be mistaken for another.
            guard let mode = RemoteMode(rawValue: try values.decode(String.self, forKey: .mode))?.mode else {
                throw DecodingError.dataCorruptedError(forKey: .mode, in: values, debugDescription: "Unknown mode")
            }
            let preset = RemotePreset(mode: mode, minutes: try values.decode(Int.self, forKey: .minutes),
                                      temperature: try values.decode(Int.self, forKey: .temperature),
                                      fanPercent: try values.decode(Int.self, forKey: .fanPercent))
            self = .remote(preset, bedJet)
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(bedJet?.uuidString, forKey: .bedJet)
        switch self {
        case .startNight: try values.encode(Kind.startNight, forKey: .kind)
        case .endNight: try values.encode(Kind.endNight, forKey: .kind)
        case .refresh: try values.encode(Kind.refresh, forKey: .kind)
        case let .remote(preset, _):
            try values.encode(Kind.remote, forKey: .kind)
            try values.encode(RemoteMode(preset.mode).rawValue, forKey: .mode)
            try values.encode(preset.minutes, forKey: .minutes)
            try values.encode(preset.temperature, forKey: .temperature)
            try values.encode(preset.fanPercent, forKey: .fanPercent)
        }
    }
}

/// How an errand from the watch went. The phone answers at once that it's on it, then again once it's done.
struct WatchReply: Codable, Equatable {
    var ok: Bool
    /// What went wrong, in the words the phone's alert would use.
    var message: String?

    static let done = WatchReply(ok: true)

    static func failed(_ message: String) -> WatchReply { WatchReply(ok: false, message: message) }

    var data: Data { (try? WatchMessages.encoder.encode(self)) ?? Data() }

    init(ok: Bool, message: String? = nil) {
        self.ok = ok
        self.message = message
    }

    init?(data: Data) {
        guard let reply = try? JSONDecoder().decode(WatchReply.self, from: data) else { return nil }
        self = reply
    }
}

/// Where each kind of message goes between the phone and the watch.
enum WatchMessages {
    /// A command from the watch.
    static let command = "command"
    /// How a command went.
    static let reply = "reply"
    /// What the widgets show, which the watch shows too.
    static let snapshot = "snapshot"
    /// When the iPhone handed that over. Watch Connectivity delivers queued transfers whenever it can, so one can arrive
    /// after something newer; the watch keeps the newest. Wear OS messages arrive in order or not at all.
    static let snapshotAt = "snapshotAt"

    fileprivate static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}
