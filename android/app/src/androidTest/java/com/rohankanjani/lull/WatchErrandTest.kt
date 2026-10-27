package com.rohankanjani.lull

import android.app.Application
import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.rohankanjani.lull.bedjetkit.BedJetError
import com.rohankanjani.lull.bedjetkit.DemoDiscovery
import com.rohankanjani.lull.bedjetkit.Generation
import com.rohankanjani.lull.bedjetkit.LinkState
import com.rohankanjani.lull.bedjetkit.Mode
import com.rohankanjani.lull.bedjetkit.NearbyBedJet
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID

/**
 * Errands from the watch, which reach the BedJet through Lull on the phone. Off screen, Lull connects for each one and
 * lets go again, so another phone can still take the BedJet over. Mirrors WatchErrandTests.swift.
 */
@RunWith(AndroidJUnit4::class)
class WatchErrandTest {
    private val mine = NearbyBedJet(UUID.randomUUID().toString(), "BEDJET_3", Generation.V3, -50)
    private val partners = NearbyBedJet(UUID.randomUUID().toString(), "BEDJET_3", Generation.V3, -70)

    private val context: Application = ApplicationProvider.getApplicationContext()
    private lateinit var directory: File
    private lateinit var prefsName: String
    private lateinit var units: CoroutineScope
    private val fakes = mutableMapOf<String, FakeLink>()
    private val launched = mutableListOf<AppModel>()

    @Before
    fun setUp() {
        directory = File(context.cacheDir, "WatchErrandTest-${UUID.randomUUID()}").apply { mkdirs() }
        prefsName = "WatchErrandTest-${UUID.randomUUID()}"
        AppModel.errandPatience = 2_000
    }

    @After
    fun tearDown() = onMain {
        for (model in launched) model.close()
        for (unit in fakes.values) unit.stop()
        units.cancel()
        directory.deleteRecursively()
        context.deleteSharedPreferences(prefsName)
        context.deleteSharedPreferences("$prefsName.link")
        AppModel.errandPatience = 8_000
    }

    /** Runs on the main thread, where Lull and its links do everything. */
    private fun onMain(block: suspend CoroutineScope.() -> Unit): Unit = runBlocking(Dispatchers.Main) {
        if (!::units.isInitialized) units = MainScope()
        block()
    }

    private fun launch(onScreen: Boolean = true): AppModel {
        val storage = Storage(
            directory = directory,
            prefs = context.getSharedPreferences(prefsName, Context.MODE_PRIVATE),
            linkPrefs = context.getSharedPreferences("$prefsName.link", Context.MODE_PRIVATE),
        )
        return AppModel(context, LaunchOptions(), storage, demoMode = false, makesLink = { unit(it.unit!!) },
            discovery = { DemoDiscovery(listOf(mine, partners)) }, onScreen = onScreen).also { launched += it }
    }

    private fun unit(id: String): FakeLink = fakes.getOrPut(id) { FakeLink("BEDJET_3", units) }

    private suspend fun waitUntil(what: String, timeoutMillis: Long = 6_000, condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + timeoutMillis
        while (!condition()) {
            if (System.currentTimeMillis() > deadline) fail("Timed out waiting for $what")
            delay(50)
        }
    }

    /** A BedJet chosen and connected, with what's saved on it read, as after using Lull for a while. */
    private suspend fun chosen(unit: NearbyBedJet, model: AppModel): BedJet {
        model.choose(unit)
        val bedJet = model.bedJets.first { it.unit == unit.id }
        waitUntil("${unit.name} to connect") { bedJet.isConnected }
        waitUntil("its slots to be read") { bedJet.deviceSlots.size == 3 }
        return bedJet
    }

    @Test
    fun offScreenAnErrandStartsTheNightThenLetsGo() = onMain {
        val model = launch()
        val bedJet = chosen(mine, model)
        model.appMovedToBackground()
        assertFalse(bedJet.isConnected)
        val stops = unit(mine.id).stops

        val reply = model.runErrand(WatchCommand.StartNight(bedJet.id))
        assertEquals(WatchReply.done, reply)
        assertEquals(bedJet.tonight?.id, bedJet.run?.schedule?.id)
        // Let go again, so another phone can take the BedJet over.
        assertTrue(unit(mine.id).stops > stops)
        assertFalse(bedJet.isConnected)
    }

    @Test
    fun wokenOffScreenNothingConnectsUntilAnErrandNeedsIt() = onMain {
        val chosen = launch()
        chosen(mine, chosen)
        chosen.appMovedToBackground()
        fakes.clear()

        // Started by the watch: no BedJet is connected, and none is asked for, so another phone keeps its night.
        val model = launch(onScreen = false)
        val bedJet = model.bedJet!!
        delay(500)
        // The link is set up, ready for an errand, and left idle.
        val link = fakes[mine.id] ?: return@onMain fail("No link was set up")
        assertEquals(LinkState.SEARCHING, link.state)
        assertFalse(bedJet.isConnected)

        val reply = model.runErrand(WatchCommand.StartNight(bedJet.id))
        assertEquals(WatchReply.done, reply)
        assertNotNull(bedJet.run)
        assertFalse(bedJet.isConnected)

        // Opened later, it talks to the BedJet as usual.
        model.appBecameActive()
        waitUntil("it to connect") { bedJet.isConnected }
    }

    @Test
    fun aRefreshDoesntCutOffAnErrandOnTheSameBedJet() = onMain {
        val model = launch()
        val bedJet = chosen(mine, model)
        model.appMovedToBackground()

        val refreshed = async { model.runErrand(WatchCommand.Refresh) }
        val started = async { model.runErrand(WatchCommand.StartNight(bedJet.id)) }
        assertEquals(WatchReply.done, refreshed.await())
        assertEquals(WatchReply.done, started.await())
        assertNotNull(bedJet.run)
        assertFalse(bedJet.isConnected)
    }

    @Test
    fun onScreenTheBedJetStaysConnected() = onMain {
        val model = launch()
        val bedJet = chosen(mine, model)
        val stops = unit(mine.id).stops

        val reply = model.runErrand(WatchCommand.StartNight(null))
        assertEquals(WatchReply.done, reply)
        assertNotNull(bedJet.run)
        assertEquals(stops, unit(mine.id).stops)
        assertTrue(bedJet.isConnected)
    }

    @Test
    fun theRemoteFromTheWatchSetsAndLetsGo() = onMain {
        val model = launch()
        val bedJet = chosen(mine, model)
        model.appMovedToBackground()

        val preset = RemotePreset(Mode.HEAT, minutes = 20, temperature = 70, fanPercent = 35)
        val reply = model.runErrand(WatchCommand.Remote(preset, bedJet.id))
        assertEquals(WatchReply.done, reply)
        // What the BedJet last said is kept once Lull lets go.
        assertEquals(Mode.HEAT, bedJet.status?.mode)
        assertEquals(70, bedJet.status?.targetTemperature)
        assertEquals(35, bedJet.status?.fanPercent)
        assertFalse(bedJet.isConnected)
    }

    @Test
    fun whatWentWrongGoesBackToTheWatchNotIntoAnAlert() = onMain {
        val model = launch()
        val bedJet = chosen(mine, model)
        model.appMovedToBackground()
        // Unplugged since.
        unit(mine.id).answers = false

        val reply = model.runErrand(WatchCommand.StartNight(bedJet.id))
        assertFalse(reply.ok)
        assertEquals(BedJetError.NotConnected.message, reply.message)
        assertNull(bedJet.run)
        assertNull(model.errorMessage)
    }

    @Test
    fun anErrandForAForgottenBedJetNeverReachesAnother() = onMain {
        val model = launch()
        val bedJet = chosen(mine, model)

        val reply = model.runErrand(WatchCommand.StartNight(UUID.randomUUID().toString()))
        assertFalse(reply.ok)
        assertNull(bedJet.run)
    }

    @Test
    fun aRefreshHearsEachBedJetThenLetsGo() = onMain {
        val model = launch()
        val first = chosen(mine, model)
        val second = chosen(partners, model)
        model.appMovedToBackground()
        val asked = System.currentTimeMillis()

        val reply = model.runErrand(WatchCommand.Refresh)
        assertEquals(WatchReply.done, reply)
        assertTrue(first.hasReported(asked))
        assertTrue(second.hasReported(asked))
        assertFalse(first.isConnected)
        assertFalse(second.isConnected)
    }
}
