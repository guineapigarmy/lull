package com.rohankanjani.lull.wear

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performRotaryScrollInput
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.rohankanjani.lull.wear.ui.CrownRow
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** The Remote's settings turn with the rotating side button or bezel once tapped, as the Apple Watch's do with the Digital Crown. */
@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class CrownRowTest {
    @get:Rule val compose = createComposeRule()

    private fun reads(text: String) = SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, text)

    @Test
    fun theBezelTurnsATappedSetting() {
        compose.setContent {
            var fan by remember { mutableIntStateOf(40) }
            CrownRow("Fan", "$fan%", fan, { fan = it }, 5..100, step = 5)
        }
        val row = compose.onNodeWithContentDescription("Fan")
        row.assert(reads("40%"))
        row.performClick()
        // About a notch of the bezel moves it one step.
        row.performRotaryScrollInput { rotateToScrollVertically(60f) }
        row.assert(reads("45%"))
        row.performRotaryScrollInput { rotateToScrollVertically(-1000f) }
        // No lower than the BedJet takes.
        row.assert(reads("5%"))
    }
}
