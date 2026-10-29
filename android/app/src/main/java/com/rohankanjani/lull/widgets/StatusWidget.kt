package com.rohankanjani.lull.widgets

import android.content.Context
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.LocalContext
import androidx.glance.LocalSize
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.background
import androidx.glance.currentState
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.padding
import androidx.glance.semantics.contentDescription
import androidx.glance.semantics.semantics
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import com.rohankanjani.lull.ActiveRun
import com.rohankanjani.lull.AppCommands
import com.rohankanjani.lull.Format
import com.rohankanjani.lull.LiveStatus
import com.rohankanjani.lull.LullTab
import com.rohankanjani.lull.WidgetBedJet
import com.rohankanjani.lull.WidgetSnapshot
import com.rohankanjani.lull.activity
import com.rohankanjani.lull.bedjetkit.Mode
import com.rohankanjani.lull.length
import com.rohankanjani.lull.setting
import com.rohankanjani.lull.spokenSummary
import com.rohankanjani.lull.ui.Theme
import com.rohankanjani.lull.ui.tint

/** What a BedJet is doing now, and the time left. Each one can be set to a BedJet, or follows the one on screen. */
class StatusWidget : GlanceAppWidget() {
    override val sizeMode = SizeMode.Exact

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        WidgetUpdates.scheduleNext(context, WidgetSnapshot.load(context) ?: WidgetSnapshot())
        provideContent { StatusContent(currentSnapshot(), currentState(PickedBedJet), System.currentTimeMillis()) }
    }

    companion object {
        val SMALL = DpSize(120.dp, 120.dp)
        val MEDIUM = DpSize(250.dp, 120.dp)
    }
}

class StatusWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget = StatusWidget()
}

@Composable
fun StatusContent(snapshot: WidgetSnapshot, bedJetId: String?, now: Long) {
    val context = LocalContext.current
    val bedJet = snapshot.bedJet(bedJetId)
    val tab = bedJet?.live(now)?.tab ?: LullTab.SCHEDULE
    Box(
        GlanceModifier
            .fillMaxSize()
            .widgetBackground()
            .clickable(actionStartActivity(AppCommands.openIntent(context, tab, showing = bedJet?.id)))
            .padding(WidgetPadding),
    ) {
        if (bedJet == null) {
            StatusUnknown()
        } else {
            val size = LocalSize.current
            StatusSummary(bedJet, snapshot, now, width = size.width - WidgetPadding * 2, isMedium = size.width >= StatusWidget.MEDIUM.width)
        }
    }
}

/** What one BedJet is doing: the body of the Status widget, and each side of Both Sides, `width` across. */
@Composable
fun StatusSummary(bedJet: WidgetBedJet, snapshot: WidgetSnapshot, now: Long, width: Dp, isMedium: Boolean = false) {
    // The BedJet's name heads it once there's more than one to tell apart.
    val name = bedJet.name.takeIf { snapshot.hasSeveralBedJets }
    when (val live = bedJet.live(now)) {
        is LiveStatus.Night -> Night(live.run, bedJet, snapshot, name, now, width, isMedium)
        is LiveStatus.Air -> Air(live, snapshot, name)
        null -> Idle(bedJet, name, width, isMedium)
    }
}

@Composable
private fun Night(run: ActiveRun, bedJet: WidgetBedJet, snapshot: WidgetSnapshot, name: String?, now: Long, width: Dp, isMedium: Boolean) {
    val current = run.phase(now)
    val mode = current?.phase?.mode ?: Mode.STANDBY
    val spoken = listOfNotNull(
        name, run.schedule.name,
        current?.let { "phase ${it.index + 1} of ${run.schedule.phases.size}" },
        current?.phase?.mode?.activity, LiveStatus.Night(run).ending,
    ).joinToString(", ")
    Column(GlanceModifier.fillMaxSize().semantics { contentDescription = spoken }) {
        Heading(name, mode)
        Gap(2.dp)
        Text(run.schedule.name, style = widgetText(15.sp, weight = FontWeight.Medium), maxLines = 1)
        if (isMedium && current != null) {
            Text(current.phase.setting(on = bedJet.generation, fahrenheit = snapshot.useFahrenheit), style = widgetText(12.sp, Theme.secondary, FontWeight.Medium), maxLines = 1)
        }
        Spacer(GlanceModifier.defaultWeight())
        Countdown(run.endsAt, 26.sp, mode.tint)
        // A Glance image can't move by itself, so the lit part moves on each redraw, every few minutes.
        WidgetCurve(run.schedule.phases, width + 16.dp, if (isMedium) 26.dp else 34.dp, run.progress(now), lineWidth = 2f)
        if (isMedium) TimeRow(run.startedAt, run.endsAt)
    }
}

@Composable
private fun Air(air: LiveStatus.Air, snapshot: WidgetSnapshot, name: String?) {
    val setting = Format.setting(air.mode, air.temperature, air.fanPercent, snapshot.useFahrenheit)
    val spoken = listOfNotNull(name, air.mode.activity, setting, air.ending).joinToString(", ")
    Column(GlanceModifier.fillMaxSize().semantics { contentDescription = spoken }) {
        Heading(name, air.mode)
        Gap(2.dp)
        Text(setting, style = widgetText(15.sp, weight = FontWeight.Medium), maxLines = 1)
        Spacer(GlanceModifier.defaultWeight())
        Countdown(air.endsAt, 26.sp, air.mode.tint)
        Text(air.ending, style = widgetText(11.sp, Theme.secondary, FontWeight.Medium), maxLines = 1)
    }
}

/**
 * Nothing running from this phone. It doesn't say "Off": with Lull closed it can't see the BedJet, which another
 * phone or the BedJet's own remote may have turned on.
 */
@Composable
private fun Idle(bedJet: WidgetBedJet, name: String?, width: Dp, isMedium: Boolean) {
    val schedule = bedJet.tonight ?: return StatusUnknown("No schedule yet", "Open Lull to plan how your night feels.")
    val context = LocalContext.current
    val spoken = listOfNotNull(name, "Tonight", schedule.name, schedule.spokenSummary).joinToString(", ")
    Column(GlanceModifier.fillMaxSize()) {
        Column(GlanceModifier.semantics { contentDescription = spoken }) {
            WidgetEyebrow(name?.let { "$it · Tonight" } ?: "Tonight")
            Gap(4.dp)
            Text(schedule.name, style = widgetText(17.sp, weight = FontWeight.Medium), maxLines = 2)
        }
        Spacer(GlanceModifier.defaultWeight())
        if (isMedium) {
            WidgetCurve(schedule.phases, width + 16.dp, 30.dp, lineWidth = 2f)
            Gap(6.dp)
        }
        Row(GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(schedule.length, style = widgetText(12.sp, Theme.secondary, FontWeight.Medium), maxLines = 1)
            Spacer(GlanceModifier.defaultWeight())
            Box(
                GlanceModifier
                    .background(Color.White)
                    .cornerRadius(16.dp)
                    .clickable(actionStartActivity(AppCommands.startNightIntent(context, bedJet.id)))
                    .semantics { contentDescription = "Start Night" }
                    .padding(horizontal = 14.dp, vertical = 6.dp),
            ) {
                Text("Start", style = widgetText(13.sp, Color.Black, FontWeight.Medium))
            }
        }
    }
}

@Composable
private fun Heading(name: String?, mode: Mode) {
    Column {
        if (name != null) {
            WidgetEyebrow(name)
            Gap(3.dp)
        }
        ModeLabel(mode)
    }
}

/** No BedJet to show yet: Lull hasn't been opened since one was chosen, or this one was forgotten. */
@Composable
fun StatusUnknown(title: String = "No BedJet yet", message: String = "Open Lull to choose your BedJet.") {
    Column(GlanceModifier.fillMaxSize().semantics { contentDescription = "$title. $message" }) {
        WidgetIcon(Icons.Filled.Bedtime, Theme.secondary, 22.dp)
        Spacer(GlanceModifier.defaultWeight())
        Text(title, style = widgetText(17.sp, weight = FontWeight.Medium))
        Gap(6.dp)
        Text(message, style = widgetText(12.sp, Theme.secondary))
    }
}
