import Foundation
import KeepMacAwakeControlProtocol
import Darwin

public enum CurrentBoot {
    public static let identifier: String? = {
        var count = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &count, nil, 0) == 0, count > 1, count < 128 else { return nil }
        var bytes = [CChar](repeating: 0, count: count)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &count, nil, 0) == 0 else { return nil }
        return UUID(uuidString: String(cString: bytes))?.uuidString
    }()
}

public enum TrustRequirements {
    public static func isExact(_ requirement: String, identifier: String) -> Bool {
        InstallationTrust.isExact(requirement, identifier: identifier)
    }
}

public struct PeerObservation {
    public let heartbeat: PeerHeartbeat?
    public let observedAt: Double

    public init(read: () -> PeerHeartbeat?, clock: () -> Double) {
        // A peer can publish while the read is in progress.
        heartbeat = read()
        observedAt = clock()
    }
}

public enum RecoveryInspection {
    public static func hasOrphanedJournal(
        withLock: (_ body: () throws -> Bool) throws -> Bool,
        readHeartbeat: @escaping () throws -> PeerHeartbeat?,
        hasJournal: @escaping () throws -> Bool
    ) throws -> Bool {
        try withLock {
            // Activation publishes its intent and creates the journal under this lock.
            guard try readHeartbeat()?.blocking != true else { return false }
            return try hasJournal()
        }
    }
}

public struct WatchdogAssessment {
    private var environmentLostAt: Double?
    private var environmentGeneration: String?
    private var batteryCutoff: (generation: String, sessionID: String, at: Double)?
    public init() {}
    public mutating func shouldFence(_ controller: PeerHeartbeat?, at now: Double, ac: Bool?, console: UInt32?,
                                    batteryPercent: Int? = nil, thermalSafe: Bool = false) -> Bool {
        guard let controller else {
            environmentLostAt = nil; environmentGeneration = nil; batteryCutoff = nil; return true
        }
        // The controller ends a timed session on its next tick. Fencing a fresh
        // controller in that moment turns a normal end into a recovery.
        if controller.isQuiescentController() {
            // An idle controller publishes once a minute, and its heartbeat ages
            // further while the Mac sleeps. Its age alone is no reason to fence.
            environmentLostAt = nil; environmentGeneration = nil; batteryCutoff = nil; return false
        }
        let grace = ControlConstants.sessionEndGraceSeconds
        let metadataIsSafe = controller.controllerIsSafe(at: now, ac: true, console: console, sessionEndGrace: grace)
        guard metadataIsSafe else {
            environmentLostAt = nil; environmentGeneration = nil; batteryCutoff = nil; return true
        }
        if let cutoff = batteryCutoff {
            if controller.generation == cutoff.generation, controller.sessionID == cutoff.sessionID, controller.blocking {
                // A cutoff observed by either process ends this battery session,
                // even if AC returns or the percentage rebounds before the next tick.
                return now < cutoff.at || now - cutoff.at >= 2
            }
            batteryCutoff = nil
        }
        if controller.controllerIsSafe(at: now, ac: ac, console: console, batteryPercent: batteryPercent,
                                       thermalSafe: thermalSafe, sessionEndGrace: grace) {
            environmentLostAt = nil; environmentGeneration = nil
            return false
        }
        // Only an environmental cutoff gets release grace. Invalid session metadata,
        // stale progress, user switch and lease expiry are still fenced immediately.
        if controller.blocking,
           metadataIsSafe {
            if controller.minimumBatteryPercent != nil, let sessionID = controller.sessionID {
                batteryCutoff = (controller.generation, sessionID, now)
                return false
            }
            if environmentLostAt == nil || environmentGeneration != controller.generation {
                environmentLostAt = now; environmentGeneration = controller.generation
            }
            return now - (environmentLostAt ?? now) >= 2
        }
        environmentLostAt = nil; environmentGeneration = nil
        return true
    }
}

public struct PeerHeartbeat: Codable {
    public let generation: String
    public let updatedAt: Double
    public let ready: Bool
    public let sessionUser: UInt32?
    public let sessionID: String?
    public let leaseDeadline: Double?
    public let sessionDeadline: Double?
    public let blocking: Bool
    public let bootID: String?
    public let minimumBatteryPercent: Int?
    public let isUnlimited: Bool
    /// The controller still has to restore the sleep setting. Missing in older
    /// heartbeats, which therefore never count as idle.
    public let restorationPending: Bool?
    public init(generation: String, updatedAt: Double, ready: Bool, sessionUser: UInt32? = nil, sessionID: String? = nil,
                leaseDeadline: Double? = nil, sessionDeadline: Double? = nil, blocking: Bool = true, bootID: String? = CurrentBoot.identifier,
                minimumBatteryPercent: Int? = nil, isUnlimited: Bool = false, restorationPending: Bool? = false) {
        self.generation = generation; self.updatedAt = updatedAt; self.ready = ready
        self.sessionUser = sessionUser; self.leaseDeadline = leaseDeadline; self.sessionDeadline = sessionDeadline
        self.sessionID = sessionID
        self.blocking = blocking
        self.bootID = bootID
        self.minimumBatteryPercent = minimumBatteryPercent; self.isUnlimited = isUnlimited
        self.restorationPending = restorationPending
    }
    public func isFresh(at now: Double, bootID currentBoot: String? = CurrentBoot.identifier) -> Bool {
        guard let currentBoot, !currentBoot.isEmpty, bootID == currentBoot else { return false }
        return ready && !generation.isEmpty && now.isFinite && updatedAt.isFinite &&
        now >= updatedAt && now - updatedAt < ControlConstants.peerTimeoutSeconds
    }
    /// An idle controller: ready, not blocking, nothing to restore and no session
    /// metadata. Its age is no reason to fence it, because the controller publishes
    /// a blocking heartbeat under the transaction lock before it changes any setting,
    /// and the journal check still finds anything left behind. A controller that stops
    /// publishing altogether is caught by `IdleControllerProgress`.
    public func isQuiescentController(bootID currentBoot: String? = CurrentBoot.identifier) -> Bool {
        guard let currentBoot, !currentBoot.isEmpty, bootID == currentBoot else { return false }
        return ready && !generation.isEmpty && !blocking && restorationPending == false && sessionUser == nil &&
            sessionID == nil && leaseDeadline == nil && sessionDeadline == nil && !isUnlimited && minimumBatteryPercent == nil
    }
    public func controllerIsSafe(at now: Double, ac: Bool?, console: UInt32?, batteryPercent: Int? = nil, thermalSafe: Bool = false,
                                 sessionEndGrace: Double = 0) -> Bool {
        guard isFresh(at: now) else { return false }
        guard minimumBatteryPercent.map(ControlConstants.batteryThresholdRange.contains) ?? true else { return false }
        if sessionUser == nil && sessionID == nil && leaseDeadline == nil && sessionDeadline == nil {
            return !isUnlimited && minimumBatteryPercent == nil
        }
        guard let user = sessionUser, user != 0, let sessionID, !sessionID.isEmpty, sessionID.utf8.count <= 128,
              let lease = leaseDeadline, lease.isFinite, now < lease, console == user else { return false }
        if isUnlimited {
            guard sessionDeadline == nil else { return false }
        } else {
            guard let deadline = sessionDeadline, deadline.isFinite, now < deadline + max(0, sessionEndGrace) else { return false }
        }
        return !blocking || SessionPowerPolicy.evaluate(minimumBatteryPercent: minimumBatteryPercent, acPower: ac,
                                                        batteryPercent: batteryPercent, thermalSafe: thermalSafe) == .allowed
    }
}

/// Notices an idle controller that stopped publishing. It measures on the uptime
/// clock, which pauses while the Mac sleeps, so waking up is not mistaken for a hang.
public struct IdleControllerProgress {
    private var last: (generation: String, updatedAt: Double)?
    private var unchangedSince: Double?
    public init() {}
    public mutating func isStalled(_ heartbeat: PeerHeartbeat?, uptime: Double) -> Bool {
        guard let heartbeat, heartbeat.isQuiescentController(), uptime.isFinite else {
            last = nil; unchangedSince = nil; return false
        }
        if let last, let unchangedSince, last.generation == heartbeat.generation, last.updatedAt == heartbeat.updatedAt {
            return uptime - unchangedSince >= ControlConstants.idleControllerStallSeconds
        }
        last = (heartbeat.generation, heartbeat.updatedAt); unchangedSince = uptime
        return false
    }
}

/// How often a service supervises: every second while anything needs it, and
/// once a minute otherwise. A short hold keeps the fast rate across state changes.
public struct SupervisionCadence {
    public private(set) var fastUntil = -Double.infinity
    public init() {}
    public mutating func hold(at now: Double) {
        guard now.isFinite else { return }
        fastUntil = max(fastUntil, now + ControlConstants.supervisionHoldSeconds)
    }
    public mutating func interval(needsSupervision: Bool, at now: Double) -> Double {
        // Without a usable clock, supervise at the full rate.
        guard now.isFinite else { return ControlConstants.supervisionSeconds }
        if needsSupervision { hold(at: now) }
        return now < fastUntil ? ControlConstants.supervisionSeconds : ControlConstants.idleSupervisionSeconds
    }
}

public final class FencedRecovery {
    public private(set) var pending = true
    private let fence: () throws -> Void
    private let restore: () throws -> Void
    private var fenced = false
    public init(fence: @escaping () throws -> Void, restore: @escaping () throws -> Void) {
        self.fence = fence; self.restore = restore
    }
    public func attempt() throws {
        guard pending else { return }
        if !fenced {
            try fence()
            fenced = true
        }
        try restore()
        pending = false
    }
}
