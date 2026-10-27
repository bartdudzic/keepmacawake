import Foundation
import Darwin
import KeepMacAwakeControlProtocol
import KeepMacAwakeServiceSupport

/// The helper's side of an update. No path, URL or command comes from the client: it
/// sends an open file, the helper copies it into a directory only root can read, checks
/// that copy (UpdatePackageCheck) and installs it in a process of its own, which holds
/// the update lock until Installer ends.
enum UpdateInstall {
    static let packageName = "update.pkg"
    static let journalPath = ControlConstants.stateDirectory + "/sleep-recovery.json"
    static let relaunchPath = ControlConstants.stateDirectory + "/relaunch-app"
    /// The install process receives the lock on this descriptor.
    static let lockDescriptor: Int32 = 3

    /// True while an install process holds the lock. It survives a helper restart, and ends
    /// when Installer ends, also when it fails before the package's scripts ran.
    static func isInstalling() -> Bool {
        let descriptor = open(ControlConstants.updateLockPath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        if flock(descriptor, LOCK_SH | LOCK_NB) == 0 { flock(descriptor, LOCK_UN); return false }
        return errno == EWOULDBLOCK
    }

    /// The lock for an install about to start, held by the caller until it hands it on.
    static func takeLock() throws -> Int32 {
        let descriptor = open(ControlConstants.updateLockPath, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ServiceError.failed("Cannot prepare the update.") }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == 0,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw ServiceError.failed("An update is already being installed.")
        }
        return descriptor
    }

    /// Copies the client's file, which must be a regular file of at most `maximumUpdateBytes`,
    /// into a new directory under the update directory; returns the copy's path.
    static func copy(_ handle: FileHandle) throws -> String {
        var source = stat()
        guard fstat(handle.fileDescriptor, &source) == 0,
              UpdatePackageCheck.acceptsUpload(isRegularFile: source.st_mode & S_IFMT == S_IFREG, size: Int64(source.st_size)) else {
            throw ServiceError.failed("The update package is not a file of the expected size.")
        }
        let base = ControlConstants.updateDirectory
        if mkdir(base, 0o700) != 0, errno != EEXIST { throw ServiceError.failed("Cannot create the update directory.") }
        // Every component root-owned and not writable by others, the last one private.
        _ = try SecureDirectory(base, privateMode: true)
        var template = Array((base + "/XXXXXXXX").utf8CString)
        guard let created = mkdtemp(&template) else { throw ServiceError.failed("Cannot create an update directory.") }
        let directory = String(cString: created)
        let path = directory + "/" + packageName
        let output = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { remove(directory); throw ServiceError.failed("Cannot write the update package.") }
        defer { close(output) }
        var total = 0
        do {
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                total += chunk.count
                guard total <= ControlConstants.maximumUpdateBytes else { throw ServiceError.failed("The update package is too large.") }
                let written = chunk.withUnsafeBytes { write(output, $0.baseAddress, chunk.count) }
                guard written == chunk.count else { throw ServiceError.failed("Cannot write the update package.") }
            }
            guard total > 0, fsync(output) == 0 else { throw ServiceError.failed("The update package is empty.") }
        } catch {
            remove(directory)
            throw error
        }
        return path
    }

    /// A fixed system tool with fixed arguments, killed after `timeout` seconds. Its output
    /// is read only for the checks; Installer's goes nowhere.
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 60,
                    captureOutput: Bool = true) -> UpdatePackageCheck.Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C"]
        process.standardInput = FileHandle.nullDevice
        let buffer = OutputBuffer()
        let pipe = Pipe()
        if captureOutput {
            process.standardOutput = pipe
            process.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { buffer.append($0.availableData) }
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return UpdatePackageCheck.Output(status: -1, text: "") }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            finished.wait()
            pipe.fileHandleForReading.readabilityHandler = nil
            return UpdatePackageCheck.Output(status: -1, text: "")
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        if captureOutput { buffer.append(pipe.fileHandleForReading.availableData) }
        return UpdatePackageCheck.Output(status: process.terminationStatus, text: buffer.text)
    }

    /// The archive's Distribution, extracted next to the copy; never used if xar failed.
    static func distribution(_ package: String) -> Data? {
        let directory = (package as NSString).deletingLastPathComponent
        guard run("/usr/bin/xar", ["-x", "-f", package, "-C", directory, "Distribution"]).status == 0 else { return nil }
        let path = directory + "/Distribution"
        var metadata = stat()
        guard lstat(path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG, metadata.st_size <= 65_536 else { return nil }
        return FileManager.default.contents(atPath: path)
    }

    static var systemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// Starts this helper's install mode in a new session, so it outlives the helper, which
    /// the package's preinstall stops. It gets the update lock on descriptor 3, default
    /// signal handling (the helper ignores SIGTERM and SIGINT) and nothing else.
    static func startDetached(_ package: String, lock: Int32) throws {
        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        posix_spawnattr_init(&attributes)
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawnattr_destroy(&attributes); posix_spawn_file_actions_destroy(&actions) }
        var defaultSignals = sigset_t(), noMask = sigset_t()
        sigfillset(&defaultSignals)
        sigemptyset(&noMask)
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        posix_spawnattr_setsigmask(&attributes, &noMask)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT |
                                                     POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, lock, lockDescriptor)
        let arguments = [ControlConstants.helperExecutable, "--install-update", package]
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        var envp: [UnsafeMutablePointer<CChar>?] = [strdup("PATH=/usr/bin:/bin:/usr/sbin:/sbin"), nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, ControlConstants.helperExecutable, &actions, &attributes, &argv, &envp) == 0 else {
            throw ServiceError.failed("Cannot start the update.")
        }
        // Reaped if it ends while this helper still runs, for example after a failed install.
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1, errno == EINTR {}
        }
    }

    /// `--install-update <copy>`: root only, and only for the package file in one of the
    /// helper's own update directories. Installer runs the package's scripts, which quit the
    /// app, stop and start the services and open the app again. If Installer fails, the
    /// installed services start again and the app opens again.
    static func installMode(_ package: String) -> Int32 {
        guard geteuid() == 0, UpdatePackageCheck.isPackagePath(package) else { return 64 }
        let directory = (package as NSString).deletingLastPathComponent
        guard (try? SecureDirectory(directory, privateMode: true)) != nil else { return 64 }
        // The lock comes from the helper on descriptor 3; root running this by hand takes it here.
        if flock(lockDescriptor, LOCK_EX | LOCK_NB) != 0 {
            guard (try? takeLock()) != nil else { return 75 }
        }
        var metadata = stat()
        guard lstat(package, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == 0,
              metadata.st_mode & 0o077 == 0 else { remove(directory); return 64 }
        let installed = run("/usr/sbin/installer", ["-pkg", package, "-target", "/"], timeout: 1800, captureOutput: false).status == 0
        if !installed { restartServices() }
        remove(directory)
        return installed ? 0 : 1
    }

    /// After a failed install: the services from the installed plists, the user's
    /// coordinator, and the app if the preinstall had quit it.
    private static func restartServices() {
        for label in [ControlConstants.serviceName, ControlConstants.watchdogName] {
            let plist = "/Library/LaunchDaemons/\(label).plist"
            if run("/bin/launchctl", ["print", "system/\(label)"]).status != 0, FileManager.default.fileExists(atPath: plist) {
                _ = run("/bin/launchctl", ["bootstrap", "system", plist])
            }
        }
        guard let console = consoleUserID() else { return }
        _ = run("/bin/launchctl", ["bootstrap", "gui/\(console)", "/Library/LaunchAgents/\(ControlConstants.coordinatorIdentifier).plist"])
        var metadata = stat()
        guard lstat(relaunchPath, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == 0,
              let data = FileManager.default.contents(atPath: relaunchPath) else { return }
        unlink(relaunchPath)
        guard String(decoding: data.prefix(16), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == String(console) else { return }
        _ = run("/bin/launchctl", ["asuser", String(console), "/usr/bin/sudo", "-u", "#\(console)", "/usr/bin/open", ControlConstants.applicationPath])
    }

    /// Removes one update directory, never anything else.
    static func remove(_ directory: String) {
        guard UpdatePackageCheck.isPackagePath(directory + "/" + packageName) else { return }
        try? FileManager.default.removeItem(atPath: directory)
    }

    static func removePackage(_ package: String) { remove((package as NSString).deletingLastPathComponent) }
}

/// Output gathered from a tool's pipe while it runs, at most 64 KB.
private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        if data.count < 65_536 { data.append(chunk.prefix(65_536 - data.count)) }
    }
    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
