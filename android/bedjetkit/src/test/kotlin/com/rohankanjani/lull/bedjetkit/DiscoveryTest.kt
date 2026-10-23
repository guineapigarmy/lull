package com.rohankanjani.lull.bedjetkit

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

/** Mirrors BedJetKit's DiscoveryTests.swift. */
class DiscoveryTest {
    @Test
    fun linksOnlyTakeTheUnitTheyWereMadeFor() {
        val mine = UUID.randomUUID().toString()
        val partners = UUID.randomUUID().toString()
        assertTrue(takes(mine, boundTo = mine))
        assertFalse(takes(partners, boundTo = mine))
        // Only a link made without a unit takes whichever BedJet answers.
        assertTrue(takes(partners, boundTo = null))
    }

    @Test
    fun simulatedBedJetsAreListedAsSoonAsLookingStarts() {
        val discovery = DemoDiscovery()
        var changes = 0
        discovery.onChange = { changes += 1 }
        assertTrue(discovery.nearby.isEmpty())
        discovery.start()
        assertEquals(DemoDiscovery.SIMULATED, discovery.nearby)
        assertTrue(changes > 0)
        // Two share a name, as real units often do; their identities differ.
        assertEquals(discovery.nearby[0].name, discovery.nearby[1].name)
        assertNotEquals(discovery.nearby[0].id, discovery.nearby[1].id)
        discovery.stop()
        assertTrue(discovery.nearby.isEmpty())
    }

    @Test
    fun signalIsDescribedInWords() {
        assertEquals(NearbyBedJet.Signal.STRONG, NearbyBedJet("a", "B", null, -50).signal)
        assertEquals(NearbyBedJet.Signal.FAIR, NearbyBedJet("a", "B", null, -70).signal)
        assertEquals(NearbyBedJet.Signal.WEAK, NearbyBedJet("a", "B", null, -90).signal)
    }

    @Test
    fun aSimulatedBedJetThatIsAwayNeverConnects() = runTest {
        val link = DemoLink(scope = backgroundScope)
        link.answers = false
        link.start()
        testScheduler.advanceTimeBy(1_500)
        assertEquals(LinkState.SEARCHING, link.state)
        link.stop()
    }

    @Test
    fun handOverRequestsAreForOneBedJetOnly() {
        // A phone asking for one unit by its name is ignored by a phone holding another.
        assertNotEquals(Handoff.uuid("BEDJET_3A1F"), Handoff.uuid("BEDJET_3B07"))
    }
}
