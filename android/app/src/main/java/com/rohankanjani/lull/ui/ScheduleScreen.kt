package com.rohankanjani.lull.ui

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.clickable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rohankanjani.lull.ActiveRun
import com.rohankanjani.lull.AppModel
import com.rohankanjani.lull.Format
import com.rohankanjani.lull.Phase
import com.rohankanjani.lull.Schedule
import com.rohankanjani.lull.activity
import com.rohankanjani.lull.bedjetkit.Codec
import com.rohankanjani.lull.bedjetkit.LinkState
import com.rohankanjani.lull.bedjetkit.Mode
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.Instant
import java.util.Locale
import java.util.UUID

/** Plan the night and run it: tonight's schedule on top, the rest of the library below. */
@Composable
fun ScheduleScreen(model: AppModel) {
    var editing by remember { mutableStateOf<Schedule?>(null) }
    val today = LocalDate.now().format(
        DateTimeFormatter.ofPattern(android.text.format.DateFormat.getBestDateTimePattern(Locale.getDefault(), "EEEEMMMd")),
    )
    val run = model.run
    /** The schedule shown in the large card: the one running, otherwise the one picked for tonight. */
    val featuredID = run?.schedule?.id ?: model.tonight?.id

    Screen(model, "Schedule", subtitle = today) {
        val tonight = model.tonight
        val elsewhere = model.runningElsewhereStep
        when {
            run != null -> {
                var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
                LaunchedEffect(run) {
                    while (true) {
                        now = System.currentTimeMillis()
                        delay(30_000)
                    }
                }
                Running(model, run, now)
            }
            elsewhere != null -> RunningElsewhere(model, elsewhere)
            tonight != null -> Planned(model, tonight, onEdit = { editing = it })
            else -> Card {
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text("No schedules yet", fontSize = 22.sp, fontWeight = FontWeight.SemiBold)
                    Text("Create one to plan how your night feels.", fontSize = 15.sp, color = Theme.secondary)
                }
            }
        }

        val others = model.schedules.filter { it.id != featuredID }
        if (others.isNotEmpty()) {
            Eyebrow("More schedules", Modifier.padding(top = 8.dp))
            others.forEach { schedule -> ScheduleRow(model, schedule, onEdit = { editing = it }) }
        }
        PrimaryButton(
            onClick = { editing = Schedule("New schedule", listOf(Phase(Mode.COOL, fanPercent = 40, minutes = 240))) },
            prominent = false,
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Icon(Icons.Filled.Add, null, modifier = Modifier.size(20.dp))
                Text("New Schedule")
            }
        }
    }

    editing?.let { schedule -> ScheduleEditor(model, schedule, onDismiss = { editing = null }) }
}

private fun minuteOfDay(millis: Long): Int {
    val time = LocalTime.ofInstant(Instant.ofEpochMilli(millis), ZoneId.systemDefault())
    return time.hour * 60 + time.minute
}

@Composable
private fun Planned(model: AppModel, schedule: Schedule, onEdit: (Schedule) -> Unit) {
    WithMenu(model, schedule, onEdit) { openMenu ->
        Card(Modifier.combinedClickable(onClick = {}, onLongClick = openMenu, indication = null, interactionSource = null)) {
            Column(verticalArrangement = Arrangement.spacedBy(18.dp)) {
                Row(verticalAlignment = Alignment.Top) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Eyebrow("Tonight")
                        Text(schedule.name, fontSize = 26.sp, fontWeight = FontWeight.SemiBold)
                    }
                    Text(
                        "Edit", fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = Theme.secondary,
                        modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable(role = Role.Button) { onEdit(schedule) }.padding(4.dp),
                    )
                }
                NightTimeline(schedule, startMinute = minuteOfDay(System.currentTimeMillis()))
                PrimaryButton(
                    onClick = { model.scope.launch { model.startTonight() } },
                    enabled = model.canControl && !model.isBusy,
                    label = "Start Night",
                ) {
                    if (model.isBusy) {
                        CircularProgressIndicator(color = Color.Black, strokeWidth = 2.dp, modifier = Modifier.size(20.dp))
                    } else {
                        Text("Start Night")
                    }
                }
                Text(
                    when (model.linkState) {
                        LinkState.READY -> "Saved to your BedJet, which runs it all night. Your phone can sleep too."
                        LinkState.YIELDED -> "Your BedJet is in use on another phone. Starting here takes over."
                        else -> "Waiting for your BedJet. Keep your phone within a few feet of it."
                    },
                    fontSize = 13.sp, color = Theme.tertiary, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth(),
                )
            }
        }
    }
}

/** Shown instead of the planned card when the BedJet is already running a schedule this phone didn't start. */
@Composable
private fun RunningElsewhere(model: AppModel, step: Int) {
    Card {
        Column(verticalArrangement = Arrangement.spacedBy(18.dp)) {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Eyebrow("Running now")
                Text("Phase $step", fontSize = 26.sp, fontWeight = FontWeight.SemiBold)
                model.status?.let { status ->
                    ModeLabel(status.mode, "${status.mode.activity} · ${Format.duration(maxOf((status.remainingSeconds + 59) / 60, 1))} left in this phase")
                }
                Text("This schedule was started from another phone or the BedJet's own remote.", fontSize = 13.sp, color = Theme.tertiary)
            }
            PrimaryButton("End Night", onClick = { model.scope.launch { model.endNight() } }, prominent = false, enabled = !model.isBusy)
        }
    }
}

@Composable
private fun Running(model: AppModel, run: ActiveRun, now: Long) {
    val current = run.phase(now)
    Card {
        Column(verticalArrangement = Arrangement.spacedBy(18.dp)) {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Eyebrow(current?.let { "Phase ${it.index + 1} of ${run.schedule.phases.size}" } ?: "Finishing")
                Text(run.schedule.name, fontSize = 26.sp, fontWeight = FontWeight.SemiBold)
                current?.let { ModeLabel(it.phase.mode, "${it.phase.mode.activity} · ${Format.duration(it.minutesLeft)} left") }
            }
            NightTimeline(run.schedule, startMinute = minuteOfDay(run.startedAt), progress = run.progress(now))
            PrimaryButton("End Night", onClick = { model.scope.launch { model.endNight() } }, prominent = false, enabled = !model.isBusy)
        }
    }
}

@Composable
private fun ModeLabel(mode: Mode, text: String) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Icon(mode.icon, null, tint = mode.tint, modifier = Modifier.size(16.dp))
        Text(text, fontSize = 15.sp, fontWeight = FontWeight.Medium, color = mode.tint)
    }
}

@Composable
private fun ScheduleRow(model: AppModel, schedule: Schedule, onEdit: (Schedule) -> Unit) {
    WithMenu(model, schedule, onEdit) { openMenu ->
        Box {
            Card(
                Modifier
                    .clip(RoundedCornerShape(28.dp))
                    .combinedClickable(onClick = { onEdit(schedule) }, onLongClick = openMenu)
                    .semantics(mergeDescendants = true) { contentDescription = schedule.name },
                padding = 18.dp,
            ) {
                Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    Text(
                        schedule.name, fontSize = 19.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis,
                        // Leaves room for the Use Tonight button laid over this corner.
                        modifier = Modifier.padding(end = 116.dp),
                    )
                    NightCurve(schedule.phases, Modifier.fillMaxWidth().height(64.dp), lineWidth = 2.5.dp)
                    Text(
                        "${Format.duration(schedule.totalMinutes)} · ${schedule.phases.size} ${if (schedule.phases.size == 1) "phase" else "phases"}",
                        fontSize = 13.sp, fontWeight = FontWeight.Medium, color = Theme.secondary,
                    )
                }
            }
            // Swapping schedules waits until the one that is running has ended.
            if (model.run == null) {
                Pill(
                    Modifier
                        .align(Alignment.TopEnd)
                        .padding(14.dp)
                        .clearAndSetSemantics {
                            contentDescription = "Use ${schedule.name} tonight"
                            role = Role.Button
                            onClick { model.tonightID = schedule.id; true }
                        },
                    onClick = { model.tonightID = schedule.id },
                ) {
                    Text("Use Tonight", fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                }
            }
        }
    }
}

/** Long-press menu for a schedule: edit, duplicate, delete. */
@Composable
private fun WithMenu(model: AppModel, schedule: Schedule, onEdit: (Schedule) -> Unit, content: @Composable (openMenu: () -> Unit) -> Unit) {
    var open by remember { mutableStateOf(false) }
    val haptics = LocalHapticFeedback.current
    Box {
        content {
            haptics.performHapticFeedback(HapticFeedbackType.LongPress)
            open = true
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }, containerColor = Theme.raised) {
            DropdownMenuItem(
                text = { Text("Edit") }, leadingIcon = { Icon(Icons.Filled.Tune, null) },
                onClick = { open = false; onEdit(schedule) },
            )
            DropdownMenuItem(
                text = { Text("Duplicate") }, leadingIcon = { Icon(Icons.Filled.ContentCopy, null) },
                onClick = {
                    open = false
                    model.save(schedule.copy(id = UUID.randomUUID().toString(), name = Codec.sanitize("${schedule.name} copy")))
                },
            )
            DropdownMenuItem(
                text = { Text("Delete", color = Theme.red) }, leadingIcon = { Icon(Icons.Filled.Delete, null, tint = Theme.red) },
                onClick = { open = false; model.delete(schedule) },
            )
        }
    }
}
