import Foundation
import CoreFoundation
import Darwin
import IOKit
import notify

/// Native operations are used only by the explicitly started privileged service.
final class NativeSleepBackend: SleepBackend {
    private let domain = "com.apple.PowerManagement" as CFString
    private let container = "SystemPowerSettings" as CFString

    func readPreferences() throws -> [String: Any]? {
        guard CFPreferencesSynchronize(domain, kCFPreferencesAnyUser, kCFPreferencesCurrentHost) else {
            throw SleepControlError.invalidState("Could not synchronize preferences.")
        }
        guard let value = CFPreferencesCopyValue(container, domain, kCFPreferencesAnyUser, kCFPreferencesCurrentHost) else { return nil }
        guard CFGetTypeID(value) == CFDictionaryGetTypeID(), let dictionary = value as? [String: Any] else {
            throw SleepControlError.invalidState("SystemPowerSettings is not a dictionary.")
        }
        return dictionary
    }

    func writePreferences(_ preferences: [String: Any]?) throws {
        guard geteuid() == 0 else { throw SleepControlError.preferencesWriteFailed }
        CFPreferencesSetValue(container, preferences as CFDictionary?, domain, kCFPreferencesAnyUser, kCFPreferencesCurrentHost)
        guard CFPreferencesSynchronize(domain, kCFPreferencesAnyUser, kCFPreferencesCurrentHost) else {
            throw SleepControlError.preferencesWriteFailed
        }
        guard notify_post("com.apple.system.powermanagement.prefschange") == NOTIFY_STATUS_OK else {
            throw SleepControlError.preferencesWriteFailed
        }
    }

    func readKernelSleepDisabled() throws -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "SleepDisabled" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else { return nil }
        return strictBoolean(value)
    }

    func waitForKernelSleepDisabled(_ value: Bool) throws {
        let deadline = continuousSeconds() + 1.5
        repeat {
            if try readKernelSleepDisabled() == value { return }
            usleep(20_000)
        } while continuousSeconds() < deadline
        throw SleepControlError.verificationFailed
    }
}

/// Monotonic time that includes sleep; wall-clock adjustments cannot extend a lease.
public func continuousSeconds() -> Double {
    var timebase = mach_timebase_info_data_t()
    guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom != 0 else { return .infinity }
    return Double(mach_continuous_time()) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
}
