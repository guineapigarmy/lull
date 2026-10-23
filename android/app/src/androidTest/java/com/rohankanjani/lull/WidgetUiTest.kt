package com.rohankanjani.lull

import android.content.Intent
import android.net.Uri
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.glance.testing.unit.hasContentDescription as glanceDescription
import androidx.glance.testing.unit.hasText as glanceText
import androidx.glance.testing.unit.hasTextEqualTo as glanceTextEqualTo
import androidx.glance.testing.unit.hasContentDescriptionEqualTo as glanceDescriptionEqualTo
import androidx.compose.runtime.Composable
import androidx.compose.ui.unit.DpSize
import androidx.glance.appwidget.testing.unit.GlanceAppWidgetUnitTest
import androidx.glance.appwidget.testing.unit.runGlanceAppWidgetUnitTest
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.rohankanjani.lull.widgets.LastNightContent
import com.rohankanjani.lull.widgets.LastNightWidget
import com.rohankanjani.lull.widgets.TonightContent
import com.rohankanjani.lull.widgets.TonightWidget
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * What each widget says at each size, and that what widgets, tiles and shortcuts open lands in the right place.
 * The Android side of HomeScreenWidgetTests.swift, which places the iPhone widgets through the system's gallery.
 */
@RunWith(AndroidJUnit4::class)
class WidgetUiTest {
    @get:Rule
    val compose = createEmptyComposeRule()

    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val now = System.currentTimeMillis()
    private val running = WidgetSnapshot.preview(now)
    private val planned = running.copy(run = null)

    /** Glance's test runner draws one widget at one size per run. */
    private fun draw(size: DpSize, content: @Composable () -> Unit, check: GlanceAppWidgetUnitTest.() -> Unit) =
        runGlanceAppWidgetUnitTest {
            setContext(context)
            setAppWidgetSize(size)
            provideComposable(content)
            check()
        }

    @Test
    fun tonightShowsWhereTheNightIsUpTo() {
        for (size in listOf(TonightWidget.SMALL, TonightWidget.MEDIUM, TonightWidget.LARGE)) {
            draw(size, { TonightContent(running, now) }) {
                onNode(glanceDescription("Cool Drift, phase 2 of 4, Cooling")).assertExists()
            }
        }
    }

    @Test
    fun tonightOffersToStartTheNight() {
        draw(TonightWidget.MEDIUM, { TonightContent(planned, now) }) {
            onNode(glanceDescriptionEqualTo("Start Night")).assertExists()
            onNode(glanceTextEqualTo("Start")).assertExists()
        }
        // The small size has no room for the button; tapping it opens the schedule instead.
        draw(TonightWidget.SMALL, { TonightContent(planned, now) }) {
            onNode(glanceDescription("Tonight, Cool Drift")).assertExists()
        }
    }

    @Test
    fun tonightWithoutASchedule() {
        draw(TonightWidget.MEDIUM, { TonightContent(WidgetSnapshot(), now) }) {
            onNode(glanceText("No schedule yet")).assertExists()
        }
    }

    @Test
    fun lastNightSumsUpTheNightBefore() {
        for (size in listOf(LastNightWidget.SMALL, LastNightWidget.MEDIUM)) {
            draw(size, { LastNightContent(planned, now) }) {
                onNode(glanceDescription("Last night, ")).assertExists()
            }
        }
        draw(LastNightWidget.MEDIUM, { LastNightContent(WidgetSnapshot(), now) }) {
            onNode(glanceText("No nights yet")).assertExists()
        }
    }

    @Test
    fun widgetLinksOpenTheirTab() {
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(LullTab.HISTORY.link), ApplicationProvider.getApplicationContext(), MainActivity::class.java)
            .putExtra("ephemeral", true)
        ActivityScenario.launch<MainActivity>(intent).use {
            compose.waitFor(hasText("No nights yet"), timeoutMillis = 10_000)
        }
    }

    @Test
    fun startNightFromATileOrShortcut() {
        val intent = AppCommands.startNightIntent(ApplicationProvider.getApplicationContext()).putExtra("ephemeral", true)
        ActivityScenario.launch<MainActivity>(intent).use {
            // Lull opens on the Schedule and starts tonight's schedule once the BedJet connects.
            compose.waitFor(hasText("End Night"), timeoutMillis = 15_000)
            compose.onNodeWithText("End Night").assertExists()
            compose.waitFor(hasContentDescription("Night timeline", substring = true))
        }
    }
}
