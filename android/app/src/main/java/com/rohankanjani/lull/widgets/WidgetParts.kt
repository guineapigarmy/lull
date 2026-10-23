package com.rohankanjani.lull.widgets

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceModifier
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.LocalContext
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.updateAll
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.size
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import com.rohankanjani.lull.Format
import com.rohankanjani.lull.Phase
import com.rohankanjani.lull.WidgetSnapshot
import com.rohankanjani.lull.activity
import com.rohankanjani.lull.bedjetkit.Mode
import com.rohankanjani.lull.title
import com.rohankanjani.lull.ui.Theme
import com.rohankanjani.lull.ui.icon
import com.rohankanjani.lull.ui.tint
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId

/** The edge every widget keeps its content inside. */
val WidgetPadding = 16.dp

fun widgetText(size: TextUnit, color: Color = Color.White, weight: FontWeight = FontWeight.Normal) =
    TextStyle(color = ColorProvider(color), fontSize = size, fontWeight = weight)

fun clock(millis: Long): String {
    val time = Instant.ofEpochMilli(millis).atZone(ZoneId.systemDefault()).toLocalTime()
    return Format.clock(time.hour * 60 + time.minute)
}

/** An icon from the app, drawn at a size and colour. */
@Composable
fun WidgetIcon(vector: ImageVector, color: Color, size: Dp) {
    val density = LocalContext.current.resources.displayMetrics.density
    Image(ImageProvider(vector.toBitmap(color, (size.value * density).toInt().coerceAtLeast(1))), contentDescription = null, modifier = GlanceModifier.size(size))
}

/** The night curve across the widget, reaching a little into its margins as in the app. */
@Composable
fun WidgetCurve(phases: List<Phase>, width: Dp, height: Dp, progress: Double? = null, lineWidth: Float = 3f) {
    val density = LocalContext.current.resources.displayMetrics.density
    val bitmap = nightCurveBitmap(phases, (width.value * density).toInt(), (height.value * density).toInt(), density, progress, lineWidth)
    Image(ImageProvider(bitmap), contentDescription = null, modifier = GlanceModifier.size(width, height))
}

/** The small all-caps label above a widget's title, like `Eyebrow` in the app but at a fixed size. */
@Composable
fun WidgetEyebrow(text: String, color: Color = Theme.secondary) {
    Text(text.uppercase(), style = widgetText(10.sp, color, FontWeight.Medium), maxLines = 1)
}

/** What the BedJet is doing, in the mode's colour: "❄ COOLING". */
@Composable
fun ModeLabel(mode: Mode) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        WidgetIcon(mode.icon, mode.tint, 12.dp)
        Spacer(GlanceModifier.width(4.dp))
        Text(mode.activity.uppercase(), style = widgetText(11.sp, mode.tint, FontWeight.Medium), maxLines = 1)
    }
}

/** Start, length and end of a night along one line, as under the curve in the app. */
@Composable
fun TimeRow(start: Long, end: Long) {
    val style = widgetText(11.sp, Theme.secondary, FontWeight.Medium)
    Row(GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(clock(start), style = style, maxLines = 1)
        Spacer(GlanceModifier.defaultWeight())
        Text(Format.duration(((end - start) / 60_000).toInt()), style = style, maxLines = 1)
        Spacer(GlanceModifier.defaultWeight())
        Text(clock(end), style = style, maxLines = 1)
    }
}

/** One phase of a schedule in a list: its mode, settings, length and when it starts. */
@Composable
fun PhaseLine(phase: Phase, detail: String, startsAt: Long, isCurrent: Boolean, isDone: Boolean) {
    val fade = if (isDone) 0.45f else 1f
    var row = GlanceModifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 5.dp)
    if (isCurrent) row = row.background(Theme.hairline).cornerRadius(12.dp)
    Row(row, verticalAlignment = Alignment.CenterVertically) {
        Box(
            GlanceModifier.size(26.dp).background(phase.mode.tint.copy(alpha = 0.16f * fade)).cornerRadius(13.dp),
            contentAlignment = Alignment.Center,
        ) { WidgetIcon(phase.mode.icon, phase.mode.tint.copy(alpha = fade), 13.dp) }
        Spacer(GlanceModifier.width(10.dp))
        Column(GlanceModifier.defaultWeight()) {
            Text(phase.mode.title, style = widgetText(13.sp, Color.White.copy(alpha = fade), FontWeight.Medium), maxLines = 1)
            Text(detail, style = widgetText(11.sp, Theme.secondary.copy(alpha = Theme.secondary.alpha * fade)), maxLines = 1)
        }
        Column(horizontalAlignment = Alignment.End) {
            Text(Format.duration(phase.minutes), style = widgetText(12.sp, Color.White.copy(alpha = fade), FontWeight.Medium), maxLines = 1)
            Text(clock(startsAt), style = widgetText(11.sp, Theme.secondary.copy(alpha = Theme.secondary.alpha * fade)), maxLines = 1)
        }
    }
}

@Composable
fun Gap(height: Dp) = Spacer(GlanceModifier.height(height))

/**
 * Redraws every widget, and books the next redraw: through a running night every few minutes and at each
 * phase change, so the widgets keep moving while Lull is closed, and at midnight, when last night moves on.
 */
object WidgetUpdates {
    suspend fun refresh(context: Context) {
        TonightWidget().updateAll(context)
        LastNightWidget().updateAll(context)
        scheduleNext(context, WidgetSnapshot.load(context) ?: WidgetSnapshot())
    }

    fun scheduleNext(context: Context, snapshot: WidgetSnapshot, now: Long = System.currentTimeMillis()) {
        val zone = ZoneId.systemDefault()
        val midnight = LocalDate.now(zone).plusDays(1).atTime(LocalTime.MIDNIGHT).atZone(zone).toInstant().toEpochMilli()
        val next = minOf(snapshot.redraws(now).firstOrNull { it > now } ?: midnight, midnight)
        val alarms = context.getSystemService(AlarmManager::class.java) ?: return
        val tick = PendingIntent.getBroadcast(
            context, 0, Intent(context, WidgetTickReceiver::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        // Inexact is close enough: what a widget shows is worked out from the clock when it's drawn.
        alarms.set(AlarmManager.RTC, next, tick)
    }
}

class WidgetTickReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val pending = goAsync()
        CoroutineScope(Dispatchers.Default).launch {
            try {
                WidgetUpdates.refresh(context)
            } finally {
                pending.finish()
            }
        }
    }
}
