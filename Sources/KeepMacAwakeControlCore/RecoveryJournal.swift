import Foundation
import Darwin

final class RecoveryJournal: RecoveryStore {
    static let filename = "sleep-recovery.json"
    let directory: URL
    let requiredOwner: uid_t

    init(directory: URL, requiredOwner: uid_t = 0) {
        self.directory = directory
        self.requiredOwner = requiredOwner
    }

    func load() throws -> RecoveryRecord? {
        let directoryFD = try openDirectory()
        defer { close(directoryFD) }
        return try load(directoryFD: directoryFD)
    }

    func save(_ record: RecoveryRecord) throws {
        guard record.schemaVersion == 1 else { throw SleepControlError.journal("Unsupported version.") }
        let directoryFD = try openDirectory()
        defer { close(directoryFD) }
        // Refuse to replace malformed, linked, or insecure existing files.
        _ = try load(directoryFD: directoryFD)
        let temporaryName = ".sleep-recovery-\(UUID().uuidString).tmp"
        let descriptor = openat(directoryFD, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw failure("creating a temporary file") }
        defer {
            close(descriptor)
            unlinkat(directoryFD, temporaryName, 0)
        }
        guard fchmod(descriptor, 0o600) == 0 else { throw failure("setting file permissions") }
        try validateFile(descriptor)
        let bytes = try JSONEncoder().encode(record)
        try bytes.withUnsafeBytes { buffer in
            guard let start = buffer.baseAddress else { throw SleepControlError.journal("Empty write.") }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, start.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw failure("writing the file") }
                offset += count
            }
        }
        // F_FULLFSYNC asks macOS to flush the drive cache, in addition to normal fsync.
        guard fsync(descriptor) == 0, fcntl(descriptor, F_FULLFSYNC) == 0 else {
            throw failure("syncing the file")
        }
        guard renameat(directoryFD, temporaryName, directoryFD, Self.filename) == 0 else {
            throw failure("publishing the file atomically")
        }
        guard fsync(directoryFD) == 0 else { throw failure("syncing the directory") }
    }

    func remove() throws {
        let directoryFD = try openDirectory()
        defer { close(directoryFD) }
        guard let record = try load(directoryFD: directoryFD) else { return }
        guard unlinkat(directoryFD, Self.filename, 0) == 0 else { throw failure("removing the file") }
        guard fsync(directoryFD) == 0 else {
            let error = failure("syncing the removal")
            // Keep recovery available if durable deletion cannot be confirmed.
            try? save(record)
            throw error
        }
    }

    private func openDirectory() throws -> Int32 {
        guard directory.isFileURL else { throw SleepControlError.journal("A local directory is required.") }
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure("opening the directory") }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == requiredOwner,
              metadata.st_mode & 0o022 == 0 else {
            close(descriptor)
            throw SleepControlError.journal("Unsafe directory owner or permissions.")
        }
        return descriptor
    }

    private func validateFile(_ descriptor: Int32) throws {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_mode & 0o777 == 0o600,
              metadata.st_uid == requiredOwner,
              metadata.st_nlink == 1 else {
            throw SleepControlError.journal("The file must be a regular single-link file with mode 0600.")
        }
    }

    private func load(directoryFD: Int32) throws -> RecoveryRecord? {
        let descriptor = openat(directoryFD, Self.filename, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw failure("opening the journal")
        }
        defer { close(descriptor) }
        try validateFile(descriptor)
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_size > 0, metadata.st_size <= 16_384 else {
            throw SleepControlError.journal("Invalid journal size.")
        }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw failure("reading the file") }
            if count == 0 { break }
            guard bytes.count + count <= 16_384 else { throw SleepControlError.journal("The journal is too large.") }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        do {
            guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  Set(object.keys) == ["schemaVersion", "original", "phase"] else {
                throw SleepControlError.journal("Invalid journal fields.")
            }
            let record = try JSONDecoder().decode(RecoveryRecord.self, from: bytes)
            guard record.schemaVersion == 1 else { throw SleepControlError.journal("Unsupported version.") }
            return record
        } catch {
            throw SleepControlError.journal("Invalid journal format or version.")
        }
    }

    private func failure(_ operation: String) -> SleepControlError {
        .journal("Failed \(operation), errno \(errno).")
    }
}
