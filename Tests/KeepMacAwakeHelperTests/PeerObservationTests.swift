import XCTest
@testable import KeepMacAwakeServiceSupport

final class PeerObservationTests: XCTestCase {
    private enum Failure: Error { case busy, unreadable }

    func testPublicationDuringReadDoesNotLookLikeAFutureHeartbeat() {
        var now = 100.0
        let observation = PeerObservation(read: {
            now = 100.02
            return PeerHeartbeat(generation: "peer", updatedAt: 100.01, ready: true)
        }, clock: { now })

        XCTAssertTrue(observation.heartbeat?.isFresh(at: observation.observedAt) == true)
    }

    func testObservationStillRejectsGenuinelyFutureAndExpiredHeartbeats() {
        for timestamp in [101.0, 92.0] {
            let observation = PeerObservation(read: {
                PeerHeartbeat(generation: "peer", updatedAt: timestamp, ready: true)
            }, clock: { 100 })
            XCTAssertFalse(observation.heartbeat?.isFresh(at: observation.observedAt) == true)
        }
    }

    func testActivationBeforeLockAcquisitionDoesNotOrphanNewSession() throws {
        var heartbeat = makeHeartbeat(blocking: false)
        var journalExists = false
        let orphaned = try RecoveryInspection.hasOrphanedJournal(withLock: { body in
            // The controller wins the lock, publishes intent and creates its journal.
            heartbeat = self.makeHeartbeat(blocking: true)
            journalExists = true
            return try body()
        }, readHeartbeat: { heartbeat }, hasJournal: { journalExists })

        XCTAssertFalse(orphaned)
    }

    func testHeartbeatAndJournalAreBothReadUnderTransactionLock() throws {
        var locked = false
        var journalReads = 0
        let orphaned = try RecoveryInspection.hasOrphanedJournal(withLock: { body in
            locked = true
            defer { locked = false }
            return try body()
        }, readHeartbeat: {
            XCTAssertTrue(locked)
            return self.makeHeartbeat(blocking: false)
        }, hasJournal: {
            XCTAssertTrue(locked)
            journalReads += 1
            return true
        })

        XCTAssertTrue(orphaned)
        XCTAssertEqual(journalReads, 1)
        XCTAssertFalse(locked)
    }

    func testBusyLockPropagatesWithoutReadingStateOutsideIt() {
        var reads = 0
        XCTAssertThrowsError(try RecoveryInspection.hasOrphanedJournal(withLock: { _ in
            throw Failure.busy
        }, readHeartbeat: {
            reads += 1
            return self.makeHeartbeat(blocking: false)
        }, hasJournal: { reads += 1; return true })) { error in
            XCTAssertEqual(error as? Failure, .busy)
        }
        XCTAssertEqual(reads, 0)
    }

    func testIdleOrMissingControllerWithJournalNeedsRecovery() throws {
        for heartbeat in [makeHeartbeat(blocking: false), nil] {
            XCTAssertTrue(try RecoveryInspection.hasOrphanedJournal(withLock: { try $0() },
                readHeartbeat: { heartbeat }, hasJournal: { true }))
        }
    }

    func testAbsentJournalOrPublishedActivationDoesNotNeedOrphanRecovery() throws {
        for (blocking, journal) in [(false, false), (true, true)] {
            XCTAssertFalse(try RecoveryInspection.hasOrphanedJournal(withLock: { try $0() },
                readHeartbeat: { self.makeHeartbeat(blocking: blocking) }, hasJournal: { journal }))
        }
    }

    func testUnreadableHeartbeatOrJournalPropagatesToRecovery() {
        for heartbeatFails in [true, false] {
            XCTAssertThrowsError(try RecoveryInspection.hasOrphanedJournal(withLock: { try $0() },
                readHeartbeat: {
                    if heartbeatFails { throw Failure.unreadable }
                    return self.makeHeartbeat(blocking: false)
                }, hasJournal: { throw Failure.unreadable })) { error in
                    XCTAssertEqual(error as? Failure, .unreadable)
                }
        }
    }

    private func makeHeartbeat(blocking: Bool) -> PeerHeartbeat {
        PeerHeartbeat(generation: "controller", updatedAt: 100, ready: true, blocking: blocking)
    }
}
