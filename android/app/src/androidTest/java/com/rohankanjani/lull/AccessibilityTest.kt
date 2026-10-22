package com.rohankanjani.lull

import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isEnabled
import androidx.compose.ui.test.isRoot
import androidx.compose.ui.test.junit4.accessibility.enableAccessibilityChecks
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.tryPerformAccessibilityChecks
import androidx.activity.ComponentActivity
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Walks every screen at the default and the largest text size: Google's Accessibility Test Framework on each
 * (what TalkBack reads and reaches, touch target sizes, contrast, text that can't grow), plus what TalkBack says
 * for the key controls. Mirrors AccessibilityTests.swift.
 */
@RunWith(AndroidJUnit4::class)
class AccessibilityTest {
    @get:Rule
    val compose = createAndroidComposeRule<ComponentActivity>()

    @After
    fun restoreTextSize() {
        shell("settings put system font_scale 1.0")
    }

    @Test
    fun everyScreen() = walk(textSize = 1f)

    /** Android's largest text size. Layouts that can't hold it stack instead, as on iOS. */
    @Test
    fun everyScreenAtLargestTextSize() = walk(textSize = 2f)

    private fun walk(textSize: Float) {
        shell("settings put system font_scale $textSize")
        compose.enableAccessibilityChecks()
        launchLull(ephemeral = true, demoHistory = true).use {
            compose.waitFor(hasText("Heat"), timeoutMillis = 10_000)
            compose.waitFor(hasContentDescription("Off, room", substring = true), timeoutMillis = 10_000)
            audit()

            compose.onNodeWithText("Heat").performScrollTo().performClick()
            compose.waitForSlider("Turns off in", "4 hours")
            compose.onNode(hasContentDescription("Heating, set to", substring = true)).assertExists()
            audit()
            compose.onNodeWithText("Off").performScrollTo().performClick()

            compose.onNode(hasContentDescription("BedJet,", substring = true)).performClick()
            compose.waitFor(hasText("Done"))
            audit()
            compose.onNodeWithText("Done").performClick()

            compose.onNodeWithText("Schedule").performClick()
            compose.waitFor(hasContentDescription("Start Night") and isEnabled(), timeoutMillis = 10_000)
            compose.onNode(hasContentDescription("Night timeline", substring = true)).assertExists()
            compose.onNodeWithContentDescription("Edit Cool Drift").assertExists()
            audit()
            compose.onNodeWithContentDescription("Start Night").performScrollTo().performClick()
            compose.waitFor(hasText("End Night"), timeoutMillis = 10_000)
            compose.onNode(hasContentDescription("Cooling,", substring = true) and hasContentDescription("left", substring = true)).assertExists()
            audit()
            compose.onNodeWithText("End Night").performScrollTo().performClick()
            compose.waitFor(hasContentDescription("Start Night"), timeoutMillis = 10_000)

            compose.onNode(hasContentDescription("Warm Welcome,", substring = true)).performScrollTo().performClick()
            compose.waitFor(hasText("Add Phase"))
            compose.onNode(hasContentDescription("Schedule name", substring = true)).assertExists()
            audit()
            val second = hasContentDescription("Phase 2, Heat,", substring = true) and hasContentDescription("30 minutes, starts", substring = true)
            compose.onNode(second).performScrollTo().performClick()
            compose.waitFor(hasText("Remove Phase"))
            assertEquals("30 minutes", compose.slider("Duration").value())
            audit()
            compose.onNodeWithText("Done").performClick()
            compose.waitUntilGone(hasText("Remove Phase"))
            compose.onNodeWithText("Cancel").performClick()

            compose.onNodeWithText("History").performClick()
            // A night without a schedule is summed up by its times, read as a range rather than a dash.
            val night = hasTestTag("Night") and hasContentDescription(" to ", substring = true)
            compose.waitFor(night)
            assertEquals("Collapsed", compose.onNode(night).fetchSemanticsNode().config.getOrNull(SemanticsProperties.StateDescription))
            compose.onNode(night).performScrollTo().performClick()
            compose.waitFor(hasContentDescription("Turned off", substring = true))
            assertEquals("Expanded", compose.onNode(night).fetchSemanticsNode().config.getOrNull(SemanticsProperties.StateDescription))
            audit()
        }
    }

    /** Runs the checks on every window showing, so a sheet and the screen beneath it are both covered. */
    private fun audit() {
        compose.waitForIdle()
        val roots = compose.onAllNodes(isRoot())
        roots.fetchSemanticsNodes().indices.forEach { roots[it].tryPerformAccessibilityChecks() }
    }

    private fun shell(command: String) {
        InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand(command).close()
        Thread.sleep(500)
    }
}

