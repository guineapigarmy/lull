import Foundation

/// Byte-level encoding for the BedJet V2, which speaks a serial protocol through a Microchip BLE UART bridge.
///
/// Every packet is `prefix, length, type, payload…, checksum`. The phone sends prefix 0x58 and the unit
/// answers with 0x59; `length` counts the type and payload, and the checksum makes every byte sum to 0xff.
/// Worked out from the official BedJet Android app; see docs/BEDJET_V2_PROTOCOL.md.
public enum CodecV2 {
    static let commandPrefix: UInt8 = 0x58
    static let replyPrefix: UInt8 = 0x59

    /// Requests understood by `BedJetLink.query` on a V2.
    public enum Query {
        /// Protocol and firmware versions, and which sequence format the unit takes.
        public static let info: UInt8 = 0x0b
        /// The unit's name, a 16-byte parameter.
        public static let deviceName: UInt8 = 0x02
    }

    /// Oldest firmware that runs sequences; the official app hides them below it.
    public static let sequenceFirmware = 48
    /// The unit reports the running step in five bits, so a sequence can't be longer than this.
    public static let stepsPerSequence = 31
    /// Heat targets the unit accepts, in half-degrees Celsius.
    public static let heatRange = 44...80

    // MARK: Framing

    static func frame(_ type: UInt8, _ payload: [UInt8] = []) -> Data {
        var bytes = [commandPrefix, UInt8(payload.count + 1), type] + payload
        bytes.append(checksum(bytes))
        return Data(bytes)
    }

    static func checksum<Bytes: Sequence>(_ bytes: Bytes) -> UInt8 where Bytes.Element == UInt8 {
        ~bytes.reduce(0, &+)
    }

    /// Splits the unit's byte stream into packets. Notifications can end partway through a packet,
    /// so whatever is incomplete stays in `buffer` for the next one; bytes that can't start a packet are dropped.
    public static func takePackets(from buffer: inout Data) -> [Data] {
        let bytes = [UInt8](buffer)
        var packets: [Data] = []
        var start = 0
        var rest = bytes.endIndex
        while let prefix = bytes[start...].firstIndex(of: replyPrefix) {
            guard prefix + 1 < bytes.count else { rest = prefix; break }
            let length = Int(bytes[prefix + 1]) + 3
            // Real packets are short, so a long length means this 0x59 was data rather than a prefix.
            guard length > 3, length <= 64 else { start = prefix + 1; continue }
            guard prefix + length <= bytes.count else { rest = prefix; break }
            let packet = bytes[prefix..<(prefix + length)]
            if checksum(packet.dropLast()) == packet.last {
                packets.append(Data(packet))
                start = prefix + length
            } else {
                start = prefix + 1
            }
        }
        buffer = Data(bytes[rest...])
        return packets
    }

    // MARK: Commands

    public static func request(_ query: UInt8) -> Data {
        query == Query.info ? frame(0x0b) : frame(0x06, [query, 16])
    }

    /// Modes are buttons: pressing one switches to that mode, and pressing the one the unit is in turns it off.
    public static func setMode(_ mode: Mode, from current: Mode) -> Data? {
        guard mode != current else { return nil }
        return button(for: mode == .standby ? current : mode).map { frame(0x01, [$0]) }
    }

    public static func setTemperature(_ halfDegrees: Int, from status: DeviceStatus) -> Data {
        scene(status, temperature: halfDegrees)
    }

    public static func setFan(step: Int, from status: DeviceStatus) -> Data {
        scene(status, fanStep: step)
    }

    public static func setRuntime(minutes: Int, from status: DeviceStatus) -> Data {
        scene(status, seconds: minutes * 60)
    }

    public static func setSettings(ledOn: Bool, muted: Bool) -> Data {
        frame(0x11, [(muted ? 0x01 : 0) | (ledOn ? 0 : 0x02)])
    }

    /// Temperature, fan and timer are set together, so whatever isn't changing is repeated from the status.
    static func scene(_ status: DeviceStatus, temperature: Int? = nil, fanStep: Int? = nil, seconds: Int? = nil) -> Data {
        let remaining = max(seconds ?? status.remainingSeconds, 0)
        let target = UInt8(clamping: min(max(temperature ?? status.targetTemperature, 0), 0x7f))
        let muted = status.extra?.beepsMuted == true
        return frame(0x0e, [
            statusCode(for: status.mode),
            UInt8(min(max(fanStep ?? status.fanStep, 0), 19) + 1),
            target | (muted ? 0x80 : 0),
            UInt8(min(remaining / 3600, 12)),
            UInt8(remaining / 60 % 60),
            UInt8(remaining % 60),
        ])
    }

    // MARK: Sequences

    /// Empties the unit's sequence before new steps are written.
    public static let clearSequence = frame(0x0c)

    /// One step, written to the parameter for its position. Units that take the newer format have one more byte.
    public static func writeStep(_ step: ProgramStep, index: Int, minutes: Int, extended: Bool) throws -> Data {
        guard let mode = stepCode(for: step.mode) else { throw BedJetError.invalidProgram(unsupportedModes) }
        let target: Int = switch step.mode {
        case .heat: min(max(step.temperature, heatRange.lowerBound), heatRange.upperBound)
        // The official app stores these, and the unit ignores them.
        case .cool: 40
        default: 80
        }
        var payload: [UInt8] = [
            UInt8(0x80 + index), extended ? 7 : 6,
            mode, UInt8(min(max(step.fanStep, 0), 19) + 1), UInt8(minutes / 60), UInt8(minutes % 60), 0, UInt8(target),
        ]
        if extended { payload.append(0) }
        return frame(0x05, payload)
    }

    /// Ten bytes the official app stores alongside a sequence to recognise it later.
    public static func tagSequence(_ tag: [UInt8]) -> Data {
        frame(0x05, [0x03, 0x0a] + tag.prefix(10) + Array(repeating: 0, count: max(0, 10 - tag.count)))
    }

    /// Starts the stored sequence. Units that take the newer format are given the time of day with it.
    public static func runSequence(at time: DateComponents?, extended: Bool) -> Data {
        guard extended, let time else { return frame(0x0d) }
        return frame(0x0d, [UInt8(time.hour ?? 0), UInt8(time.minute ?? 0), UInt8(time.second ?? 0)])
    }

    static let unsupportedModes = "A BedJet V2 doesn't have Gentle heat or Dry. Change those phases to Heat or Cool."

    // MARK: Replies

    public struct Info: Equatable, Sendable {
        public var protocolVersion: Int
        public var firmware: Int
        /// Steps are written in the longer format and the run command carries the time of day.
        public var extendedSequences: Bool
        public var runsSequences: Bool { firmware >= CodecV2.sequenceFirmware }
    }

    /// The payload of the reply to `query`, or nil when the packet answers something else.
    public static func reply(to query: UInt8, in packet: Data) -> Data? {
        let b = [UInt8](packet)
        guard b.count >= 4, b[0] == replyPrefix else { return nil }
        if query == Query.info { return b[2] == 0x01 ? Data(b[3..<(b.count - 1)]) : nil }
        guard b[2] == 0x05, b.count >= 5, b[3] == query else { return nil }
        return Data(b[4..<(b.count - 1)])
    }

    public static func parseInfo(_ payload: Data) -> Info? {
        let b = [UInt8](payload)
        guard b.count >= 2 else { return nil }
        let firmware = Int(b[1])
        let newerFormat = b.count > 7 && b[7] & 0x01 != 0
        return Info(protocolVersion: Int(b[0]), firmware: firmware, extendedSequences: newerFormat && firmware >= 53)
    }

    /// A unit that was never named answers with no bytes.
    public static func parseName(_ payload: Data) -> String {
        String(decoding: payload.prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    public static func parseStatus(_ packet: Data) -> DeviceStatus? {
        let b = [UInt8](packet)
        guard b.count >= 14, b[0] == replyPrefix, b[2] == 0x02, let mode = mode(forStatusCode: b[4] >> 5 & 0x07) else { return nil }
        let fanStep = max(Int(b[4] & 0x1f) - 1, 0)
        let target = Int(b[7] & 0x7f)
        let actual = Int(b[3] & 0x7f)
        let hours = Int(b[5] >> 4), minutes = Int((b[5] << 2) & 0x3c | b[6] >> 6), seconds = Int(b[6] & 0x3f)
        let limits: ClosedRange<Int> = switch mode {
        case .heat: heatRange
        case .turbo: 86...86
        case .cool: 44...44
        default: 80...80
        }
        let longest: Int = switch mode {
        case .turbo: 10
        case .heat: ProgramStep.longestMinutes(mode: .heat, temperature: target, fanStep: fanStep)
        case .cool: 12 * 60
        default: 0
        }
        return DeviceStatus(
            remainingSeconds: hours * 3600 + minutes * 60 + seconds,
            actualTemperature: actual,
            targetTemperature: target,
            mode: mode,
            fanStep: fanStep,
            maxRuntimeMinutes: longest,
            minTemperature: limits.lowerBound,
            maxTemperature: limits.upperBound,
            // The V2 has no room sensor; with the air off, its air sensor reads the room.
            ambientTemperature: actual,
            lastShutdownReason: b[1] > 10 ? Int(b[12]) : 0,
            extra: .init(
                ledEnabled: b[3] & 0x80 == 0,
                beepsMuted: b[8] & 0x80 != 0,
                programStep: Int(b[10] >> 3 & 0x1f),
                notification: 0
            )
        )
    }

    // MARK: Modes

    /// The V2 reports off, Turbo, Heat and Cool as 0 to 3 and has no other modes.
    static func mode(forStatusCode code: UInt8) -> Mode? {
        switch code {
        case 0: return .standby
        case 1: return .turbo
        case 2: return .heat
        case 3: return .cool
        default: return nil
        }
    }

    static func statusCode(for mode: Mode) -> UInt8 {
        switch mode {
        case .turbo: return 1
        case .heat: return 2
        case .cool: return 3
        default: return 0
        }
    }

    /// Sequence steps use the same codes, with 0 meaning wait rather than off.
    static func stepCode(for mode: Mode) -> UInt8? {
        switch mode {
        case .wait: return 0
        case .turbo, .heat, .cool: return statusCode(for: mode)
        default: return nil
        }
    }

    static func button(for mode: Mode) -> UInt8? {
        switch mode {
        case .turbo: return 0x01
        case .heat: return 0x02
        case .cool: return 0x03
        default: return nil
        }
    }
}
