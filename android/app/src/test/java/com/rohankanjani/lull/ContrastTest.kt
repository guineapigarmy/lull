package com.rohankanjani.lull

import androidx.compose.ui.graphics.Color
import com.rohankanjani.lull.bedjetkit.Mode
import com.rohankanjani.lull.ui.Theme
import com.rohankanjani.lull.ui.tint
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.pow

/**
 * Every pairing of text colour and background the screens use reads at 4.5:1 or better, the WCAG AA level for
 * body text. Checked from the colours themselves, so it holds wherever the text sits or scrolls. Mirrors ContrastTests.swift.
 */
class ContrastTest {
    private val backgrounds = listOf("background" to Theme.background, "surface" to Theme.surface, "raised" to Theme.raised)

    @Test
    fun labelsOnEveryBackground() {
        for ((text, color) in listOf("primary" to Color.White, "secondary" to Theme.secondary, "tertiary" to Theme.tertiary)) {
            for ((name, background) in backgrounds) assertReadable(color, background, "$text text on $name")
        }
    }

    @Test
    fun modeButtons() {
        for (mode in Mode.entries) {
            // Unselected: the mode's colour on a raised button. Selected: black on the mode's colour.
            assertReadable(mode.tint, Theme.raised, "${mode.title} on a mode button")
            assertReadable(Color.Black, mode.tint, "a selected ${mode.title} button")
            // The running phase is written in its mode's colour on a card.
            assertReadable(mode.tint, Theme.surface, "${mode.title} on a card")
        }
    }

    @Test
    fun primaryButtons() {
        assertReadable(Color.Black, Color.White, "a prominent button")
        assertReadable(Color.White, Theme.raised, "a plain button")
    }

    /** The faintest grey before it was raised, which this check is there to catch. */
    @Test
    fun catchesTheOldFaintGrey() {
        assertTrue(contrast(Color.White.copy(alpha = 0.32f), Theme.surface) < 4.5)
    }

    // WCAG contrast

    private fun assertReadable(text: Color, background: Color, what: String) {
        val ratio = contrast(text, background)
        assertTrue("$what is %.2f:1".format(ratio), ratio >= 4.5)
    }

    private fun contrast(text: Color, background: Color): Double {
        val back = listOf(background.red, background.green, background.blue).map(Float::toDouble)
        val front = listOf(text.red, text.green, text.blue).map(Float::toDouble)
        val alpha = text.alpha.toDouble()
        // Translucent text shows the background through it.
        val blended = (0..2).map { front[it] * alpha + back[it] * (1 - alpha) }
        val lighter = maxOf(luminance(blended), luminance(back))
        val darker = minOf(luminance(blended), luminance(back))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private fun luminance(rgb: List<Double>): Double {
        val linear = rgb.map { if (it <= 0.04045) it / 12.92 else ((it + 0.055) / 1.055).pow(2.4) }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }
}
