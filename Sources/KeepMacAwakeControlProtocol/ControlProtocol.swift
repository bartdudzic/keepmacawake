import Foundation

public enum ControlConstants {
    public static let version = "1.2"
    public static let serviceName = "com.keepmacawake.Helper"
    public static let watchdogName = "com.keepmacawake.Watchdog"
    public static let installationDirectory = "/Library/PrivilegedHelperTools/com.keepmacawake"
    public static let stateDirectory = "/Library/Application Support/KeepMacAwake"
    /// The only application bundle accepted by the installed service manifest.
    public static let applicationPath = "/Applications/Keep Mac Awake.app"
    public static let appIdentifier = "com.keepmacawake"
    /// The per-user coordinator owns sessions; it is the helper's only client.
    public static let coordinatorIdentifier = "com.keepmacawake.Coordinator"
    public static let coordinatorPath = applicationPath + "/Contents/MacOS/KeepMacAwakeCoordinator"
    public static let cliIdentifier = "com.keepmacawake.cli"
    public static let cliPath = applicationPath + "/Contents/MacOS/keepmacawake"
    public static let leaseSeconds: Double = 12
    public static let peerTimeoutSeconds: Double = 8
    /// How long the watchdog lets a fresh controller end a timed session on its
    /// own after the deadline: one controller tick, a bounded restore and a read.
    public static let sessionEndGraceSeconds: Double = 4
    /// Both services check every second while anything needs supervision.
    public static let supervisionSeconds: Double = 1
    /// With no session, nothing to restore and no recovery, they check once a minute.
    public static let idleSupervisionSeconds: Double = 60
    /// After the last state that needed it, or a wake from the peer, the fast rate lasts this long.
    public static let supervisionHoldSeconds: Double = 10
    /// Start waits this long for the watchdog to answer a wake. Together with the
    /// 1.5 s kernel confirmation it stays well below the app's 3 s request timeout.
    public static let watchdogWakeTimeoutSeconds: Double = 0.75
    /// An idle controller whose heartbeat stays unchanged this long while the Mac is
    /// awake has stopped working, and the watchdog restarts it.
    public static let idleControllerStallSeconds: Double = 3 * idleSupervisionSeconds
    /// Darwin notifications carry no data and grant nothing; they only end an idle wait.
    public static let watchdogWakeName = watchdogName + ".wake"
    public static let watchdogStartName = watchdogName + ".start"
    /// A timed session lasts a whole number of hours in this range, at most one week.
    public static let sessionHours = 1...168
    public static let maximumSessionSeconds = sessionHours.upperBound * 3600
    public static let batteryThresholdRange = 1...100

    /// Zero explicitly requests a session without a time limit, never an infinite lease.
    public static func isSupportedDuration(_ seconds: Int) -> Bool {
        seconds == 0 || (seconds % 3600 == 0 && sessionHours.contains(seconds / 3600))
    }
}

@objc public protocol KeepMacAwakeServiceProtocol {
    func request(_ data: Data, withReply reply: @escaping (Data) -> Void)
}

public struct ControlRequest: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case status, start, renew, stop }
    public let kind: Kind
    public let durationSeconds: Int?
    public let sessionID: String?
    public let minimumBatteryPercent: Int?
    public init(_ kind: Kind, durationSeconds: Int? = nil, sessionID: String? = nil, minimumBatteryPercent: Int? = nil) {
        self.kind = kind; self.durationSeconds = durationSeconds; self.sessionID = sessionID
        self.minimumBatteryPercent = minimumBatteryPercent
    }
    public var isValid: Bool {
        guard sessionID.map({ !$0.isEmpty && $0.utf8.count <= 128 }) ?? true else { return false }
        switch kind {
        case .start:
            return sessionID == nil && durationSeconds.map(ControlConstants.isSupportedDuration) == true &&
                (minimumBatteryPercent.map(ControlConstants.batteryThresholdRange.contains) ?? true)
        case .renew:
            return sessionID != nil && durationSeconds == nil && minimumBatteryPercent == nil
        case .stop:
            return durationSeconds == nil && minimumBatteryPercent == nil
        case .status:
            return sessionID == nil && durationSeconds == nil && minimumBatteryPercent == nil
        }
    }
}

public struct ControlStatus: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable {
        case unavailable, idle, starting, active, waitingForAC, restoring, failed
    }
    /// A closed code for the observed terminal trigger. Unknown future codes
    /// remain valid status responses and never become arbitrary log content.
    public enum TerminationReason: String, Codable, Sendable {
        case clientStopped, durationElapsed, leaseExpired, consoleUserChanged
        case watchdogUnavailable, watchdogRestarted
        case batteryThresholdReached, powerUnknown, batteryUnknown, thermalUnsafe, invalidConfiguration
        case disconnected, backendActivationFailed, backendVerificationFailed
        case recoveryRequired, recoveryFailed, serviceStopping, unknown

        public init(from decoder: Decoder) throws {
            let value = try? decoder.singleValueContainer().decode(String.self)
            self = value.flatMap(Self.init(rawValue:)) ?? .unknown
        }
    }
    public var phase: Phase
    public var message: String
    public var sessionID: String?
    public var remainingSeconds: Int?
    public var version: String
    public var minimumBatteryPercent: Int?
    public var isUnlimited: Bool
    public var terminationReason: TerminationReason?
    /// When the helper first accepted a session on this Mac, and the latest
    /// wall-clock time it has seen since (Unix seconds); nil before the first session.
    public var firstSessionAt: Int?
    public var latestSeenAt: Int?
    public init(phase: Phase, message: String, sessionID: String? = nil, remainingSeconds: Int? = nil,
                minimumBatteryPercent: Int? = nil, isUnlimited: Bool = false,
                terminationReason: TerminationReason? = nil) {
        self.phase = phase; self.message = message; self.sessionID = sessionID
        self.remainingSeconds = remainingSeconds; self.version = ControlConstants.version
        self.minimumBatteryPercent = minimumBatteryPercent; self.isUnlimited = isUnlimited
        self.terminationReason = terminationReason
    }
}

/// Exact code requirements (identifier and cdhash) of one installed build,
/// written by the installer into a root-owned file.
public struct InstallationTrust: Codable, Sendable {
    public let helperRequirement: String
    public let appRequirement: String
    public let coordinatorRequirement: String
    public let cliRequirement: String
    public init(helperRequirement: String, appRequirement: String,
                coordinatorRequirement: String, cliRequirement: String) {
        self.helperRequirement = helperRequirement; self.appRequirement = appRequirement
        self.coordinatorRequirement = coordinatorRequirement; self.cliRequirement = cliRequirement
    }

    /// True only for `identifier "<identifier>" and cdhash H"<40 hex>"`.
    public static func isExact(_ requirement: String, identifier: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: identifier)
        let pattern = "^identifier \"\(escaped)\" and cdhash H\"[a-fA-F0-9]{40}\"$"
        return requirement.range(of: pattern, options: .regularExpression) != nil
    }
}
