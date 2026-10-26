import XCTest
@testable import KeepMacAwakeServiceSupport
import KeepMacAwakeControlProtocol

final class PeerSupervisionTests: XCTestCase {
    enum Failure: Error { case simulated }
    func testHeartbeatRejectsFutureStaleNotReadyAndNonFiniteTimes() {
        XCTAssertTrue(PeerHeartbeat(generation: "a", updatedAt: 100, ready: true).isFresh(at: 107))
        for (then, now, ready) in [(100.0, 108.0, true), (101, 100, true), (100, 101, false), (.nan, 101, true), (100, .infinity, true)] {
            XCTAssertFalse(PeerHeartbeat(generation: "a", updatedAt: then, ready: ready).isFresh(at: now))
        }
    }
    func testWatchdogIndependentlyEnforcesACConsoleLeaseAndDeadline() {
        let beat = PeerHeartbeat(generation: "a", updatedAt: 100, ready: true, sessionUser: 501, sessionID: "session", leaseDeadline: 112, sessionDeadline: 400)
        XCTAssertTrue(beat.controllerIsSafe(at: 101, ac: true, console: 501))
        XCTAssertFalse(beat.controllerIsSafe(at: 101, ac: nil, console: 501))
        XCTAssertFalse(beat.controllerIsSafe(at: 101, ac: true, console: 502))
        XCTAssertFalse(beat.controllerIsSafe(at: 112, ac: true, console: 501))
        let nearEnd = PeerHeartbeat(generation: "a", updatedAt: 100, ready: true, sessionUser: 501, sessionID: "session", leaseDeadline: 112, sessionDeadline: 102)
        XCTAssertFalse(nearEnd.controllerIsSafe(at: 102, ac: true, console: 501))
    }
    func testMalformedPartialSessionCannotAuthorizeController() {
        let malformed = PeerHeartbeat(generation: "a", updatedAt: 100, ready: true, sessionUser: 501)
        XCTAssertFalse(malformed.controllerIsSafe(at: 101, ac: true, console: 501))
    }
    func testPriorBootHeartbeatCannotAuthorizeWatchdog() {
        let beat = PeerHeartbeat(generation: "a", updatedAt: 100, ready: true, bootID: "previous-boot")
        XCTAssertFalse(beat.isFresh(at: 101, bootID: "current-boot"))
        XCTAssertFalse(beat.isFresh(at: 101, bootID: nil))
    }
    func testIdleControllerIsNeverFencedForItsAgeAlone() {
        // Idle supervision publishes once a minute, and sleep ages the heartbeat further.
        var monitor = WatchdogAssessment()
        let idle = PeerHeartbeat(generation: "a", updatedAt: 100, ready: true, blocking: false)
        XCTAssertTrue(idle.isQuiescentController())
        for now: Double in [101, 100 + ControlConstants.idleSupervisionSeconds * 3, 100 + 86_400] {
            XCTAssertFalse(monitor.shouldFence(idle, at: now, ac: nil, console: nil), "\(now)")
        }
    }
    func testOnlyAReadyIdleControllerOfThisBootSkipsTheAgeCheck() {
        let stale = 100 + ControlConstants.peerTimeoutSeconds + 1
        let notIdle = [
            PeerHeartbeat(generation: "a", updatedAt: 100, ready: false, blocking: false),
            PeerHeartbeat(generation: "a", updatedAt: 100, ready: true),
            PeerHeartbeat(generation: "", updatedAt: 100, ready: true, blocking: false),
            PeerHeartbeat(generation: "a", updatedAt: 100, ready: true, sessionUser: 501, blocking: false),
            PeerHeartbeat(generation: "a", updatedAt: 100, ready: true, sessionID: "session", blocking: false),
            PeerHeartbeat(generation: "a", updatedAt: 100, ready: true, leaseDeadline: 112, blocking: false),
            PeerHeartbeat(generation: "a", updatedAt: 100, ready: true, sessionDeadline: 400, blocking: false),
            PeerHeartbeat(generation: "a", updatedAt: 100, ready: true, blocking: false, minimumBatteryPercent: 20),
            PeerHeartbeat(generation: "a", updatedAt: 100, ready: true, blocking: false, isUnlimited: true),
            PeerHeartbeat(generation: "a", updatedAt: 100, ready: true, blocking: false, bootID: "previous-boot"),
            PeerHeartbeat(generation: "a", updatedAt: 100, ready: true, blocking: false, restorationPending: true),
            PeerHeartbeat(generation: "a", updatedAt: 100, ready: true, blocking: false, restorationPending: nil),
            PeerHeartbeat(generation: "a", updatedAt: 100, ready: true, sessionUser: 501, sessionID: "session",
                          leaseDeadline: 112, sessionDeadline: 400, blocking: false),
        ]
        for beat in notIdle {
            XCTAssertFalse(beat.isQuiescentController())
            var monitor = WatchdogAssessment()
            XCTAssertTrue(monitor.shouldFence(beat, at: stale, ac: true, console: 501))
        }
        XCTAssertFalse(PeerHeartbeat(generation: "a", updatedAt: 100, ready: true, blocking: false).isQuiescentController(bootID: nil))
    }
    func testSupervisionIsFastWhileNeededAndForAShortHoldAfterwards() {
        var cadence = SupervisionCadence()
        XCTAssertEqual(cadence.interval(needsSupervision: false, at: 100), ControlConstants.idleSupervisionSeconds)
        XCTAssertEqual(cadence.interval(needsSupervision: true, at: 101), ControlConstants.supervisionSeconds)
        let hold = ControlConstants.supervisionHoldSeconds
        XCTAssertEqual(cadence.interval(needsSupervision: false, at: 101 + hold - 0.1), ControlConstants.supervisionSeconds)
        XCTAssertEqual(cadence.interval(needsSupervision: false, at: 101 + hold), ControlConstants.idleSupervisionSeconds)
        cadence.hold(at: 200)
        XCTAssertEqual(cadence.interval(needsSupervision: false, at: 200.5), ControlConstants.supervisionSeconds)
        XCTAssertEqual(cadence.interval(needsSupervision: false, at: 200 + hold), ControlConstants.idleSupervisionSeconds)
    }
    func testSupervisionWithoutAUsableClockStaysFast() {
        var cadence = SupervisionCadence()
        for now in [Double.infinity, .nan] {
            XCTAssertEqual(cadence.interval(needsSupervision: false, at: now), ControlConstants.supervisionSeconds)
        }
        cadence.hold(at: .infinity)
        XCTAssertEqual(cadence.interval(needsSupervision: false, at: 100), ControlConstants.idleSupervisionSeconds)
    }
    func testIdleRateStaysWithinTheLimitsTheRestOfSupervisionAssumes() {
        XCTAssertLessThan(ControlConstants.supervisionSeconds * 2, ControlConstants.peerTimeoutSeconds)
        XCTAssertGreaterThan(ControlConstants.supervisionHoldSeconds, ControlConstants.supervisionSeconds * 2)
        XCTAssertGreaterThan(ControlConstants.idleSupervisionSeconds, ControlConstants.supervisionHoldSeconds)
        // Start = wake answer + up to 1.5 s kernel confirmation + I/O, within the app's 3 s timeout.
        XCTAssertLessThanOrEqual(ControlConstants.watchdogWakeTimeoutSeconds + 1.5, 2.25)
        // A stall needs several missed idle publications, never one late timer.
        XCTAssertGreaterThanOrEqual(ControlConstants.idleControllerStallSeconds, ControlConstants.idleSupervisionSeconds * 3)
    }
    func testOlderHeartbeatWithoutRestorationFieldNeverCountsAsIdle() throws {
        let legacy = Data(#"{"generation":"a","updatedAt":100,"ready":true,"blocking":false,"isUnlimited":false,"bootID":"\#(CurrentBoot.identifier ?? "")"}"#.utf8)
        let beat = try JSONDecoder().decode(PeerHeartbeat.self, from: legacy)
        XCTAssertNil(beat.restorationPending)
        XCTAssertFalse(beat.isQuiescentController())
        let current = PeerHeartbeat(generation: "a", updatedAt: 100, ready: true, blocking: false)
        let decoded = try JSONDecoder().decode(PeerHeartbeat.self, from: JSONEncoder().encode(current))
        XCTAssertEqual(decoded.restorationPending, false)
        XCTAssertTrue(decoded.isQuiescentController())
    }
    func testIdleControllerThatStopsPublishingIsStalledOnlyAfterAwakeTime() {
        var progress = IdleControllerProgress()
        let idle = PeerHeartbeat(generation: "a", updatedAt: 100, ready: true, blocking: false)
        let stall = ControlConstants.idleControllerStallSeconds
        XCTAssertFalse(progress.isStalled(idle, uptime: 1_000))
        XCTAssertFalse(progress.isStalled(idle, uptime: 1_000 + stall - 1))
        XCTAssertTrue(progress.isStalled(idle, uptime: 1_000 + stall))
        // Any new publication, or a new generation after a restart, resets the measurement.
        let next = PeerHeartbeat(generation: "a", updatedAt: 160, ready: true, blocking: false)
        XCTAssertFalse(progress.isStalled(next, uptime: 2_000))
        XCTAssertFalse(progress.isStalled(next, uptime: 2_000 + stall - 1))
        let restarted = PeerHeartbeat(generation: "b", updatedAt: 160, ready: true, blocking: false)
        XCTAssertFalse(progress.isStalled(restarted, uptime: 2_000 + stall + 1))
    }
    func testSleepAndNonIdleControllersNeverCountAsStalled() {
        var progress = IdleControllerProgress()
        let idle = PeerHeartbeat(generation: "a", updatedAt: 100, ready: true, blocking: false)
        // The uptime clock does not advance while the Mac sleeps, however long the sleep.
        XCTAssertFalse(progress.isStalled(idle, uptime: 500))
        XCTAssertFalse(progress.isStalled(idle, uptime: 501))
        let session = PeerHeartbeat(generation: "a", updatedAt: 100, ready: true, sessionUser: 501, sessionID: "s",
                                    leaseDeadline: 112, sessionDeadline: 400)
        XCTAssertFalse(progress.isStalled(session, uptime: 10_000))
        XCTAssertFalse(progress.isStalled(nil, uptime: 20_000))
        XCTAssertFalse(progress.isStalled(idle, uptime: 30_000), "Tracking restarts after a non-idle heartbeat")
        XCTAssertFalse(progress.isStalled(idle, uptime: .nan))
    }
    func testACLossAllowsBoundedReleaseGraceButCannotKeepStoppedWriter() {
        var monitor = WatchdogAssessment()
        let active = PeerHeartbeat(generation: "a", updatedAt: 100, ready: true, sessionUser: 501, sessionID: "session", leaseDeadline: 112, sessionDeadline: 400)
        XCTAssertFalse(monitor.shouldFence(active, at: 101, ac: false, console: 501))
        XCTAssertFalse(monitor.shouldFence(active, at: 102, ac: nil, console: 501))
        XCTAssertTrue(monitor.shouldFence(active, at: 103, ac: false, console: 501))
    }
    func testControllerCanPreserveWaitingACIntentAndResume() {
        var monitor = WatchdogAssessment()
        let active = PeerHeartbeat(generation: "a", updatedAt: 100, ready: true, sessionUser: 501, sessionID: "session", leaseDeadline: 112, sessionDeadline: 400)
        XCTAssertFalse(monitor.shouldFence(active, at: 101, ac: false, console: 501))
        let waiting = PeerHeartbeat(generation: "a", updatedAt: 102, ready: true, sessionUser: 501, sessionID: "session", leaseDeadline: 114, sessionDeadline: 400, blocking: false)
        XCTAssertFalse(monitor.shouldFence(waiting, at: 102, ac: false, console: 501))
        XCTAssertFalse(monitor.shouldFence(waiting, at: 103, ac: true, console: 501))
    }
    func testACGraceNeverDelaysUserSwitchOrExpiredLease() {
        var monitor = WatchdogAssessment()
        let beat = PeerHeartbeat(generation: "a", updatedAt: 100, ready: true, sessionUser: 501, sessionID: "session", leaseDeadline: 102, sessionDeadline: 400)
        XCTAssertFalse(monitor.shouldFence(beat, at: 101, ac: false, console: 501))
        XCTAssertTrue(monitor.shouldFence(beat, at: 101.1, ac: false, console: 502))
        XCTAssertTrue(monitor.shouldFence(beat, at: 102, ac: false, console: 501))
    }
    func testWatchdogLetsFreshControllerEndTimedSessionBeforeFencing() {
        // The controller ticks once per second; the deadline can pass before it publishes the end.
        var monitor = WatchdogAssessment()
        let ending = PeerHeartbeat(generation: "a", updatedAt: 101.6, ready: true, sessionUser: 501, sessionID: "session", leaseDeadline: 112, sessionDeadline: 102)
        XCTAssertFalse(monitor.shouldFence(ending, at: 102.3, ac: true, console: 501))
        XCTAssertFalse(monitor.shouldFence(ending, at: 105.9, ac: true, console: 501))
        let ended = PeerHeartbeat(generation: "a", updatedAt: 103, ready: true, blocking: false)
        XCTAssertFalse(monitor.shouldFence(ended, at: 103.1, ac: true, console: 501))
    }
    func testSessionEndGraceIsBoundedAndKeepsOtherChecksImmediate() {
        var monitor = WatchdogAssessment()
        let ending = PeerHeartbeat(generation: "a", updatedAt: 101.6, ready: true, sessionUser: 501, sessionID: "session", leaseDeadline: 112, sessionDeadline: 102)
        XCTAssertTrue(monitor.shouldFence(ending, at: 102 + ControlConstants.sessionEndGraceSeconds, ac: true, console: 501))
        XCTAssertTrue(monitor.shouldFence(ending, at: 102.3, ac: true, console: 502))
        let staleEnding = PeerHeartbeat(generation: "a", updatedAt: 94, ready: true, sessionUser: 501, sessionID: "session", leaseDeadline: 112, sessionDeadline: 102)
        XCTAssertTrue(monitor.shouldFence(staleEnding, at: 102.3, ac: true, console: 501))
        let leaseEnding = PeerHeartbeat(generation: "a", updatedAt: 101.6, ready: true, sessionUser: 501, sessionID: "session", leaseDeadline: 102, sessionDeadline: 102)
        XCTAssertTrue(monitor.shouldFence(leaseEnding, at: 102.3, ac: true, console: 501))
        XCTAssertLessThan(ControlConstants.sessionEndGraceSeconds, ControlConstants.peerTimeoutSeconds)
    }
    func testSessionEndGraceKeepsEnvironmentAndBatteryCutoffs() {
        var acOnly = WatchdogAssessment()
        let ending = PeerHeartbeat(generation: "a", updatedAt: 101.6, ready: true, sessionUser: 501, sessionID: "session", leaseDeadline: 112, sessionDeadline: 102)
        XCTAssertFalse(acOnly.shouldFence(ending, at: 102.3, ac: false, console: 501))
        XCTAssertTrue(acOnly.shouldFence(ending, at: 104.3, ac: false, console: 501))
        var battery = WatchdogAssessment()
        let onBattery = PeerHeartbeat(generation: "a", updatedAt: 101.6, ready: true, sessionUser: 501, sessionID: "session", leaseDeadline: 112, sessionDeadline: 102, minimumBatteryPercent: 20)
        XCTAssertFalse(battery.shouldFence(onBattery, at: 102.3, ac: false, console: 501, batteryPercent: 19, thermalSafe: true))
        XCTAssertFalse(battery.shouldFence(onBattery, at: 103.3, ac: true, console: 501))
        XCTAssertTrue(battery.shouldFence(onBattery, at: 104.3, ac: true, console: 501))
    }
    func testSessionEndGraceDoesNotApplyToUnlimitedSessions() {
        var monitor = WatchdogAssessment()
        let unlimited = PeerHeartbeat(generation: "a", updatedAt: 101.6, ready: true, sessionUser: 501, sessionID: "session", leaseDeadline: 112, isUnlimited: true)
        XCTAssertFalse(monitor.shouldFence(unlimited, at: 102.3, ac: true, console: 501))
        let malformed = PeerHeartbeat(generation: "a", updatedAt: 101.6, ready: true, sessionUser: 501, sessionID: "session", leaseDeadline: 112, sessionDeadline: 102, isUnlimited: true)
        XCTAssertTrue(monitor.shouldFence(malformed, at: 101.7, ac: true, console: 501))
        XCTAssertTrue(monitor.shouldFence(unlimited, at: 112, ac: true, console: 501))
    }
    func testTrustRequirementRejectsBroadenedExpressionsAndWrongIdentity() {
        let exact = "identifier \"com.keepmacawake\" and cdhash H\"" + String(repeating: "a", count: 40) + "\""
        XCTAssertTrue(TrustRequirements.isExact(exact, identifier: "com.keepmacawake"))
        XCTAssertFalse(TrustRequirements.isExact(exact + " or true", identifier: "com.keepmacawake"))
        XCTAssertFalse(TrustRequirements.isExact(exact, identifier: "com.keepmacawake.Helper"))
        XCTAssertFalse(TrustRequirements.isExact("cdhash H\"abcd\"", identifier: "com.keepmacawake"))
    }
    func testRecoveryNeverWaitsOnLockBeforeFencingStoppedWriter() throws {
        var order: [String] = []
        let recovery = FencedRecovery(fence: { order.append("kill-stopped-writer") }, restore: { order.append("nonblocking-lock-and-restore") })
        try recovery.attempt()
        XCTAssertEqual(order, ["kill-stopped-writer", "nonblocking-lock-and-restore"])
        XCTAssertFalse(recovery.pending)
    }
    func testFailedFenceDoesNotAttemptRecovery() {
        var restored = false
        let recovery = FencedRecovery(fence: { throw Failure.simulated }, restore: { restored = true })
        XCTAssertThrowsError(try recovery.attempt())
        XCTAssertFalse(restored)
        XCTAssertTrue(recovery.pending)
    }
    func testBusyLockRetriesWithoutUnfencingOldWriter() throws {
        var fences = 0, restores = 0
        let recovery = FencedRecovery(fence: { fences += 1 }, restore: {
            restores += 1
            if restores == 1 { throw Failure.simulated }
        })
        XCTAssertThrowsError(try recovery.attempt())
        XCTAssertTrue(recovery.pending)
        try recovery.attempt()
        XCTAssertEqual(fences, 1)
        XCTAssertEqual(restores, 2)
        XCTAssertFalse(recovery.pending)
    }
}
