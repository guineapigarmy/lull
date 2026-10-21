package com.rohankanjani.lull

import android.content.Intent
import android.graphics.Bitmap
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isEnabled
import androidx.compose.ui.test.junit4.ComposeTestRule
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performSemanticsAction
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/** Walks the main flows against the simulated BedJet and keeps a screenshot of each screen. Mirrors LullUITests.swift. */
@RunWith(AndroidJUnit4::class)
class LullUiTest {
    @get:Rule
    val compose = createEmptyComposeRule()
    private lateinit var scenario: ActivityScenario<MainActivity>

    @Before
    fun launch() {
        scenario = launchLull(ephemeral = true)
    }

    @After
    fun close() {
        scenario.close()
    }

    @Test
    fun opensOnRemote() {
        compose.waitFor(hasText("Remote"), timeoutMillis = 10_000)
        compose.onNode(hasText("Remote") and SemanticsMatcher.keyIsDefined(SemanticsProperties.Selected)).assertIsSelected()
    }

    @Test
    fun startAndEndNight() {
        compose.onNodeWithText("Schedule").performClick()
        // The button enables once the simulated BedJet connects.
        compose.waitFor(hasContentDescription("Start Night") and isEnabled(), timeoutMillis = 10_000)
        compose.onNodeWithContentDescription("Start Night").performClick()

        compose.waitFor(hasText("End Night"), timeoutMillis = 10_000)
        compose.waitFor(hasText("PHASE 1 OF", substring = true))
        Thread.sleep(2000)
        compose.capture("schedule-running")

        compose.onNodeWithText("End Night").performClick()
        compose.waitFor(hasContentDescription("Start Night"), timeoutMillis = 10_000)
    }

    @Test
    fun editScheduleAndUseItTonight() {
        compose.onNodeWithText("Schedule").performClick()
        compose.onNodeWithContentDescription("Warm Welcome").performScrollTo().performClick()
        compose.waitFor(hasText("Add Phase"))
        compose.capture("editor")

        compose.onNode(hasContentDescription("Turbo,", substring = true) and hasContentDescription("10 min", substring = true)).performClick()
        compose.waitFor(hasText("Remove Phase"))
        compose.onNodeWithText("Gentle heat").performClick()
        Thread.sleep(1000)
        compose.capture("phase-editor")
        compose.onNodeWithText("Done").performClick()

        compose.onNodeWithText("Add Phase").performScrollTo().performClick()
        compose.waitFor(hasText("Remove Phase"))
        compose.onNodeWithText("Done").performClick()
        compose.waitUntilGone(hasText("Remove Phase"))
        compose.onNodeWithText("Use Tonight").performClick()

        // Warm Welcome is now the featured schedule, so Cool Drift moves down and offers the swap back.
        compose.waitFor(hasContentDescription("Use Cool Drift tonight"))
        compose.onNodeWithContentDescription("Use Warm Welcome tonight").assertDoesNotExist()
        compose.capture("schedule-planned")

        compose.onNodeWithContentDescription("Use Cool Drift tonight").performScrollTo().performClick()
        compose.waitFor(hasContentDescription("Use Warm Welcome tonight"))
    }

    @Test
    fun historyKeepsTheNight() {
        compose.onNodeWithText("History").performClick()
        compose.waitFor(hasText("No nights yet"), timeoutMillis = 10_000)

        compose.onNodeWithText("Remote").performClick()
        compose.waitFor(hasText("Heat"), timeoutMillis = 10_000)
        // History starts from the BedJet's first settled report; a change before that is where it starts.
        Thread.sleep(5000)
        compose.onNodeWithText("Heat").performClick()
        compose.waitFor(hasContentDescription("Turns off in"))
        // A setting is recorded once the BedJet has held it for a few seconds.
        Thread.sleep(4000)
        compose.onNodeWithText("Off").performClick()
        Thread.sleep(4000)

        // A schedule's phases are its own; only its start and end are recorded.
        compose.onNodeWithText("Schedule").performClick()
        compose.waitFor(hasContentDescription("Start Night") and isEnabled(), timeoutMillis = 10_000)
        compose.onNodeWithContentDescription("Start Night").performClick()
        compose.waitFor(hasText("End Night"), timeoutMillis = 10_000)
        Thread.sleep(4000)
        compose.onNodeWithText("End Night").performClick()
        compose.waitFor(hasContentDescription("Start Night"), timeoutMillis = 10_000)
        Thread.sleep(4000)

        compose.onNodeWithText("History").performClick()
        // The night is one row named after the schedule that ran, and opens up to the whole night.
        compose.waitFor(hasTestTag("Night"))
        val night = compose.onNodeWithTag("Night")
        assertTrue(night.label().endsWith("Cool Drift"))
        compose.onNodeWithText("Turned off").assertDoesNotExist()
        compose.capture("history-collapsed")
        night.performClick()
        compose.waitFor(hasText("Heat ·", substring = true))
        compose.onNodeWithText("Turned off").assertExists()
        compose.onNodeWithText("Started Cool Drift").assertExists()
        compose.onNodeWithText("Ended Cool Drift").assertExists()
        // Nothing else: the schedule's first phase and the BedJet turning off with it are not separate entries.
        assertEquals(0, compose.onAllNodes(hasText("Cool ·", substring = true)).fetchSemanticsNodes().size)
        Thread.sleep(1000)
        compose.capture("history-expanded")

        night.performClick()
        compose.waitUntilGone(hasText("Turned off"))
    }

    @Test
    fun historyListsNightsAsRows() {
        scenario.close()
        scenario = launchLull(ephemeral = true, demoHistory = true)
        compose.onNodeWithText("History").performClick()

        compose.waitFor(hasTestTag("Night"))
        val nights = compose.onAllNodesWithTag("Night")
        assertEquals(3, nights.fetchSemanticsNodes().size)
        // Newest first; a night without a schedule is summed up by its times instead.
        assertTrue(nights[0].label().endsWith("Cool Drift"))
        assertTrue(nights[1].label().contains(" – "))
        compose.capture("history-rows")

        nights[1].performClick()
        compose.waitFor(hasText("Turned off"))
        compose.onNodeWithText("Timer ran out", substring = true).assertExists()
        Thread.sleep(1000)
        compose.capture("history-row-expanded")
    }

    @Test
    fun remoteAndDevice() {
        compose.waitFor(hasText("Heat"), timeoutMillis = 10_000)
        Thread.sleep(2000)
        compose.onNodeWithText("Heat").performClick()
        // Turning a mode on asks for the longest run the simulated BedJet allows: 4 hours of heat.
        compose.waitFor(hasContentDescription("Turns off in"))
        compose.waitForSlider("Turns off in", "4 hr")

        // A shorter time picked by hand sticks, and survives a fan change.
        compose.slider("Turns off in").setTo(0f)
        Thread.sleep(3000)
        assertEquals("5 min", compose.slider("Turns off in").value())
        compose.slider("Fan").setTo(0.8f)
        Thread.sleep(3000)
        assertEquals("5 min", compose.slider("Turns off in").value())

        // Switching mode starts over at that mode's longest run.
        compose.onNodeWithText("Cool").performClick()
        compose.waitForSlider("Turns off in", "12 hr")
        compose.onNodeWithText("Heat").performClick()
        compose.waitForSlider("Turns off in", "4 hr")
        compose.capture("remote-heat")
        compose.onNodeWithText("Off").performClick()

        compose.onNode(hasContentDescription("BedJet,", substring = true)).performClick()
        compose.waitFor(hasText("SAVED ON THE BEDJET"), timeoutMillis = 10_000)
        compose.capture("device")
    }
}

fun launchLull(
    ephemeral: Boolean = true,
    demoElapsedMinutes: Int = 0,
    demoLabelConnected: Boolean = false,
    demoHistory: Boolean = false,
): ActivityScenario<MainActivity> {
    val intent = Intent(ApplicationProvider.getApplicationContext(), MainActivity::class.java)
        .putExtra("ephemeral", ephemeral)
        .putExtra("demoHistory", demoHistory)
        .putExtra("demoElapsedMinutes", demoElapsedMinutes)
        .putExtra("demoLabelConnected", demoLabelConnected)
    return ActivityScenario.launch(intent)
}

fun ComposeTestRule.waitFor(matcher: SemanticsMatcher, timeoutMillis: Long = 5_000) {
    waitUntil(timeoutMillis) { onAllNodes(matcher, useUnmergedTree = false).fetchSemanticsNodes().isNotEmpty() }
}

fun ComposeTestRule.waitUntilGone(matcher: SemanticsMatcher, timeoutMillis: Long = 5_000) {
    waitUntil(timeoutMillis) { onAllNodes(matcher).fetchSemanticsNodes().isEmpty() }
}

fun ComposeTestRule.slider(title: String): SemanticsNodeInteraction =
    onNode(hasContentDescription(title) and SemanticsMatcher.keyIsDefined(SemanticsActions.SetProgress))

fun SemanticsNodeInteraction.label(): String =
    fetchSemanticsNode().config.getOrNull(SemanticsProperties.ContentDescription)?.joinToString() ?: ""

fun SemanticsNodeInteraction.value(): String? =
    fetchSemanticsNode().config.getOrNull(SemanticsProperties.StateDescription)

/** Moves a slider to a point along its track, 0 at the start and 1 at the end, like XCUIElement.adjust. */
fun SemanticsNodeInteraction.setTo(fraction: Float) {
    val range = fetchSemanticsNode().config[SemanticsProperties.ProgressBarRangeInfo].range
    performSemanticsAction(SemanticsActions.SetProgress) { it(range.start + (range.endInclusive - range.start) * fraction) }
}

fun ComposeTestRule.waitForSlider(title: String, value: String, timeoutMillis: Long = 5_000) {
    waitUntil(timeoutMillis) { runCatching { slider(title).value() == value }.getOrDefault(false) }
}

/**
 * Saves the screen to the app's files, where `adb pull` can collect it. Compose only draws new frames
 * when a test syncs with it, so let it catch up first.
 */
fun ComposeTestRule.capture(name: String, folder: String = "screens") {
    waitForIdle()
    Thread.sleep(300)
    waitForIdle()
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val bitmap = instrumentation.uiAutomation.takeScreenshot() ?: return
    val directory = File(instrumentation.targetContext.getExternalFilesDir(null), folder).apply { mkdirs() }
    File(directory, "$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
}
