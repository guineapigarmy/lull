package com.rohankanjani.lull.wear.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bed
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.rohankanjani.lull.Format
import com.rohankanjani.lull.LiveStatus
import com.rohankanjani.lull.Phase
import com.rohankanjani.lull.PresetChoice
import com.rohankanjani.lull.RemotePreset
import com.rohankanjani.lull.WatchCommand
import com.rohankanjani.lull.WidgetBedJet
import com.rohankanjani.lull.bedjetkit.Mode
import com.rohankanjani.lull.defaultTemperature
import com.rohankanjani.lull.maxMinutes
import com.rohankanjani.lull.remoteModes
import com.rohankanjani.lull.title
import com.rohankanjani.lull.ui.tint
import com.rohankanjani.lull.wear.WatchModel

/**
 * Air right now rather than a schedule, as the phone's Remote: a mode, and the temperature, fan and timer to run it at,
 * sent together once they're set.
 */
@Composable
fun RemotePage(model: WatchModel) {
    val bedJet = model.bedJet
    if (bedJet == null) {
        EmptyMessage(Icons.Filled.Bed, "No BedJet yet", "Choose your BedJet in Lull on your phone.")
    } else {
        Controls(model, bedJet)
    }
    model.unavailable?.let { Footnote(it) }
}

@Composable
private fun Controls(model: WatchModel, bedJet: WidgetBedJet) {
    val fahrenheit = model.snapshot.useFahrenheit
    var mode by remember { mutableStateOf(Mode.COOL) }
    var temperature by remember { mutableIntStateOf(Mode.COOL.defaultTemperature) }
    var fan by remember { mutableIntStateOf(40) }
    var minutes by remember { mutableIntStateOf(30) }

    /** How long the mode may run at this temperature and fan, with a step that suits the span, as on the phone. */
    fun runtimeLimit(): Pair<IntRange, Int> {
        val longest = Phase(mode, temperature, fan, 1).maxMinutes
        val step = if (longest <= 15) 1 else if (longest <= 240) 5 else 15
        return step..maxOf(longest / step * step, step * 2) to step
    }

    // Starts from what the BedJet is doing, and again for another BedJet: air from the Remote, or the Quick Remote's
    // first button, Cool for 30 minutes.
    LaunchedEffect(bedJet.id) {
        val air = bedJet.live(System.currentTimeMillis()) as? LiveStatus.Air
        if (air != null) {
            mode = air.mode
            temperature = air.temperature ?: air.mode.defaultTemperature
            fan = air.fanPercent
            val step = runtimeLimit().second
            minutes = maxOf(((air.endsAt - System.currentTimeMillis()) / 60_000L).toInt() / step * step, step)
        } else {
            val first = PresetChoice.defaults[0].preset(fahrenheit)
            mode = first.mode
            temperature = first.temperature
            fan = first.fanPercent
            minutes = first.minutes
        }
    }

    val modes = remoteModes.filter(bedJet.generation::supports) + Mode.STANDBY
    for (row in modes.chunked(3)) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            for (option in row) {
                ModeButton(option, option == mode, Modifier.weight(1f), option.title) {
                    if (option != mode) {
                        mode = option
                        temperature = option.defaultTemperature
                        val (range, _) = runtimeLimit()
                        minutes = minutes.coerceIn(range.first, range.last)
                    }
                }
            }
            repeat(3 - row.size) { Spacer(Modifier.weight(1f)) }
        }
    }
    if (mode != Mode.STANDBY) {
        if (bedJet.generation.adjustsTemperature(mode)) {
            // In the degrees Lull shows, whole degrees at a time, as on the phone.
            val low = Format.degrees(mode.temperatureRange.first, fahrenheit)
            val high = maxOf(Format.degrees(mode.temperatureRange.last, fahrenheit), low + 1)
            CrownRow(
                title = "Temperature",
                valueText = model.snapshot.degrees(temperature),
                value = Format.degrees(temperature, fahrenheit),
                onValueChange = { temperature = Format.halfCelsius(it, fahrenheit).coerceIn(mode.temperatureRange) },
                range = low..high,
                tint = mode.tint,
            )
        }
        if (mode.usesFan) {
            CrownRow("Fan", "$fan%", fan, { fan = it }, 5..100, step = 5, tint = mode.tint)
        }
        val (range, step) = runtimeLimit()
        CrownRow("Turns off in", Format.duration(minutes), minutes, { minutes = it }, range, step, spokenValue = Format.spokenDuration(minutes))
    }
    val preset = RemotePreset(mode, minutes, temperature, fan).clamped
    ErrandButton(model, if (mode == Mode.STANDBY) "Turn Off" else "Apply", "Sending…", WatchCommand.Remote(preset, bedJet.id))
    if (bedJet.live(System.currentTimeMillis()) is LiveStatus.Night) {
        Footnote("Choosing a mode here ends the schedule that's running.")
    }
}
