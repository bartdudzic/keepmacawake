import Foundation
import Darwin
import XCTest
@testable import KeepMacAwakeServiceSupport

final class ServiceFileValidationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testAtomicReplacementKeepsOpenedHeartbeatReadableWithoutWeakeningPersistentFiles() throws {
        let file = try write("heartbeat.json", timestamp: 100)
        let replacement = try write("next.json", timestamp: 101)
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fd, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var before = stat()
        XCTAssertEqual(fstat(fd, &before), 0)
        XCTAssertEqual(before.st_nlink, 1)

        // Deterministically publish between the reader's open and fstat.
        XCTAssertEqual(rename(replacement.path, file.path), 0)
        var after = stat()
        XCTAssertEqual(fstat(fd, &after), 0)
        XCTAssertEqual(after.st_nlink, 0)
        XCTAssertEqual(after.st_ino, before.st_ino)
        XCTAssertEqual(after.st_dev, before.st_dev)
        XCTAssertTrue(ServiceFileValidation.isSafe(after, owner: geteuid(), kind: .heartbeat))
        XCTAssertFalse(ServiceFileValidation.isSafe(after, owner: geteuid(), kind: .persistent))

        var bytes = [UInt8](repeating: 0, count: 1024)
        let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        XCTAssertGreaterThan(count, 0)
        let beat = try JSONDecoder().decode(PeerHeartbeat.self, from: Data(bytes.prefix(max(0, count))))
        XCTAssertEqual(beat.updatedAt, 100)
        XCTAssertTrue(beat.isFresh(at: 101, bootID: "test-boot"))
        XCTAssertFalse(beat.isFresh(at: 108, bootID: "test-boot"))
        XCTAssertFalse(beat.isFresh(at: 101, bootID: "another-boot"))
        let current = try JSONDecoder().decode(PeerHeartbeat.self, from: Data(contentsOf: file))
        XCTAssertEqual(current.updatedAt, 101)
        XCTAssertTrue(ServiceFileValidation.isSafe(try metadata(file), owner: geteuid(), kind: .persistent))
    }

    func testOrdinaryOwnedFileIsAcceptedForBothKinds() throws {
        let data = try metadata(write("heartbeat.json"))
        for kind in [ServiceFileValidation.Kind.persistent, .heartbeat] {
            XCTAssertTrue(ServiceFileValidation.isSafe(data, owner: geteuid(), kind: kind))
        }
    }

    func testMultipleHardLinksAreRejectedForBothKinds() throws {
        let file = try write("heartbeat.json")
        XCTAssertEqual(link(file.path, directory.appendingPathComponent("alias.json").path), 0)
        let data = try metadata(file)
        XCTAssertEqual(data.st_nlink, 2)
        assertRejected(data)
    }

    func testUnexpectedOwnerIsRejectedEvenForUnlinkedHeartbeat() throws {
        var data = try metadata(write("heartbeat.json"))
        data.st_nlink = 0
        XCTAssertFalse(ServiceFileValidation.isSafe(data, owner: geteuid() &+ 1, kind: .heartbeat))
        data.st_nlink = 1
        for kind in [ServiceFileValidation.Kind.persistent, .heartbeat] {
            XCTAssertFalse(ServiceFileValidation.isSafe(data, owner: geteuid() &+ 1, kind: kind))
        }
    }

    func testGroupOrWorldWritableFileIsRejectedEvenWhenUnlinked() throws {
        let file = try write("heartbeat.json")
        for mode: mode_t in [0o620, 0o602, 0o666] {
            XCTAssertEqual(chmod(file.path, mode), 0)
            var data = try metadata(file)
            assertRejected(data)
            data.st_nlink = 0
            XCTAssertFalse(ServiceFileValidation.isSafe(data, owner: geteuid(), kind: .heartbeat))
        }
    }

    func testDirectorySymlinkAndFIFOAreRejected() throws {
        let file = try write("heartbeat.json")
        let alias = directory.appendingPathComponent("alias.json")
        XCTAssertEqual(symlink(file.path, alias.path), 0)
        let fd = open(alias.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd >= 0 { close(fd) }
        XCTAssertEqual(fd, -1)
        assertRejected(try metadata(alias))
        assertRejected(try metadata(directory))
        let fifo = directory.appendingPathComponent("fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        assertRejected(try metadata(fifo))
    }

    private func assertRejected(_ metadata: stat, file: StaticString = #filePath, line: UInt = #line) {
        for kind in [ServiceFileValidation.Kind.persistent, .heartbeat] {
            XCTAssertFalse(ServiceFileValidation.isSafe(metadata, owner: geteuid(), kind: kind), file: file, line: line)
        }
    }

    private func write(_ name: String, timestamp: Double = 100) throws -> URL {
        let file = directory.appendingPathComponent(name)
        let beat = PeerHeartbeat(generation: "test-generation", updatedAt: timestamp, ready: true, bootID: "test-boot")
        try JSONEncoder().encode(beat).write(to: file)
        XCTAssertEqual(chmod(file.path, 0o600), 0)
        return file
    }

    private func metadata(_ file: URL) throws -> stat {
        var data = stat()
        guard lstat(file.path, &data) == 0 else { throw POSIXError(.EIO) }
        return data
    }
}
