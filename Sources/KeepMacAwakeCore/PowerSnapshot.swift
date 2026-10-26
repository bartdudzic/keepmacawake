public enum PowerSource: String, Codable {
    case ac, battery, unknown
}

public struct PowerSnapshot: Codable, Equatable {
    public let source: PowerSource
    public let batteryPercent: Int?
    public let isCharging: Bool?
    public let lidClosed: Bool?

    public init(source: PowerSource, batteryPercent: Int?, isCharging: Bool?, lidClosed: Bool?) {
        self.source = source
        self.batteryPercent = batteryPercent
        self.isCharging = isCharging
        self.lidClosed = lidClosed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(source, forKey: .source)
        // A stable JSON shape makes unavailable measurements explicit.
        try container.encode(batteryPercent, forKey: .batteryPercent)
        try container.encode(isCharging, forKey: .isCharging)
        try container.encode(lidClosed, forKey: .lidClosed)
    }
}

public struct PowerProbeResult: Codable, Equatable {
    public let snapshot: PowerSnapshot
    public let issues: [PowerProbeIssue]
    /// A Mac with neither a built-in battery nor a lid (Mac mini, iMac, Mac Studio, Mac Pro).
    public let isDesktop: Bool

    public init(snapshot: PowerSnapshot, issues: [PowerProbeIssue] = [], isDesktop: Bool = false) {
        self.snapshot = snapshot
        self.issues = issues
        self.isDesktop = isDesktop
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        snapshot = try container.decode(PowerSnapshot.self, forKey: .snapshot)
        issues = try container.decode([PowerProbeIssue].self, forKey: .issues)
        // Readings from before build 22 have no field: they came from a MacBook path.
        isDesktop = try container.decodeIfPresent(Bool.self, forKey: .isDesktop) ?? false
    }
}

/// Fixed codes only: no raw registry values or device identifiers are retained.
public enum PowerProbeIssue: String, Codable {
    case powerSourcesUnavailable
    case powerSourceListUnavailable
    case powerSourceDescriptionUnavailable
    case internalBatteryUnavailable
    case internalBatteryAmbiguous
    case powerSourceTypeInvalid
    case batteryPresenceInvalid
    case powerSourceStateUnavailable
    case powerSourceStateInvalid
    case batteryCapacityUnavailable
    case batteryCapacityInvalid
    case chargingStateUnavailable
    case chargingStateInvalid
    case lidServiceUnavailable
    case lidStateUnavailable
    case lidStateInvalid
}
