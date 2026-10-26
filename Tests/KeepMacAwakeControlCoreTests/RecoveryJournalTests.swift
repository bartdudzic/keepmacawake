import Foundation
import Darwin
import XCTest
@testable import KeepMacAwakeControlCore

final class RecoveryJournalTests: XCTestCase {
    var directory: URL!
    var journal: RecoveryJournal!
    var file: URL { directory.appendingPathComponent(RecoveryJournal.filename) }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        journal = RecoveryJournal(directory: directory, requiredOwner: getuid())
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testSecureAtomicSaveRoundTripAndUpdate() throws {
        var record = RecoveryRecord(original: .containerAbsent)
        XCTAssertNil(try journal.load())
        try journal.save(record)
        XCTAssertEqual(try journal.load(), record)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        record.phase = .kernelRestored
        try journal.save(record)
        XCTAssertEqual(try journal.load(), record)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [RecoveryJournal.filename])
        try journal.remove()
        try journal.remove()
        XCTAssertNil(try journal.load())
    }

    func testRejectsSymlinkForReadSaveAndRemoveWithoutTouchingTarget() throws {
        let target = directory.appendingPathComponent("target")
        try Data("unchanged".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        XCTAssertThrowsError(try journal.load())
        XCTAssertThrowsError(try journal.save(RecoveryRecord(original: .falseValue)))
        XCTAssertThrowsError(try journal.remove())
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "unchanged")
    }

    func testRejectsWritableByOtherUsers() throws {
        try writeRaw("{\"schemaVersion\":1,\"original\":\"falseValue\",\"phase\":\"changing\"}")
        XCTAssertEqual(chmod(file.path, 0o666), 0)
        XCTAssertThrowsError(try journal.load())
        XCTAssertThrowsError(try journal.save(RecoveryRecord(original: .falseValue)))
    }

    func testRejectsWrongOwnerAndUnsafeDirectory() throws {
        let wrongOwner = RecoveryJournal(directory: directory, requiredOwner: getuid() == 0 ? 1 : 0)
        XCTAssertThrowsError(try wrongOwner.load())
        XCTAssertThrowsError(try wrongOwner.save(RecoveryRecord(original: .falseValue)))
        XCTAssertEqual(chmod(directory.path, 0o777), 0)
        XCTAssertThrowsError(try journal.load())
    }

    func testRejectsMalformedUnsupportedAndInstructionBearingData() throws {
        for contents in [
            "broken",
            "{\"schemaVersion\":2,\"original\":\"falseValue\",\"phase\":\"changing\"}",
            "{\"schemaVersion\":1,\"original\":\"true\",\"phase\":\"changing\"}",
            "{\"schemaVersion\":1,\"original\":\"falseValue\",\"phase\":\"changing\",\"path\":\"/tmp/unsafe\"}",
            String(repeating: " ", count: 20_000)
        ] {
            try writeRaw(contents)
            XCTAssertThrowsError(try journal.load())
        }
    }

    func testRejectsHardLinkedJournal() throws {
        try writeRaw("{\"schemaVersion\":1,\"original\":\"falseValue\",\"phase\":\"changing\"}")
        let other = directory.appendingPathComponent("hardlink")
        XCTAssertEqual(link(file.path, other.path), 0)
        XCTAssertThrowsError(try journal.load())
    }

    private func writeRaw(_ contents: String) throws {
        try Data(contents.utf8).write(to: file)
        XCTAssertEqual(chmod(file.path, 0o600), 0)
    }
}
