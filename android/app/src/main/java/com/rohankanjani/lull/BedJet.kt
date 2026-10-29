package com.rohankanjani.lull

import android.icu.text.ListFormatter
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.rohankanjani.lull.bedjetkit.BedJetError
import com.rohankanjani.lull.bedjetkit.BedJetLink
import com.rohankanjani.lull.bedjetkit.Codec
import com.rohankanjani.lull.bedjetkit.DemoLink
import com.rohankanjani.lull.bedjetkit.DeviceStatus
import com.rohankanjani.lull.bedjetkit.FirmwareUpdate
import com.rohankanjani.lull.bedjetkit.Generation
import com.rohankanjani.lull.bedjetkit.Limits
import com.rohankanjani.lull.bedjetkit.LinkState
import com.rohankanjani.lull.bedjetkit.Mode
import com.rohankanjani.lull.bedjetkit.StoredProgram
import com.rohankanjani.lull.bedjetkit.acknowledgeNotification
import com.rohankanjani.lull.bedjetkit.deviceName
import com.rohankanjani.lull.bedjetkit.firmwareVersion
import com.rohankanjani.lull.bedjetkit.joinWiFi
import com.rohankanjani.lull.bedjetkit.setFan
import com.rohankanjani.lull.bedjetkit.setLED
import com.rohankanjani.lull.bedjetkit.setMode
import com.rohankanjani.lull.bedjetkit.setMuted
import com.rohankanjani.lull.bedjetkit.setRuntime
import com.rohankanjani.lull.bedjetkit.setTemperature
import com.rohankanjani.lull.bedjetkit.startProgram
import com.rohankanjani.lull.bedjetkit.store
import com.rohankanjani.lull.bedjetkit.storedPrograms
import com.rohankanjani.lull.bedjetkit.syncClock
import com.rohankanjani.lull.bedjetkit.updateFirmware
import kotlinx.coroutines.CancellationException
import kotlin.math.abs
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import java.io.File
import java.time.LocalTime
import java.time.format.DateTimeFormatter
import java.util.UUID

/** What is kept of a BedJet between launches. */
@Serializable
data class SavedBedJet(
    val id: String = UUID.randomUUID().toString(),
    /** The Bluetooth identity of the unit this BedJet always connects to. */
    val unit: String? = null,
    val name: String? = null,
    val nickname: String? = null,
    /** Null until the unit has said what it is. */
    val generation: Generation? = null,
    val tonightID: String? = null,
    val run: ActiveRun? = null,
    val slot: Int? = null,
)

/** A BedJet 3 using its Wi-Fi because Lull asked: to join a network, or to check for newer firmware. */
data class WiFiActivity(
    val purpose: Purpose,
    /** What the BedJet is doing, until it's over. */
    val step: String = "Asking your BedJet…",
    /** How it went, once it's over. */
    val outcome: String? = null,
    val failed: Boolean = false,
    /** Installing new firmware, so the version is read again once the BedJet is back. */
    val awaitsRestart: Boolean = false,
) {
    enum class Purpose { JOINING, UPDATING }

    val isRunning: Boolean get() = outcome == null
}

/** One BedJet Lull knows: its connection, what it reports, the schedule running on it and what it did. */
class BedJet(saved: SavedBedJet, val isDemo: Boolean, private val app: AppModel) {
    val id: String = saved.id
    /** The Bluetooth identity of the unit picked for this BedJet. Lull never connects it to another. */
    val unit: String? = saved.unit
    /** The name the BedJet gives itself, kept so it can be shown while the BedJet is away. */
    var name by mutableStateOf(saved.name); private set
    private var savedNickname by mutableStateOf(saved.nickname)
    /** A name given on this phone, such as "My side". The BedJet itself isn't renamed. */
    var nickname: String?
        get() = savedNickname
        set(value) { savedNickname = value; app.save() }
    val displayName: String
        get() = nickname?.trim()?.takeIf { it.isNotEmpty() } ?: name ?: "BedJet"
    var linkState by mutableStateOf(LinkState.SEARCHING); private set
    var status by mutableStateOf<DeviceStatus?>(null); private set
    /** When [status] arrived. It is kept while another phone has the BedJet or Lull is off screen, so it ages. */
    var statusReceivedAt: Long? = null; private set
    var firmware by mutableStateOf<String?>(null); private set
    /** The kind of BedJet, kept so schedules can be edited for it while it is away. Null until it has said. */
    var knownGeneration by mutableStateOf(saved.generation); private set
    val generation: Generation get() = knownGeneration ?: Generation.V3
    /** What is saved in the BedJet's three program slots. */
    var deviceSlots by mutableStateOf<List<StoredProgram?>>(emptyList()); private set

    private var savedTonightID by mutableStateOf(saved.tonightID)
    var tonightID: String?
        get() = savedTonightID
        set(value) { savedTonightID = value; app.save() }

    private var savedRun by mutableStateOf(saved.run?.takeIf { it.endsAt > System.currentTimeMillis() })
    var run: ActiveRun?
        get() = savedRun
        private set(value) { savedRun = value; app.save() }

    /** The BedJet slot this app keeps tonight's schedule in. */
    private var savedSlot by mutableStateOf(saved.slot)
    var slot: Int?
        get() = savedSlot
        private set(value) { savedSlot = value; app.save() }

    /** What the BedJet did, oldest first, so the morning after can be checked against how the night felt. */
    var history by mutableStateOf<List<HistoryEntry>>(emptyList()); private set
    val nights: List<Night> get() = Night.group(history)

    /** Set once Lull has looked for the BedJet for a while without reaching it, to suggest what to check. */
    var isSlowToFind by mutableStateOf(false); private set
    var isBusy by mutableStateOf(false); private set
    private var writingSchedule by mutableStateOf(false)
    /**
     * A schedule is being written to the BedJet, which takes several steps. Its Live Update holds still while this is
     * set, and moves on to the night as soon as it clears.
     */
    var isSavingSchedule: Boolean
        get() = writingSchedule
        private set(value) { writingSchedule = value; app.publishLiveNotifications() }
    /** Set when every slot on the BedJet is taken and the user has to pick one to reuse. */
    var needsSlotChoice by mutableStateOf(false)
    /** The BedJet using its Wi-Fi because Lull asked, and how that went. One at a time. */
    var wifiActivity by mutableStateOf<WiFiActivity?>(null); private set
    /** Set when the BedJet says newer firmware is available, until it has been asked to check. */
    var updateAvailable by mutableStateOf(false); private set

    private var link: BedJetLink? = null
    private var lastRefresh = 0L
    /** How air from the Remote is timed. Schedules keep their own timing. */
    var remoteTimer by mutableStateOf<RemoteTimer>(RemoteTimer.Longest)
        private set
    private var searchTimer: Job? = null
    /** What the history last recorded the BedJet doing, kept across launches to notice what changed while Lull was closed. */
    private var lastSeen: Seen? = null
    /** The latest report, waiting to settle before it is compared with [lastSeen]. */
    private var observed: Seen? = null
    private var settling: Job? = null
    private var connectedAt = 0L
    private var lastCommandAt = 0L
    /** When this phone last turned the BedJet off, to tell a report sent just before that from one sent after. */
    private var turnedOffAt: Long? = null
    private var acknowledgingUpdate = false

    val saved: SavedBedJet
        get() = SavedBedJet(id, unit, name, nickname, knownGeneration, tonightID, run, slot)

    val tonight: Schedule?
        get() = app.schedules.firstOrNull { it.id == tonightID } ?: app.schedules.firstOrNull()

    val isConnected: Boolean get() = linkState == LinkState.READY
    /**
     * Controls stay live while connecting or while another phone has the BedJet: what is tapped
     * is sent the moment the connection is up.
     */
    val canControl: Boolean get() = linkState != LinkState.BLUETOOTH_OFF && linkState != LinkState.UNAUTHORIZED
    /** A schedule is running on the BedJet that this phone didn't start, for example from a partner's phone. */
    val runningElsewhereStep: Int?
        get() {
            if (run != null) return null
            val step = status?.extra?.programStep ?: return null
            return if (step > 0) step else null
        }

    init {
        loadHistory()
        val ended = saved.run
        if (ended != null && run == null) {
            record(HistoryEntry.Event.ScheduleEnded(ended.schedule.name, HistoryEntry.Ending.Finished), at = ended.endsAt)
        }
    }

    // Connection

    /**
     * Starts talking to the BedJet. Only the one on screen asks another phone to hand it over;
     * the rest connect whenever they are free.
     */
    fun connect(asking: Boolean, resuming: Boolean = true) {
        link?.apply {
            onStateChange = null
            onStatus = null
            stop()
        }
        status = null
        firmware = null
        deviceSlots = emptyList()
        val link = app.makeLink(this)
        // Never hand the BedJet to another phone halfway through saving a schedule, or while it uses its Wi-Fi.
        (link as? BleLink)?.canYield = { !isBusy && wifiActivity?.isRunning != true }
        link.onStateChange = { linkStateChanged(it) }
        link.onStatus = { statusChanged(it) }
        this.link = link
        linkState = link.state
        lastRefresh = 0
        if (resuming) resume(asking)
    }

    /**
     * The BedJet talks to one phone at a time, so it is released whenever Lull leaves the screen.
     * Holding on to it would make coming back instant, but a phone that is off screen cannot be
     * relied on to hear another phone asking for the BedJet.
     */
    fun pause() {
        link?.stop()
        // A change still settling would otherwise wait until Lull is opened again.
        if (settling != null) commitObserved()
        saveHistory()
    }

    fun resume(asking: Boolean) {
        val ble = link as? BleLink
        if (!asking && ble != null) ble.listen() else link?.start()
        restartSearchTimer()
    }

    /**
     * Whether the BedJet has reported everything it does since [since], both halves of its report, so what it's doing
     * now is known rather than what Lull last saw.
     */
    fun hasReported(since: Long): Boolean {
        val at = statusReceivedAt ?: return false
        return at >= since && status?.extra != null
    }

    /**
     * Waits for the BedJet to say what it's doing, so an errand from the watch acts on that. Gives up after [timeout],
     * leaving the errand's own commands to say what's wrong.
     */
    suspend fun awaitReport(since: Long, timeout: Long = 10_000) {
        val deadline = System.currentTimeMillis() + timeout
        while (System.currentTimeMillis() < deadline && !hasReported(since)) delay(100)
    }

    private fun restartSearchTimer() {
        searchTimer?.cancel()
        searchTimer = null
        isSlowToFind = false
        timeSearch()
    }

    /**
     * Counts how long Lull has been looking, across searching and connecting, but not while
     * another phone has the BedJet or Bluetooth is unavailable, which already say what is wrong.
     */
    private fun timeSearch() {
        if (linkState != LinkState.SEARCHING && linkState != LinkState.CONNECTING) {
            searchTimer?.cancel()
            searchTimer = null
            isSlowToFind = false
            return
        }
        if (searchTimer != null) return
        searchTimer = app.scope.launch {
            delay(15_000)
            // Restarting into new firmware takes a while, and the tips would suggest unplugging it, so they wait longer.
            if (wifiActivity?.awaitsRestart == true) delay(165_000)
            isSlowToFind = true
        }
    }

    private fun linkStateChanged(state: LinkState) {
        linkState = state
        timeSearch()
        val link = link ?: return
        if (state != LinkState.READY) return
        connectedAt = System.currentTimeMillis()
        knownGeneration = link.generation
        app.save()
        logConnection()
        // Phones take turns with the BedJet, so reconnecting is routine; what is saved on it
        // only needs re-reading now and then.
        if (System.currentTimeMillis() - lastRefresh <= 300_000) return
        app.scope.launch {
            // Anything the person tapped while connecting goes first.
            delay(1200)
            while (isBusy) delay(200)
            if (link.state != LinkState.READY) return@launch
            try {
                link.syncClock()
                name = link.deviceName()
                app.save()
                val firmware = link.firmwareVersion()
                this@BedJet.firmware = firmware
                if (wifiActivity?.awaitsRestart == true) {
                    wifiActivity = wifiActivity?.copy(outcome = "Your BedJet restarted with firmware $firmware.", awaitsRestart = false)
                }
                refreshSlots()
                lastRefresh = System.currentTimeMillis()
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                // Status keeps streaming without these; they are retried on the next connection.
            }
        }
    }

    private fun statusChanged(status: DeviceStatus) {
        // The BedJet reports every second, so a report it sent just before it took Off can arrive just after. Shown, it
        // would put the air back on outside Lull, where it stays if Lull lets go of the BedJet before the next report.
        val turnedOffAt = turnedOffAt
        if (turnedOffAt != null && status.isRunning && System.currentTimeMillis() - turnedOffAt < staleReportWindow) return
        this.turnedOffAt = null
        this.status = status
        statusReceivedAt = System.currentTimeMillis()
        observe(status)
        app.publishLiveNotifications()
        app.publishWidgets()
        noticeUpdate(status)
        val run = run ?: return
        val now = System.currentTimeMillis()
        val settled = now - run.startedAt > 15_000
        val programStopped = status.mode == Mode.STANDBY && status.extra?.programStep == 0
        if (now < run.endsAt && !(settled && programStopped)) return
        this.run = null
        // Lull lets go of the BedJet overnight, so it only learns about an early stop on the next connection.
        // Nothing on this phone asked for it, so say so and keep the unit's reason code for diagnosis.
        val minutesEarly = ((run.endsAt - now) / 60_000).toInt()
        if (isBusy) return
        if (minutesEarly > 2) {
            record(HistoryEntry.Event.ScheduleEnded(run.schedule.name, HistoryEntry.Ending.Early(minutesEarly)), noticedLater = isJustConnected)
        } else {
            record(HistoryEntry.Event.ScheduleEnded(run.schedule.name, HistoryEntry.Ending.Finished), at = minOf(run.endsAt, now))
        }
        if (minutesEarly > 2) {
            app.report(
                "Your BedJet turned off ${Format.duration(minutesEarly)} before tonight's schedule ended " +
                    "(BedJet reason ${status.lastShutdownReason}).",
                from = this,
            )
        }
    }

    private suspend fun refreshSlots() {
        val link = link ?: return
        deviceSlots = link.storedPrograms()
        // Keep a copy of programs made elsewhere so reusing a slot never loses them.
        deviceSlots.forEachIndexed { index, program ->
            if (program != null && index != slot) app.keepCopy(program)
        }
    }

    // Tonight

    suspend fun startTonight() {
        val schedule = tonight ?: return
        val link = link ?: return
        isSavingSchedule = true
        try {
            startTonight(schedule, link)
        } finally {
            isSavingSchedule = false
        }
    }

    private suspend fun startTonight(schedule: Schedule, link: BedJetLink) {
        perform {
            // Demos that show a night in progress pretend it started earlier.
            val elapsed = if (link is DemoLink) app.options.demoElapsedMinutes else 0
            val startedAt = System.currentTimeMillis() - elapsed * 60_000L
            // Known for certain once connected, which `perform` waited for; checked before anything is written.
            problem(schedule, startedAt)?.let { throw BedJetError.InvalidProgram(it) }
            // With a wake time, every phase is scaled to end at it from now. A BedJet 3 is still given the wake time itself for
            // the last step, so it keeps to it by its own clock.
            val tonight = schedule.resolved(startingAt = Format.minuteOfDay(startedAt))
            // A V2 holds just the one sequence, which Lull always replaces.
            val slot: Int
            if (link.generation == Generation.V2) {
                slot = 0
            } else {
                if (deviceSlots.isEmpty()) refreshSlots()
                val free = this.slot ?: deviceSlots.indexOf(null).takeIf { it >= 0 }
                if (free == null) {
                    needsSlotChoice = true
                    return@perform
                }
                slot = free
                this.slot = slot
            }
            link.store(tonight.program, slot)
            link.startProgram(slot)
            confirmStarted()
            run = ActiveRun(tonight, startedAt)
            remoteTimer = RemoteTimer.Longest
            record(HistoryEntry.Event.ScheduleStarted(schedule.name, tonight.phases))
            if (link is DemoLink && elapsed > 0) link.skipAhead(elapsed)
            attempt { refreshSlots() }
        }
    }

    /** A BedJet that can't run a schedule stays off and raises a notification instead of starting it. */
    private suspend fun confirmStarted() {
        val link = link ?: return
        repeat(20) {
            delay(200)
            val extra = status?.extra ?: return@repeat
            if (extra.programStep > 0) return
            val refusal = when (extra.notification) {
                Codec.Notification.PROGRAM_NEEDS_CLOCK -> BedJetError.ClockNotSet
                Codec.Notification.PROGRAM_TOO_LONG -> BedJetError.ProgramTooLong
                else -> null
            }
            if (refusal != null) {
                attempt { link.acknowledgeNotification() }
                throw refusal
            }
        }
    }

    suspend fun startTonight(replacingSlot: Int) {
        slot = replacingSlot
        startTonight()
    }

    suspend fun endNight() {
        val link = link ?: return
        val name = run?.schedule?.name
        perform {
            link.setMode(Mode.STANDBY)
            run = null
            record(HistoryEntry.Event.ScheduleEnded(name, HistoryEntry.Ending.ByYou))
        }
    }

    // Remote

    suspend fun setMode(mode: Mode) {
        val link = link ?: return
        // Captured first: the BedJet's report that the schedule stopped can clear `run` before this returns.
        val endingSchedule = run?.schedule?.name
        // Shown as a time, the end on screen holds across modes: a time picked here, or the BedJet's own countdown, as
        // after Lull relaunches and no longer knows a time was picked.
        val shown = status
        if (app.remoteTimerShowsTime && mode != Mode.STANDBY && !remoteTimer.isAhead && run == null && runningElsewhereStep == null &&
            shown != null && shown.isRunning && shown.remainingSeconds > 60
        ) {
            remoteTimer = RemoteTimer.Until(System.currentTimeMillis() + shown.remainingSeconds * 1000L)
        }
        perform {
            link.setMode(mode)
            // The BedJet only says it's off in its next report, and Lull may have let go of it by then, leaving it shown
            // as running outside Lull. The BedJet took the command, so it is off already; setting `run` publishes it.
            if (mode == Mode.STANDBY) status = status?.copy(mode = Mode.STANDBY)
            turnedOffAt = if (mode == Mode.STANDBY) System.currentTimeMillis() else null
            run = null
            if (endingSchedule != null) record(HistoryEntry.Event.ScheduleEnded(endingSchedule, HistoryEntry.Ending.ByYou))
            // A time picked on the Remote holds across modes until it passes, while the Remote shows the time. Otherwise each
            // mode starts at its longest run, as the timer always has.
            if (mode == Mode.STANDBY || !remoteTimer.isAhead || !app.remoteTimerShowsTime) remoteTimer = RemoteTimer.Longest
            extendRuntime(entering = mode)
        }
    }

    suspend fun setTemperature(halfCelsius: Int) {
        val link = link ?: return
        perform {
            link.setTemperature(halfCelsius)
            extendRuntime()
        }
    }

    suspend fun setFan(percent: Int) {
        val link = link ?: return
        perform {
            link.setFan(percent / 5 - 1)
            extendRuntime()
        }
    }

    suspend fun setRuntime(minutes: Int) {
        val link = link ?: return
        remoteTimer = RemoteTimer.Picked
        perform { link.setRuntime(minutes) }
    }

    /**
     * Turns the air off at [untilMillis], or as near it as the mode allows. Lull keeps aiming at it as the temperature and
     * fan change, since each changes how long the BedJet lets the air run, and as the mode changes while the Remote shows
     * the time.
     */
    suspend fun setRuntime(untilMillis: Long) {
        val link = link ?: return
        remoteTimer = RemoteTimer.Until(untilMillis)
        val limit = status?.let { if (it.maxRuntimeMinutes > 0) it.maxRuntimeMinutes else it.mode.maxMinutes } ?: Limits.MAX_STEP_MINUTES
        perform { link.setRuntime(minutes(untilMillis, limit)) }
    }

    /** Minutes from now until [endsAt], to the nearest minute, as far as [limit] allows. */
    private fun minutes(endsAt: Long, limit: Int): Int =
        Math.round((endsAt - System.currentTimeMillis()) / 60_000.0).toInt().coerceAtLeast(1).coerceAtMost(limit)

    /**
     * Air started from the Remote runs for as long as the BedJet allows, or until the time picked there, until a
     * duration is picked instead. Schedules keep their own timing.
     */
    private suspend fun extendRuntime(entering: Mode? = null) {
        // A schedule started from another phone times its own phases; leave its timer alone.
        if (remoteTimer == RemoteTimer.Picked || run != null || runningElsewhereStep != null) return
        val link = link ?: return
        // The limit depends on mode, temperature and fan, and the unit keeps the previous timer when
        // the mode changes, so wait for it to report the new state before reading the limit.
        delay(600)
        repeat(20) {
            val status = status
            if (status != null && status.isRunning && status.maxRuntimeMinutes > 0 && (entering == null || status.mode == entering)) {
                val timer = remoteTimer
                if (timer is RemoteTimer.Until && timer.isAhead) {
                    val minutes = minutes(timer.endsAt, status.maxRuntimeMinutes)
                    if (abs(status.remainingSeconds - minutes * 60) > 60) link.setRuntime(minutes)
                } else if (status.remainingSeconds <= (status.maxRuntimeMinutes - 1) * 60) {
                    link.setRuntime(status.maxRuntimeMinutes)
                }
                return
            }
            delay(200)
        }
    }

    suspend fun setLED(on: Boolean) {
        val link = link ?: return
        perform { link.setLED(on) }
    }

    suspend fun setMuted(muted: Boolean) {
        val link = link ?: return
        perform { link.setMuted(muted) }
    }

    private suspend fun perform(work: suspend () -> Unit) {
        isBusy = true
        try {
            takeControl()
            work()
        } catch (error: CancellationException) {
            // A newer slider move replaced this one; nothing went wrong.
            throw error
        } catch (error: Exception) {
            app.report(error.message ?: BedJetError.BadResponse.message.orEmpty(), from = this)
        } finally {
            isBusy = false
            lastCommandAt = System.currentTimeMillis()
        }
    }

    // Wi-Fi and firmware

    /** Updating restarts the BedJet, which would end a schedule partway through the night, or one being saved. */
    val updateWaitsForSchedule: Boolean get() = isSavingSchedule || run != null || runningElsewhereStep != null
    val canUpdateFirmware: Boolean get() = canJoinWiFi && !updateWaitsForSchedule
    val canJoinWiFi: Boolean get() = isConnected && wifiActivity?.isRunning != true

    /** Gives the BedJet the Wi-Fi network it fetches firmware over. Lull keeps neither the name nor the password. */
    suspend fun joinWiFi(network: String, password: String) {
        useWiFi(WiFiActivity.Purpose.JOINING) { link, progress ->
            link.joinWiFi(network, password, progress)
            "Your BedJet joined “$network” and can now check for firmware updates."
        }
    }

    /** Asks the BedJet to check for newer firmware, which it installs straight away. */
    suspend fun updateFirmware() {
        // A schedule may have started while the person was confirming.
        if (!canUpdateFirmware) return
        useWiFi(WiFiActivity.Purpose.UPDATING) { link, progress ->
            when (link.updateFirmware(progress)) {
                FirmwareUpdate.UP_TO_DATE -> "Your BedJet's firmware is up to date."
                FirmwareUpdate.INSTALLING -> {
                    // Read again once it's back, to show the new version.
                    lastRefresh = 0
                    wifiActivity = wifiActivity?.copy(awaitsRestart = true)
                    "Your BedJet is installing the update and restarts when it's done. Keep it plugged in."
                }
            }
        }
    }

    private suspend fun useWiFi(purpose: WiFiActivity.Purpose, work: suspend (BedJetLink, (Int) -> Unit) -> String) {
        val link = link ?: return
        if (wifiActivity?.isRunning == true) return
        wifiActivity = WiFiActivity(purpose)
        try {
            val outcome = work(link) { phase -> step(phase)?.let { wifiActivity = wifiActivity?.copy(step = it) } }
            wifiActivity = wifiActivity?.copy(outcome = outcome)
            if (purpose == WiFiActivity.Purpose.UPDATING) updateAvailable = false
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            wifiActivity = wifiActivity?.copy(
                outcome = error.message ?: BedJetError.BadResponse.message.orEmpty(),
                failed = true,
                awaitsRestart = false,
            )
        }
    }

    /** What the BedJet is doing at each step it reports while it uses its Wi-Fi. */
    private fun step(phase: Int): String? = when (phase) {
        Codec.WiFiPhase.STARTING -> "Starting…"
        Codec.WiFiPhase.JOINING -> "Joining Wi-Fi…"
        Codec.WiFiPhase.JOINED -> "Connected to Wi-Fi…"
        Codec.WiFiPhase.TESTING -> "Testing the connection…"
        Codec.WiFiPhase.CHECKING -> "Checking for an update…"
        Codec.WiFiPhase.UPDATING -> "Installing the update…"
        Codec.WiFiPhase.RESTARTING -> "Restarting your BedJet…"
        else -> null
    }

    /**
     * A BedJet 3 on Wi-Fi checks for firmware by itself now and then, and says when there's newer firmware until
     * that's acknowledged, as the official app does once it has shown it.
     */
    private fun noticeUpdate(status: DeviceStatus) {
        if (status.extra?.notification != Codec.Notification.UPDATE_AVAILABLE || acknowledgingUpdate) return
        val link = link ?: return
        updateAvailable = true
        acknowledgingUpdate = true
        app.scope.launch {
            attempt { link.acknowledgeNotification() }
            acknowledgingUpdate = false
        }
    }

    /** Like Swift's `try?`: anything that goes wrong is ignored, but cancellation still cancels. */
    private suspend fun attempt(work: suspend () -> Unit) {
        try {
            work()
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
        }
    }

    /** Using a control while another phone has the BedJet asks that phone to hand it over first. */
    private suspend fun takeControl() {
        val link = link ?: return
        if (link.state == LinkState.READY) return
        val wasElsewhere = link.state == LinkState.YIELDED
        link.requestControl()
        val deadline = System.currentTimeMillis() + 8000
        while (System.currentTimeMillis() < deadline) {
            delay(20)
            if (link.state == LinkState.READY) return
        }
        throw if (wasElsewhere) BedJetError.InUseElsewhere else BedJetError.NotConnected
    }

    private fun logConnection() {
        if (!app.options.logsConnections) return
        val timing = (link as? BleLink)?.lastConnection ?: return
        val line = "new connection: radio %.0f, link %.0f, services %.0f, usable %.0f ms, %s (%s)\n".format(
            timing.radioOn * 1000, timing.linkUp * 1000, timing.services * 1000, timing.usable * 1000,
            if (timing.knownUnit) "known unit" else "scanned", name ?: "unnamed",
        )
        val stamp = LocalTime.now().format(DateTimeFormatter.ofPattern("HH:mm:ss"))
        File(app.application.filesDir, "connections.txt").appendText("$stamp $line")
    }

    // History

    /** The settings worth remembering from a status report. The timer is carried along to tell when it ran out. */
    @Serializable
    private data class Seen(
        val mode: Mode,
        val temperature: Int,
        val fanPercent: Int,
        val programStep: Int,
        val remainingSeconds: Int,
        val at: Long = System.currentTimeMillis(),
    ) {
        constructor(status: DeviceStatus, programStep: Int) :
            this(status.mode, status.targetTemperature, status.fanPercent, programStep, status.remainingSeconds)

        fun sameSettings(other: Seen): Boolean =
            mode == other.mode && fanPercent == other.fanPercent && programStep == other.programStep &&
                (!mode.usesTemperature || temperature == other.temperature)
    }

    /** The first reports after connecting describe the BedJet as it was left, not something that just happened. */
    private val isJustConnected: Boolean get() = System.currentTimeMillis() - connectedAt < 10_000

    /** Waits for the BedJet to hold a setting for a few seconds, so dragging a slider is one entry, not twenty. */
    private fun observe(status: DeviceStatus) {
        // Whether a schedule is running arrives in the second half of the report; without it a phase
        // change can't be told from a change someone made.
        val step = status.extra?.programStep ?: return
        val seen = Seen(status, step)
        val isNew = observed?.let { !seen.sameSettings(it) } ?: true
        observed = seen
        val last = lastSeen
        if (last != null && seen.sameSettings(last)) {
            settling?.cancel()
            settling = null
            lastSeen = seen
            return
        }
        if (!isNew && settling != null) return
        settling?.cancel()
        settling = app.scope.launch {
            delay(3000)
            commitObserved()
        }
    }

    private fun commitObserved() {
        settling?.cancel()
        settling = null
        val now = observed ?: return
        // The first report ever only sets where the history starts from.
        val before = lastSeen
        lastSeen = now
        if (before == null) return
        val wasAway = before.at < connectedAt && isJustConnected
        when {
            before.programStep == 0 && now.programStep >= 1 -> {
                // Started from this phone, it is recorded once the BedJet confirms it.
                if (run == null && !isBusy) record(HistoryEntry.Event.ScheduleStarted(null, null), noticedLater = wasAway)
                return
            }
            // The schedule moved on to its next phase, or ended; its start and end are recorded on their own.
            before.programStep >= 1 && now.programStep >= 1 && before.programStep != now.programStep -> return
            before.programStep >= 1 && now.programStep == 0 && now.mode == Mode.STANDBY -> return
        }
        val clock = System.currentTimeMillis()
        if (now.mode == Mode.STANDBY) {
            if (before.mode == Mode.STANDBY) return
            val timerEnds = before.at + before.remainingSeconds * 1000L
            val ranOut = lastCommandAt < before.at && (before.remainingSeconds < 120 || (wasAway && timerEnds < clock))
            record(HistoryEntry.Event.Off(ranOut), at = if (ranOut) minOf(timerEnds, clock) else clock, noticedLater = wasAway && !ranOut)
        } else {
            record(HistoryEntry.Event.Air(now.mode, now.temperature, now.fanPercent), noticedLater = wasAway)
        }
    }

    private fun record(event: HistoryEntry.Event, at: Long = System.currentTimeMillis(), noticedLater: Boolean = false) {
        var entries = history + HistoryEntry(at, event, status?.ambientTemperature, noticedLater)
        val previous = entries.dropLast(1).lastOrNull()
        if (previous != null && previous.date > at) entries = entries.sortedBy { it.date }
        // Two months is plenty to compare one season's nights with the next.
        val cutoff = System.currentTimeMillis() - 60 * 86_400_000L
        history = entries.filter { it.date >= cutoff }
        saveHistory()
    }

    @Serializable
    private data class SavedHistory(val entries: List<HistoryEntry>, val lastSeen: Seen? = null)

    private fun loadHistory() {
        val saved = historyFile?.let { file -> runCatching { AppModel.json.decodeFromString<SavedHistory>(file.readText()) }.getOrNull() }
        history = saved?.entries ?: if (app.options.demoHistory) HistoryEntry.samples() else emptyList()
        lastSeen = saved?.lastSeen
    }

    private fun saveHistory() {
        app.publishWidgets()
        val file = historyFile ?: return
        val saved = SavedHistory(history, lastSeen)
        runCatching {
            file.parentFile?.mkdirs()
            val temporary = File(file.parentFile, file.name + ".tmp")
            temporary.writeText(AppModel.json.encodeToString(SavedHistory.serializer(), saved))
            temporary.renameTo(file)
        }
    }

    /** Each BedJet keeps its own history, and demo BedJets are separate ones, so pretend nights never mix with real ones. */
    private val historyFile: File? get() = app.storage.historyFile(id)

    // Schedules

    /** Modes the Remote and the phase editor offer for this kind of BedJet. */
    val remoteModes: List<Mode> get() = com.rohankanjani.lull.remoteModes.filter(generation::supports)
    val phaseModes: List<Mode> get() = com.rohankanjani.lull.phaseModes.filter(generation::supports)

    fun adjustsTemperature(mode: Mode): Boolean = generation.adjustsTemperature(mode)

    /**
     * Modes in a schedule that this BedJet can't run. Schedules are shared between BedJets, so one made for a
     * BedJet 3 may not suit a V2; it is never changed to fit, only refused.
     */
    fun unsupportedModes(schedule: Schedule): List<Mode> =
        schedule.phases.map { it.mode }.filter { !generation.supports(it) }.distinct()

    /** Why a schedule can't run on this BedJet when started at [now], if it can't. */
    fun problem(schedule: Schedule, now: Long = System.currentTimeMillis()): String? {
        val modes = unsupportedModes(schedule)
        if (modes.isNotEmpty()) {
            val names = ListFormatter.getInstance().format(modes.map { it.title })
            return "$displayName is a BedJet V2, which can't run $names. Edit “${schedule.name}” or pick another schedule for it."
        }
        // Started then, the last phase has to reach the wake time within what BedJet lets it run.
        return schedule.wakeProblem(startingAt = Format.minuteOfDay(now))
    }

    /** A word or two on how the connection is going, short enough for the pill. */
    val connectionLabel: String
        get() {
            // Invites a tap through to the things worth checking.
            if (isSlowToFind) return "Not found"
            return when (linkState) {
                LinkState.READY -> if (isDemo && !app.options.labelsDemoAsConnected) "Demo" else "Connected"
                LinkState.CONNECTING -> "Connecting"
                LinkState.SEARCHING -> "Searching"
                LinkState.YIELDED -> "Other phone"
                LinkState.BLUETOOTH_OFF -> "Bluetooth off"
                LinkState.UNAUTHORIZED -> "No access"
            }
        }

    val spokenConnectionLabel: String
        get() = if (linkState == LinkState.YIELDED && !isSlowToFind) "in use on another phone" else connectionLabel

    companion object {
        /** How long after Off a report saying the BedJet is still running is taken to have been sent before it. */
        var staleReportWindow = 2_000L
    }
}

/** How air started from the Remote is timed. */
sealed interface RemoteTimer {
    /** As long as the BedJet allows, which depends on the mode, temperature and fan. */
    data object Longest : RemoteTimer

    /** For a duration picked on the Remote. */
    data object Picked : RemoteTimer

    /** Until a time picked on the Remote, as far as the mode allows. */
    data class Until(val endsAt: Long) : RemoteTimer

    /** A time picked on the Remote that hasn't come yet. */
    val isAhead: Boolean get() = this is Until && endsAt > System.currentTimeMillis()
}
