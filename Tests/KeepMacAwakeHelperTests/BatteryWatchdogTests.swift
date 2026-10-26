import XCTest
@testable import KeepMacAwakeServiceSupport

final class BatteryWatchdogTests: XCTestCase {
    private func beat(threshold: Int? = 20, unlimited: Bool = false, deadline: Double? = 400, lease: Double = 112,
                      sessionID: String? = "session", blocking: Bool = true) -> PeerHeartbeat {
        PeerHeartbeat(generation: "controller", updatedAt: 100, ready: true, sessionUser: 501, sessionID: sessionID,
                      leaseDeadline: lease, sessionDeadline: deadline, blocking: blocking, minimumBatteryPercent: threshold, isUnlimited: unlimited)
    }
    func testWatchdogUsesIndependentBatteryAndThermalReading() {
        let heartbeat = beat()
        XCTAssertTrue(heartbeat.controllerIsSafe(at: 101, ac: false, console: 501, batteryPercent: 21, thermalSafe: true))
        for percent: Int? in [nil, -1, 20, 101] {
            XCTAssertFalse(heartbeat.controllerIsSafe(at: 101, ac: false, console: 501, batteryPercent: percent, thermalSafe: true))
        }
        XCTAssertFalse(heartbeat.controllerIsSafe(at: 101, ac: false, console: 501, batteryPercent: 80, thermalSafe: false))
        XCTAssertFalse(heartbeat.controllerIsSafe(at: 101, ac: nil, console: 501, batteryPercent: 80, thermalSafe: true))
        XCTAssertTrue(heartbeat.controllerIsSafe(at: 101, ac: true, console: 501, batteryPercent: 5, thermalSafe: false))
    }
    func testCutoffGraceEndsAndNeverCoversExpiredLeaseOrUserSwitch() {
        var monitor = WatchdogAssessment()
        let heartbeat = beat(lease: 104)
        XCTAssertFalse(monitor.shouldFence(heartbeat, at: 101, ac: false, console: 501, batteryPercent: 20, thermalSafe: true))
        XCTAssertFalse(monitor.shouldFence(heartbeat, at: 102, ac: false, console: 501, batteryPercent: 20, thermalSafe: true))
        XCTAssertTrue(monitor.shouldFence(heartbeat, at: 103, ac: false, console: 501, batteryPercent: 20, thermalSafe: true))
        XCTAssertTrue(monitor.shouldFence(heartbeat, at: 104, ac: false, console: 501, batteryPercent: 21, thermalSafe: true))
        XCTAssertTrue(monitor.shouldFence(heartbeat, at: 101, ac: false, console: 502, batteryPercent: 20, thermalSafe: true))
    }
    func testUnlimitedHeartbeatRequiresExplicitFlagAndLiveLease() {
        XCTAssertTrue(beat(unlimited: true, deadline: nil).controllerIsSafe(at: 101, ac: false, console: 501, batteryPercent: 50, thermalSafe: true))
        XCTAssertFalse(beat(unlimited: false, deadline: nil).controllerIsSafe(at: 101, ac: true, console: 501))
        XCTAssertFalse(beat(unlimited: true, deadline: 400).controllerIsSafe(at: 101, ac: true, console: 501))
        XCTAssertFalse(beat(unlimited: true, deadline: nil, lease: 101).controllerIsSafe(at: 101, ac: true, console: 501))
    }
    func testMalformedThresholdCannotHideBehindACOrGrace() {
        for threshold in [0, 101] {
            var monitor = WatchdogAssessment()
            let heartbeat = beat(threshold: threshold)
            XCTAssertFalse(heartbeat.controllerIsSafe(at: 101, ac: true, console: 501))
            XCTAssertTrue(monitor.shouldFence(heartbeat, at: 101, ac: false, console: 501, batteryPercent: 50, thermalSafe: true))
        }
    }
    func testHeartbeatRoundTripsBatteryModeAndUnlimitedDuration() throws {
        let original = beat(unlimited: true, deadline: nil)
        let decoded = try JSONDecoder().decode(PeerHeartbeat.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded.minimumBatteryPercent, 20)
        XCTAssertTrue(decoded.isUnlimited)
        XCTAssertTrue(decoded.controllerIsSafe(at: 101, ac: false, console: 501, batteryPercent: 21, thermalSafe: true))
    }
    func testObservedBatteryCutoffSurvivesPercentReboundOrACReconnect() {
        for reconnected in [false, true] {
            var monitor = WatchdogAssessment()
            let heartbeat = beat()
            XCTAssertFalse(monitor.shouldFence(heartbeat, at: 101, ac: false, console: 501, batteryPercent: 20, thermalSafe: true))
            XCTAssertFalse(monitor.shouldFence(heartbeat, at: 102, ac: reconnected, console: 501, batteryPercent: 21, thermalSafe: true))
            XCTAssertTrue(monitor.shouldFence(heartbeat, at: 103, ac: reconnected, console: 501, batteryPercent: 21, thermalSafe: true))
        }
    }
    func testCutoffDoesNotApplyToANewExplicitSessionOrDelayExpiredLease() {
        var monitor = WatchdogAssessment()
        XCTAssertFalse(monitor.shouldFence(beat(), at: 101, ac: false, console: 501, batteryPercent: 20, thermalSafe: true))
        XCTAssertFalse(monitor.shouldFence(beat(sessionID: "new-session"), at: 103, ac: true, console: 501))
        XCTAssertFalse(monitor.shouldFence(beat(), at: 104, ac: false, console: 501, batteryPercent: 20, thermalSafe: true))
        XCTAssertTrue(monitor.shouldFence(beat(lease: 104), at: 104, ac: true, console: 501))
    }
    func testCompletedRestorationAndACOnlyReboundCanClearCutoff() {
        var monitor = WatchdogAssessment()
        XCTAssertFalse(monitor.shouldFence(beat(), at: 101, ac: false, console: 501, batteryPercent: 20, thermalSafe: true))
        XCTAssertFalse(monitor.shouldFence(beat(blocking: false), at: 102, ac: true, console: 501))
        XCTAssertFalse(monitor.shouldFence(beat(), at: 103, ac: true, console: 501))
        var acMonitor = WatchdogAssessment()
        XCTAssertFalse(acMonitor.shouldFence(beat(threshold: nil), at: 101, ac: false, console: 501))
        XCTAssertFalse(acMonitor.shouldFence(beat(threshold: nil), at: 103, ac: true, console: 501))
    }
    func testMissingOrMalformedSessionIdentityCannotAuthorizeEvenOnAC() {
        for identifier: String? in [nil, "", String(repeating: "a", count: 129)] {
            XCTAssertFalse(beat(sessionID: identifier).controllerIsSafe(at: 101, ac: true, console: 501))
        }
    }
}
