package com.rohankanjani.lull.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rohankanjani.lull.AppModel
import com.rohankanjani.lull.bedjetkit.LinkState
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DeviceSheet(model: AppModel, onDismiss: () -> Unit) {
    val sheet = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val statusText = when (model.linkState) {
        LinkState.READY -> if (model.demoMode) "Demo BedJet" else "Connected"
        LinkState.CONNECTING -> "Connecting…"
        LinkState.SEARCHING -> "Searching…"
        LinkState.YIELDED -> "In use on another phone"
        LinkState.BLUETOOTH_OFF -> "Bluetooth is off"
        LinkState.UNAUTHORIZED -> "Bluetooth not allowed"
    }
    val help = when (model.linkState) {
        LinkState.READY -> if (model.demoMode) "Demo mode uses a pretend BedJet so you can explore the app."
        else "Everything stays between this phone and your BedJet. No account, no cloud."
        LinkState.CONNECTING, LinkState.SEARCHING -> "Stand near your BedJet and close the official BedJet app. The BedJet talks to one phone " +
            "at a time; phones with Lull hand it over to each other automatically."
        LinkState.YIELDED -> "The BedJet talks to one phone at a time, and another phone with Lull asked for it. Use any control here to take it back."
        LinkState.BLUETOOTH_OFF -> "Turn on Bluetooth in Quick Settings to connect."
        LinkState.UNAUTHORIZED -> "Allow Nearby devices for Lull in Settings to connect."
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheet, containerColor = Theme.background, dragHandle = null) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).navigationBarsPadding().padding(bottom = 24.dp)) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                Spacer(Modifier.width(72.dp))
                Text("BedJet", fontSize = 17.sp, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center, modifier = Modifier.weight(1f))
                TextButton(onDismiss, Modifier.width(72.dp)) { Text("Done", fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = Color.White) }
            }

            Section(footer = help) {
                Labeled("Status", statusText)
                model.deviceName?.let { Labeled("Name", it) }
                model.firmware?.let { Labeled("Firmware", it) }
            }

            val extra = model.status?.extra
            if (model.isConnected && extra != null) {
                Section(header = "BedJet") {
                    Toggle("Light ring", extra.ledEnabled) { on -> model.scope.launch { model.setLED(on) } }
                    Toggle("Mute beeps", extra.beepsMuted) { muted -> model.scope.launch { model.setMuted(muted) } }
                }
            }

            if (model.deviceSlots.isNotEmpty()) {
                Section(header = "Saved on the BedJet", footer = "Lull keeps tonight's schedule in one slot and leaves the others alone.") {
                    model.deviceSlots.forEachIndexed { index, program ->
                        val name = program?.name ?: "Empty"
                        Labeled("Slot ${index + 1}", if (index == model.slot) "Lull · $name" else name)
                    }
                }
            }

            Section(header = "App") {
                Row(Modifier.fillMaxWidth().heightIn(min = 48.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text("Temperature", fontSize = 17.sp, modifier = Modifier.weight(1f))
                    SingleChoiceSegmentedButtonRow(Modifier.width(140.dp)) {
                        listOf(true to "°F", false to "°C").forEachIndexed { index, (fahrenheit, label) ->
                            SegmentedButton(
                                selected = model.useFahrenheit == fahrenheit,
                                onClick = { model.useFahrenheit = fahrenheit },
                                shape = SegmentedButtonDefaults.itemShape(index, 2),
                                icon = {},
                                colors = SegmentedButtonDefaults.colors(
                                    activeContainerColor = Theme.neutral.copy(alpha = 0.5f),
                                    activeContentColor = Color.White,
                                    inactiveContainerColor = Theme.raised,
                                    inactiveContentColor = Color.White,
                                    activeBorderColor = Theme.hairline,
                                    inactiveBorderColor = Theme.hairline,
                                ),
                            ) { Text(label) }
                        }
                    }
                }
                Toggle("Demo mode", model.demoMode) { model.demoMode = it }
                if (!model.demoMode) {
                    Text(
                        "Forget This BedJet",
                        fontSize = 17.sp,
                        color = Theme.red,
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable(role = Role.Button) { model.forgetDevice() }
                            .padding(vertical = 13.dp),
                    )
                }
            }
        }
    }
}

/** A grouped list section, like a Settings screen. */
@Composable
private fun Section(header: String? = null, footer: String? = null, content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.padding(horizontal = 16.dp).padding(top = 20.dp)) {
        if (header != null) {
            Text(header.uppercase(), fontSize = 13.sp, color = Theme.secondary, modifier = Modifier.padding(start = 16.dp, bottom = 6.dp))
        }
        Column(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(12.dp))
                .background(Theme.raised)
                .padding(horizontal = 16.dp),
        ) {
            content()
        }
        if (footer != null) {
            Text(footer, fontSize = 13.sp, color = Theme.secondary, modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 6.dp))
        }
    }
}

@Composable
private fun Labeled(label: String, value: String) {
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(label, fontSize = 17.sp)
        Spacer(Modifier.weight(1f))
        Text(value, fontSize = 17.sp, color = Theme.secondary)
    }
    HorizontalDivider(color = Theme.hairline)
}

@Composable
private fun Toggle(label: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
        Text(label, fontSize = 17.sp)
        Switch(
            checked, onChange,
            colors = SwitchDefaults.colors(
                checkedTrackColor = Theme.green, checkedThumbColor = Color.White, checkedBorderColor = Theme.green,
                uncheckedTrackColor = Theme.neutral.copy(alpha = 0.35f), uncheckedThumbColor = Color.White, uncheckedBorderColor = Color.Transparent,
            ),
        )
    }
}
