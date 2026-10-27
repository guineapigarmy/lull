package com.rohankanjani.lull.wear.ui

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.focusable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Remove
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.rotary.onRotaryScrollEvent
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.progressBarRangeInfo
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.setProgress
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.wear.compose.material3.CircularProgressIndicator
import androidx.wear.compose.material3.Icon
import androidx.wear.compose.material3.Text
import com.rohankanjani.lull.WatchCommand
import com.rohankanjani.lull.activity
import com.rohankanjani.lull.bedjetkit.Mode
import com.rohankanjani.lull.ui.Theme
import com.rohankanjani.lull.ui.icon
import com.rohankanjani.lull.ui.tint
import com.rohankanjani.lull.wear.WatchModel
import kotlinx.coroutines.launch

/** The capsule button for a page's main action, sized for the wrist: the phone's `PrimaryButton`, smaller. */
@Composable
fun WatchButton(text: String, onClick: () -> Unit, modifier: Modifier = Modifier, prominent: Boolean = true, enabled: Boolean = true, busy: Boolean = false) {
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val scale by animateFloatAsState(if (pressed) 0.97f else 1f, label = "press")
    val color = if (prominent) Color.Black else Color.White
    Row(
        modifier
            .fillMaxWidth()
            .heightIn(min = 44.dp)
            .scale(scale)
            .alpha(if (enabled) 1f else 0.4f)
            .clip(CircleShape)
            .background(if (prominent) Color.White else Theme.raised)
            .border(BorderStroke(1.dp, if (prominent) Color.Transparent else Theme.hairline), CircleShape)
            .clickable(interaction, indication = null, enabled = enabled, role = Role.Button, onClick = onClick)
            .semantics(mergeDescendants = true) { },
        horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (busy) CircularProgressIndicator(Modifier.size(16.dp))
        Text(text, color = color, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
    }
}

/** A page's main action, which waits for the phone once tapped: "Start Night", then "Starting…". */
@Composable
fun ErrandButton(model: WatchModel, title: String, busyTitle: String, command: WatchCommand, prominent: Boolean = true) {
    val busy = model.isSending(command)
    WatchButton(
        text = if (busy) busyTitle else title,
        // On the model's scope rather than the page's: swiping to another page mid-send would cancel it, as an
        // unstructured Task on the Apple Watch isn't.
        onClick = { model.scope.launch { model.send(command) } },
        prominent = prominent,
        enabled = model.pending == null && model.unavailable == null,
        busy = busy,
    )
}

/** Small all-caps label used above groups of content, as on the phone. */
@Composable
fun Eyebrow(text: String, color: Color = Theme.secondary) {
    Text(
        text.uppercase(),
        // Read as written rather than in capitals, which TalkBack can spell out letter by letter.
        modifier = Modifier.semantics { contentDescription = text },
        fontSize = 11.sp,
        fontWeight = FontWeight.SemiBold,
        letterSpacing = 1.6.sp,
        color = color,
        maxLines = 1,
    )
}

/** What the BedJet is doing, in the mode's colour: "❄ COOLING". */
@Composable
fun ModeLabel(mode: Mode) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(mode.icon, contentDescription = null, tint = mode.tint, modifier = Modifier.size(12.dp))
        Spacer(Modifier.width(4.dp))
        Text(mode.activity.uppercase(), color = mode.tint, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 1.2.sp, maxLines = 1)
    }
}

/** Why the controls are off, under them. */
@Composable
fun Footnote(text: String) {
    Text(text, color = Theme.tertiary, fontSize = 12.sp, modifier = Modifier.fillMaxWidth(), textAlign = TextAlign.Center)
}

/** A title and a line under it, for a page with nothing to show yet. */
@Composable
fun EmptyMessage(icon: ImageVector, title: String, message: String) {
    Column(
        Modifier.fillMaxWidth().semantics(mergeDescendants = true) { },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Icon(icon, contentDescription = null, tint = Theme.secondary, modifier = Modifier.size(20.dp))
        Text(title, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center)
        Text(message, fontSize = 13.sp, color = Theme.secondary, textAlign = TextAlign.Center)
    }
}

/**
 * A setting the rotating side button or bezel turns once it's tapped, with − and + for a finger. It reads as one
 * adjustable control to TalkBack, as the phone's sliders do. The twin of the Apple Watch's Digital Crown rows.
 */
@Composable
fun CrownRow(
    title: String,
    valueText: String,
    value: Int,
    onValueChange: (Int) -> Unit,
    range: IntRange,
    step: Int = 1,
    tint: Color = Color.White,
    spokenValue: String? = null,
) {
    val focus = remember { FocusRequester() }
    var focused by remember { mutableStateOf(false) }
    // Rotary input arrives in pixels; a step per notch or so.
    var turned by remember { mutableStateOf(0f) }
    fun change(by: Int) = onValueChange((value + by).coerceIn(range.first, range.last))
    val shape = RoundedCornerShape(14.dp)
    Column(
        Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(Theme.raised)
            .border(if (focused) 2.dp else 1.dp, if (focused) tint else Theme.hairline, shape)
            .onFocusChanged { focused = it.isFocused }
            .focusRequester(focus)
            .onRotaryScrollEvent { event ->
                turned += event.verticalScrollPixels
                // All at once: the value only updates on the next redraw, so steps taken one by one would each
                // start from the same place.
                val notches = (turned / 48f).toInt()
                if (notches != 0) {
                    change(notches * step)
                    turned -= notches * 48f
                }
                true
            }
            .focusable()
            .clickable { focus.requestFocus() }
            .clearAndSetSemantics {
                contentDescription = title
                stateDescription = spokenValue ?: valueText
                progressBarRangeInfo = ProgressBarRangeInfo(value.toFloat(), range.first.toFloat()..range.last.toFloat(), (range.last - range.first) / step - 1)
                setProgress { target ->
                    onValueChange(((target.toInt() - range.first) / step * step + range.first).coerceIn(range.first, range.last))
                    true
                }
            }
            .padding(horizontal = 8.dp, vertical = 6.dp),
    ) {
        Text(title, color = Theme.secondary, fontSize = 12.sp, fontWeight = FontWeight.Medium)
        Row(verticalAlignment = Alignment.CenterVertically) {
            Nudge(Icons.Filled.Remove, tint, enabled = value > range.first) { change(-step) }
            Text(valueText, Modifier.weight(1f), fontSize = 18.sp, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center, maxLines = 1, style = Theme.tabular)
            Nudge(Icons.Filled.Add, tint, enabled = value < range.last) { change(step) }
        }
    }
}

@Composable
private fun Nudge(icon: ImageVector, tint: Color, enabled: Boolean, onClick: () -> Unit) {
    Box(
        Modifier.size(28.dp).alpha(if (enabled) 1f else 0.3f).clip(CircleShape).clickable(enabled = enabled, role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) { Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(16.dp)) }
}

/** A mode to pick on the Remote, tinted when it's the one chosen. */
@Composable
fun ModeButton(mode: Mode, isSelected: Boolean, modifier: Modifier = Modifier, title: String, onClick: () -> Unit) {
    val color = if (isSelected) Color.Black else mode.tint
    Column(
        modifier
            .heightIn(min = 48.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(if (isSelected) mode.tint else Theme.raised)
            .clickable(role = Role.Button, onClick = onClick)
            .semantics(mergeDescendants = true) { selected = isSelected; role = Role.Button }
            .padding(4.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(3.dp, Alignment.CenterVertically),
    ) {
        Icon(mode.icon, contentDescription = null, tint = color, modifier = Modifier.size(15.dp))
        Text(title, color = color, fontSize = 10.sp, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center, maxLines = 2)
    }
}
