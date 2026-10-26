import KeepMacAwakeControlProtocol

/// Shared rules, evaluated against independent native readings by each process.
public enum SessionPowerDecision: Equatable {
    case allowed, waitingForAC, batteryLimitReached, unknownPower, unknownBattery, thermalLimit, invalidConfiguration

    public var terminationReason: ControlStatus.TerminationReason? {
        switch self {
        case .allowed, .waitingForAC: return nil
        case .batteryLimitReached: return .batteryThresholdReached
        case .unknownPower: return .powerUnknown
        case .unknownBattery: return .batteryUnknown
        case .thermalLimit: return .thermalUnsafe
        case .invalidConfiguration: return .invalidConfiguration
        }
    }

    /// Describes the decision for a session that is already running.
    public func message(minimumBatteryPercent: Int?) -> String {
        switch self {
        case .allowed: return "Power conditions allow the session."
        case .waitingForAC: return "Waiting for AC power. Connecting it does not wake a Mac that is already asleep."
        case .batteryLimitReached:
            return "The battery reached the \(minimumBatteryPercent ?? 20)% threshold. The session ended and sleep prevention is off."
        case .unknownPower: return "The power source could not be confirmed. The session ended."
        case .unknownBattery: return "The battery level could not be confirmed. The session ended."
        case .thermalLimit: return "This Mac is too warm to keep running on battery power. The session ended."
        case .invalidConfiguration: return "The battery threshold is invalid. The session ended."
        }
    }

    /// Explains why a new Start was refused before any setting changed.
    public func startRefusalMessage(minimumBatteryPercent: Int?) -> String {
        switch self {
        case .allowed: return "Power conditions allow the session."
        case .waitingForAC:
            return "AC power is not connected and battery use is off. Connect AC power or turn on Run on battery."
        case .batteryLimitReached:
            return "The battery is at or below the \(minimumBatteryPercent ?? 20)% threshold. Connect AC power or lower the battery threshold."
        case .unknownPower: return "The power source could not be confirmed. Try again in a moment."
        case .unknownBattery: return "The battery level could not be confirmed. Try again in a moment."
        case .thermalLimit: return "This Mac is too warm to start on battery power. Let it cool down or connect AC power."
        case .invalidConfiguration: return "The battery threshold is invalid. Choose a value from 1 to 100%."
        }
    }
}

public enum SessionPowerPolicy {
    public static func evaluate(minimumBatteryPercent: Int?, acPower: Bool?, batteryPercent: Int?, thermalSafe: Bool) -> SessionPowerDecision {
        if let minimumBatteryPercent, !ControlConstants.batteryThresholdRange.contains(minimumBatteryPercent) {
            return .invalidConfiguration
        }
        if acPower == true { return .allowed }
        guard let minimumBatteryPercent else { return .waitingForAC }
        guard acPower == false else { return .unknownPower }
        guard let batteryPercent, (0...100).contains(batteryPercent) else { return .unknownBattery }
        guard batteryPercent > minimumBatteryPercent else { return .batteryLimitReached }
        guard thermalSafe else { return .thermalLimit }
        return .allowed
    }
}
