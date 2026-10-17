import Foundation

/// Operating modes as the BedJet 3 reports them and stores them in program steps.
public enum Mode: UInt8, Codable, CaseIterable, Sendable {
    case standby = 0
    case heat = 1
    case turbo = 2
    case extendedHeat = 3
    case cool = 4
    case dry = 5
    case wait = 6

    /// Button code that switches the unit into this mode right now.
    var button: UInt8? {
        switch self {
        case .standby: return 0x01
        case .cool: return 0x02
        case .heat: return 0x03
        case .turbo: return 0x04
        case .dry: return 0x05
        case .extendedHeat: return 0x06
        case .wait: return nil
        }
    }

    /// Target temperature limits in half-degrees Celsius, as enforced by the official app.
    public var temperatureRange: ClosedRange<Int> {
        switch self {
        case .heat: return 45...80
        case .turbo: return 86...86
        case .extendedHeat: return 38...67
        case .cool: return 38...62
        case .dry: return 40...80
        case .standby, .wait: return 80...80
        }
    }

    public var usesTemperature: Bool { temperatureRange.lowerBound != temperatureRange.upperBound }
    public var usesFan: Bool { self != .standby && self != .wait }
}

/// One step of an on-device program ("biorhythm"). Five bytes on the wire.
public struct ProgramStep: Codable, Hashable, Sendable {
    public var mode: Mode
    /// 0...19, where the fan runs at `(fanStep + 1) * 5` percent.
    public var fanStep: Int
    /// Target temperature in half-degrees Celsius.
    public var temperature: Int
    public var hours: Int
    public var minutes: Int
    /// When set, hours/minutes are a wall-clock end time instead of a duration.
    public var endsAtClockTime: Bool

    public init(mode: Mode, fanStep: Int, temperature: Int, hours: Int, minutes: Int, endsAtClockTime: Bool = false) {
        self.mode = mode
        self.fanStep = fanStep
        self.temperature = temperature
        self.hours = hours
        self.minutes = minutes
        self.endsAtClockTime = endsAtClockTime
    }
}

/// A program stored in one of the unit's three slots.
public struct StoredProgram: Equatable, Sendable {
    public var name: String
    public var steps: [ProgramStep]

    public init(name: String, steps: [ProgramStep]) {
        self.name = name
        self.steps = steps
    }
}

public struct DeviceStatus: Equatable, Sendable {
    public var remainingSeconds: Int
    public var actualTemperature: Int
    public var targetTemperature: Int
    public var mode: Mode
    public var fanStep: Int
    public var maxRuntimeMinutes: Int
    public var minTemperature: Int
    public var maxTemperature: Int
    public var ambientTemperature: Int
    /// The second half of the status packet arrives separately and may lag the first.
    public var extra: Extra?

    public struct Extra: Equatable, Sendable {
        public var ledEnabled: Bool
        public var beepsMuted: Bool
        /// Non-zero while an on-device program is running.
        public var programStep: Int
        public var notification: Int
    }

    public var fanPercent: Int { (fanStep + 1) * 5 }
    public var isRunning: Bool { mode != .standby }
}

public enum LinkState: Equatable, Sendable {
    case bluetoothOff
    case unauthorized
    case searching
    case connecting
    case ready
    /// Handed over to another phone that asked for the BedJet. Reconnects by itself once that phone lets go.
    case yielded
}

/// How long the most recent connection took, measured from the moment the BedJet was asked for.
public struct ConnectionTiming: Equatable, Sendable {
    /// Until Bluetooth reported it was on. Zero when it already was.
    public var radioOn: TimeInterval
    /// Until the radio link was up. Includes any wait for another phone to hand the BedJet over.
    public var linkUp: TimeInterval
    /// Until the unit's service was found.
    public var services: TimeInterval
    /// Until commands could be sent.
    public var usable: TimeInterval
    /// False when the unit had to be found by scanning, as on a first connection.
    public var knownUnit: Bool
}

public enum BedJetError: LocalizedError, Equatable {
    case notConnected
    case inUseElsewhere
    case timeout
    case badResponse
    case verifyFailed
    case invalidProgram(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "Couldn't reach your BedJet. Check that it's plugged in and nearby."
        case .inUseElsewhere: return "Another phone is using your BedJet right now. Try again in a moment."
        case .timeout: return "Your BedJet didn't respond. Move closer and try again."
        case .badResponse: return "Your BedJet sent something unexpected. Try again."
        case .verifyFailed: return "The schedule didn't save correctly. Try again."
        case .invalidProgram(let why): return why
        }
    }
}

public enum Limits {
    public static let slots = 3
    public static let stepsPerProgram = 32
    public static let stepsPerFragment = 8
    public static let nameLength = 15
    /// The unit refuses steps of 12 hours or longer.
    public static let maxStepMinutes = 11 * 60 + 59
}
