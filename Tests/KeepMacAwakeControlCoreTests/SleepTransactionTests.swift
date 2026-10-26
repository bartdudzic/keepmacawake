import Foundation
import XCTest
@testable import KeepMacAwakeControlCore

final class SleepTransactionTests: XCTestCase {
    func testFailedConflictDowngradeRemovesNeverAppliedJournal() throws {
        let backend = FakeSleepBackend(preferences: nil)
        let store = MemoryRecoveryStore()
        store.afterSave = { record in
            if record.phase == .changing {
                backend.preferences = ["SleepDisabled": true]
                store.failSave = true
            }
        }
        let transaction = SleepTransaction(backend: backend, store: store)
        XCTAssertThrowsError(try transaction.activate())
        XCTAssertNil(store.record)
        try transaction.restore()
        XCTAssertTrue(backend.writes.isEmpty)
        XCTAssertEqual(backend.preferences?["SleepDisabled"] as? Bool, true)
    }

    func testConflictAndBothJournalFailuresRefuseRollbackInSameProcess() {
        let backend = FakeSleepBackend(preferences: nil)
        let store = MemoryRecoveryStore()
        store.afterSave = { record in
            if record.phase == .changing {
                backend.preferences = ["SleepDisabled": true]
                store.failSave = true
                store.failRemove = true
            }
        }
        let transaction = SleepTransaction(backend: backend, store: store)
        XCTAssertThrowsError(try transaction.activate())
        XCTAssertThrowsError(try transaction.restore())
        XCTAssertTrue(backend.writes.isEmpty)
        XCTAssertEqual(backend.preferences?["SleepDisabled"] as? Bool, true)
        XCTAssertNotNil(store.record)
    }

    func testMergeReadsForeignKeysAddedDuringJournalSync() throws {
        let backend = FakeSleepBackend(preferences: nil)
        let store = MemoryRecoveryStore()
        store.afterSave = { record in
            if record.phase == .changing { backend.preferences = ["ForeignDuringSync": "keep"] }
        }
        try SleepTransaction(backend: backend, store: store).activate()
        XCTAssertEqual(backend.preferences?["ForeignDuringSync"] as? String, "keep")
    }

    func testConflictAfterJournalSyncDoesNotAuthorizeForeignRollback() throws {
        let backend = FakeSleepBackend(preferences: nil)
        let store = MemoryRecoveryStore()
        store.afterSave = { record in
            if record.phase == .changing { backend.preferences = ["SleepDisabled": true] }
        }
        let transaction = SleepTransaction(backend: backend, store: store)
        XCTAssertThrowsError(try transaction.activate())
        try transaction.restore()
        XCTAssertTrue(backend.writes.isEmpty)
        XCTAssertEqual(backend.preferences?["SleepDisabled"] as? Bool, true)
    }

    func testExpiredAuthorizationAfterDurableJournalCannotEnableSleepDisabled() {
        let backend = FakeSleepBackend(preferences: nil)
        let store = MemoryRecoveryStore()
        let transaction = SleepTransaction(backend: backend, store: store)
        XCTAssertThrowsError(try transaction.activate(authorized: { store.record?.phase != .changing }))
        XCTAssertTrue(backend.writes.isEmpty)
    }

    func testDurableOriginalPrecedesEveryEnableWrite() throws {
        let backend = FakeSleepBackend(preferences: nil)
        let store = MemoryRecoveryStore()
        backend.beforeWrite = { preferences in
            if preferences?["SleepDisabled"] as? Bool == true {
                XCTAssertEqual(store.record?.original, .containerAbsent)
                XCTAssertEqual(store.record?.phase, .changing)
            }
        }
        let transaction = SleepTransaction(backend: backend, store: store)
        try transaction.activate()
        XCTAssertTrue(try transaction.verifyActive())
        XCTAssertTrue(transaction.hasPendingRecovery)
    }

    func testJournalFailureDoesNotChangePowerPreferences() {
        let backend = FakeSleepBackend(preferences: nil)
        let store = MemoryRecoveryStore()
        store.failSave = true
        XCTAssertThrowsError(try SleepTransaction(backend: backend, store: store).activate())
        XCTAssertTrue(backend.writes.isEmpty)
    }

    func testRejectsPreexistingTrueAndUnknownKernel() {
        for (preferences, kernel) in [(["SleepDisabled": true] as [String: Any]?, false as Bool?), (nil, nil), (nil, true)] {
            let backend = FakeSleepBackend(preferences: preferences, kernel: kernel)
            let store = MemoryRecoveryStore()
            XCTAssertThrowsError(try SleepTransaction(backend: backend, store: store).activate())
            XCTAssertTrue(backend.writes.isEmpty)
            XCTAssertNil(store.record)
        }
    }

    func testRejectsNumericBooleanInsteadOfClaimingKnownBaseline() {
        let backend = FakeSleepBackend(preferences: ["SleepDisabled": NSNumber(value: 0)])
        XCTAssertThrowsError(try SleepTransaction(backend: backend, store: MemoryRecoveryStore()).activate())
        XCTAssertTrue(backend.writes.isEmpty)
    }

    func testFalseBaselineIsRestoredAndForeignKeysSurvive() throws {
        let backend = FakeSleepBackend(preferences: ["SleepDisabled": false, "Initial": "value"])
        let store = MemoryRecoveryStore()
        let transaction = SleepTransaction(backend: backend, store: store)
        try transaction.activate()
        backend.preferences?["Later"] = 9
        try transaction.restore()
        XCTAssertEqual(backend.preferences?["SleepDisabled"] as? Bool, false)
        XCTAssertEqual(backend.preferences?["Initial"] as? String, "value")
        XCTAssertEqual(backend.preferences?["Later"] as? Int, 9)
        XCTAssertFalse(transaction.hasPendingRecovery)
    }

    func testMissingKeyIsRemovedWithoutRemovingOriginalEmptyContainer() throws {
        let backend = FakeSleepBackend(preferences: [:])
        let transaction = SleepTransaction(backend: backend, store: MemoryRecoveryStore())
        try transaction.activate()
        try transaction.restore()
        XCTAssertNotNil(backend.preferences)
        XCTAssertNil(backend.preferences?["SleepDisabled"])
    }

    func testMissingContainerRestoresKernelBeforeRemovingContainer() throws {
        let backend = FakeSleepBackend(preferences: nil)
        let store = MemoryRecoveryStore()
        let transaction = SleepTransaction(backend: backend, store: store)
        try transaction.activate()
        backend.beforeWrite = { preferences in
            if preferences == nil {
                XCTAssertEqual(backend.kernel, false)
                XCTAssertEqual(store.record?.phase, .kernelRestored)
            }
        }
        try transaction.restore()
        XCTAssertNil(backend.preferences)
        XCTAssertEqual(backend.kernel, false)
        XCTAssertNil(store.record)
    }

    func testNewForeignKeyPreventsRemovalOfOriginallyMissingContainer() throws {
        let backend = FakeSleepBackend(preferences: nil)
        let transaction = SleepTransaction(backend: backend, store: MemoryRecoveryStore())
        try transaction.activate()
        backend.preferences?["Foreign"] = "keep"
        try transaction.restore()
        XCTAssertEqual(backend.preferences?["Foreign"] as? String, "keep")
        XCTAssertNil(backend.preferences?["SleepDisabled"])
    }

    func testUnconfirmedActivationKeepsRecoveryRecord() {
        let backend = FakeSleepBackend(preferences: nil)
        backend.applyToKernel = false
        let store = MemoryRecoveryStore()
        let transaction = SleepTransaction(backend: backend, store: store)
        XCTAssertThrowsError(try transaction.activate())
        XCTAssertTrue(transaction.hasPendingRecovery)
        XCTAssertFalse(try transaction.verifyActive())
    }

    func testRestoreRetriesAfterKernelWriteFailure() throws {
        let backend = FakeSleepBackend(preferences: nil)
        let store = MemoryRecoveryStore()
        try SleepTransaction(backend: backend, store: store).activate()
        backend.failNextWrite = true
        XCTAssertThrowsError(try SleepTransaction(backend: backend, store: store).restore())
        XCTAssertNotNil(store.record)
        try SleepTransaction(backend: backend, store: store).restore()
        XCTAssertNil(backend.preferences)
        XCTAssertNil(store.record)
    }

    func testRestoreRetriesAfterMetadataWriteFailure() throws {
        let backend = FakeSleepBackend(preferences: nil)
        let store = MemoryRecoveryStore()
        let transaction = SleepTransaction(backend: backend, store: store)
        try transaction.activate()
        backend.failContainerRemoval = true
        XCTAssertThrowsError(try transaction.restore())
        XCTAssertEqual(store.record?.phase, .kernelRestored)
        XCTAssertEqual(backend.kernel, false)
        backend.failContainerRemoval = false
        try SleepTransaction(backend: backend, store: store).restore()
        XCTAssertNil(backend.preferences)
        XCTAssertNil(store.record)
    }

    func testRecoveryAfterMetadataDeletionIsIdempotent() throws {
        let backend = FakeSleepBackend(preferences: nil)
        let store = MemoryRecoveryStore(record: RecoveryRecord(original: .containerAbsent, phase: .kernelRestored))
        try SleepTransaction(backend: backend, store: store).restore()
        XCTAssertNil(store.record)
        XCTAssertTrue(backend.writes.isEmpty)
    }

    func testPreparedJournalNeverOverwritesForeignMutation() throws {
        let backend = FakeSleepBackend(preferences: ["SleepDisabled": true], kernel: true)
        let store = MemoryRecoveryStore(record: RecoveryRecord(original: .falseValue))
        try SleepTransaction(backend: backend, store: store).restore()
        XCTAssertTrue(backend.writes.isEmpty)
        XCTAssertEqual(backend.kernel, true)
    }

    func testForeignReenableAfterKernelRestorationIsConflict() {
        let backend = FakeSleepBackend(preferences: ["SleepDisabled": true], kernel: true)
        let store = MemoryRecoveryStore(record: RecoveryRecord(original: .containerAbsent, phase: .kernelRestored))
        XCTAssertThrowsError(try SleepTransaction(backend: backend, store: store).restore())
        XCTAssertTrue(backend.writes.isEmpty)
        XCTAssertNotNil(store.record)
    }

    func testPendingJournalBlocksNewActivation() {
        let backend = FakeSleepBackend(preferences: nil)
        let store = MemoryRecoveryStore(record: RecoveryRecord(original: .containerAbsent))
        XCTAssertThrowsError(try SleepTransaction(backend: backend, store: store).activate())
        XCTAssertTrue(backend.writes.isEmpty)
    }

    func testReadFailureIsPendingRecoveryAndBlocksActivation() {
        let store = MemoryRecoveryStore()
        store.failLoad = true
        let backend = FakeSleepBackend(preferences: nil)
        let transaction = SleepTransaction(backend: backend, store: store)
        XCTAssertTrue(transaction.hasPendingRecovery)
        XCTAssertThrowsError(try transaction.activate())
        XCTAssertTrue(backend.writes.isEmpty)
    }
}

private enum InjectedFailure: Error { case failure }

private final class MemoryRecoveryStore: RecoveryStore {
    var record: RecoveryRecord?
    var failSave = false
    var failLoad = false
    var failRemove = false
    var afterSave: ((RecoveryRecord) -> Void)?
    init(record: RecoveryRecord? = nil) { self.record = record }
    func load() throws -> RecoveryRecord? {
        if failLoad { throw InjectedFailure.failure }
        return record
    }
    func save(_ record: RecoveryRecord) throws {
        if failSave { throw InjectedFailure.failure }
        self.record = record
        afterSave?(record)
    }
    func remove() throws {
        if failRemove { throw InjectedFailure.failure }
        record = nil
    }
}

private final class FakeSleepBackend: SleepBackend {
    var preferences: [String: Any]?
    var kernel: Bool?
    var writes: [[String: Any]?] = []
    var applyToKernel = true
    var failNextWrite = false
    var failContainerRemoval = false
    var beforeWrite: (([String: Any]?) -> Void)?
    init(preferences: [String: Any]?, kernel: Bool? = false) {
        self.preferences = preferences
        self.kernel = kernel
    }
    func readPreferences() throws -> [String: Any]? { preferences }
    func writePreferences(_ preferences: [String: Any]?) throws {
        if failNextWrite {
            failNextWrite = false
            throw InjectedFailure.failure
        }
        if preferences == nil && failContainerRemoval { throw InjectedFailure.failure }
        beforeWrite?(preferences)
        writes.append(preferences)
        self.preferences = preferences
        // Model powerd's important behavior: an absent container does not reset RAM.
        if applyToKernel, let preferences { kernel = preferences["SleepDisabled"] as? Bool ?? false }
    }
    func readKernelSleepDisabled() throws -> Bool? { kernel }
    func waitForKernelSleepDisabled(_ value: Bool) throws {
        guard kernel == value else { throw InjectedFailure.failure }
    }
}
