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
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Bed
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Power
import androidx.compose.material.icons.filled.Smartphone
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
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
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.foundation.selection.selectable
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
    val bedJet = model.bedJet
    val statusText = when (bedJet.linkState) {
        LinkState.READY -> if (model.demoMode) "Demo BedJet" else "Connected"
        LinkState.CONNECTING -> "Connecting…"
        LinkState.SEARCHING -> "Searching…"
        LinkState.YIELDED -> "In use on another phone"
        LinkState.BLUETOOTH_OFF -> "Bluetooth is off"
        LinkState.UNAUTHORIZED -> "Bluetooth not allowed"
    }
    val help = when (bedJet.linkState) {
        LinkState.READY -> if (model.demoMode) "Demo mode uses a pretend BedJet so you can explore the app."
        else "Everything stays between this phone and your BedJet. No account, no cloud."
        LinkState.CONNECTING, LinkState.SEARCHING ->
            if (bedJet.unit == null && model.hasSeveralBedJets && !model.demoMode) {
                "Turn on the BedJet you're adding and stand near it. Lull connects to the first one it finds that it doesn't already know."
            } else "Stand near your BedJet and force-quit the official BedJet app. The BedJet talks to one phone " +
            "at a time; phones with Lull hand it over to each other automatically."
        LinkState.YIELDED -> "The BedJet talks to one phone at a time, and another phone with Lull asked for it. Use any control here to take it back."
        LinkState.BLUETOOTH_OFF -> "Turn on Bluetooth in Quick Settings to connect."
        LinkState.UNAUTHORIZED -> "Allow Nearby devices for Lull in Settings to connect."
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheet, containerColor = Theme.background, dragHandle = null) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).navigationBarsPadding().padding(bottom = 24.dp)) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                Spacer(Modifier.width(72.dp))
                Text(
                    if (model.hasSeveralBedJets) "BedJets" else "BedJet",
                    fontSize = 17.sp, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center,
                    modifier = Modifier.weight(1f).semantics { heading() },
                )
                TextButton(onDismiss, Modifier.width(72.dp)) { Text("Done", fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = Color.White) }
            }

            if (model.hasSeveralBedJets) {
                // Every BedJet, to switch between. The sections below are about the ticked one.
                Section(header = "Your BedJets", footer = "Every screen shows the ticked BedJet. Switch from the top of any screen too.") {
                    model.bedJets.forEach { other ->
                        val isShown = other === bedJet
                        Row(
                            Modifier
                                .fillMaxWidth()
                                .heightIn(min = 56.dp)
                                .selectable(selected = isShown, role = Role.RadioButton) { model.select(other.id) }
                                .padding(vertical = 8.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                Text(model.title(other), fontSize = 17.sp)
                                Text(other.connectionLabel, fontSize = 13.sp, color = Theme.secondary)
                            }
                            if (isShown) Icon(Icons.Filled.Check, null, tint = Theme.green, modifier = Modifier.size(22.dp))
                        }
                        HorizontalDivider(color = Theme.hairline)
                    }
                    AddButton(model)
                }
            }

            Section(header = if (model.hasSeveralBedJets) model.title(bedJet) else null, footer = help) {
                Labeled("Status", statusText)
                bedJet.name?.let { Labeled("Name", it) }
                bedJet.firmware?.let { Labeled("Firmware", it) }
            }

            if (bedJet.isSlowToFind) {
                Section(header = "Can't find your BedJet?", footer = "Lull keeps looking while it's open.") {
                    Tip(Icons.Filled.Bed, "Lull works with BedJet 3 and BedJet V2. The original BedJet isn't supported.")
                    Tip(Icons.Filled.Close, "Force-quit the BedJet app: open your recent apps, then swipe the BedJet app away.")
                    Tip(Icons.Filled.Smartphone, "Close the BedJet app on any other phone or tablet nearby.")
                    Tip(Icons.Filled.Power, "Unplug the BedJet for 10 seconds, then plug it back in.")
                }
            }

            val extra = bedJet.status?.extra
            if (bedJet.isConnected && extra != null) {
                Section(header = "BedJet") {
                    Toggle("Light ring", extra.ledEnabled) { on -> model.scope.launch { bedJet.setLED(on) } }
                    Toggle("Mute beeps", extra.beepsMuted) { muted -> model.scope.launch { bedJet.setMuted(muted) } }
                }
            }

            if (bedJet.deviceSlots.isNotEmpty()) {
                Section(header = "Saved on the BedJet", footer = "Lull keeps tonight's schedule in one slot and leaves the others alone.") {
                    bedJet.deviceSlots.forEachIndexed { index, program ->
                        val name = program?.name ?: "Empty"
                        val isLull = index == bedJet.slot
                        Labeled(
                            "Slot ${index + 1}", if (isLull) "Lull · $name" else name,
                            spoken = if (isLull) "Used by Lull, ${program?.name ?: "empty"}" else name,
                        )
                    }
                }
            }

            if (!model.hasSeveralBedJets) {
                Section(footer = "Have a BedJet on each side of the bed? Add both, then switch between them from the top of any screen.") {
                    AddButton(model)
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
                                modifier = Modifier.semantics { contentDescription = if (fahrenheit) "Fahrenheit" else "Celsius" },
                            ) { Text(label) }
                        }
                    }
                }
                Toggle("Demo mode", model.demoMode) { model.demoMode = it }
                if (!model.demoMode || model.hasSeveralBedJets) {
                    Text(
                        "Forget This BedJet",
                        fontSize = 17.sp,
                        color = Theme.red,
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable(role = Role.Button) { model.forget(bedJet) }
                            .padding(vertical = 13.dp),
                    )
                }
            }
        }
    }
}

@Composable
private fun AddButton(model: AppModel) {
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 48.dp)
            .clickable(role = Role.Button) { model.addBedJet() }
            .padding(vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(Icons.Filled.Add, null, tint = Theme.green, modifier = Modifier.size(22.dp))
        Text("Add Another BedJet", fontSize = 17.sp, color = Theme.green)
    }
}

/** A grouped list section, like a Settings screen. */
@Composable
private fun Section(header: String? = null, footer: String? = null, content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.padding(horizontal = 16.dp).padding(top = 20.dp)) {
        if (header != null) {
            Text(
                header.uppercase(), fontSize = 13.sp, color = Theme.secondary,
                modifier = Modifier.padding(start = 16.dp, bottom = 6.dp).semantics {
                    heading()
                    contentDescription = header
                },
            )
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
private fun Tip(icon: ImageVector, text: String) {
    Row(Modifier.fillMaxWidth().padding(vertical = 11.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        Icon(icon, null, tint = Theme.green, modifier = Modifier.size(22.dp))
        Text(text, fontSize = 17.sp)
    }
    HorizontalDivider(color = Theme.hairline)
}

@Composable
private fun Labeled(label: String, value: String, spoken: String = value) {
    Row(
        Modifier.fillMaxWidth().heightIn(min = 48.dp).clearAndSetSemantics { contentDescription = "$label, $spoken" },
        verticalAlignment = Alignment.CenterVertically,
    ) {
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
