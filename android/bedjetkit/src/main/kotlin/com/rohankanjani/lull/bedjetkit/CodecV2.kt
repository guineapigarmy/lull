package com.rohankanjani.lull.bedjetkit

import java.time.LocalTime

/**
 * Byte-level encoding for the BedJet V2, which speaks a serial protocol through a Microchip BLE UART bridge.
 *
 * Every packet is `prefix, length, type, payload…, checksum`. The phone sends prefix 0x58 and the unit
 * answers with 0x59; `length` counts the type and payload, and the checksum makes every byte sum to 0xff.
 * Worked out from the official BedJet Android app; see docs/BEDJET_V2_PROTOCOL.md.
 */
object CodecV2 {
    private const val COMMAND_PREFIX = 0x58
    private const val REPLY_PREFIX = 0x59

    /** Requests understood by [BedJetLink.query] on a V2. */
    object Query {
        /** Protocol and firmware versions, and which sequence format the unit takes. */
        const val INFO = 0x0b
        /** The unit's name, a 16-byte parameter. */
        const val DEVICE_NAME = 0x02
    }

    /** Oldest firmware that runs sequences; the official app hides them below it. */
    const val SEQUENCE_FIRMWARE = 48
    /** The unit reports the running step in five bits, so a sequence can't be longer than this. */
    const val STEPS_PER_SEQUENCE = 31
    /** Heat targets the unit accepts, in half-degrees Celsius. */
    val heatRange = 44..80

    // Framing

    internal fun frame(type: Int, payload: List<Int> = emptyList()): ByteArray {
        val bytes = listOf(COMMAND_PREFIX, payload.size + 1, type) + payload
        return (bytes + checksum(bytes)).map { it.toByte() }.toByteArray()
    }

    internal fun checksum(bytes: List<Int>): Int = bytes.sum().inv() and 0xff

    /** Complete packets found in a byte stream, and whatever was left over for the next notification. */
    class Split(val packets: List<ByteArray>, val rest: ByteArray)

    /**
     * Splits the unit's byte stream into packets. Notifications can end partway through a packet,
     * so whatever is incomplete is returned as [Split.rest] for the next one; bytes that can't start a packet are dropped.
     */
    fun takePackets(buffer: ByteArray): Split {
        val bytes = buffer.map { it.toInt() and 0xff }
        val packets = mutableListOf<ByteArray>()
        var start = 0
        var rest = bytes.size
        while (true) {
            val prefix = (start until bytes.size).firstOrNull { bytes[it] == REPLY_PREFIX } ?: break
            if (prefix + 1 >= bytes.size) { rest = prefix; break }
            val length = bytes[prefix + 1] + 3
            // Real packets are short, so a long length means this 0x59 was data rather than a prefix.
            if (length <= 3 || length > 64) { start = prefix + 1; continue }
            if (prefix + length > bytes.size) { rest = prefix; break }
            val packet = bytes.subList(prefix, prefix + length)
            if (checksum(packet.dropLast(1)) == packet.last()) {
                packets += buffer.copyOfRange(prefix, prefix + length)
                start = prefix + length
            } else {
                start = prefix + 1
            }
        }
        return Split(packets, buffer.copyOfRange(minOf(rest, buffer.size), buffer.size))
    }

    // Commands

    fun request(query: Int): ByteArray = if (query == Query.INFO) frame(0x0b) else frame(0x06, listOf(query, 16))

    /** Modes are buttons: pressing one switches to that mode, and pressing the one the unit is in turns it off. */
    fun setMode(mode: Mode, from: Mode): ByteArray? {
        if (mode == from) return null
        return button(if (mode == Mode.STANDBY) from else mode)?.let { frame(0x01, listOf(it)) }
    }

    fun setTemperature(halfDegrees: Int, from: DeviceStatus): ByteArray = scene(from, temperature = halfDegrees)

    fun setFan(step: Int, from: DeviceStatus): ByteArray = scene(from, fanStep = step)

    fun setRuntime(minutes: Int, from: DeviceStatus): ByteArray = scene(from, seconds = minutes * 60)

    fun setSettings(ledOn: Boolean, muted: Boolean): ByteArray =
        frame(0x11, listOf((if (muted) 0x01 else 0) or (if (ledOn) 0 else 0x02)))

    /** Temperature, fan and timer are set together, so whatever isn't changing is repeated from the status. */
    internal fun scene(status: DeviceStatus, temperature: Int? = null, fanStep: Int? = null, seconds: Int? = null): ByteArray {
        val remaining = maxOf(seconds ?: status.remainingSeconds, 0)
        val target = (temperature ?: status.targetTemperature).coerceIn(0, 0x7f)
        val muted = status.extra?.beepsMuted == true
        return frame(0x0e, listOf(
            statusCode(status.mode),
            (fanStep ?: status.fanStep).coerceIn(0, 19) + 1,
            target or (if (muted) 0x80 else 0),
            minOf(remaining / 3600, 12),
            remaining / 60 % 60,
            remaining % 60,
        ))
    }

    // Sequences

    /** Empties the unit's sequence before new steps are written. */
    val clearSequence: ByteArray get() = frame(0x0c)

    /** One step, written to the parameter for its position. Units that take the newer format have one more byte. */
    fun writeStep(step: ProgramStep, index: Int, minutes: Int, extended: Boolean): ByteArray {
        val mode = stepCode(step.mode) ?: throw BedJetError.InvalidProgram(UNSUPPORTED_MODES)
        val target = when (step.mode) {
            Mode.HEAT -> step.temperature.coerceIn(heatRange)
            // The official app stores these, and the unit ignores them.
            Mode.COOL -> 40
            else -> 80
        }
        val payload = mutableListOf(
            0x80 + index, if (extended) 7 else 6,
            mode, step.fanStep.coerceIn(0, 19) + 1, minutes / 60, minutes % 60, 0, target,
        )
        if (extended) payload += 0
        return frame(0x05, payload)
    }

    /** Ten bytes the official app stores alongside a sequence to recognise it later. */
    fun tagSequence(tag: List<Int>): ByteArray = frame(0x05, listOf(0x03, 0x0a) + tag.take(10) + List(maxOf(0, 10 - tag.size)) { 0 })

    /** Starts the stored sequence. Units that take the newer format are given the time of day with it. */
    fun runSequence(at: LocalTime?, extended: Boolean): ByteArray {
        if (!extended || at == null) return frame(0x0d)
        return frame(0x0d, listOf(at.hour, at.minute, at.second))
    }

    const val UNSUPPORTED_MODES = "A BedJet V2 doesn't have Gentle heat or Dry. Change those phases to Heat or Cool."

    // Replies

    data class Info(
        val protocolVersion: Int,
        val firmware: Int,
        /** Steps are written in the longer format and the run command carries the time of day. */
        val extendedSequences: Boolean,
    ) {
        val runsSequences: Boolean get() = firmware >= SEQUENCE_FIRMWARE
    }

    /** The payload of the reply to `query`, or null when the packet answers something else. */
    fun reply(query: Int, packet: ByteArray): ByteArray? {
        val b = packet.map { it.toInt() and 0xff }
        if (b.size < 4 || b[0] != REPLY_PREFIX) return null
        if (query == Query.INFO) return if (b[2] == 0x01) packet.copyOfRange(3, b.size - 1) else null
        if (b[2] != 0x05 || b.size < 5 || b[3] != query) return null
        return packet.copyOfRange(4, b.size - 1)
    }

    fun parseInfo(payload: ByteArray): Info? {
        val b = payload.map { it.toInt() and 0xff }
        if (b.size < 2) return null
        val firmware = b[1]
        val newerFormat = b.size > 7 && b[7] and 0x01 != 0
        return Info(protocolVersion = b[0], firmware = firmware, extendedSequences = newerFormat && firmware >= 53)
    }

    /** A unit that was never named answers with no bytes. */
    fun parseName(payload: ByteArray): String = Codec.parseText(payload).trim(' ', '\t')

    fun parseStatus(packet: ByteArray): DeviceStatus? {
        val b = packet.map { it.toInt() and 0xff }
        if (b.size < 14 || b[0] != REPLY_PREFIX || b[2] != 0x02) return null
        val mode = mode(statusCode = b[4] shr 5 and 0x07) ?: return null
        val fanStep = maxOf((b[4] and 0x1f) - 1, 0)
        val target = b[7] and 0x7f
        val actual = b[3] and 0x7f
        val hours = b[5] shr 4
        val minutes = ((b[5] shl 2) and 0x3c) or (b[6] shr 6)
        val seconds = b[6] and 0x3f
        val limits = when (mode) {
            Mode.HEAT -> heatRange
            Mode.TURBO -> 86..86
            Mode.COOL -> 44..44
            else -> 80..80
        }
        val longest = when (mode) {
            Mode.TURBO -> 10
            Mode.HEAT -> ProgramStep.longestMinutes(Mode.HEAT, target, fanStep)
            Mode.COOL -> 12 * 60
            else -> 0
        }
        return DeviceStatus(
            remainingSeconds = hours * 3600 + minutes * 60 + seconds,
            actualTemperature = actual,
            targetTemperature = target,
            mode = mode,
            fanStep = fanStep,
            maxRuntimeMinutes = longest,
            minTemperature = limits.first,
            maxTemperature = limits.last,
            // The V2 has no room sensor; with the air off, its air sensor reads the room.
            ambientTemperature = actual,
            lastShutdownReason = if (b[1] > 10) b[12] else 0,
            extra = DeviceStatus.Extra(
                ledEnabled = b[3] and 0x80 == 0,
                beepsMuted = b[8] and 0x80 != 0,
                programStep = b[10] shr 3 and 0x1f,
                notification = 0,
            ),
        )
    }

    // Modes

    /** The V2 reports off, Turbo, Heat and Cool as 0 to 3 and has no other modes. */
    internal fun mode(statusCode: Int): Mode? = when (statusCode) {
        0 -> Mode.STANDBY
        1 -> Mode.TURBO
        2 -> Mode.HEAT
        3 -> Mode.COOL
        else -> null
    }

    internal fun statusCode(mode: Mode): Int = when (mode) {
        Mode.TURBO -> 1
        Mode.HEAT -> 2
        Mode.COOL -> 3
        else -> 0
    }

    /** Sequence steps use the same codes, with 0 meaning wait rather than off. */
    internal fun stepCode(mode: Mode): Int? = when (mode) {
        Mode.WAIT -> 0
        Mode.TURBO, Mode.HEAT, Mode.COOL -> statusCode(mode)
        else -> null
    }

    internal fun button(mode: Mode): Int? = when (mode) {
        Mode.TURBO -> 0x01
        Mode.HEAT -> 0x02
        Mode.COOL -> 0x03
        else -> null
    }
}
