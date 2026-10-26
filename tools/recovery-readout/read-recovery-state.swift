import Foundation
import CoreFoundation
import Darwin
import IOKit

struct JournalReading: Codable {
    let state: String
    var schemaVersion: Int? = nil
    var original: String? = nil
    var phase: String? = nil
}

enum RecoveryReadout {
    static func preferences(_ value: Any?) -> String {
        guard let value else { return "containerAbsent" }
        guard CFGetTypeID(value as CFTypeRef) == CFDictionaryGetTypeID(),
              let dictionary = value as? [String: Any] else { return "invalid" }
        guard let setting = dictionary["SleepDisabled"] else { return "keyAbsent" }
        return kernel(setting)
    }

    static func kernel(_ value: Any?) -> String {
        guard let value else { return "missing" }
        let object = value as CFTypeRef
        guard CFGetTypeID(object) == CFBooleanGetTypeID() else { return "invalid" }
        return CFEqual(object, kCFBooleanTrue) ? "true" : "false"
    }

    static func parseJournal(_ data: Data) -> JournalReading {
        guard !data.isEmpty, data.count <= 16_384,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["schemaVersion", "original", "phase"],
              let version = object["schemaVersion"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1,
              let original = object["original"] as? String,
              ["containerAbsent", "keyAbsent", "falseValue"].contains(original),
              let phase = object["phase"] as? String,
              ["prepared", "changing", "kernelRestored"].contains(phase) else {
            return JournalReading(state: "invalid")
        }
        return JournalReading(state: "present", schemaVersion: 1, original: original, phase: phase)
    }

    // The descriptor anchors the read even if the directory is renamed. Never lock
    // transaction.lock: this observer must work while its owner is suspended.
    static func journal(in directory: Int32, owner: uid_t) -> JournalReading {
        let fd = openat(directory, "sleep-recovery.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return JournalReading(state: errno == ENOENT ? "absent" : "error") }
        defer { close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0 else { return JournalReading(state: "error") }
        guard metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_mode & 0o7777 == 0o600, metadata.st_uid == owner,
              metadata.st_nlink == 1, metadata.st_size > 0, metadata.st_size <= 16_384 else {
            return JournalReading(state: "invalid")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { return JournalReading(state: "error") }
            if count == 0 { break }
            guard data.count + count <= 16_384 else { return JournalReading(state: "invalid") }
            data.append(contentsOf: buffer.prefix(count))
        }
        return parseJournal(data)
    }

    static func installedJournal() -> JournalReading {
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return JournalReading(state: "error") }
        defer { close(fd) }
        for component in ["Library", "Application Support", "KeepMacAwake"] {
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { return JournalReading(state: errno == ENOENT ? "absent" : "error") }
            close(fd)
            fd = next
            var metadata = stat()
            guard fstat(fd, &metadata) == 0 else { return JournalReading(state: "error") }
            guard metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_uid == 0,
                  metadata.st_mode & 0o022 == 0,
                  component != "KeepMacAwake" || metadata.st_mode & 0o077 == 0 else {
                return JournalReading(state: "invalid")
            }
        }
        return journal(in: fd, owner: 0)
    }

    static func nativePreferences() -> String {
        let domain = "com.apple.PowerManagement" as CFString
        guard CFPreferencesSynchronize(domain, kCFPreferencesAnyUser, kCFPreferencesCurrentHost) else { return "error" }
        return preferences(CFPreferencesCopyValue("SystemPowerSettings" as CFString, domain,
                                                  kCFPreferencesAnyUser, kCFPreferencesCurrentHost))
    }

    static func nativeKernel() -> String {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return "error" }
        defer { IOObjectRelease(service) }
        return kernel(IORegistryEntryCreateCFProperty(service, "SleepDisabled" as CFString,
                                                       kCFAllocatorDefault, 0)?.takeRetainedValue())
    }

    static func continuousSeconds() -> Double? {
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom != 0 else { return nil }
        return Double(mach_continuous_time()) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }
}

#if !RECOVERY_READOUT_TESTS
@main
enum RecoveryReadoutMain {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--help"] {
            print("Usage: KeepMacAwakeRecoveryReadout [--json]\nOne read-only sample of fixed sleep preference, kernel and recovery-journal states. Requires root. No activation, recovery or file writes.")
            return
        }
        guard arguments.isEmpty || arguments == ["--json"] else {
            fputs("Unsupported arguments. Use --help.\n", stderr); exit(64)
        }
        guard geteuid() == 0 else { fputs("Root is required to read the complete system state.\n", stderr); exit(77) }
        struct State: Encodable { let state: String }
        struct Sample: Encodable {
            let schemaVersion = 1
            let observedAt: String
            let continuousSeconds: Double?
            let preferences: State
            let kernel: State
            let journal: JournalReading
        }
        let preferences = RecoveryReadout.nativePreferences()
        let kernel = RecoveryReadout.nativeKernel()
        let journal = RecoveryReadout.installedJournal()
        // Stamp completion, not the beginning of potentially slow native reads.
        let time = RecoveryReadout.continuousSeconds()
        let sample = Sample(observedAt: Date().ISO8601Format(.init(includingFractionalSeconds: true)),
                            continuousSeconds: time, preferences: State(state: preferences),
                            kernel: State(state: kernel), journal: journal)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let bytes = try? encoder.encode(sample), bytes.count < 4096 else {
            fputs("Cannot encode the bounded readout.\n", stderr); exit(1)
        }
        print(String(decoding: bytes, as: UTF8.self))
        let complete = time != nil && ["containerAbsent", "keyAbsent", "false", "true"].contains(preferences)
            && ["false", "true"].contains(kernel) && ["absent", "present"].contains(journal.state)
        exit(complete ? 0 : 1)
    }
}
#endif
