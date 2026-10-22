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
import com.rohankanjani.lull.bedjetkit.DemoLink
import com.rohankanjani.lull.bedjetkit.Generation
import com.rohankanjani.lull.bedjetkit.StoredProgram
import kotlinx.coroutines.CoroutineScope
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File

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
    /** Fills an empty History with a few sample nights, for listing screenshots. */
    val demoHistory: Boolean = false,
)

class AppModel(application: Application, val options: LaunchOptions) : AndroidViewModel(application) {
    /** Every BedJet Lull connects to, in the order they were added. Never empty once loaded. */
    var bedJets by mutableStateOf<List<BedJet>>(emptyList()); private set
    private var selectedID by mutableStateOf<String?>(null)
    /** The BedJet every screen shows and controls. */
    val bedJet: BedJet get() = bedJets.firstOrNull { it.id == selectedID } ?: bedJets[0]
    val hasSeveralBedJets: Boolean get() = bedJets.size > 1

    private var savedSchedules by mutableStateOf<List<Schedule>>(emptyList())
    var schedules: List<Schedule>
        get() = savedSchedules
        set(value) { savedSchedules = value; save() }

    private val prefs = application.getSharedPreferences("Lull", Context.MODE_PRIVATE)

    private var fahrenheit by mutableStateOf(prefs.getBoolean("useFahrenheit", usesUSUnits()))
    var useFahrenheit: Boolean
        get() = fahrenheit
        set(value) { fahrenheit = value; prefs.edit().putBoolean("useFahrenheit", value).apply() }

    private var demo by mutableStateOf(isEmulator() || prefs.getBoolean("demoMode", false))
    var demoMode: Boolean
        get() = demo
        set(value) {
            if (value == demo) return
            demo = value
            prefs.edit().putBoolean("demoMode", value).apply()
            val leaving = fleet
            show(otherFleet)
            otherFleet = leaving
            save()
        }

    var errorMessage by mutableStateOf<String?>(null)

    /**
     * Where the screens run what the person asked for. It outlives the screen that asked, as an
     * unstructured Task does on iOS, so a card that disappears mid-save doesn't cancel the save.
     */
    val scope: CoroutineScope get() = viewModelScope

    private var isLoaded = false
    /** The BedJets of the mode not in use, kept as they were saved. */
    private var otherFleet: Fleet? = null

    override fun onCleared() {
        for (bedJet in bedJets) bedJet.pause()
    }

    // BedJets

    fun select(id: String) {
        if (id == bedJet.id) return
        selectedID = id
        save()
    }

    /** Adds a BedJet and shows it, so the person can watch it being looked for. */
    fun addBedJet() {
        val saved = SavedBedJet(
            tonightID = bedJet.tonightID,
            name = if (demoMode) "${DemoLink.DEFAULT_NAME}-${bedJets.size + 1}" else null,
        )
        val added = BedJet(saved, isDemo = demoMode, app = this)
        bedJets = bedJets + added
        selectedID = added.id
        added.connect(asking = true)
        save()
    }

    /** With one BedJet, forgetting it lets Lull pair with whichever is nearest. With several, it is removed. */
    fun forget(bedJet: BedJet) {
        if (!hasSeveralBedJets) return bedJet.forgetUnit()
        bedJet.pause()
        bedJet.deleteHistory()
        bedJets = bedJets.filter { it !== bedJet }
        if (selectedID == bedJet.id) selectedID = bedJets.firstOrNull()?.id
        save()
    }

    /**
     * Whether a unit found nearby may connect for `bedJet`. Two BedJets never take the same unit, and one
     * that already has a unit keeps to it, unless it is the only one and its unit may have been replaced.
     */
    fun accepts(unit: String, bedJet: BedJet): Boolean {
        val others = bedJets.filter { it !== bedJet }
        if (others.any { it.unit == unit || it.unitInUse == unit }) return false
        return bedJet.unit == null || bedJet.unit == unit || others.isEmpty()
    }

    /** What a BedJet is called on screen: its own name, numbered when two share one. */
    fun title(of: BedJet): String {
        val name = of.name ?: "New BedJet"
        val twins = bedJets.filter { (it.name ?: "New BedJet") == name }
        val index = twins.indexOfFirst { it === of }
        if (twins.size <= 1 || index < 0) return name
        return "$name ${index + 1}"
    }

    fun report(message: String, from: BedJet) {
        errorMessage = if (hasSeveralBedJets) "${title(from)}: $message" else message
    }

    fun appMovedToBackground() {
        for (bedJet in bedJets) bedJet.pause()
    }

    fun appBecameActive() {
        for (bedJet in bedJets) bedJet.resume(asking = bedJet === this.bedJet)
    }

    /** Bluetooth access was just granted or refused; look at the radio again. */
    fun permissionsChanged() {
        if (!demoMode) for (bedJet in bedJets) bedJet.connect(asking = bedJet === this.bedJet)
    }

    private fun show(fleet: Fleet?) {
        for (bedJet in bedJets) bedJet.pause()
        var saved = fleet?.bedJets.orEmpty()
        if (saved.isEmpty()) saved = listOf(firstBedJet(demoMode))
        bedJets = saved.map { BedJet(it, isDemo = demoMode, app = this) }
        selectedID = fleet?.selected
        for (bedJet in bedJets) bedJet.connect(asking = bedJet === this.bedJet)
    }

    /** The BedJet a mode starts out with. One an earlier version of Lull knew, with its history, carries over. */
    private fun firstBedJet(demo: Boolean, legacy: Saved? = null): SavedBedJet {
        val legacyUnit = if (demo) null else BleLink.legacyUnit(getApplication())
        val first = SavedBedJet(
            unit = legacyUnit?.first,
            name = if (demo) DemoLink.DEFAULT_NAME else legacyUnit?.second,
            generation = if (demo) Generation.V3
            else prefs.getString("generation", null)?.let { name -> Generation.entries.firstOrNull { it.name == name } } ?: Generation.V3,
            tonightID = legacy?.tonightID ?: schedules.firstOrNull()?.id,
            run = legacy?.run,
            slot = legacy?.slot,
        )
        if (!options.ephemeral) {
            val history = File(getApplication<Application>().filesDir, if (demo) "history-demo.json" else "history.json")
            if (history.exists()) history.renameTo(BedJet.historyFile(this, first.id))
        }
        return first
    }

    // Schedules

    /** Keeps a copy of a program made elsewhere, so reusing its slot never loses it. */
    fun keepCopy(program: StoredProgram) {
        val imported = Schedule.importing(program)
        if (schedules.none { existing -> existing.phases.map { it.step } == imported.phases.map { it.step } }) {
            schedules = schedules + imported
        }
    }

    fun save(schedule: Schedule) {
        val index = schedules.indexOfFirst { it.id == schedule.id }
        schedules = if (index >= 0) schedules.toMutableList().also { it[index] = schedule } else schedules + schedule
    }

    fun delete(schedule: Schedule) {
        schedules = schedules.filter { it.id != schedule.id }
        for (bedJet in bedJets) if (bedJet.tonightID == schedule.id) bedJet.tonightID = schedules.firstOrNull()?.id
    }

    fun degrees(halfCelsius: Int): String = "${Format.degrees(halfCelsius, useFahrenheit)}°"

    /** A phase in words for TalkBack, such as "Heat, 75°, fan 40%, 30 minutes". */
    fun spokenSummary(phase: Phase): String {
        val parts = mutableListOf(phase.mode.title)
        if (bedJet.adjustsTemperature(phase.mode)) parts += degrees(phase.temperature)
        if (phase.mode.usesFan) parts += "fan ${phase.fanPercent}%"
        parts += Format.spokenDuration(phase.minutes)
        return parts.joinToString(", ")
    }

    // Persistence

    /** The BedJets known in one mode. Demo mode keeps its own, so pretend units never mix with real ones. */
    @Serializable
    private data class Fleet(val bedJets: List<SavedBedJet>, val selected: String? = null)

    @Serializable
    private data class Saved(
        val schedules: List<Schedule>,
        val fleet: Fleet? = null,
        val demoFleet: Fleet? = null,
        // Kept by versions that knew a single BedJet.
        val tonightID: String? = null,
        val run: ActiveRun? = null,
        val slot: Int? = null,
    )

    private val fleet: Fleet get() = Fleet(bedJets.map { it.saved }, selectedID)

    private val file = File(application.filesDir, "lull.json")

    private fun load() {
        val saved = if (options.ephemeral) null else runCatching { json.decodeFromString<Saved>(file.readText()) }.getOrNull()
        savedSchedules = saved?.schedules ?: Schedule.templates
        otherFleet = if (demoMode) saved?.fleet else saved?.demoFleet
        val fleet = if (demoMode) saved?.demoFleet else saved?.fleet
        // Before Lull knew several BedJets, what it kept belonged to the one in use.
        show(fleet ?: Fleet(listOf(firstBedJet(demoMode, legacy = saved))))
        isLoaded = true
        save()
    }

    fun save() {
        if (!isLoaded || options.ephemeral) return
        val saved = Saved(
            schedules = schedules,
            fleet = if (demoMode) otherFleet else fleet,
            demoFleet = if (demoMode) fleet else otherFleet,
        )
        runCatching {
            val temporary = File(file.parentFile, "lull.json.tmp")
            temporary.writeText(json.encodeToString(Saved.serializer(), saved))
            temporary.renameTo(file)
        }
    }

    // Last, so every property above is set before anything is loaded or connected.
    init {
        load()
    }

    companion object {
        val json = Json { ignoreUnknownKeys = true }

        private fun usesUSUnits(): Boolean = LocaleData.getMeasurementSystem(ULocale.getDefault()) == LocaleData.MeasurementSystem.US

        /** The emulator has no BedJet nearby, so it always uses the simulated one, like the iOS Simulator. */
        private fun isEmulator(): Boolean =
            Build.FINGERPRINT.startsWith("generic") || Build.HARDWARE in setOf("goldfish", "ranchu") ||
                Build.PRODUCT.contains("sdk")
    }
}
