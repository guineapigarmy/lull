package com.rohankanjani.lull.bedjetkit

import java.time.LocalTime

/** A connection to one BedJet. `BleLink` talks to real hardware; [DemoLink] simulates a unit. */
interface BedJetLink {
    val state: LinkState
    var onStateChange: ((LinkState) -> Unit)?
    var onStatus: ((DeviceStatus) -> Unit)?

    fun start()
    fun stop()

    /**
     * Asks for the BedJet on the person's behalf. It accepts one phone at a time, so this also asks
     * another phone that is holding it to hand it over.
     */
    fun requestControl() {}

    /** Writes a command and waits for the unit to acknowledge it. */
    suspend fun send(command: ByteArray)

    /** Asks the unit for stored data and returns the reply payload. */
    suspend fun query(request: Int): ByteArray
}

suspend fun BedJetLink.setMode(mode: Mode) {
    val command = Codec.setMode(mode) ?: return
    send(command)
}

suspend fun BedJetLink.syncClock(time: LocalTime = LocalTime.now()) {
    send(Codec.setClock(time.hour, time.minute))
}

suspend fun BedJetLink.deviceName(): String = Codec.parseText(query(Codec.Query.DEVICE_NAME))

suspend fun BedJetLink.firmwareVersion(): String = Codec.parseText(query(Codec.Query.FIRMWARE))

/** Everything saved on the unit, one entry per slot; `null` where the slot is empty. */
suspend fun BedJetLink.storedPrograms(): List<StoredProgram?> {
    val names = Codec.parseNames(query(Codec.Query.PROGRAM_NAMES))
    return (0 until Limits.SLOTS).map { slot ->
        val name = names.getOrNull(slot) ?: return@map null
        val steps = programSteps(slot)
        if (steps.isEmpty()) null else StoredProgram(name, steps)
    }
}

suspend fun BedJetLink.programSteps(slot: Int): List<ProgramStep> {
    val steps = mutableListOf<ProgramStep>()
    var index = 0
    while (true) {
        val payload = query(Codec.Query.fragment(slot, index))
        val fragment = Codec.parseFragment(payload, index) ?: throw BedJetError.BadResponse
        steps += fragment.steps
        index += 1
        if (steps.size >= fragment.total || fragment.steps.isEmpty()) return steps
    }
}

/** Saves a program into a slot, replacing whatever was there, and confirms the unit kept it. */
suspend fun BedJetLink.store(program: StoredProgram, slot: Int) {
    if (program.steps.isEmpty()) throw BedJetError.InvalidProgram("Add at least one phase first.")
    if (program.steps.size > Limits.STEPS_PER_PROGRAM) {
        throw BedJetError.InvalidProgram("A BedJet schedule can hold up to ${Limits.STEPS_PER_PROGRAM} phases.")
    }
    if (!program.steps.all { it.fitsUnitLimits }) throw BedJetError.ProgramTooLong
    for (command in Codec.writeProgram(slot, program.steps)) send(command)
    send(Codec.nameProgram(slot, program.name))
    if (programSteps(slot) != program.steps) throw BedJetError.VerifyFailed
}

suspend fun BedJetLink.startProgram(slot: Int) {
    syncClock()
    send(Codec.startProgram(slot))
}
