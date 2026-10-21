package com.rohankanjani.lull.ui

import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Add
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TimePicker
import androidx.compose.material3.TimePickerDefaults
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.material3.rememberTimePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.rohankanjani.lull.AppModel
import com.rohankanjani.lull.Format
import com.rohankanjani.lull.Phase
import com.rohankanjani.lull.Schedule
import com.rohankanjani.lull.bedjetkit.Limits
import com.rohankanjani.lull.bedjetkit.Mode
import com.rohankanjani.lull.defaultTemperature
import com.rohankanjani.lull.maxMinutes
import com.rohankanjani.lull.title

@Composable
fun ScheduleEditor(model: AppModel, initial: Schedule, onDismiss: () -> Unit) {
    var schedule by remember(initial.id) { mutableStateOf(initial) }
    var selection by remember { mutableStateOf<String?>(null) }
    var picksBedtime by remember { mutableStateOf(false) }
    val focus = LocalFocusManager.current
    val isValid = schedule.name.isNotBlank() && schedule.phases.isNotEmpty()

    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        Box(Modifier.fillMaxSize().background(Theme.background)) {
            Column(Modifier.fillMaxSize().statusBarsPadding()) {
                Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                    TextButton(onDismiss) { Text("Cancel", fontSize = 17.sp, color = Color.White) }
                    Spacer(Modifier.weight(1f))
                    TextButton(
                        onClick = {
                            model.save(schedule)
                            onDismiss()
                        },
                        enabled = isValid,
                    ) { Text("Save", fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = Color.White.copy(alpha = if (isValid) 1f else 0.4f)) }
                }
                Column(
                    Modifier
                        .weight(1f)
                        .verticalScroll(rememberScrollState())
                        .padding(horizontal = 20.dp)
                        .padding(bottom = 24.dp),
                    verticalArrangement = Arrangement.spacedBy(20.dp),
                ) {
                    BasicTextField(
                        value = schedule.name,
                        // The BedJet stores 15 characters.
                        onValueChange = { schedule = schedule.copy(name = it.take(Limits.NAME_LENGTH)) },
                        textStyle = TextStyle(fontSize = 30.sp, fontWeight = FontWeight.Bold, color = Color.White),
                        cursorBrush = SolidColor(Color.White),
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Words, imeAction = ImeAction.Done),
                        keyboardActions = KeyboardActions(onDone = { focus.clearFocus() }),
                        modifier = Modifier.fillMaxWidth().semantics { contentDescription = "Name" },
                        decorationBox = { field ->
                            if (schedule.name.isEmpty()) Text("Name", fontSize = 30.sp, fontWeight = FontWeight.Bold, color = Theme.tertiary)
                            field()
                        },
                    )

                    Card(Modifier.animateContentSize()) {
                        NightTimeline(schedule, selection = selection, height = 170.dp)
                    }

                    Card(padding = 16.dp) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                                Text("Usual bedtime", fontSize = 17.sp, fontWeight = FontWeight.Medium)
                                Text("Wake around ${Format.clock(schedule.bedtime + schedule.totalMinutes)}", fontSize = 13.sp, color = Theme.secondary)
                            }
                            Text(
                                Format.clock(schedule.bedtime),
                                fontSize = 17.sp,
                                style = Theme.tabular,
                                modifier = Modifier
                                    .clip(RoundedCornerShape(8.dp))
                                    .background(Theme.raised)
                                    .clickable(role = Role.Button) { picksBedtime = true }
                                    .padding(horizontal = 12.dp, vertical = 6.dp),
                            )
                        }
                    }

                    Eyebrow("Phases")
                    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        schedule.phases.forEach { phase ->
                            PhaseRow(model, phase, schedule.startMinute(phase)) { selection = phase.id }
                        }
                    }
                    if (schedule.phases.size < Limits.STEPS_PER_PROGRAM) {
                        PrimaryButton(
                            onClick = {
                                val phase = Phase(Mode.COOL, fanPercent = 30, minutes = 60)
                                schedule = schedule.copy(phases = schedule.phases + phase)
                                selection = phase.id
                            },
                            prominent = false,
                        ) {
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                Icon(Icons.Filled.Add, null, modifier = Modifier.size(20.dp))
                                Text("Add Phase")
                            }
                        }
                    }
                }
                Box(Modifier.fillMaxWidth().background(Theme.surface.copy(alpha = 0.92f)).navigationBarsPadding().imePadding()) {
                    PrimaryButton(
                        "Use Tonight",
                        onClick = {
                            model.save(schedule)
                            model.tonightID = schedule.id
                            onDismiss()
                        },
                        enabled = isValid,
                        modifier = Modifier.padding(horizontal = 20.dp, vertical = 12.dp),
                    )
                }
            }

            val index = schedule.phases.indexOfFirst { it.id == selection }
            if (index >= 0) {
                PhaseEditor(
                    model,
                    phase = schedule.phases[index],
                    onChange = { changed -> schedule = schedule.copy(phases = schedule.phases.toMutableList().also { it[index] = changed }) },
                    canDelete = schedule.phases.size > 1,
                    onDelete = {
                        selection = null
                        schedule = schedule.copy(phases = schedule.phases.toMutableList().also { it.removeAt(index) })
                    },
                    onDismiss = { selection = null },
                )
            }
            if (picksBedtime) {
                BedtimePicker(schedule.bedtime, onPick = { schedule = schedule.copy(bedtime = it) }, onDismiss = { picksBedtime = false })
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun BedtimePicker(minuteOfDay: Int, onPick: (Int) -> Unit, onDismiss: () -> Unit) {
    val state = rememberTimePickerState(minuteOfDay / 60, minuteOfDay % 60, is24Hour = Format.use24Hour)
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Theme.raised,
        title = { Text("Usual bedtime") },
        text = {
            TimePicker(
                state,
                colors = TimePickerDefaults.colors(
                    clockDialColor = Theme.surface,
                    selectorColor = Color.White,
                    clockDialSelectedContentColor = Color.Black,
                    timeSelectorSelectedContainerColor = Color.White,
                    timeSelectorSelectedContentColor = Color.Black,
                    timeSelectorUnselectedContainerColor = Theme.surface,
                    periodSelectorSelectedContainerColor = Color.White,
                    periodSelectorSelectedContentColor = Color.Black,
                ),
            )
        },
        confirmButton = {
            TextButton({
                onPick(state.hour * 60 + state.minute)
                onDismiss()
            }) { Text("Done") }
        },
        dismissButton = { TextButton(onDismiss) { Text("Cancel") } },
    )
}

@Composable
private fun PhaseRow(model: AppModel, phase: Phase, startsAt: Int, onClick: () -> Unit) {
    val detail = buildList {
        if (model.adjustsTemperature(phase.mode)) add(model.degrees(phase.temperature))
        if (phase.mode.usesFan) add("Fan ${phase.fanPercent}%")
    }.ifEmpty { listOf("Air off") }.joinToString(" · ")
    val shape = RoundedCornerShape(22.dp)
    Row(
        Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(Theme.surface)
            .border(BorderStroke(1.dp, Theme.hairline), shape)
            .clickable(role = Role.Button, onClick = onClick)
            .semantics(mergeDescendants = true) {
                contentDescription = "${phase.mode.title}, $detail, ${Format.duration(phase.minutes)}, ${Format.clock(startsAt)}"
            }
            .padding(14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Box(Modifier.size(40.dp).background(phase.mode.tint.copy(alpha = 0.16f), CircleShape), contentAlignment = Alignment.Center) {
            Icon(phase.mode.icon, null, tint = phase.mode.tint, modifier = Modifier.size(18.dp))
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(phase.mode.title, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
            Text(detail, fontSize = 13.sp, color = Theme.secondary)
        }
        Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(Format.duration(phase.minutes), fontSize = 15.sp, fontWeight = FontWeight.Medium, style = Theme.tabular)
            Text(Format.clock(startsAt), fontSize = 13.sp, color = Theme.secondary, style = Theme.tabular)
        }
        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = Theme.tertiary, modifier = Modifier.size(18.dp))
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PhaseEditor(
    model: AppModel,
    phase: Phase,
    onChange: (Phase) -> Unit,
    canDelete: Boolean,
    onDelete: () -> Unit,
    onDismiss: () -> Unit,
) {
    val sheet = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val isHeatLimited = phase.maxMinutes < phase.mode.maxMinutes
    LaunchedEffect(phase.maxMinutes) {
        if (phase.minutes > phase.maxMinutes) onChange(phase.copy(minutes = phase.maxMinutes))
    }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheet, containerColor = Theme.surface, dragHandle = null) {
        Column(
            Modifier.padding(24.dp).padding(top = 8.dp).navigationBarsPadding().animateContentSize(),
            verticalArrangement = Arrangement.spacedBy(24.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Phase", fontSize = 22.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.weight(1f))
                TextButton(onDismiss) { Text("Done", fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = Color.White) }
            }
            ModePicker(model.phaseModes, phase.mode) { mode ->
                onChange(
                    phase.copy(
                        mode = mode,
                        temperature = if (phase.temperature in mode.temperatureRange) phase.temperature else mode.defaultTemperature,
                    ),
                )
            }
            if (model.adjustsTemperature(phase.mode)) {
                TemperatureSlider(model, phase.mode, phase.temperature, onChange = { onChange(phase.copy(temperature = it)) })
            }
            if (phase.mode.usesFan) {
                LabeledSlider(
                    "Fan", "${phase.fanPercent}%", phase.fanPercent.toFloat(),
                    onValueChange = { onChange(phase.copy(fanPercent = it.toInt())) },
                    range = 5f..100f, step = 5f, tint = phase.mode.tint,
                )
            }
            LabeledSlider(
                "Duration", Format.duration(phase.minutes), phase.minutes.toFloat(),
                onValueChange = { onChange(phase.copy(minutes = it.toInt())) },
                range = 5f..(phase.maxMinutes / 5 * 5).toFloat(), step = 5f,
            )
            if (isHeatLimited) {
                Text(
                    "At this temperature and fan, BedJet heats for up to ${Format.duration(phase.maxMinutes)} before its safety cut-off." +
                        if (model.generation.supports(Mode.EXTENDED_HEAT)) " Use Gentle heat to run longer." else "",
                    fontSize = 13.sp, color = Theme.secondary,
                )
            }
            if (canDelete) {
                Text(
                    "Remove Phase",
                    fontSize = 17.sp, fontWeight = FontWeight.Medium, color = Theme.red,
                    modifier = Modifier
                        .align(Alignment.CenterHorizontally)
                        .clip(RoundedCornerShape(8.dp))
                        .clickable(role = Role.Button, onClick = onDelete)
                        .padding(8.dp),
                )
            }
        }
    }
}
