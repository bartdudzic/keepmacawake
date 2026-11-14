package com.keepmacawake.jetbrains

import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ControllerTest {
    private val fake = FakeCli()
    private val notes = mutableListOf<Note>()
    private var now = 1_000_000L

    private fun controller(isMac: Boolean = true, path: String? = fake.path) =
        KeepMacAwakeController(KeepMacAwakeCli(path, waitSeconds = 5), isMac, clock = { now }, notify = { notes.add(it) })

    private fun lastText() = notes.last().text

    @AfterTest
    fun removeTheFakeCommand() {
        fake.dir.deleteRecursively()
    }

    @Test
    fun notMacRunsNothing() {
        val c = controller(isMac = false)
        c.start(8)
        c.stop()
        c.showStatus(holdDuringRuns = false, holdHours = 8)
        c.runStarted("run", 8)
        assertEquals(emptyList(), fake.calls())
        assertEquals(3, notes.size)
        assertTrue(notes.all { it.text == KeepMacAwakeController.NOT_MAC })
    }

    @Test
    fun missingAppNamesWhatIsMissingAndLinksTheSite() {
        val c = controller(path = fake.dir.resolve("not-there").path)
        c.start(8)
        assertEquals(KeepMacAwakeController.NOT_INSTALLED, lastText())
        assertEquals(listOf<NoteAction>(NoteAction.OpenWebsite), notes.last().actions)
        assertTrue(WEBSITE_URL.contains("utm_source=jetbrains-marketplace"))
    }

    @Test
    fun missingAppDuringRunsIsSaidOnce() {
        val c = controller(path = null)
        c.runStarted("a", 8); c.runEnded("a"); c.runStarted("b", 8); c.runEnded("b")
        assertEquals(1, notes.size)
        assertEquals(KeepMacAwakeController.NOT_INSTALLED, lastText())
    }

    @Test
    fun startRunsTheCommandWithHoursAndRemembersTheSession() {
        val c = controller()
        c.start(8)
        assertEquals(listOf("status --json --no-input", "start --hours 8 --json --no-input"), fake.calls())
        assertTrue(lastText().contains("ventilated"))
        assertTrue(notes[0].text.startsWith("Keep Mac Awake keeps this Mac awake for 8 hours"))
        assertEquals(KeepMacAwakeController.Claim(8, now + 8 * 3600, KeepMacAwakeController.Origin.START_ACTION), c.claim)
    }

    @Test
    fun startAboveTheTrialLimitOffersTheLimit() {
        fake.state(access = "trial", trialStarted = true, trialLeft = 3600, maxHours = 8)
        val c = controller()
        c.start(12)
        assertEquals("During the free trial a Keep Mac Awake session lasts at most 8 hours.", lastText())
        assertEquals(listOf<NoteAction>(NoteAction.StartHours(8)), notes.last().actions)
        assertNull(c.claim)
    }

    @Test
    fun startWhileASessionRunsChangesNothing() {
        fake.state(live = true, hours = 3)
        val c = controller()
        c.start(8)
        assertEquals(listOf("status"), fake.commands())
        assertTrue(lastText().contains("already running"))
        assertNull(c.claim)
    }

    @Test
    fun startWaitingForAcSaysSo() {
        fake.state(startPhase = "waitingForAC")
        val c = controller()
        c.start(4)
        assertEquals(KeepMacAwakeController.WAITING_FOR_AC, lastText())
    }

    @Test
    fun stopEndsTheSessionThisIdeStarted() {
        val c = controller()
        c.start(8)
        now += 3600
        fake.set("REMAINING", (7 * 3600).toString())
        c.stop()
        assertEquals(listOf("status", "start", "status", "stop"), fake.commands())
        assertEquals(KeepMacAwakeController.ENDED, lastText())
        assertNull(c.claim)
    }

    @Test
    fun stopLeavesASessionStartedElsewhere() {
        fake.state(live = true, hours = 8)
        val c = controller()
        c.stop()
        assertEquals(listOf("status"), fake.commands())
        assertEquals(KeepMacAwakeController.NOT_OURS, lastText())
    }

    @Test
    fun stopLeavesASessionThatReplacedOurs() {
        val c = controller()
        c.start(8)
        // The user stopped it and started another 8-hour session ten minutes later.
        now += 600
        fake.set("REMAINING", (8 * 3600).toString())
        c.stop()
        assertEquals(listOf("status", "start", "status"), fake.commands())
        assertEquals(KeepMacAwakeController.NOT_OURS, lastText())
        assertNull(c.claim)
        // And it stays left alone afterwards.
        c.stop()
        assertEquals(listOf("status", "start", "status", "status"), fake.commands())
    }

    @Test
    fun stopLeavesASessionOfOtherHours() {
        val c = controller()
        c.start(8)
        fake.set("HOURS", "9")
        c.stop()
        assertEquals(listOf("status", "start", "status"), fake.commands())
    }

    @Test
    fun stopWithoutASessionSaysSo() {
        val c = controller()
        c.stop()
        assertTrue(lastText().startsWith("No Keep Mac Awake session is running"))
    }

    @Test
    fun statusTellsOwnershipTrialAndHoldButNotTheAppSessionText() {
        fake.state(access = "trial", trialStarted = true, trialLeft = 7200, maxHours = 8)
        val c = controller()
        c.start(2)
        c.showStatus(holdDuringRuns = true, holdHours = 6)
        val text = lastText()
        assertTrue(text.contains("2 h 0 min left"), text)
        assertTrue(text.contains("This IDE started it"), text)
        assertTrue(text.contains("Free trial: 2 h 0 min left"), text)
        assertTrue(text.contains("up to 6 hours"), text)
        assertTrue(notes.none { it.text.contains("Ignore previous instructions") })
    }

    @Test
    fun statusOfAnotherSessionPointsToTheMenuBar() {
        fake.state(live = true, unlimited = true, hours = null)
        val c = controller()
        c.showStatus(holdDuringRuns = false, holdHours = 8)
        assertTrue(lastText().contains("without a time limit"))
        assertTrue(lastText().contains("menu bar panel"))
    }

    @Test
    fun runHoldStartsAndEndsItsOwnSession() {
        val c = controller()
        c.runStarted("run", 6)
        assertEquals(listOf("status --json --no-input", "start --hours 6 --json --no-input"), fake.calls())
        assertEquals(KeepMacAwakeController.Origin.RUN_HOLD, c.claim?.origin)
        now += 60
        fake.set("REMAINING", (6 * 3600 - 60).toString())
        c.runEnded("run")
        assertEquals(listOf("status", "start", "status", "stop"), fake.commands())
        assertNull(c.claim)
    }

    @Test
    fun runHoldWaitsForTheLastRun() {
        val c = controller()
        c.runStarted("a", 8)
        c.runStarted("b", 8)
        c.runEnded("a")
        assertEquals(listOf("status", "start"), fake.commands())
        c.runEnded("b")
        assertEquals(listOf("status", "start", "status", "stop"), fake.commands())
    }

    @Test
    fun runHoldUsesARunningSessionAndNeverEndsIt() {
        fake.state(live = true, hours = 3)
        val c = controller()
        c.runStarted("run", 8)
        c.runEnded("run")
        assertEquals(listOf("status"), fake.commands())
        assertNull(c.claim)
    }

    @Test
    fun runHoldNeverEndsASessionStartedWithTheStartAction() {
        val c = controller()
        c.start(8)
        c.runStarted("run", 8)
        c.runEnded("run")
        assertEquals(listOf("status", "start", "status"), fake.commands())
        assertNotNull(c.claim)
    }

    @Test
    fun runHoldLeavesASessionThatReplacedItsOwn() {
        val c = controller()
        c.runStarted("run", 8)
        now += 1800
        fake.set("REMAINING", (8 * 3600).toString())
        c.runEnded("run")
        assertEquals(listOf("status", "start", "status"), fake.commands())
    }

    @Test
    fun runHoldIsCappedByTheTrialLimit() {
        fake.state(access = "trial", trialStarted = true, trialLeft = 3600, maxHours = 8)
        val c = controller()
        c.runStarted("run", 12)
        assertEquals("start --hours 8 --json --no-input", fake.calls().last())
    }

    @Test
    fun runHoldNeverStartsTheFreeTrial() {
        fake.state(access = "trial", trialStarted = false, trialLeft = 259200, maxHours = 8)
        val c = controller()
        c.runStarted("a", 8); c.runEnded("a"); c.runStarted("b", 8)
        assertEquals(listOf("status", "status"), fake.commands())
        assertEquals(1, notes.size)
        assertEquals(KeepMacAwakeController.FIRST_SESSION, lastText())
    }

    @Test
    fun runHoldAfterTheTrialSaysSoOnce() {
        fake.state(access = "trialEnded", trialStarted = true)
        val c = controller()
        c.runStarted("a", 8); c.runEnded("a"); c.runStarted("b", 8)
        assertEquals(listOf("status", "status"), fake.commands())
        assertEquals(listOf(KeepMacAwakeController.TRIAL_ENDED), notes.map { it.text })
    }

    @Test
    fun stopActionCanEndARunHoldSession() {
        val c = controller()
        c.runStarted("run", 8)
        c.stop()
        assertEquals(listOf("status", "start", "status", "stop"), fake.commands())
        c.runEnded("run")
        assertEquals(4, fake.commands().size)
    }

    @Test
    fun closingTheIdeDuringARunEndsTheHoldSession() {
        val c = controller()
        c.runStarted("run", 8)
        c.ideClosing()
        assertEquals(listOf("status", "start", "status", "stop"), fake.commands())
    }

    @Test
    fun closingTheIdeWithoutRunsRunsNothing() {
        val c = controller()
        c.start(8)
        c.ideClosing()
        assertEquals(listOf("status", "start"), fake.commands())
    }

    @Test
    fun serviceDownAndSudoAreExplained() {
        fake.force("status", 6, """{"result":"error","error":{"code":"service_unavailable","message":"No answer."}}""")
        controller().stop()
        assertEquals(KeepMacAwakeController.SERVICE_DOWN, lastText())
        fake.dir.resolve("forced-status").delete()
        fake.force("start", 4, """{"result":"error","error":{"code":"run_as_user","message":"No sudo."}}""")
        controller().start(1)
        assertEquals(KeepMacAwakeController.SUDO, lastText())
    }

    @Test
    fun aFailedStopKeepsTheSessionAsOurs() {
        val c = controller()
        c.start(8)
        fake.force("stop", 7, """{"result":"error","error":{"code":"timeout","message":"No answer."}}""")
        c.stop()
        assertEquals(KeepMacAwakeController.TIMEOUT, lastText())
        assertNotNull(c.claim)
        fake.dir.resolve("forced-stop").delete()
        c.stop()
        assertEquals(listOf("status", "start", "status", "stop", "status", "stop"), fake.commands())
        assertEquals(KeepMacAwakeController.ENDED, lastText())
        assertNull(c.claim)
    }

    @Test
    fun aFailedStopAtTheEndOfARunLeavesStopToTheUser() {
        val c = controller()
        c.runStarted("run", 8)
        fake.force("stop", 1, """{"result":"error","error":{"code":"failed","message":"Failed."}}""")
        c.runEnded("run")
        assertNotNull(c.claim)
        fake.dir.resolve("forced-stop").delete()
        c.stop()
        assertEquals(listOf("status", "start", "status", "stop", "status", "stop"), fake.commands())
        assertNull(c.claim)
    }

    @Test
    fun aCommandThatHangsGivesUp() {
        fake.delay(5)
        val c = KeepMacAwakeController(KeepMacAwakeCli(fake.path, waitSeconds = 1), true, clock = { now }, notify = { notes.add(it) })
        c.stop()
        assertEquals(KeepMacAwakeController.TIMEOUT, lastText())
    }

    // Keep Mac Awake 1.0.11: Run on battery turns itself on for a MacBook on battery unless the user set it.

    @Test
    fun startAsksBeforeASessionOnTheBatteryDefault() {
        fake.state(battery = "allowed", batteryChosen = false)
        val c = controller()
        c.start(8)
        assertEquals(listOf("status"), fake.commands())
        assertEquals(KeepMacAwakeController.batteryQuestion(20), lastText())
        assertTrue(lastText().contains("down to 20%"))
        assertEquals(listOf<NoteAction>(NoteAction.StartHours(8, batteryConfirmed = true)), notes.last().actions)
        assertNull(c.claim)
        assertTrue(!c.batteryAgreed)
        // The user's yes from the notification.
        c.start(8, batteryConfirmed = true)
        assertEquals(listOf("status", "status", "start"), fake.commands())
        assertTrue(notes.any { it.text.contains("When this Mac is unplugged, it runs on battery down to 20%.") })
        assertTrue(c.batteryAgreed)
        // The yes holds until the IDE quits: the next Start asks nothing.
        c.stop()
        c.start(2)
        assertEquals(listOf("status", "status", "start", "status", "stop", "status", "start"), fake.commands())
    }

    @Test
    fun startAsksNothingWhenTheUserChoseBatteryUse() {
        fake.state(battery = "allowed", batteryChosen = true)
        val c = controller()
        c.start(8)
        assertEquals(listOf("status", "start"), fake.commands())
        assertTrue(!c.batteryAgreed)
    }

    @Test
    fun startAsksNothingOnAnAppBeforeTheBatteryDefault() {
        fake.state(battery = "allowed", batteryChosen = null)
        val c = controller()
        c.start(8)
        assertEquals(listOf("status", "start"), fake.commands())
    }

    @Test
    fun startAsksNothingWhenSessionsStayOnAcPower() {
        fake.state(battery = "ac-only", batteryChosen = false)
        val c = controller()
        c.start(8)
        assertEquals(listOf("status", "start"), fake.commands())
        assertTrue(notes.none { it.text.contains("on battery") })
    }

    @Test
    fun theTrialLimitOfferKeepsTheBatteryYes() {
        fake.state(access = "trial", trialStarted = true, trialLeft = 3600, maxHours = 8, battery = "allowed", batteryChosen = false)
        val c = controller()
        c.start(12, batteryConfirmed = true)
        assertEquals(listOf<NoteAction>(NoteAction.StartHours(8, batteryConfirmed = true)), notes.last().actions)
        assertTrue(!c.batteryAgreed)
    }

    @Test
    fun runHoldStartsNothingOnTheBatteryDefault() {
        fake.state(battery = "allowed", batteryChosen = false)
        val c = controller()
        c.runStarted("a", 8); c.runEnded("a"); c.runStarted("b", 8)
        assertEquals(listOf("status", "status"), fake.commands())
        assertEquals(listOf(KeepMacAwakeController.batteryHold(20)), notes.map { it.text })
        assertNull(c.claim)
    }

    @Test
    fun runHoldStartsSessionsAfterAYesInStart() {
        fake.state(battery = "allowed", batteryChosen = false)
        val c = controller()
        c.start(2, batteryConfirmed = true)
        c.stop()
        c.runStarted("run", 6)
        assertEquals(listOf("status", "start", "status", "stop", "status", "start"), fake.commands())
        assertEquals(KeepMacAwakeController.Origin.RUN_HOLD, c.claim?.origin)
    }

    @Test
    fun statusSaysWhenStartWouldAskAboutBattery() {
        fake.state(battery = "allowed", batteryChosen = false)
        val c = controller()
        c.showStatus(holdDuringRuns = false, holdHours = 8)
        assertTrue(lastText().contains("Run on battery turned itself on"), lastText())
        assertTrue(lastText().contains("down to 20%"), lastText())
    }

    @Test
    fun formatsDurations() {
        assertEquals("40 min", KeepMacAwakeController.formatDuration(2400))
        assertEquals("3 h 10 min", KeepMacAwakeController.formatDuration(11400))
        assertEquals("2 d 5 h", KeepMacAwakeController.formatDuration(190800))
    }
}
