import XCTest
import KeepMacAwakeControlProtocol
@testable import KeepMacAwakeServiceSupport

final class SessionPolicyTests: XCTestCase {
    final class Backend: SessionBackend {
        var active = false
        var operations: [String] = []
        var failRestore = false
        var failVerification = false
        var beforeActivate: (() -> Void)?
        func activate(authorized: () -> Bool) throws {
            beforeActivate?()
            guard authorized() else { throw Failure.denied }
            operations.append("activate"); active = true
        }
        func restore() throws {
            operations.append("restore")
            if failRestore { throw Failure.denied }
            active = false
        }
        func verifyActive() throws -> Bool { active && !failVerification }
        enum Failure: Error { case denied }
    }
    final class Clock {
        var value = SafetySnapshot(now: 100, acPower: true, consoleUser: 501, watchdogGeneration: "watchdog-1", watchdogFresh: true)
    }
    let owner = UUID()
    func make() -> (SessionPolicy, Backend, Clock) {
        let backend = Backend(), clock = Clock()
        return (SessionPolicy(backend: backend, snapshot: { clock.value }), backend, clock)
    }
    func start(_ policy: SessionPolicy, duration: Int = 3600) -> ControlStatus {
        policy.handle(ControlRequest(.start, durationSeconds: duration), connection: owner, user: 501)
    }
    func testExplicitStartChangesBackendAndReturnsRandomSession() {
        let (policy, backend, _) = make()
        XCTAssertFalse(backend.active)
        let result = start(policy)
        XCTAssertEqual(result.phase, .active)
        XCTAssertNotNil(result.sessionID)
        XCTAssertEqual(result.remainingSeconds, 3600)
        XCTAssertEqual(backend.operations, ["activate"])
    }
    /// The app treats a failed Start reply without session token or termination
    /// reason as a refusal that changed nothing. Every refusal path must keep that shape.
    func testStartRefusalsCarryNoSessionOrReasonAndNeverTouchTheBackend() {
        let cases: [(String, (SessionPolicy, Clock) -> ControlStatus)] = [
            ("AC-only on battery", { policy, clock in clock.value.acPower = false; return self.start(policy) }),
            ("unknown power", { policy, clock in clock.value.acPower = nil; return self.start(policy) }),
            ("stale watchdog", { policy, clock in clock.value.watchdogFresh = false; return self.start(policy) }),
            ("invalid duration", { policy, _ in self.start(policy, duration: 301) }),
            ("other console user", { policy, clock in clock.value.consoleUser = 502; return self.start(policy) }),
            ("battery at threshold", { policy, clock in
                clock.value.acPower = false; clock.value.batteryPercent = 20; clock.value.thermalSafe = true
                return policy.handle(ControlRequest(.start, durationSeconds: 3600, minimumBatteryPercent: 20), connection: self.owner, user: 501)
            }),
        ]
        for (label, refuse) in cases {
            let (policy, backend, clock) = make()
            let result = refuse(policy, clock)
            XCTAssertEqual(result.phase, .failed, label)
            XCTAssertNil(result.sessionID, label)
            XCTAssertNil(result.terminationReason, label)
            XCTAssertTrue(backend.operations.isEmpty, label)
        }
        let (policy, backend, _) = make()
        let first = start(policy)
        XCTAssertNotNil(first.sessionID)
        let second = policy.handle(ControlRequest(.start, durationSeconds: 3600), connection: UUID(), user: 501)
        XCTAssertEqual(second.phase, .failed)
        XCTAssertNil(second.sessionID)
        XCTAssertNil(second.terminationReason, "A concurrent session refusal is also a refusal")
        XCTAssertEqual(backend.operations, ["activate"])
    }
    func testFailuresAfterSessionCreationAlwaysCarryAReason() {
        let (policy, backend, clock) = make()
        backend.beforeActivate = { clock.value.watchdogFresh = false }
        let activation = start(policy)
        XCTAssertEqual(activation.phase, .failed)
        XCTAssertEqual(activation.terminationReason, .backendActivationFailed)
        let (verifying, verifyingBackend, _) = make()
        verifyingBackend.failVerification = true
        let verification = start(verifying)
        XCTAssertEqual(verification.phase, .failed)
        XCTAssertEqual(verification.terminationReason, .backendVerificationFailed)
    }
    func testACOnlyRefusalOnBatteryExplainsHowToProceed() {
        let (policy, _, clock) = make()
        clock.value.acPower = false
        let result = start(policy)
        XCTAssertTrue(result.message.contains("battery use is off"), result.message)
        XCTAssertTrue(result.message.contains("Run on battery"), result.message)
    }
    func testUnknownPowerRefusalDoesNotClaimACIsDisconnected() {
        let (policy, backend, clock) = make()
        clock.value.acPower = nil
        let result = start(policy)
        XCTAssertTrue(result.message.contains("could not be confirmed"), result.message)
        XCTAssertFalse(result.message.contains("not connected"), result.message)
        XCTAssertTrue(backend.operations.isEmpty)
    }
    func testUnknownPowerAndStaleWatchdogNeverEnable() {
        for unsafe in [0, 1] {
            let (policy, backend, clock) = make()
            if unsafe == 0 { clock.value.acPower = nil } else { clock.value.watchdogFresh = false }
            XCTAssertNotEqual(start(policy).phase, .active)
            XCTAssertTrue(backend.operations.isEmpty)
        }
    }
    func testConsoleAndDurationAreValidated() {
        let (policy, backend, clock) = make()
        for duration in [-3600, 301, 300, 1800, 5400, 169 * 3600, Int.max, Int.min] {
            XCTAssertNil(start(policy, duration: duration).sessionID, "\(duration)")
        }
        clock.value.consoleUser = 502
        XCTAssertNil(start(policy).sessionID)
        XCTAssertTrue(backend.operations.isEmpty)
    }
    func testTimedSessionsLastWholeHoursUpToOneWeek() {
        for hours in [1, 8, 13, 24, 168] {
            let (policy, _, _) = make()
            XCTAssertEqual(start(policy, duration: hours * 3600).remainingSeconds, hours * 3600, "\(hours) h")
        }
    }
    func testSupervisionIsNeededFromStartUntilTheSettingIsRestored() {
        let (policy, backend, clock) = make()
        XCTAssertFalse(policy.needsSupervision)
        let session = start(policy).sessionID!
        XCTAssertTrue(policy.needsSupervision)
        clock.value.acPower = nil; policy.tick()
        XCTAssertEqual(policy.status.phase, .waitingForAC)
        XCTAssertTrue(policy.needsSupervision, "A session waiting for AC is still a session")
        clock.value.acPower = true; policy.tick()
        backend.failRestore = true
        _ = policy.handle(ControlRequest(.stop, sessionID: session), connection: owner, user: 501)
        XCTAssertTrue(policy.needsSupervision, "A failed restoration keeps supervision at full rate")
        backend.failRestore = false; policy.tick()
        XCTAssertFalse(policy.needsSupervision)
        XCTAssertFalse(backend.active)
    }
    func testControllerHeartbeatIsIdleOnlyWithNothingToRestore() {
        let (policy, backend, clock) = make()
        func beat() -> PeerHeartbeat { policy.controllerHeartbeat(generation: "g", updatedAt: clock.value.now, ready: true) }
        XCTAssertTrue(beat().isQuiescentController())
        let session = start(policy).sessionID!
        XCTAssertFalse(beat().isQuiescentController())
        XCTAssertTrue(beat().blocking)
        clock.value.acPower = nil; policy.tick()
        XCTAssertEqual(policy.status.phase, .waitingForAC)
        XCTAssertFalse(beat().blocking)
        XCTAssertFalse(beat().isQuiescentController(), "Waiting for AC still carries the session")
        clock.value.acPower = true; policy.tick()
        backend.failRestore = true
        _ = policy.handle(ControlRequest(.stop, sessionID: session), connection: owner, user: 501)
        XCTAssertEqual(policy.status.phase, .failed)
        XCTAssertNil(beat().sessionID)
        XCTAssertFalse(beat().blocking)
        XCTAssertEqual(beat().restorationPending, true)
        XCTAssertFalse(beat().isQuiescentController(), "A failed restoration must never look idle")
        backend.failRestore = false; policy.tick()
        XCTAssertTrue(beat().isQuiescentController())
        XCTAssertFalse(policy.controllerHeartbeat(generation: "g", updatedAt: clock.value.now, ready: false).isQuiescentController())
    }
    func testNaturalEndAndRefusedStartLeaveNothingToSupervise() {
        let (policy, _, clock) = make()
        _ = start(policy)
        for time in stride(from: 105.0, through: 3705.0, by: 5.0) {
            clock.value.now = time
            _ = policy.handle(ControlRequest(.renew, sessionID: policy.sessionIdentifier), connection: owner, user: 501)
        }
        XCTAssertEqual(policy.status.terminationReason, .durationElapsed)
        XCTAssertFalse(policy.needsSupervision)
        let (refusing, _, refusingClock) = make()
        refusingClock.value.watchdogFresh = false
        XCTAssertNil(start(refusing).sessionID)
        XCTAssertFalse(refusing.needsSupervision)
    }
    func testLeaseExpiryCannotBeRevivedByLateRenewal() {
        let (policy, backend, clock) = make()
        let session = start(policy).sessionID!
        clock.value.now += 12
        let result = policy.handle(ControlRequest(.renew, sessionID: session), connection: owner, user: 501)
        XCTAssertNil(result.sessionID)
        XCTAssertFalse(backend.active)
        XCTAssertEqual(backend.operations, ["activate", "restore"])
        XCTAssertEqual(result.terminationReason, .leaseExpired)
    }
    func testAnotherConnectionCannotRenewOrStopOrReadSessionToken() {
        let (policy, backend, clock) = make()
        let session = start(policy).sessionID!
        let stranger = UUID()
        for kind in [ControlRequest.Kind.renew, .stop, .status] {
            XCTAssertNil(policy.handle(ControlRequest(kind, sessionID: session), connection: stranger, user: 501).sessionID)
        }
        XCTAssertTrue(backend.active)
        clock.value.now += 12
        policy.tick()
        XCTAssertFalse(backend.active)
    }
    func testACLossRestoresAndFreshLeaseCanResumeOnAC() {
        let (policy, backend, clock) = make()
        let session = start(policy).sessionID!
        clock.value.acPower = nil; policy.tick()
        XCTAssertEqual(policy.status.phase, .waitingForAC)
        XCTAssertFalse(backend.active)
        clock.value.now += 2
        _ = policy.handle(ControlRequest(.renew, sessionID: session), connection: owner, user: 501)
        clock.value.acPower = true; policy.tick()
        XCTAssertTrue(backend.active)
        XCTAssertEqual(backend.operations, ["activate", "restore", "activate"])
    }
    func testFailedReleaseOnACLossKeepsTheIntentAndRetries() {
        let (policy, backend, clock) = make()
        func beat() -> PeerHeartbeat { policy.controllerHeartbeat(generation: "g", updatedAt: clock.value.now, ready: true) }
        let session = start(policy).sessionID!
        backend.failRestore = true
        clock.value.acPower = false; policy.tick()
        XCTAssertEqual(policy.status.phase, .waitingForAC)
        XCTAssertEqual(policy.status.sessionID, session, "One failed release does not end the session")
        XCTAssertNil(policy.status.terminationReason)
        XCTAssertTrue(beat().blocking, "The setting may still be on, so only the watchdog's release grace applies")
        clock.value.now += 1; policy.tick()
        XCTAssertEqual(policy.status.sessionID, session)
        backend.failRestore = false
        clock.value.now += 1; policy.tick()
        XCTAssertEqual(policy.status.phase, .waitingForAC)
        XCTAssertFalse(backend.active)
        XCTAssertFalse(beat().blocking)
        _ = policy.handle(ControlRequest(.renew, sessionID: session), connection: owner, user: 501)
        clock.value.acPower = true; policy.tick()
        XCTAssertEqual(policy.status.phase, .active)
        XCTAssertEqual(policy.status.sessionID, session)
        XCTAssertEqual(backend.operations, ["activate", "restore", "restore", "restore", "activate"])
    }
    func testACReturningBeforeTheReleaseRestoresFirst() {
        let (policy, backend, clock) = make()
        let session = start(policy).sessionID!
        backend.failRestore = true
        clock.value.acPower = false; policy.tick()
        backend.failRestore = false
        clock.value.acPower = true; policy.tick()
        XCTAssertEqual(policy.status.phase, .active)
        XCTAssertEqual(policy.status.sessionID, session)
        XCTAssertEqual(backend.operations, ["activate", "restore", "restore", "activate"])

        let (failing, failingBackend, failingClock) = make()
        _ = start(failing)
        failingBackend.failRestore = true
        failingClock.value.acPower = false; failing.tick()
        failingClock.value.acPower = true; failing.tick()
        XCTAssertEqual(failing.status.phase, .failed, "An unconfirmed release with AC back ends the session")
        XCTAssertNil(failing.status.sessionID)
        XCTAssertEqual(failing.status.terminationReason, .recoveryFailed)
        XCTAssertEqual(failingBackend.operations, ["activate", "restore", "restore"])
        XCTAssertTrue(failing.needsSupervision)
    }
    func testOnlyAStartThatPassedEveryOtherCheckWaitsForTheWatchdog() {
        let (policy, backend, clock) = make()
        var waits = 0
        let confirm = { () -> Bool in waits += 1; return true }
        func start(_ duration: Int, connection: UUID) -> ControlStatus {
            policy.handle(ControlRequest(.start, durationSeconds: duration), connection: connection, user: 501, confirmWatchdog: confirm)
        }
        clock.value.acPower = false
        XCTAssertNil(start(3600, connection: owner).sessionID)
        clock.value.acPower = true
        XCTAssertNil(start(301, connection: owner).sessionID)
        XCTAssertEqual(waits, 0)
        XCTAssertNotNil(start(3600, connection: owner).sessionID)
        XCTAssertEqual(waits, 1)
        let second = start(3600, connection: UUID())
        XCTAssertEqual(second.message, "Another session or a recovery is still in progress. Try again in a moment.")
        XCTAssertEqual(waits, 1)
        XCTAssertEqual(backend.operations, ["activate"])
    }
    func testAStartIsRefusedWithoutTheWatchdogsAnswerAndUsesItsLatestState() {
        let (policy, backend, clock) = make()
        let unanswered = policy.handle(ControlRequest(.start, durationSeconds: 3600), connection: owner, user: 501,
                                       confirmWatchdog: { false })
        XCTAssertEqual(unanswered.phase, .failed)
        XCTAssertNil(unanswered.sessionID)
        XCTAssertNil(unanswered.terminationReason)
        XCTAssertFalse(policy.needsSupervision)
        let stale = policy.handle(ControlRequest(.start, durationSeconds: 3600), connection: owner, user: 501,
                                  confirmWatchdog: { clock.value.watchdogFresh = false; return true })
        XCTAssertNil(stale.sessionID)
        XCTAssertTrue(backend.operations.isEmpty)
        clock.value.watchdogFresh = true
        for change in [{ clock.value.acPower = false }, { clock.value.consoleUser = 502 }] {
            let changed = policy.handle(ControlRequest(.start, durationSeconds: 3600), connection: owner, user: 501,
                                        confirmWatchdog: { change(); return true })
            XCTAssertEqual(changed.phase, .failed, "A Start refused after the wait never becomes a session")
            XCTAssertNil(changed.sessionID)
            XCTAssertNil(changed.terminationReason)
            XCTAssertFalse(policy.needsSupervision)
            clock.value.acPower = true; clock.value.consoleUser = 501
        }
        XCTAssertTrue(backend.operations.isEmpty)
        // The generation read after the wait is the one the session follows.
        let restarted = policy.handle(ControlRequest(.start, durationSeconds: 3600), connection: owner, user: 501,
                                      confirmWatchdog: { clock.value.watchdogGeneration = "watchdog-2"; clock.value.now += 0.5; return true })
        XCTAssertEqual(restarted.phase, .active)
        XCTAssertEqual(restarted.remainingSeconds, 3600)
    }
    func testUserSwitchWatchdogRestartAndDisconnectEndIntent() {
        for cause in [0, 1, 2, 3] {
            let (policy, backend, clock) = make()
            _ = start(policy)
            switch cause {
            case 0: clock.value.consoleUser = 502
            case 1: clock.value.watchdogGeneration = "watchdog-2"
            case 2: policy.disconnected(owner)
            default: clock.value.watchdogFresh = false
            }
            policy.tick()
            XCTAssertFalse(backend.active)
            XCTAssertNil(policy.status.sessionID)
            clock.value.consoleUser = 501; clock.value.watchdogFresh = true
            policy.tick()
            XCTAssertFalse(backend.active)
        }
    }
    func testDeadlineDoesNotExtendWithRenewals() {
        let (policy, backend, clock) = make()
        let session = start(policy).sessionID!
        for time in stride(from: 105.0, through: 3705.0, by: 5.0) {
            clock.value.now = time
            _ = policy.handle(ControlRequest(.renew, sessionID: session), connection: owner, user: 501)
        }
        XCTAssertFalse(backend.active)
        XCTAssertNil(policy.status.sessionID)
    }
    func testFailedRestorationKeepsRetryingWithoutResurrectingSession() {
        let (policy, backend, _) = make()
        _ = start(policy); backend.failRestore = true
        policy.disconnected(owner)
        XCTAssertEqual(policy.status.phase, .failed)
        XCTAssertEqual(policy.status.terminationReason, .disconnected)
        XCTAssertNil(policy.status.sessionID)
        backend.failRestore = false; policy.tick()
        XCTAssertFalse(backend.active)
        XCTAssertNil(policy.status.sessionID)
        XCTAssertEqual(policy.status.terminationReason, .disconnected)
    }
    func testDurationAndLeaseHaveDistinctTerminalCodesAndNewStartResetsCause() {
        let (policy, _, clock) = make()
        _ = start(policy)
        clock.value.now = 112
        policy.tick()
        XCTAssertEqual(policy.status.terminationReason, .leaseExpired)
        clock.value.now = 120
        _ = start(policy)
        XCTAssertNil(policy.status.terminationReason)
        for time in stride(from: 130.0, through: 3730.0, by: 10) {
            clock.value.now = time
            _ = policy.handle(ControlRequest(.renew, sessionID: policy.sessionIdentifier), connection: owner, user: 501)
        }
        XCTAssertEqual(policy.status.terminationReason, .durationElapsed)
    }
    func testWatchdogAndConsoleCodesComeFromSeparateObservedChecks() {
        let cases: [((Clock) -> Void, ControlStatus.TerminationReason)] = [
            ({ $0.value.consoleUser = 502 }, .consoleUserChanged),
            ({ $0.value.watchdogFresh = false }, .watchdogUnavailable),
            ({ $0.value.watchdogGeneration = "watchdog-2" }, .watchdogRestarted)
        ]
        for (change, reason) in cases {
            let (policy, _, clock) = make()
            _ = start(policy)
            change(clock)
            policy.tick()
            XCTAssertEqual(policy.status.terminationReason, reason)
        }
    }
    func testVerificationFailureSurvivesFailedThenSuccessfulRestoration() {
        let (policy, backend, _) = make()
        backend.failVerification = true
        backend.failRestore = true
        let result = start(policy)
        XCTAssertEqual(result.phase, .failed)
        XCTAssertEqual(result.terminationReason, .backendVerificationFailed)
        backend.failRestore = false
        policy.tick()
        XCTAssertEqual(policy.status.terminationReason, .backendVerificationFailed)
        policy.recoveryDidComplete()
        XCTAssertEqual(policy.status.phase, .idle)
        XCTAssertEqual(policy.status.terminationReason, .backendVerificationFailed)
    }
    func testClientStopAndExternalRecoveryKeepObservedCodes() {
        let (policy, _, _) = make()
        let token = start(policy).sessionID
        let stopped = policy.handle(ControlRequest(.stop, sessionID: token), connection: owner, user: 501)
        XCTAssertEqual(stopped.phase, .idle)
        XCTAssertEqual(stopped.terminationReason, .clientStopped)
        _ = start(policy)
        policy.suspendForRecovery("watchdog stalled", reason: .watchdogUnavailable)
        XCTAssertEqual(policy.status.phase, .restoring)
        XCTAssertEqual(policy.status.terminationReason, .watchdogUnavailable)
        policy.recoveryDidComplete()
        XCTAssertEqual(policy.status.terminationReason, .watchdogUnavailable)
    }
    func testTokenlessNoOpStopCannotReplayPreviousSessionReason() {
        let (policy, _, clock) = make()
        let token = start(policy).sessionID
        clock.value.now = 112
        policy.tick()
        XCTAssertEqual(policy.status.terminationReason, .leaseExpired)
        let noOp = policy.handle(ControlRequest(.stop), connection: owner, user: 501)
        XCTAssertEqual(noOp.phase, .idle)
        XCTAssertNil(noOp.terminationReason)
        let owned = policy.handle(ControlRequest(.stop, sessionID: token), connection: owner, user: 501)
        XCTAssertEqual(owned.terminationReason, .leaseExpired)
        XCTAssertNil(policy.retainedTerminationReason(sessionID: nil, connection: owner, user: 501))
        XCTAssertNil(policy.retainedTerminationReason(sessionID: token, connection: UUID(), user: 501))
        XCTAssertNil(policy.retainedTerminationReason(sessionID: token, connection: owner, user: 502))
        XCTAssertEqual(policy.retainedTerminationReason(sessionID: token, connection: owner, user: 501), .leaseExpired)
        clock.value.acPower = nil
        XCTAssertEqual(start(policy).phase, .failed)
        XCTAssertNil(policy.handle(ControlRequest(.stop), connection: owner, user: 501).terminationReason)
    }
    func testPowerIsCheckedAgainInsideBackendLock() {
        let (policy, backend, clock) = make()
        backend.beforeActivate = { clock.value.acPower = false }
        XCTAssertNotEqual(start(policy).phase, .active)
        XCTAssertFalse(backend.active)
    }
}
