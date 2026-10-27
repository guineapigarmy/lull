package com.rohankanjani.lull

import com.rohankanjani.lull.bedjetkit.Mode
import kotlinx.serialization.Serializable

/** The app's tabs, which widgets, tiles and shortcuts open to. */
enum class LullTab {
    REMOTE, SCHEDULE, HISTORY;

    /** Opens Lull on this tab when a widget is tapped. */
    val link: String get() = "lull://${name.lowercase()}"

    /** Opens Lull on this tab showing one BedJet, from something outside Lull that shows it. */
    fun link(showing: String): String = "$link?bedjet=$showing"

    companion object {
        fun from(link: String?): LullTab? = entries.firstOrNull { it.link == link?.substringBefore('?') }

        /** The BedJet a link asks to show, if it names one. */
        fun bedJet(link: String?): String? =
            link?.substringAfter('?', "")?.split('&')?.firstOrNull { it.startsWith("bedjet=") }?.removePrefix("bedjet=")?.ifEmpty { null }
    }
}

/** Air from one Quick Remote button: a mode, how long, and the temperature and fan to run it at. */
data class RemotePreset(
    val mode: Mode,
    val minutes: Int,
    /** Half-degrees Celsius. Ignored for Off, and for modes the BedJet doesn't take a temperature for. */
    val temperature: Int,
    val fanPercent: Int,
) {
    /** "Cool · 30 min", as on the widget's button. */
    val title: String get() = if (mode == Mode.STANDBY) "Off" else "${mode.title} · ${Format.duration(minutes)}"

    /** What else it sets, such as "72° · Fan 40%", read out after the button's title. Null for Off. */
    fun setting(fahrenheit: Boolean): String? {
        if (mode == Mode.STANDBY) return null
        return Format.setting(mode, temperature.takeIf { mode.usesTemperature }, fanPercent, fahrenheit)
    }

    /**
     * Kept to what the BedJet takes: the mode's temperatures, the fan in steps of 5, and no longer than a phase in that
     * mode may run, so Turbo stops at 10 minutes and hot, fast Heat at the BedJet's safety cut-off.
     */
    val clamped: RemotePreset
        get() {
            val temperature = temperature.coerceIn(mode.temperatureRange)
            val fanPercent = ((fanPercent + 2) / 5 * 5).coerceIn(5, 100)
            val longest = Phase(mode, temperature, fanPercent, minutes).maxMinutes
            return RemotePreset(mode, minutes.coerceIn(1, longest), temperature, fanPercent)
        }

    companion object {
        /** Cool for 30 minutes, Heat for 15, and Off: the buttons a Quick Remote widget starts with. */
        val defaults = PresetChoice.defaults.map { it.preset(fahrenheit = false) }
    }
}

/**
 * One Quick Remote button as set up when editing the widget. Its temperature is in the degrees Lull shows, as the
 * person chose it, or null for the mode's usual temperature.
 */
@Serializable
data class PresetChoice(val mode: Mode, val minutes: Int, val degrees: Int? = null, val fanPercent: Int = 40) {
    /** What the button sets, in the BedJet's units and within what it takes. */
    fun preset(fahrenheit: Boolean): RemotePreset {
        val temperature = degrees?.let { Format.halfCelsius(it, fahrenheit) } ?: mode.defaultTemperature
        return RemotePreset(mode, minutes, temperature, fanPercent).clamped
    }

    companion object {
        val defaults = listOf(
            PresetChoice(Mode.COOL, 30),
            PresetChoice(Mode.HEAT, 15),
            PresetChoice(Mode.STANDBY, 30),
        )
    }
}
