import XCTest
@testable import KeepMacAwakeServiceSupport

final class FirstSessionRecordTests: XCTestCase {
    private let start = 1_792_454_400
    private let hour = 3600

    func testFirstAcceptedSessionCreatesTheRecord() {
        XCTAssertEqual(FirstSessionRecord.next(after: nil, event: .sessionAccepted, now: start),
                       FirstSessionRecord(firstSessionAt: start, latestSeenAt: start))
    }

    func testOnlyAnAcceptedSessionCreatesIt() {
        XCTAssertNil(FirstSessionRecord.next(after: nil, event: .sessionEnded, now: start))
        XCTAssertNil(FirstSessionRecord.next(after: nil, event: .idleCheck, now: start))
        XCTAssertNil(FirstSessionRecord.next(after: nil, event: .sessionAccepted, now: 0))
    }

    func testSessionEventsRaiseTheLatestTime() {
        let record = FirstSessionRecord(firstSessionAt: start, latestSeenAt: start)
        XCTAssertEqual(FirstSessionRecord.next(after: record, event: .sessionAccepted, now: start + 10),
                       FirstSessionRecord(firstSessionAt: start, latestSeenAt: start + 10))
        XCTAssertEqual(FirstSessionRecord.next(after: record, event: .sessionEnded, now: start + 10)?.latestSeenAt,
                       start + 10)
    }

    func testIdleChecksRaiseItAtMostOnceAnHour() {
        let record = FirstSessionRecord(firstSessionAt: start, latestSeenAt: start)
        XCTAssertNil(FirstSessionRecord.next(after: record, event: .idleCheck, now: start + hour - 1))
        XCTAssertEqual(FirstSessionRecord.next(after: record, event: .idleCheck, now: start + hour)?.latestSeenAt,
                       start + hour)
    }

    func testAnEarlierClockNeverLowersIt() {
        let record = FirstSessionRecord(firstSessionAt: start, latestSeenAt: start + 50 * hour)
        for event in [FirstSessionRecord.Event.sessionAccepted, .sessionEnded, .idleCheck] {
            XCTAssertNil(FirstSessionRecord.next(after: record, event: event, now: start + 2 * hour))
            XCTAssertNil(FirstSessionRecord.next(after: record, event: event, now: start + 50 * hour))
        }
    }

    func testASettledRecordIsNeverWrittenAgain() {
        let settled = FirstSessionRecord(firstSessionAt: start, latestSeenAt: start + FirstSessionRecord.activeSeconds)
        XCTAssertTrue(settled.isSettled)
        XCTAssertNil(FirstSessionRecord.next(after: settled, event: .sessionAccepted, now: start + 30 * 24 * hour))
        XCTAssertNil(FirstSessionRecord.next(after: settled, event: .idleCheck, now: start + 30 * 24 * hour))
        let almost = FirstSessionRecord(firstSessionAt: start, latestSeenAt: start + FirstSessionRecord.activeSeconds - 1)
        XCTAssertFalse(almost.isSettled)
        XCTAssertNotNil(FirstSessionRecord.next(after: almost, event: .idleCheck, now: start + 30 * 24 * hour))
    }

    func testAnInvalidRecordIsTreatedAsAbsent() {
        let invalid = FirstSessionRecord(firstSessionAt: start, latestSeenAt: start - 1)
        XCTAssertFalse(invalid.isValid)
        XCTAssertNil(FirstSessionRecord.next(after: invalid, event: .idleCheck, now: start + 2 * hour))
        XCTAssertEqual(FirstSessionRecord.next(after: invalid, event: .sessionAccepted, now: start + 2 * hour)?.firstSessionAt,
                       start + 2 * hour)
        XCTAssertNil(FirstSessionTracker(stored: invalid).record)
    }

    func testTheStoredFormIsStable() throws {
        let record = FirstSessionRecord(firstSessionAt: start, latestSeenAt: start + 5)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Int]
        XCTAssertEqual(json, ["firstSessionAt": start, "latestSeenAt": start + 5])
    }

    func testTrackerFollowsSessionsAndRetriesFailedWrites() throws {
        var tracker = FirstSessionTracker(stored: nil)
        XCTAssertNil(tracker.observe(sessionLive: false, now: start))
        let created = try XCTUnwrap(tracker.observe(sessionLive: true, now: start + 1))
        XCTAssertEqual(created, FirstSessionRecord(firstSessionAt: start + 1, latestSeenAt: start + 1))
        // The write failed: the next observation asks again, also during the session.
        XCTAssertEqual(tracker.observe(sessionLive: true, now: start + 2), created)
        tracker.didWrite(created)
        XCTAssertNil(tracker.observe(sessionLive: true, now: start + 3))
        // The session ends: the latest time rises once.
        let ended = try XCTUnwrap(tracker.observe(sessionLive: false, now: start + 8 * hour))
        XCTAssertEqual(ended.latestSeenAt, start + 8 * hour)
        tracker.didWrite(ended)
        XCTAssertNil(tracker.observe(sessionLive: false, now: start + 8 * hour + 60))
        XCTAssertEqual(tracker.observe(sessionLive: false, now: start + 9 * hour)?.latestSeenAt, start + 9 * hour)
        XCTAssertEqual(tracker.record?.firstSessionAt, start + 1)
    }

    func testAWriteOfAnOlderValueDoesNotClearANewerOne() throws {
        var tracker = FirstSessionTracker(stored: FirstSessionRecord(firstSessionAt: start, latestSeenAt: start))
        let first = try XCTUnwrap(tracker.observe(sessionLive: true, now: start + 10))
        let second = try XCTUnwrap(tracker.observe(sessionLive: false, now: start + 20))
        tracker.didWrite(first)
        XCTAssertEqual(tracker.observe(sessionLive: false, now: start + 21), second)
    }
}
