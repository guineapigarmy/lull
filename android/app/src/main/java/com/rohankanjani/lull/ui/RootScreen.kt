package com.rohankanjani.lull.ui

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.NightsStay
import androidx.compose.material.icons.filled.SettingsRemote
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rohankanjani.lull.AppModel
import com.rohankanjani.lull.bedjetkit.LinkState
import kotlinx.coroutines.launch

@Composable
fun RootScreen(model: AppModel) {
    var selectedTab by rememberSaveable { mutableIntStateOf(0) }
    Scaffold(
        containerColor = Theme.background,
        // Each screen pads for the status bar itself, so it can scroll beneath it.
        contentWindowInsets = WindowInsets(0, 0, 0, 0),
        bottomBar = {
            Column {
                HorizontalDivider(color = Theme.hairline)
                NavigationBar(containerColor = Theme.background, tonalElevation = 0.dp) {
                    val colors = NavigationBarItemDefaults.colors(
                        selectedIconColor = Color.White,
                        selectedTextColor = Color.White,
                        unselectedIconColor = Theme.tertiary,
                        unselectedTextColor = Theme.tertiary,
                        indicatorColor = Theme.raised,
                    )
                    NavigationBarItem(
                        selected = selectedTab == 0, onClick = { selectedTab = 0 },
                        icon = { Icon(Icons.Filled.SettingsRemote, null) }, label = { Text("Remote") }, colors = colors,
                    )
                    NavigationBarItem(
                        selected = selectedTab == 1, onClick = { selectedTab = 1 },
                        icon = { Icon(Icons.Filled.NightsStay, null) }, label = { Text("Schedule") }, colors = colors,
                    )
                    NavigationBarItem(
                        selected = selectedTab == 2, onClick = { selectedTab = 2 },
                        icon = { Icon(Icons.Filled.History, null) }, label = { Text("History") }, colors = colors,
                    )
                }
            }
        },
    ) { padding ->
        Box(Modifier.padding(padding).fillMaxSize()) {
            when (selectedTab) {
                0 -> RemoteScreen(model)
                1 -> ScheduleScreen(model)
                else -> HistoryScreen(model)
            }
        }
    }

    model.errorMessage?.let { message ->
        AlertDialog(
            onDismissRequest = { model.errorMessage = null },
            confirmButton = { TextButton({ model.errorMessage = null }) { Text("OK") } },
            title = { Text("Something went wrong") },
            text = { Text(message) },
            containerColor = Theme.raised,
        )
    }

    if (model.needsSlotChoice) {
        AlertDialog(
            onDismissRequest = { model.needsSlotChoice = false },
            title = { Text("Your BedJet's three slots are full", textAlign = TextAlign.Center) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(
                        "Lull keeps tonight's schedule in one slot on the BedJet. Pick one to reuse. " +
                            "Everything on the BedJet is already copied into your schedules.",
                        color = Theme.secondary,
                    )
                    Spacer(Modifier.height(8.dp))
                    model.deviceSlots.forEachIndexed { index, program ->
                        TextButton(
                            onClick = {
                                model.needsSlotChoice = false
                                model.scope.launch { model.startTonight(replacingSlot = index) }
                            },
                            modifier = Modifier.fillMaxWidth(),
                        ) { Text("Replace “${program?.name ?: "Slot ${index + 1}"}”") }
                    }
                }
            },
            confirmButton = {},
            dismissButton = { TextButton({ model.needsSlotChoice = false }) { Text("Cancel") } },
            containerColor = Theme.raised,
        )
    }
}

/** Screen scaffold shared by the tabs: large title on the left, BedJet connection on the right. */
@Composable
fun Screen(model: AppModel, title: String, subtitle: String? = null, content: @Composable ColumnScope.() -> Unit) {
    var showsDevice by remember { mutableStateOf(false) }
    Column(
        Modifier
            .fillMaxSize()
            .background(Theme.background)
            .verticalScroll(rememberScrollState())
            .statusBarsPadding()
            .padding(horizontal = 20.dp)
            .padding(bottom = 32.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Row(Modifier.padding(top = 8.dp), verticalAlignment = Alignment.Top) {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                if (subtitle != null) Eyebrow(subtitle)
                Text(title, fontSize = 34.sp, fontWeight = FontWeight.Bold)
            }
            Spacer(Modifier.weight(1f))
            ConnectionPill(model) { showsDevice = true }
        }
        content()
    }
    if (showsDevice) DeviceSheet(model) { showsDevice = false }
}

@Composable
fun ConnectionPill(model: AppModel, onClick: () -> Unit) {
    // "Not found" invites a tap through to the things worth checking.
    val label = if (model.isSlowToFind) "Not found" else when (model.linkState) {
        LinkState.READY -> if (model.demoMode && !model.options.labelsDemoAsConnected) "Demo" else "Connected"
        LinkState.CONNECTING -> "Connecting"
        LinkState.SEARCHING -> "Searching"
        LinkState.YIELDED -> "Other phone"
        LinkState.BLUETOOTH_OFF -> "Bluetooth off"
        LinkState.UNAUTHORIZED -> "No access"
    }
    val pulse = rememberInfiniteTransition(label = "pulse")
    val dimmed by pulse.animateFloat(1f, 0.3f, infiniteRepeatable(tween(900), RepeatMode.Reverse), label = "dot")
    Pill(Modifier.height(36.dp).semantics(mergeDescendants = true) { contentDescription = "BedJet, $label" }, onClick = onClick) {
        Box(
            Modifier
                .size(8.dp)
                .alpha(if (model.isConnected) 1f else dimmed)
                .background(if (model.isConnected) Theme.green else Theme.neutral, CircleShape),
        )
        Text(label, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
    }
}
