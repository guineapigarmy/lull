package com.rohankanjani.lull

import android.app.Application
import android.content.Context
import android.icu.util.LocaleData
import android.icu.util.ULocale
import android.os.Build
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.rohankanjani.lull.bedjetkit.BedJetError
import com.rohankanjani.lull.bedjetkit.BedJetLink
import com.rohankanjani.lull.bedjetkit.Codec
import com.rohankanjani.lull.bedjetkit.DemoLink
import com.rohankanjani.lull.bedjetkit.DeviceStatus
import com.rohankanjani.lull.bedjetkit.LinkState
import com.rohankanjani.lull.bedjetkit.Mode
import com.rohankanjani.lull.bedjetkit.StoredProgram
import com.rohankanjani.lull.bedjetkit.deviceName
import com.rohankanjani.lull.bedjetkit.firmwareVersion
import com.rohankanjani.lull.bedjetkit.setMode
import com.rohankanjani.lull.bedjetkit.startProgram
import com.rohankanjani.lull.bedjetkit.store
import com.rohankanjani.lull.bedjetkit.storedPrograms
import com.rohankanjani.lull.bedjetkit.syncClock
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File
import java.time.LocalTime
import java.time.format.DateTimeFormatter

/** Launch flags, passed as intent extras. They match the iOS app's launch arguments. */
data class LaunchOptions(
    /** UI tests launch with this so every run starts from the built-in schedules. */
    val ephemeral: Boolean = false,
    /** Makes a night started in demo mode appear this far along, for listing screenshots. */
    val demoElapsedMinutes: Int = 0,
    /** Shows the simulated BedJet as connected, for listing screenshots. */
    val labelsDemoAsConnected: Boolean = false,
    /** Keeps a record of connection times, so they can be measured on a real phone. */
    val logsConnections: Boolean = false,
)

class AppModel(application: Application, val options: LaunchOptions) : AndroidViewModel(application) {
    var linkState by mutableStateOf(LinkState.SEARCHING); private set
    var status by mutableStateOf<DeviceStatus?>(null); private set
    var deviceName by mutableStateOf<String?>(null); private set
    var firmware by mutableStateOf<String?>(null); private set
    /** What is saved in the BedJet's three program slots. */
    var deviceSlots by mutableStateOf<List<StoredProgram?>>(emptyList()); private set

    private var savedSchedules by mutableStateOf<List<Schedule>>(emptyList())
    var schedules: List<Schedule>
        get() = savedSchedules
        set(value) { savedSchedules = value; save() }

    private var savedTonightID by mutableStateOf<String?>(null)
    var tonightID: String?
        get() = savedTonightID
        set(value) { savedTonightID = value; save() }

    private var savedRun by mutableStateOf<ActiveRun?>(null)
    var run: ActiveRun?
        get() = savedRun
        private set(value) { savedRun = value; save() }

    /** The BedJet slot this app keeps tonight's schedule in. */
    private var savedSlot by mutableStateOf<Int?>(null)
    var slot: Int?
        get() = savedSlot
        private set(value) { savedSlot = value; save() }

    private val prefs = application.getSharedPreferences("Lull", Context.MODE_PRIVATE)

    private var fahrenheit by mutableStateOf(prefs.getBoolean("useFahrenheit", usesUSUnits()))
    var useFahrenheit: Boolean
        get() = fahrenheit
        set(value) { fahrenheit = value; prefs.edit().putBoolean("useFahrenheit", value).apply() }

    private var demo by mutableStateOf(isEmulator() || prefs.getBoolean("demoMode", false))
    var demoMode: Boolean
        get() = demo
        set(value) { demo = value; prefs.edit().putBoolean("demoMode", value).apply(); reconnect() }

    var isBusy by mutableStateOf(false); private set
    var errorMessage by mutableStateOf<String?>(null)
    /** Set when every slot on the BedJet is taken and the user has to pick one to reuse. */
    var needsSlotChoice by mutableStateOf(false)

    private var link: BedJetLink? = null
    private var lastRefresh = 0L
    private var keepsLongestRuntime = true
    private var isLoaded = false

    val tonight: Schedule? get() = schedules.firstOrNull { it.id == tonightID } ?: schedules.firstOrNull()
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

    /**
     * Where the screens run what the person asked for. It outlives the screen that asked, as an
     * unstructured Task does on iOS, so a card that disappears mid-save doesn't cancel the save.
     */
    val scope: CoroutineScope get() = viewModelScope

    override fun onCleared() {
        link?.stop()
    }

    // Connection

    private fun reconnect() {
        link?.apply {
            onStateChange = null
            onStatus = null
            stop()
        }
        status = null
        deviceName = null
        firmware = null
        deviceSlots = emptyList()
        val link: BedJetLink = if (demoMode) {
            DemoLink(listOf(StoredProgram("Summer nights", Schedule.templates[2].program.steps), null, null), viewModelScope)
        } else {
            BleLink(getApplication())
        }
        link.onStateChange = { linkStateChanged(it) }
        link.onStatus = { statusChanged(it) }
        // Never hand the BedJet to another phone halfway through saving a schedule.
        (link as? BleLink)?.canYield = { !isBusy }
        this.link = link
        linkState = link.state
        lastRefresh = 0
        link.start()
    }

    /**
     * The BedJet talks to one phone at a time, so it is released whenever Lull leaves the screen.
     * Holding on to it would make coming back instant, but a phone that is off screen cannot be
     * relied on to hear another phone asking for the BedJet.
     */
    fun appMovedToBackground() {
        link?.stop()
    }

    fun appBecameActive() {
        link?.start()
    }

    /** Bluetooth access was just granted or refused; look at the radio again. */
    fun permissionsChanged() {
        if (!demoMode) reconnect()
    }

    fun forgetDevice() {
        (link as? BleLink)?.forget()
        slot = null
    }

    private fun linkStateChanged(state: LinkState) {
        linkState = state
        val link = link ?: return
        if (state != LinkState.READY) return
        logConnection()
        // Phones take turns with the BedJet, so reconnecting is routine; what is saved on it
        // only needs re-reading now and then.
        if (System.currentTimeMillis() - lastRefresh <= 300_000) return
        viewModelScope.launch {
            // Anything the person tapped while connecting goes first.
            delay(1200)
            while (isBusy) delay(200)
            if (link.state != LinkState.READY) return@launch
            try {
                link.syncClock()
                deviceName = link.deviceName()
                firmware = link.firmwareVersion()
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
        this.status = status
        val run = run ?: return
        val now = System.currentTimeMillis()
        val settled = now - run.startedAt > 15_000
        val programStopped = status.mode == Mode.STANDBY && status.extra?.programStep == 0
        if (now < run.endsAt && !(settled && programStopped)) return
        this.run = null
        // Lull lets go of the BedJet overnight, so it only learns about an early stop on the next connection.
        // Nothing on this phone asked for it, so say so and keep the unit's reason code for diagnosis.
        val minutesEarly = ((run.endsAt - now) / 60_000).toInt()
        if (!isBusy && minutesEarly > 2) {
            errorMessage = "Your BedJet turned off ${Format.duration(minutesEarly)} before tonight's schedule ended " +
                "(BedJet reason ${status.lastShutdownReason})."
        }
    }

    private suspend fun refreshSlots() {
        val link = link ?: return
        deviceSlots = link.storedPrograms()
        // Keep a copy of programs made elsewhere so reusing a slot never loses them.
        deviceSlots.forEachIndexed { index, program ->
            if (program == null || index == slot) return@forEachIndexed
            val imported = Schedule.importing(program)
            if (schedules.none { existing -> existing.phases.map { it.step } == imported.phases.map { it.step } }) {
                schedules = schedules + imported
            }
        }
    }

    // Tonight

    suspend fun startTonight() {
        val schedule = tonight ?: return
        val link = link ?: return
        perform {
            if (deviceSlots.isEmpty()) refreshSlots()
            val slot = slot ?: deviceSlots.indexOf(null).takeIf { it >= 0 }
            if (slot == null) {
                needsSlotChoice = true
                return@perform
            }
            this.slot = slot
            link.store(schedule.program, slot)
            link.startProgram(slot)
            confirmStarted()
            run = ActiveRun(schedule, System.currentTimeMillis())
            if (link is DemoLink && options.demoElapsedMinutes > 0) {
                link.skipAhead(options.demoElapsedMinutes)
                run = run?.copy(startedAt = System.currentTimeMillis() - options.demoElapsedMinutes * 60_000L)
            }
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
                attempt { link.send(Codec.acknowledgeNotification) }
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
        perform {
            link.setMode(Mode.STANDBY)
            run = null
        }
    }

    // Remote

    suspend fun setMode(mode: Mode) {
        val link = link ?: return
        perform {
            link.setMode(mode)
            run = null
            keepsLongestRuntime = true
            extendRuntime(entering = mode)
        }
    }

    suspend fun setTemperature(halfCelsius: Int) {
        val link = link ?: return
        perform {
            link.send(Codec.setTemperature(halfCelsius))
            extendRuntime()
        }
    }

    suspend fun setFan(percent: Int) {
        val link = link ?: return
        perform {
            link.send(Codec.setFan(percent / 5 - 1))
            extendRuntime()
        }
    }

    suspend fun setRuntime(minutes: Int) {
        val link = link ?: return
        keepsLongestRuntime = false
        perform { link.send(Codec.setRuntime(minutes)) }
    }

    /**
     * Air started from the Remote runs for as long as the BedJet allows, until a shorter time is
     * picked there. Schedules keep their own timing.
     */
    private suspend fun extendRuntime(entering: Mode? = null) {
        // A schedule started from another phone times its own phases; leave its timer alone.
        if (!keepsLongestRuntime || run != null || runningElsewhereStep != null) return
        val link = link ?: return
        // The limit depends on mode, temperature and fan, and the unit keeps the previous timer when
        // the mode changes, so wait for it to report the new state before reading the limit.
        delay(600)
        repeat(20) {
            val status = status
            if (status != null && status.isRunning && status.maxRuntimeMinutes > 0 && (entering == null || status.mode == entering)) {
                if (status.remainingSeconds <= (status.maxRuntimeMinutes - 1) * 60) {
                    link.send(Codec.setRuntime(status.maxRuntimeMinutes))
                }
                return
            }
            delay(200)
        }
    }

    suspend fun setLED(on: Boolean) {
        val link = link ?: return
        perform { link.send(Codec.setLED(on)) }
    }

    suspend fun setMuted(muted: Boolean) {
        val link = link ?: return
        perform { link.send(Codec.setMuted(muted)) }
    }

    private suspend fun perform(work: suspend () -> Unit) {
        isBusy = true
        try {
            takeControl()
            work()
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            errorMessage = error.message ?: BedJetError.BadResponse.message
        } finally {
            isBusy = false
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
        if (!options.logsConnections) return
        val timing = (link as? BleLink)?.lastConnection ?: return
        val line = "new connection: radio %.0f, link %.0f, services %.0f, usable %.0f ms, %s\n".format(
            timing.radioOn * 1000, timing.linkUp * 1000, timing.services * 1000, timing.usable * 1000,
            if (timing.knownUnit) "known unit" else "scanned",
        )
        val stamp = LocalTime.now().format(DateTimeFormatter.ofPattern("HH:mm:ss"))
        File(getApplication<Application>().filesDir, "connections.txt").appendText("$stamp $line")
    }

    // Schedules

    fun save(schedule: Schedule) {
        val index = schedules.indexOfFirst { it.id == schedule.id }
        schedules = if (index >= 0) schedules.toMutableList().also { it[index] = schedule } else schedules + schedule
    }

    fun delete(schedule: Schedule) {
        schedules = schedules.filter { it.id != schedule.id }
        if (tonightID == schedule.id) tonightID = schedules.firstOrNull()?.id
    }

    fun degrees(halfCelsius: Int): String = "${Format.degrees(halfCelsius, useFahrenheit)}°"

    // Persistence

    @Serializable
    private data class Saved(
        val schedules: List<Schedule>,
        val tonightID: String? = null,
        val run: ActiveRun? = null,
        val slot: Int? = null,
    )

    private val file = File(application.filesDir, "lull.json")
    private val json = Json { ignoreUnknownKeys = true }

    // Last, so every property above is set before anything is loaded or connected.
    init {
        load()
        reconnect()
    }

    private fun load() {
        val saved = if (options.ephemeral) null else runCatching { json.decodeFromString<Saved>(file.readText()) }.getOrNull()
        if (saved != null) {
            savedSchedules = saved.schedules
            savedTonightID = saved.tonightID
            savedRun = saved.run?.takeIf { it.endsAt > System.currentTimeMillis() }
            savedSlot = saved.slot
        } else {
            savedSchedules = Schedule.templates
            savedTonightID = savedSchedules.firstOrNull()?.id
        }
        isLoaded = true
    }

    private fun save() {
        if (!isLoaded || options.ephemeral) return
        val saved = Saved(schedules, tonightID, run, slot)
        runCatching {
            val temporary = File(file.parentFile, "lull.json.tmp")
            temporary.writeText(json.encodeToString(Saved.serializer(), saved))
            temporary.renameTo(file)
        }
    }

    private companion object {
        fun usesUSUnits(): Boolean = LocaleData.getMeasurementSystem(ULocale.getDefault()) == LocaleData.MeasurementSystem.US

        /** The emulator has no BedJet nearby, so it always uses the simulated one, like the iOS Simulator. */
        fun isEmulator(): Boolean =
            Build.FINGERPRINT.startsWith("generic") || Build.HARDWARE in setOf("goldfish", "ranchu") ||
                Build.PRODUCT.contains("sdk")
    }
}
