import Foundation
import CoreFoundation

enum OriginalSleepSetting: String, Codable {
    case containerAbsent
    case keyAbsent
    case falseValue
}

enum RecoveryPhase: String, Codable {
    case prepared
    case changing
    case kernelRestored
}

struct RecoveryRecord: Codable, Equatable {
    let schemaVersion: Int
    let original: OriginalSleepSetting
    var phase: RecoveryPhase

    init(original: OriginalSleepSetting, phase: RecoveryPhase = .prepared) {
        schemaVersion = 1
        self.original = original
        self.phase = phase
    }
}

protocol SleepBackend: AnyObject {
    func readPreferences() throws -> [String: Any]?
    func writePreferences(_ preferences: [String: Any]?) throws
    func readKernelSleepDisabled() throws -> Bool?
    func waitForKernelSleepDisabled(_ value: Bool) throws
}

protocol RecoveryStore: AnyObject {
    func load() throws -> RecoveryRecord?
    func save(_ record: RecoveryRecord) throws
    func remove() throws
}

public enum SleepControlError: Error, LocalizedError {
    case conflict(String)
    case invalidState(String)
    case pendingRecovery
    case verificationFailed
    case journal(String)
    case preferencesWriteFailed
    case authorizationExpired

    public var errorDescription: String? {
        switch self {
        case .conflict(let reason): return "Sleep setting conflict: \(reason)"
        case .invalidState(let reason): return "Unknown sleep setting state: \(reason)"
        case .pendingRecovery: return "The previous session must be restored first."
        case .verificationFailed: return "The system did not confirm the expected SleepDisabled value."
        case .journal(let reason): return "Recovery journal error: \(reason)"
        case .preferencesWriteFailed: return "Could not write the sleep setting."
        case .authorizationExpired: return "The session or power conditions became invalid before activation."
        }
    }
}

/// The caller must hold the shared external filesystem lock for every operation.
public final class SleepTransaction {
    let backend: SleepBackend
    let store: RecoveryStore
    private var unappliedRecoveryBlocked = false

    public convenience init(directory: URL) {
        self.init(backend: NativeSleepBackend(), store: RecoveryJournal(directory: directory))
    }

    init(backend: SleepBackend, store: RecoveryStore) {
        self.backend = backend
        self.store = store
    }

    public var hasPendingRecovery: Bool {
        do { return try store.load() != nil } catch { return true }
    }

    public func activate() throws { try activate(authorized: { true }) }

    public func activate(authorized: () -> Bool) throws {
        guard authorized() else { throw SleepControlError.authorizationExpired }
        guard try store.load() == nil else { throw SleepControlError.pendingRecovery }
        unappliedRecoveryBlocked = false
        let initial = try backend.readPreferences()
        let initialValue = try setting(in: initial)
        guard initialValue != .on else { throw SleepControlError.conflict("SleepDisabled is already on. Another tool may be preventing sleep.") }
        try requireKernel(false)
        let original: OriginalSleepSetting = initial == nil ? .containerAbsent : (initialValue == .absent ? .keyAbsent : .falseValue)
        var record = RecoveryRecord(original: original)
        try store.save(record)

        // Re-read after durable preparation. Never write a saved whole dictionary back.
        let current = try backend.readPreferences()
        guard try setting(in: current) == initialValue else {
            // A prepared record cannot authorize recovery writes, even if removal fails.
            try store.remove()
            throw SleepControlError.conflict("SleepDisabled changed before activation.")
        }
        try requireKernel(false)
        record.phase = .changing
        try store.save(record)
        var changed: [String: Any]
        do {
            let fresh = try backend.readPreferences()
            guard try setting(in: fresh) == initialValue else {
                throw SleepControlError.conflict("SleepDisabled changed while the recovery journal was being prepared.")
            }
            try requireKernel(false)
            changed = fresh ?? [:]
            changed["SleepDisabled"] = true
        } catch {
            try discardUnappliedRecord(record)
            throw error
        }
        guard authorized() else {
            try discardUnappliedRecord(record)
            throw SleepControlError.authorizationExpired
        }
        // The durable changing record precedes the first possible mutation.
        // CFPreferences has no CAS; concurrent external writers remain a documented limit.
        try backend.writePreferences(changed)
        try backend.waitForKernelSleepDisabled(true)
        guard try verifyActive() else { throw SleepControlError.verificationFailed }
    }

    public func restore() throws {
        guard var record = try store.load() else { return }
        guard record.schemaVersion == 1 else { throw SleepControlError.journal("Unsupported version.") }
        if record.phase == .prepared {
            try store.remove()
            return
        }
        guard !unappliedRecoveryBlocked else {
            throw SleepControlError.conflict("An invalidated journal cannot be restored safely after it could be neither updated nor removed.")
        }

        if record.phase == .changing {
            var current = try backend.readPreferences()
            let value = try setting(in: current)
            if record.original == .falseValue && value == .absent {
                throw SleepControlError.conflict("Another process removed the original key.")
            }
            guard let kernel = try backend.readKernelSleepDisabled() else {
                throw SleepControlError.invalidState("The system did not report SleepDisabled.")
            }
            if value == .on || kernel {
                // A real false value is necessary before removing an originally absent container.
                if current == nil { current = [:] }
                current?["SleepDisabled"] = false
                try backend.writePreferences(current)
                try backend.waitForKernelSleepDisabled(false)
            }
            try requireKernel(false)
            guard try setting(in: backend.readPreferences()) != .on else {
                throw SleepControlError.conflict("SleepDisabled was turned on again during restoration.")
            }
            record.phase = .kernelRestored
            try store.save(record)
        }

        // This phase is repeatable after interruption before or after metadata cleanup.
        try requireKernel(false)
        var current = try backend.readPreferences()
        let value = try setting(in: current)
        guard value != .on else {
            throw SleepControlError.conflict("SleepDisabled was turned on again after the kernel state was restored.")
        }
        if record.original == .falseValue {
            guard value == .off else { throw SleepControlError.conflict("The original key was removed.") }
        } else {
            if value == .off {
                current?.removeValue(forKey: "SleepDisabled")
                if record.original == .containerAbsent && current?.isEmpty == true { current = nil }
                try backend.writePreferences(current)
            } else if record.original == .containerAbsent && current?.isEmpty == true {
                try backend.writePreferences(nil)
            }
            let restored = try backend.readPreferences()
            guard try setting(in: restored) == .absent else { throw SleepControlError.verificationFailed }
            if record.original == .keyAbsent && restored == nil {
                throw SleepControlError.conflict("Another process removed the original settings dictionary.")
            }
        }
        try requireKernel(false)
        try store.remove()
    }

    public func verifyActive() throws -> Bool {
        guard !unappliedRecoveryBlocked else { return false }
        guard let record = try store.load(), record.phase == .changing else { return false }
        return try setting(in: backend.readPreferences()) == .on && backend.readKernelSleepDisabled() == true
    }

    private func requireKernel(_ expected: Bool) throws {
        guard let actual = try backend.readKernelSleepDisabled() else {
            throw SleepControlError.invalidState("The system did not report SleepDisabled.")
        }
        guard actual == expected else { throw SleepControlError.verificationFailed }
    }

    private func discardUnappliedRecord(_ record: RecoveryRecord) throws {
        // No native mutation has been attempted. Never roll back a newly observed
        // foreign value merely because invalidating the write-ahead record failed.
        unappliedRecoveryBlocked = true
        var prepared = record
        prepared.phase = .prepared
        do {
            try store.save(prepared)
        } catch {
            do {
                try store.remove()
                unappliedRecoveryBlocked = false
                return
            } catch {
                // If neither durable update nor deletion works, another process
                // cannot learn this fact from the journal. Concurrent external
                // writes plus this storage failure are outside the recovery guarantee.
                throw SleepControlError.journal("Cannot invalidate the journal before changing settings. Check for conflicting tools and disk state.")
            }
        }
        try store.remove()
        unappliedRecoveryBlocked = false
    }
}

private enum SleepSettingValue { case absent, off, on }

private func setting(in preferences: [String: Any]?) throws -> SleepSettingValue {
    guard let value = preferences?["SleepDisabled"] else { return .absent }
    guard let boolean = strictBoolean(value) else { throw SleepControlError.invalidState("SleepDisabled is not a boolean value.") }
    return boolean ? .on : .off
}

func strictBoolean(_ value: Any) -> Bool? {
    let object = value as CFTypeRef
    guard CFGetTypeID(object) == CFBooleanGetTypeID() else { return nil }
    return CFEqual(object, kCFBooleanTrue)
}
