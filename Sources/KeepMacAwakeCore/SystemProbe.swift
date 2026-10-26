import Foundation
import IOKit
import IOKit.pwr_mgt
import IOKit.ps

enum ProbeRead<Value> {
    case value(Value)
    case unavailable(PowerProbeIssue)
}

/// Reads independent power and lid observations. It never changes power state.
/// The two APIs do not provide an atomic snapshot across both observations.
public struct SystemProbe {
    private let readPowerSources: () -> ProbeRead<[NSDictionary]>
    private let readLidState: () -> ProbeRead<Any>
    private let readProvidingSource: () -> ProbeRead<String>
    private let readHasBatteryService: () -> Bool

    public init() {
        self.init(readPowerSources: NativePowerReader.readPowerSources,
                  readLidState: NativePowerReader.readLidState,
                  readProvidingSource: NativePowerReader.readProvidingSource,
                  readHasBatteryService: NativePowerReader.readHasBatteryService)
    }

    init(
        readPowerSources: @escaping () -> ProbeRead<[NSDictionary]>,
        readLidState: @escaping () -> ProbeRead<Any>,
        readProvidingSource: @escaping () -> ProbeRead<String> = { .unavailable(.powerSourceStateUnavailable) },
        readHasBatteryService: @escaping () -> Bool = { true }
    ) {
        self.readPowerSources = readPowerSources
        self.readLidState = readLidState
        self.readProvidingSource = readProvidingSource
        self.readHasBatteryService = readHasBatteryService
    }

    public func read() -> PowerProbeResult {
        PowerSnapshotMapper.map(powerSources: readPowerSources(), lidState: readLidState(),
                                providingSource: readProvidingSource, hasBatteryService: readHasBatteryService)
    }

    /// Whether this Mac is a desktop, for the interface: false as soon as the kernel
    /// has a battery service (every MacBook), true when a full reading says desktop,
    /// nil while the readings do not settle it. Both answers are hardware facts.
    public func readKind() -> Bool? {
        if readHasBatteryService() { return false }
        return read().isDesktop ? true : nil
    }
}

enum PowerSnapshotMapper {
    static func map(
        descriptions: [NSDictionary], lidState: Any?, providingSource: String? = nil, hasBatteryService: Bool = true
    ) -> PowerProbeResult {
        map(powerSources: .value(descriptions),
            lidState: lidState.map(ProbeRead.value) ?? .unavailable(.lidStateUnavailable),
            providingSource: { providingSource.map(ProbeRead.value) ?? .unavailable(.powerSourceStateUnavailable) },
            hasBatteryService: { hasBatteryService })
    }

    static func map(
        powerSources: ProbeRead<[NSDictionary]>, lidState: ProbeRead<Any>,
        providingSource: () -> ProbeRead<String> = { .unavailable(.powerSourceStateUnavailable) },
        hasBatteryService: () -> Bool = { true }
    ) -> PowerProbeResult {
        if let desktop = desktopReading(powerSources: powerSources, lidState: lidState,
                                        providingSource: providingSource, hasBatteryService: hasBatteryService) {
            return desktop
        }
        var issues: [PowerProbeIssue] = []
        let description: NSDictionary?
        switch powerSources {
        case .value(let descriptions):
            description = selectInternalBattery(descriptions, issues: &issues)
        case .unavailable(let issue):
            issues.append(issue)
            description = nil
        }
        let source = description.map { powerSource($0, issues: &issues) } ?? .unknown
        let percent = description.flatMap { batteryPercent($0, issues: &issues) }
        let charging = description.flatMap {
            boolean($0[kIOPSIsChargingKey], missing: .chargingStateUnavailable,
                    invalid: .chargingStateInvalid, issues: &issues)
        }
        let lidClosed: Bool?
        switch lidState {
        case .value(let value):
            lidClosed = boolean(value, missing: .lidStateUnavailable,
                                invalid: .lidStateInvalid, issues: &issues)
        case .unavailable(let issue):
            issues.append(issue)
            lidClosed = nil
        }

        return PowerProbeResult(snapshot: PowerSnapshot(
            source: source,
            batteryPercent: percent,
            isCharging: charging,
            lidClosed: lidClosed
        ), issues: issues.reduce(into: []) { unique, issue in
            if !unique.contains(issue) { unique.append(issue) }
        })
    }

    /// A Mac without a built-in battery has no battery to read AC power from, so the
    /// source macOS says is providing power answers instead. Three independent signals
    /// must agree: the power source list has no built-in battery entry at all, the
    /// power manager has no lid state, and the kernel has no battery service. A MacBook
    /// keeps its battery service even while the other two are not yet published (early
    /// in boot), so a failed or incomplete battery read there still ends as unknown.
    /// The later reads happen only when the earlier signals already point to a desktop.
    private static func desktopReading(
        powerSources: ProbeRead<[NSDictionary]>, lidState: ProbeRead<Any>,
        providingSource: () -> ProbeRead<String>, hasBatteryService: () -> Bool
    ) -> PowerProbeResult? {
        guard case .value(let descriptions) = powerSources,
              case .unavailable(.lidStateUnavailable) = lidState else { return nil }
        for description in descriptions {
            // Any unreadable type or any built-in battery entry, present or not, means a MacBook path.
            guard let type = description[kIOPSTypeKey] as? String,
                  type != kIOPSInternalBatteryType else { return nil }
        }
        guard !hasBatteryService() else { return nil }
        var issues: [PowerProbeIssue] = []
        let source: PowerSource
        // macOS answers "AC Power" whenever it has nothing else to report, so on a desktop
        // AC is the default; only a UPS on its battery reports otherwise.
        switch providingSource() {
        case .value(let value) where value == kIOPMACPowerKey:
            source = .ac
        case .value(let value) where value == kIOPMBatteryPowerKey || value == kIOPMUPSPowerKey:
            // A UPS running on its battery: there is no AC, and no level of ours to rely on.
            source = .battery
        case .value:
            issues.append(.powerSourceStateInvalid)
            source = .unknown
        case .unavailable(let issue):
            // Defensive: current macOS never fails this read.
            issues.append(issue)
            source = .unknown
        }
        return PowerProbeResult(
            snapshot: PowerSnapshot(source: source, batteryPercent: nil, isCharging: nil, lidClosed: nil),
            issues: issues, isDesktop: true)
    }

    private static func selectInternalBattery(
        _ descriptions: [NSDictionary], issues: inout [PowerProbeIssue]
    ) -> NSDictionary? {
        var presentBatteries: [NSDictionary] = []
        for description in descriptions {
            guard let type = description[kIOPSTypeKey] as? String else {
                issues.append(.powerSourceTypeInvalid)
                continue
            }
            // A UPS or attached accessory describes its own battery, not the MacBook's.
            guard type == kIOPSInternalBatteryType else { continue }
            guard let present = strictBoolean(description[kIOPSIsPresentKey]) else {
                issues.append(.batteryPresenceInvalid)
                continue
            }
            if present { presentBatteries.append(description) }
        }
        guard !issues.contains(.batteryPresenceInvalid) else { return nil }
        guard !presentBatteries.isEmpty else {
            issues.append(.internalBatteryUnavailable)
            return nil
        }
        guard presentBatteries.count == 1 else {
            issues.append(.internalBatteryAmbiguous)
            return nil
        }
        return presentBatteries[0]
    }

    private static func powerSource(
        _ description: NSDictionary, issues: inout [PowerProbeIssue]
    ) -> PowerSource {
        guard let value = description[kIOPSPowerSourceStateKey] else {
            issues.append(.powerSourceStateUnavailable)
            return .unknown
        }
        switch value as? String {
        case kIOPSACPowerValue: return .ac
        case kIOPSBatteryPowerValue: return .battery
        default:
            issues.append(.powerSourceStateInvalid)
            return .unknown
        }
    }

    private static func batteryPercent(
        _ description: NSDictionary, issues: inout [PowerProbeIssue]
    ) -> Int? {
        guard let currentValue = description[kIOPSCurrentCapacityKey],
              let maximumValue = description[kIOPSMaxCapacityKey] else {
            issues.append(.batteryCapacityUnavailable)
            return nil
        }
        guard let current = strictInteger(currentValue),
              let maximum = strictInteger(maximumValue),
              maximum > 0, current >= 0, current <= maximum else {
            issues.append(.batteryCapacityInvalid)
            return nil
        }
        // Divide before multiplying to avoid integer overflow. Display nearest percent.
        return Int((Double(current) / Double(maximum) * 100).rounded())
    }

    private static func boolean(
        _ value: Any?, missing: PowerProbeIssue, invalid: PowerProbeIssue,
        issues: inout [PowerProbeIssue]
    ) -> Bool? {
        guard let value else {
            issues.append(missing)
            return nil
        }
        guard let result = strictBoolean(value) else {
            issues.append(invalid)
            return nil
        }
        return result
    }

    private static func strictBoolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func strictInteger(_ value: Any) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFNumberGetTypeID() else { return nil }
        let cfNumber = number as CFNumber
        guard !CFNumberIsFloatType(cfNumber) else { return nil }
        var result: Int64 = 0
        guard CFNumberGetValue(cfNumber, .sInt64Type, &result) else { return nil }
        return result
    }
}

private enum NativePowerReader {
    static func readPowerSources() -> ProbeRead<[NSDictionary]> {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return .unavailable(.powerSourcesUnavailable)
        }
        guard let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() else {
            return .unavailable(.powerSourceListUnavailable)
        }

        // GetPowerSourceDescription borrows from info. Keep it alive while copying
        // only the fields this probe needs, retaining no device names or identifiers.
        return withExtendedLifetime(info) {
            var descriptions: [NSDictionary] = []
            let keys = [kIOPSTypeKey, kIOPSIsPresentKey, kIOPSPowerSourceStateKey,
                        kIOPSCurrentCapacityKey, kIOPSMaxCapacityKey, kIOPSIsChargingKey]
            for handle in list as NSArray {
                guard let description = IOPSGetPowerSourceDescription(info, handle as CFTypeRef)?
                    .takeUnretainedValue() else {
                    return .unavailable(.powerSourceDescriptionUnavailable)
                }
                let dictionary = description as NSDictionary
                var fields: [String: Any] = [:]
                for key in keys {
                    fields[key] = dictionary[key]
                }
                descriptions.append(fields as NSDictionary)
            }
            return .value(descriptions)
        }
    }

    static func readProvidingSource() -> ProbeRead<String> {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return .unavailable(.powerSourcesUnavailable)
        }
        return withExtendedLifetime(info) {
            guard let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else {
                return .unavailable(.powerSourceStateUnavailable)
            }
            return .value(type as String)
        }
    }

    /// Whether the kernel has a battery service. Every MacBook has one from early boot.
    static func readHasBatteryService() -> Bool {
        // GetMatchingService consumes the matching dictionary and owns one service reference.
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return false }
        IOObjectRelease(service)
        return true
    }

    static func readLidState() -> ProbeRead<Any> {
        // GetMatchingService consumes the matching dictionary and owns one service reference.
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return .unavailable(.lidServiceUnavailable) }
        defer { IOObjectRelease(service) }

        guard let state = IORegistryEntryCreateCFProperty(
            service, kAppleClamshellStateKey as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() else {
            return .unavailable(.lidStateUnavailable)
        }
        return .value(state)
    }
}
