package com.rohankanjani.lull

import com.rohankanjani.lull.bedjetkit.Mode
import com.rohankanjani.lull.bedjetkit.ProgramStep
import com.rohankanjani.lull.bedjetkit.StoredProgram
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ScheduleTest {
    @Test
    fun schedulesSurviveSavingAndLoading() {
        val json = Json { ignoreUnknownKeys = true }
        val serializer = ListSerializer(Schedule.serializer())
        val saved = json.encodeToString(serializer, Schedule.templates)
        assertEquals(Schedule.templates, json.decodeFromString(serializer, saved))
    }

    @Test
    fun phasesBecomeTheStepsTheBedJetStores() {
        val phase = Phase(Mode.HEAT, temperature = 68, fanPercent = 40, minutes = 95)
        assertEquals(ProgramStep(Mode.HEAT, fanStep = 7, temperature = 68, hours = 1, minutes = 35), phase.step)
    }

    @Test
    fun clockTimeStepsImportAsDurationsFromBedtime() {
        // Ends at 6:30, starting from the usual 22:30 bedtime: eight hours.
        val program = StoredProgram("", listOf(ProgramStep(Mode.COOL, fanStep = 5, temperature = 44, hours = 6, minutes = 30, endsAtClockTime = true)))
        val schedule = Schedule.importing(program)
        assertEquals("From BedJet", schedule.name)
        assertEquals(480, schedule.phases.single().minutes)
        assertEquals(30, schedule.phases.single().fanPercent)
    }

    @Test
    fun aRunKnowsWhichPhaseItIsIn() {
        val schedule = Schedule.templates[0]
        val run = ActiveRun(schedule, startedAt = 0)
        assertEquals(0, run.phase(now = 10 * 60_000L)?.index)
        assertEquals(35, run.phase(now = 10 * 60_000L)?.minutesLeft)
        assertEquals(1, run.phase(now = 50 * 60_000L)?.index)
        assertNull(run.phase(now = schedule.totalMinutes * 60_000L))
        assertEquals(0.5, run.progress(now = run.endsAt / 2), 0.001)
    }

    @Test
    fun temperaturesRoundLikeTheIPhoneApp() {
        assertEquals(86, Format.degrees(60, fahrenheit = true))
        assertEquals(30, Format.degrees(60, fahrenheit = false))
        assertEquals(23, Format.degrees(45, fahrenheit = false))
        assertEquals(60, Format.halfCelsius(86, fahrenheit = true))
        assertEquals("1 hr 5 min", Format.duration(65))
        assertEquals("2 hr", Format.duration(120))
        assertEquals("45 min", Format.duration(45))
    }

    @Test
    fun heatPhasesAreCappedByTheSafetyCutOff() {
        assertEquals(60, Phase(Mode.HEAT, temperature = 80, fanPercent = 100, minutes = 30).maxMinutes)
        assertEquals(10, Phase(Mode.TURBO, minutes = 10).maxMinutes)
        assertEquals(240, Phase(Mode.HEAT, temperature = 66, fanPercent = 40, minutes = 30).maxMinutes)
    }
}
