package com.rohankanjani.lull.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.BlurredEdgeTreatment
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rohankanjani.lull.AppModel
import com.rohankanjani.lull.Format
import com.rohankanjani.lull.activity
import com.rohankanjani.lull.bedjetkit.DeviceStatus
import com.rohankanjani.lull.bedjetkit.LinkState
import com.rohankanjani.lull.bedjetkit.Mode
import com.rohankanjani.lull.maxMinutes
import com.rohankanjani.lull.remoteModes
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Direct control, for when you want air right now rather than a schedule. */
@Composable
fun RemoteScreen(model: AppModel) {
    val status = model.status
    val mode = status?.mode ?: Mode.STANDBY
    var temperature by remember { mutableIntStateOf(60) }
    var fan by remember { mutableFloatStateOf(40f) }
    var runtime by remember { mutableFloatStateOf(60f) }
    /** While a slider is in use, and briefly after, it leads and the BedJet's reports are not applied to it. */
    var followAfter by remember { mutableLongStateOf(0L) }
    val pending = remember { mutableStateMapOf<String, Job>() }
    /** The mode just tapped, shown as selected until the BedJet reports it. */
    var chosenMode by remember { mutableStateOf<Mode?>(null) }

    /**
     * Forwards what the person sets to the BedJet shortly after they stop moving the slider.
     * Only their input passes through here, so values applied from the BedJet are never echoed back.
     */
    fun sending(name: String, send: suspend () -> Unit) {
        followAfter = System.currentTimeMillis() + 1500
        pending[name]?.cancel()
        pending[name] = model.scope.launch {
            delay(350)
            send()
        }
    }

    LaunchedEffect(status) {
        // Follow the unit, which can also be changed from its own remote, but never
        // while a slider is being moved or its new value is still on the way there.
        if (status == null || model.isBusy || System.currentTimeMillis() <= followAfter) return@LaunchedEffect
        temperature = status.targetTemperature
        fan = status.fanPercent.toFloat()
        val limit = runtimeLimit(status)
        runtime = minutesLeft(status).toFloat().coerceIn(limit.range)
    }

    Screen(model, "Remote") {
        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) { ClimateOrb(model, status) }

        if (model.linkState == LinkState.YIELDED) {
            Text(
                "In use on another phone. Touch a control to take over.",
                fontSize = 13.sp, color = Theme.secondary, modifier = Modifier.align(Alignment.CenterHorizontally),
            )
        }

        Box(Modifier.alpha(if (model.canControl) 1f else 0.4f)) {
            ModePicker(remoteModes + Mode.STANDBY, chosenMode ?: status?.mode) { picked ->
                if (!model.canControl) return@ModePicker
                chosenMode = picked
                model.scope.launch {
                    model.setMode(picked)
                    chosenMode = null
                }
            }
        }

        AnimatedVisibility(
            visible = status?.isRunning == true,
            enter = fadeIn(tween(300)) + slideInVertically(tween(300)) { it / 3 },
            exit = fadeOut(tween(300)) + slideOutVertically(tween(300)) { it / 3 },
        ) {
            val shown = status ?: return@AnimatedVisibility
            Card(padding = 18.dp) {
                Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
                    if (shown.mode.usesTemperature) {
                        TemperatureSlider(
                            model, shown.mode, temperature,
                            onChange = {
                                temperature = it
                                sending("temperature") { model.setTemperature(temperature) }
                            },
                            limits = if (shown.minTemperature < shown.maxTemperature) shown.minTemperature..shown.maxTemperature else null,
                        )
                    }
                    LabeledSlider(
                        "Fan", "${fan.toInt()}%", fan,
                        onValueChange = {
                            fan = it
                            sending("fan") { model.setFan(fan.toInt()) }
                        },
                        range = 5f..100f, step = 5f, tint = shown.mode.tint,
                    )
                    if (model.run == null) {
                        val limit = runtimeLimit(shown)
                        LabeledSlider(
                            "Turns off in", Format.duration(runtime.toInt()), runtime,
                            onValueChange = {
                                runtime = it
                                sending("runtime") { model.setRuntime(runtime.toInt()) }
                            },
                            range = limit.range, step = limit.step,
                        )
                    } else {
                        // A schedule sets its own timing, so this is read-only until it ends.
                        Row(verticalAlignment = Alignment.Bottom) {
                            Text("Phase ends in", fontSize = 15.sp, fontWeight = FontWeight.Medium, color = Theme.secondary)
                            Spacer(Modifier.weight(1f))
                            Text(Format.duration(minutesLeft(shown)), fontSize = 20.sp, fontWeight = FontWeight.SemiBold, style = Theme.tabular)
                        }
                    }
                }
            }
        }
        if (model.run != null) {
            Text(
                "Choosing a mode here ends the schedule that's running.",
                fontSize = 13.sp, color = Theme.tertiary, modifier = Modifier.align(Alignment.CenterHorizontally),
            )
        }
    }
}

private fun minutesLeft(status: DeviceStatus): Int = maxOf((status.remainingSeconds + 59) / 60, 1)

private class RuntimeLimit(val range: ClosedFloatingPointRange<Float>, val step: Float)

/** How long the current mode may run, as the BedJet reports it, with a step size that suits the span. */
private fun runtimeLimit(status: DeviceStatus): RuntimeLimit {
    val longest = if (status.maxRuntimeMinutes > 0) status.maxRuntimeMinutes else status.mode.maxMinutes
    val step = if (longest <= 15) 1 else if (longest <= 240) 5 else 15
    return RuntimeLimit(step.toFloat()..maxOf(longest / step * step, step * 2).toFloat(), step.toFloat())
}

/**
 * Temperature in the person's unit, stored in half-degrees Celsius.
 * The Remote passes the limits the BedJet reports for the mode it is in, which can be narrower than the mode's range.
 */
@Composable
fun TemperatureSlider(model: AppModel, mode: Mode, temperature: Int, onChange: (Int) -> Unit, limits: IntRange? = null) {
    val bounds = limits ?: mode.temperatureRange
    val low = Format.degrees(bounds.first, model.useFahrenheit)
    val high = maxOf(Format.degrees(bounds.last, model.useFahrenheit), low + 1)
    LabeledSlider(
        "Temperature", model.degrees(temperature), Format.degrees(temperature, model.useFahrenheit).toFloat(),
        onValueChange = { value ->
            val halves = Format.halfCelsius(value.toInt(), model.useFahrenheit)
            onChange(halves.coerceIn(bounds))
        },
        range = low.toFloat()..high.toFloat(), tint = mode.tint,
    )
}

/** The glowing live readout: what the BedJet is doing this second. */
@Composable
fun ClimateOrb(model: AppModel, status: DeviceStatus?) {
    val mode = status?.mode ?: Mode.STANDBY
    val isOn = status?.isRunning ?: false
    val tint by animateColorAsState(mode.tint, tween(600), label = "tint")
    val ring by animateDpAsState(if (isOn) 2.5.dp else 1.dp, tween(600), label = "ring")
    Box(Modifier.size(204.dp).semantics(mergeDescendants = true) {}, contentAlignment = Alignment.Center) {
        Canvas(Modifier.fillMaxSize().blur(24.dp, BlurredEdgeTreatment.Unbounded)) {
            drawCircle(
                Brush.radialGradient(
                    listOf(tint.copy(alpha = if (isOn) 0.55f else 0.12f), Color.Transparent),
                    radius = 112.dp.toPx(),
                ),
            )
        }
        Canvas(Modifier.fillMaxSize().padding(8.dp)) {
            val width = ring.toPx()
            drawCircle(
                Brush.sweepGradient(listOf(tint.copy(alpha = 0.9f), tint.copy(alpha = 0.15f), tint.copy(alpha = 0.9f))),
                radius = size.minDimension / 2 - width / 2,
                style = Stroke(width),
            )
        }
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
            if (status != null) {
                Eyebrow(mode.activity)
                Text(
                    if (isOn && mode.usesTemperature) model.degrees(status.targetTemperature) else if (isOn) "${status.fanPercent}%" else "Off",
                    fontSize = 60.sp, fontWeight = FontWeight.Thin, style = Theme.tabular,
                )
                Text(
                    if (isOn) "Fan ${status.fanPercent}% · Air ${model.degrees(status.actualTemperature)}"
                    else "Room ${model.degrees(status.ambientTemperature)}",
                    fontSize = 15.sp, fontWeight = FontWeight.Medium, color = Theme.secondary, style = Theme.tabular,
                )
            } else {
                CircularProgressIndicator(color = Theme.secondary, strokeWidth = 2.dp, modifier = Modifier.size(22.dp))
                Text(
                    "Looking for your BedJet", fontSize = 15.sp, fontWeight = FontWeight.Medium, color = Theme.secondary,
                    modifier = Modifier.padding(top = 8.dp),
                )
            }
        }
    }
}
