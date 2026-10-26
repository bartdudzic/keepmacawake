import XCTest
import KeepMacAwakeControlProtocol
@testable import KeepMacAwakeServiceSupport

final class BatterySessionPolicyTests: XCTestCase {
    private let owner = UUID()
    private func make(percent: Int? = 50, ac: Bool? = false) -> (SessionPolicy, SessionPolicyTests.Backend, SessionPolicyTests.Clock) {
        let backend = SessionPolicyTests.Backend(), clock = SessionPolicyTests.Clock()
        clock.value.acPower = ac
        clock.value.batteryPercent = percent
        clock.value.thermalSafe = true
        return (SessionPolicy(backend: backend, snapshot: { clock.value }), backend, clock)
    }
    private func start(_ policy: SessionPolicy, threshold: Int? = 20, duration: Int = 3600) -> ControlStatus {
        policy.handle(ControlRequest(.start, durationSeconds: duration, minimumBatteryPercent: threshold), connection: owner, user: 501)
    }
    func testBatteryStartsOnlyStrictlyAboveSelectedThreshold() {
        for percent in [19, 20, 21, 100] {
            let (policy, backend, _) = make(percent: percent)
            let status = start(policy)
            XCTAssertEqual(status.phase == .active, percent > 20)
            XCTAssertEqual(backend.active, percent > 20)
            if percent <= 20 { XCTAssertTrue(backend.operations.isEmpty) }
            else { XCTAssertEqual(status.minimumBatteryPercent, 20) }
        }
    }
    func testThresholdRestoresAndEndsIntentInsteadOfResumingOnACOrRebound() {
        let (policy, backend, clock) = make(percent: 21)
        let token = start(policy).sessionID
        XCTAssertNotNil(token)
        clock.value.batteryPercent = 20
        policy.tick()
        XCTAssertEqual(policy.status.phase, .idle)
        XCTAssertEqual(policy.status.terminationReason, .batteryThresholdReached)
        XCTAssertNil(policy.status.sessionID)
        XCTAssertTrue(policy.status.message.contains("20%"))
        XCTAssertFalse(backend.active)
        XCTAssertEqual(backend.operations, ["activate", "restore"])
        clock.value.batteryPercent = 21; clock.value.acPower = true
        policy.tick()
        _ = policy.handle(ControlRequest(.renew, sessionID: token), connection: owner, user: 501)
        XCTAssertFalse(backend.active)
    }
    func testACCanStartBelowThresholdAndThenContinueOnBatteryAboveThreshold() {
        let (policy, backend, clock) = make(percent: 5, ac: true)
        XCTAssertEqual(start(policy).phase, .active)
        clock.value.batteryPercent = 60; clock.value.acPower = false
        policy.tick()
        XCTAssertTrue(backend.active)
        XCTAssertEqual(backend.operations, ["activate"])
        clock.value.acPower = true; policy.tick()
        XCTAssertTrue(backend.active)
    }
    func testDefaultStillRequiresACAndPreservesWaitingIntent() {
        let (policy, backend, clock) = make()
        XCTAssertNotEqual(start(policy, threshold: nil).phase, .active)
        clock.value.acPower = true
        let token = start(policy, threshold: nil).sessionID
        clock.value.acPower = false; policy.tick()
        XCTAssertEqual(policy.status.phase, .waitingForAC)
        XCTAssertEqual(policy.status.sessionID, token)
        XCTAssertFalse(backend.active)
        clock.value.acPower = true; policy.tick()
        XCTAssertTrue(backend.active)
    }
    func testUnknownOrMalformedBatteryNeverAuthorizesAndEndsRunningBatterySession() {
        for percent: Int? in [nil, -1, 101] {
            let (policy, backend, clock) = make(percent: percent)
            XCTAssertNotEqual(start(policy).phase, .active)
            XCTAssertTrue(backend.operations.isEmpty)
            clock.value.acPower = true; _ = start(policy)
            clock.value.acPower = false; policy.tick()
            XCTAssertFalse(backend.active)
            XCTAssertNil(policy.status.sessionID)
            XCTAssertEqual(policy.status.terminationReason, .batteryUnknown)
        }
    }
    func testUnknownSourceAndThermalLimitEndBatterySession() {
        for unknownPower in [false, true] {
            let (policy, backend, clock) = make()
            _ = start(policy)
            if unknownPower { clock.value.acPower = nil }
            else { clock.value.thermalSafe = false }
            policy.tick()
            XCTAssertFalse(backend.active)
            XCTAssertNil(policy.status.sessionID)
            XCTAssertEqual(policy.status.terminationReason, unknownPower ? .powerUnknown : .thermalUnsafe)
        }
    }
    func testRechecksPercentAndThermalConditionsInsideActivationLock() {
        for thermal in [false, true] {
            let (policy, backend, clock) = make()
            backend.beforeActivate = {
                if thermal { clock.value.thermalSafe = false }
                else { clock.value.batteryPercent = 20 }
            }
            XCTAssertNotEqual(start(policy).phase, .active)
            XCTAssertFalse(backend.active)
            XCTAssertFalse(backend.operations.contains("activate"))
        }
    }
    func testInvalidThresholdAndRenewConfigurationCannotChangeSession() {
        let (policy, backend, _) = make()
        for bad in [0, -1, 101, Int.max] { XCTAssertNil(start(policy, threshold: bad).sessionID) }
        XCTAssertTrue(backend.operations.isEmpty)
        let token = start(policy).sessionID
        let reply = policy.handle(ControlRequest(.renew, sessionID: token, minimumBatteryPercent: 1), connection: owner, user: 501)
        XCTAssertEqual(reply.phase, .failed)
        XCTAssertEqual(policy.status.minimumBatteryPercent, 20)
    }
    func testUnlimitedSessionHasExplicitStatusAndFiniteLeaseThatStillExpires() {
        let (policy, backend, clock) = make()
        let started = start(policy, duration: 0)
        XCTAssertEqual(started.phase, .active)
        XCTAssertTrue(started.isUnlimited)
        XCTAssertNil(started.remainingSeconds)
        XCTAssertNil(policy.sessionDeadline)
        XCTAssertEqual(policy.leaseDeadline, 112)
        for time in stride(from: 105.0, through: 30_000.0, by: 5) {
            clock.value.now = time
            let status = policy.handle(ControlRequest(.renew, sessionID: started.sessionID), connection: owner, user: 501)
            XCTAssertEqual(status.phase, .active)
        }
        XCTAssertTrue(backend.active)
        clock.value.now += 12; policy.tick()
        XCTAssertFalse(backend.active)
        XCTAssertNil(policy.status.sessionID)
    }
    func testCutoffRestoreFailureRetriesWithoutReauthorizingBattery() {
        let (policy, backend, clock) = make()
        _ = start(policy)
        backend.failRestore = true; clock.value.batteryPercent = 20
        policy.tick()
        XCTAssertTrue(policy.requiresRestoration)
        XCTAssertEqual(policy.status.phase, .failed)
        XCTAssertEqual(policy.status.terminationReason, .batteryThresholdReached)
        XCTAssertNil(policy.status.sessionID)
        backend.failRestore = false; clock.value.acPower = true
        policy.tick()
        XCTAssertFalse(backend.active)
        XCTAssertFalse(policy.requiresRestoration)
        XCTAssertEqual(policy.status.terminationReason, .batteryThresholdReached)
    }
    func testRenewReturnsCutoffReasonEvenAfterEarlierBackgroundTick() {
        let (policy, backend, clock) = make(percent: 21)
        let token = start(policy).sessionID
        clock.value.batteryPercent = 20; policy.tick()
        let result = policy.handle(ControlRequest(.renew, sessionID: token), connection: owner, user: 501)
        XCTAssertEqual(result.phase, .idle)
        XCTAssertTrue(result.message.contains("20%"))
        XCTAssertFalse(backend.active)
        let stranger = policy.handle(ControlRequest(.renew, sessionID: token), connection: UUID(), user: 501)
        XCTAssertEqual(stranger.phase, .failed)
    }
    func testRenewReturnsCutoffReasonWhenItDetectsCutoff() {
        let (policy, _, clock) = make(percent: 21)
        let token = start(policy).sessionID
        clock.value.batteryPercent = 20
        let result = policy.handle(ControlRequest(.renew, sessionID: token), connection: owner, user: 501)
        XCTAssertEqual(result.phase, .idle)
        XCTAssertTrue(result.message.contains("20%"))
    }
    func testThreshold100AllowsFastACUnplugCutoffWithoutBatteryDrain() {
        let (policy, backend, clock) = make(percent: 100, ac: true)
        XCTAssertEqual(start(policy, threshold: 100).phase, .active)
        clock.value.acPower = false; policy.tick()
        XCTAssertFalse(backend.active)
        XCTAssertEqual(policy.status.phase, .idle)
        XCTAssertTrue(policy.status.message.contains("100%"))
    }
}
