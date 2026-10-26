import Foundation
import Darwin
import KeepMacAwakeServiceSupport

enum ServiceError: LocalizedError {
    case unsafeFile, busy, unauthorized, failed(String)
    var errorDescription: String? {
        switch self {
        case .unsafeFile: return "A service file has untrusted permissions or format."
        case .busy: return "Another recovery operation is in progress."
        case .unauthorized: return "The authorization to turn on expired."
        case .failed(let text): return text
        }
    }
}

/// Only fixed installation/state paths reach this type. No paths come from XPC.
final class SecureDirectory {
    enum HeartbeatFile: String {
        case controller = "controller-heartbeat.json"
        case watchdog = "watchdog-heartbeat.json"
    }

    let path: String
    private let descriptor: Int32
    init(_ path: String, privateMode: Bool) throws {
        guard geteuid() == 0, path.hasPrefix("/") else { throw ServiceError.unsafeFile }
        var checked = ""
        for component in path.split(separator: "/") {
            checked += "/" + component
            var metadata = stat()
            guard lstat(checked, &metadata) == 0,
                  metadata.st_mode & S_IFMT == S_IFDIR,
                  metadata.st_uid == 0, metadata.st_mode & 0o022 == 0 else { throw ServiceError.unsafeFile }
        }
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ServiceError.unsafeFile }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, !privateMode || metadata.st_mode & 0o077 == 0 else {
            close(descriptor); throw ServiceError.unsafeFile
        }
        self.path = path; self.descriptor = descriptor
    }
    deinit { close(descriptor) }

    private func validatedFile(_ name: String, flags: Int32,
                               kind: ServiceFileValidation.Kind = .persistent) throws -> Int32 {
        guard !name.contains("/"), name != ".", name != ".." else { throw ServiceError.unsafeFile }
        let fd = openat(descriptor, name, flags | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ServiceError.failed("Cannot open a service file (errno \(errno)).") }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0,
              ServiceFileValidation.isSafe(metadata, owner: 0, kind: kind) else {
            close(fd); throw ServiceError.unsafeFile
        }
        return fd
    }

    func read<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        try read(name, as: type, kind: .persistent)
    }

    func readHeartbeat(_ file: HeartbeatFile) throws -> PeerHeartbeat {
        try read(file.rawValue, as: PeerHeartbeat.self, kind: .heartbeat)
    }

    private func read<T: Decodable>(_ name: String, as type: T.Type,
                                     kind: ServiceFileValidation.Kind) throws -> T {
        let fd = try validatedFile(name, flags: O_RDONLY, kind: kind)
        defer { close(fd) }
        var buffer = [UInt8](repeating: 0, count: 16_385)
        var count = 0
        while count < buffer.count {
            let amount = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: count), $0.count - count) }
            if amount < 0, errno == EINTR { continue }
            guard amount >= 0 else { throw ServiceError.unsafeFile }
            if amount == 0 { break }
            count += amount
        }
        guard count <= 16_384 else { throw ServiceError.unsafeFile }
        return try JSONDecoder().decode(type, from: Data(buffer.prefix(count)))
    }

    func write<T: Encodable>(_ value: T, name: String) throws {
        guard !name.contains("/") else { throw ServiceError.unsafeFile }
        let bytes = try JSONEncoder().encode(value)
        let temporary = ".heartbeat-\(UUID().uuidString)"
        let fd = try validatedFile(temporary, flags: O_WRONLY | O_CREAT | O_EXCL)
        defer { close(fd); unlinkat(descriptor, temporary, 0) }
        try bytes.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let result = Darwin.write(fd, buffer.baseAddress!.advanced(by: written), buffer.count - written)
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw ServiceError.failed("Cannot write the supervision state.") }
                written += result
            }
        }
        // Heartbeats are volatile. The backend owns durable fsync of its journal.
        guard renameat(descriptor, temporary, descriptor, name) == 0 else { throw ServiceError.failed("Cannot publish the supervision state.") }
    }

    /// The lock is never awaited without bound: a stopped holder must not stop the caller.
    /// The controller retries briefly, because the watchdog's journal check holds the
    /// lock for well under a millisecond and a collision must not end a session.
    func withTransactionLock<T>(attempts: Int = 1, _ body: () throws -> T) throws -> T {
        let fd = try validatedFile("transaction.lock", flags: O_RDWR | O_CREAT)
        defer { close(fd) }
        var attempt = 1
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR, attempt < attempts else { throw ServiceError.busy }
            attempt += 1
            usleep(20_000)
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}

enum FixedPeer {
    case controller, watchdog
    var label: String {
        switch self {
        case .controller: return KeepMacAwakeControlProtocol.ControlConstants.serviceName
        case .watchdog: return KeepMacAwakeControlProtocol.ControlConstants.watchdogName
        }
    }
}

import KeepMacAwakeControlProtocol

enum PeerFencer {
    static func requireUnloaded(_ peer: FixedPeer) throws {
        guard try launchctl(["print", "system/" + peer.label]).status != 0 else {
            throw ServiceError.failed("Unload both fixed services through launchd first.")
        }
    }
    /// The command and service label are fixed; XPC cannot supply either.
    static func kill(_ peer: FixedPeer) throws {
        let result = try launchctl(["kill", "SIGKILL", "system/" + peer.label])
        if result.status == 0 { return }
        let inspection = try launchctl(["print", "system/" + peer.label])
        // Absent jobs cannot write. A loaded job without a PID can restart only inactive.
        if inspection.status != 0 { return }
        if !inspection.output.split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("pid = ") }) { return }
        throw ServiceError.failed("Could not stop an unresponsive service.")
    }

    private static func launchctl(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Drain independently, so launchctl cannot block on a full stdout pipe.
        final class Output: @unchecked Sendable { var data = Data(); let lock = NSLock() }
        let captured = Output()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            captured.lock.lock()
            if captured.data.count < 65_536 { captured.data.append(data.prefix(65_536 - captured.data.count)) }
            captured.lock.unlock()
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(10_000) }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
            output.fileHandleForReading.readabilityHandler = nil
            throw ServiceError.failed("Timed out while stopping a service.")
        }
        output.fileHandleForReading.readabilityHandler = nil
        let tail = output.fileHandleForReading.readDataToEndOfFile()
        captured.lock.lock()
        captured.data.append(tail.prefix(max(0, 65_536 - captured.data.count)))
        let text = String(decoding: captured.data, as: UTF8.self)
        captured.lock.unlock()
        return (process.terminationStatus, text)
    }
}
