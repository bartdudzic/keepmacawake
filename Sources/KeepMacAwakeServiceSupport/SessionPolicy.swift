import Foundation
import KeepMacAwakeControlProtocol

public struct SafetySnapshot {
    public var now: Double
    public var acPower: Bool?
    public var consoleUser: UInt32?
    public var watchdogGeneration: String?
    public var watchdogFresh: Bool
    public var batteryPercent: Int?
    public var thermalSafe: Bool
    public init(now: Double, acPower: Bool?, consoleUser: UInt32?, watchdogGeneration: String?, watchdogFresh: Bool,
                batteryPercent: Int? = nil, thermalSafe: Bool = false) {
        self.now = now; self.acPower = acPower; self.consoleUser = consoleUser
        self.watchdogGeneration = watchdogGeneration; self.watchdogFresh = watchdogFresh
        self.batteryPercent = batteryPercent; self.thermalSafe = thermalSafe
    }
    func powerDecision(minimumBatteryPercent: Int?) -> SessionPowerDecision {
        SessionPowerPolicy.evaluate(minimumBatteryPercent: minimumBatteryPercent, acPower: acPower,
                                    batteryPercent: batteryPercent, thermalSafe: thermalSafe)
    }
}

public protocol SessionBackend: AnyObject {
    func activate(authorized: () -> Bool) throws
    func restore() throws
    func verifyActive() throws -> Bool
}

public final class SessionPolicy {
    public private(set) var status = ControlStatus(phase: .idle, message: "Ready.")
    public var leaseDeadline: Double? { session?.leaseDeadline }
    public var sessionDeadline: Double? { session?.deadline }
    public var sessionUser: UInt32? { session?.user }
    public var sessionIdentifier: String? { session?.id }
    public var minimumBatteryPercent: Int? { session?.minimumBatteryPercent }
    public var sessionIsUnlimited: Bool { session != nil && session?.deadline == nil }
    public var requiresRestoration: Bool { restorationNeeded }
    /// A session or a pending restoration needs supervision every second.
    public var needsSupervision: Bool { session != nil || restorationNeeded }
    /// What the controller tells the watchdog about this policy.
    public func controllerHeartbeat(generation: String, updatedAt: Double, ready: Bool) -> PeerHeartbeat {
        let blocking = status.phase == .starting || status.phase == .active || status.phase == .restoring
        return PeerHeartbeat(generation: generation, updatedAt: updatedAt, ready: ready,
                             sessionUser: sessionUser, sessionID: sessionIdentifier, leaseDeadline: leaseDeadline,
                             sessionDeadline: sessionDeadline, blocking: blocking,
                             minimumBatteryPercent: minimumBatteryPercent, isUnlimited: sessionIsUnlimited,
                             restorationPending: restorationNeeded)
    }
    /// Recovery responses can expose a retained reason only to the exact
    /// connection and token that owned the ended session.
    public func retainedTerminationReason(sessionID: String?, connection: UUID, user: UInt32) -> ControlStatus.TerminationReason? {
        guard let sessionID, let endedSession,
              endedSession.id == sessionID, endedSession.connection == connection,
              endedSession.user == user else { return nil }
        return terminalReason
    }
    private struct Session {
        let id: String
        let connection: UUID
        let user: UInt32
        let deadline: Double?
        let minimumBatteryPercent: Int?
        var leaseDeadline: Double
        let watchdog: String
        func isWithinTime(at now: Double) -> Bool {
            now.isFinite && now < leaseDeadline && (deadline.map { now < $0 } ?? true)
        }
    }
    private var session: Session?
    // Retain one terminal owner/token so a later Renew can learn why its session ended.
    private var endedSession: Session?
    private var terminalReason: ControlStatus.TerminationReason?
    private var active = false
    private var restorationNeeded = false
    private let backend: SessionBackend
    private let snapshot: () -> SafetySnapshot

    public init(backend: SessionBackend, snapshot: @escaping () -> SafetySnapshot) {
        self.backend = backend; self.snapshot = snapshot
    }

    public func handle(_ request: ControlRequest, connection: UUID, user: UInt32) -> ControlStatus {
        // Expiration is evaluated BEFORE renewal, so an old token never revives intent.
        tick()
        let safety = snapshot()
        guard safety.consoleUser == user, user != 0 else {
            return rejected("The request must come from the user logged in at the console.")
        }
        guard request.isValid else { return rejected("Invalid duration, battery threshold or request parameters.") }
        // A cutoff detected during Renew must reach the UI with its actual reason.
        if request.kind == .renew, session == nil, let endedSession,
           endedSession.connection == connection, endedSession.user == user, endedSession.id == request.sessionID {
            return statusFor(connection)
        }
        switch request.kind {
        case .status:
            if session == nil && !restorationNeeded && status.phase == .failed {
                status = ControlStatus(phase: .idle, message: "The sleep setting was restored. Ready for a new session.",
                                       terminationReason: terminalReason)
            }
        case .start:
            guard session == nil, !restorationNeeded else { return rejected("Another session or a recovery is still in progress. Try again in a moment.") }
            guard let duration = request.durationSeconds else {
                return rejected("Unsupported session duration.")
            }
            let decision = safety.powerDecision(minimumBatteryPercent: request.minimumBatteryPercent)
            guard decision == .allowed else {
                // AC-only treats an unknown source like missing AC; explain the actual cause.
                let refusal = decision == .waitingForAC && safety.acPower == nil ? SessionPowerDecision.unknownPower : decision
                return rejected(refusal.startRefusalMessage(minimumBatteryPercent: request.minimumBatteryPercent))
            }
            guard safety.now.isFinite, safety.watchdogFresh, let generation = safety.watchdogGeneration else {
                return rejected("The supervising service is not ready. Try again in a moment.")
            }
            session = Session(id: UUID().uuidString, connection: connection, user: user,
                              deadline: duration == 0 ? nil : safety.now + Double(duration), minimumBatteryPercent: request.minimumBatteryPercent,
                              leaseDeadline: safety.now + ControlConstants.leaseSeconds,
                              watchdog: generation)
            endedSession = nil
            terminalReason = nil
            tick()
        case .renew:
            guard var current = session, current.connection == connection, current.user == user,
                  current.id == request.sessionID, request.durationSeconds == nil else {
                return rejected("The session expired or belongs to another connection.")
            }
            current.leaseDeadline = safety.now + ControlConstants.leaseSeconds
            session = current
        case .stop:
            if let current = session {
                guard current.connection == connection, current.user == user,
                      request.sessionID == nil || request.sessionID == current.id else {
                    return rejected("Only the connection that started the session can end it.")
                }
                cancel("Turned off. Sleep prevention is off.", reason: .clientStopped)
            } else if endedSession?.connection != connection || endedSession?.user != user ||
                        endedSession?.id != request.sessionID || request.sessionID == nil {
                // A tokenless Stop after an unconfirmed Start may be a no-op.
                // Do not attach an earlier session's cause to this response.
                var result = statusFor(connection)
                result.terminationReason = nil
                return result
            }
        }
        return statusFor(connection)
    }

    public func tick() {
        if restorationNeeded && !active {
            guard restore() else { return }
        }
        guard let current = session else { return }
        let safety = snapshot()
        guard safety.now.isFinite, safety.now < current.leaseDeadline else {
            cancel("Keep Mac Awake stopped renewing the session. Sleep prevention is off.", reason: safety.now.isFinite ? .leaseExpired : .unknown); return
        }
        guard current.deadline.map({ safety.now < $0 }) ?? true else {
            cancel("The selected time ended. Sleep prevention is off.", reason: .durationElapsed); return
        }
        guard safety.consoleUser == current.user else {
            cancel("The active user changed. The session ended.", reason: .consoleUserChanged); return
        }
        guard safety.watchdogFresh else {
            cancel("The supervising service stopped responding. The session ended.", reason: .watchdogUnavailable); return
        }
        guard safety.watchdogGeneration == current.watchdog else {
            cancel("The supervising service restarted. The session ended.", reason: .watchdogRestarted); return
        }
        let decision = safety.powerDecision(minimumBatteryPercent: current.minimumBatteryPercent)
        if decision == .waitingForAC {
            if active {
                active = false
                guard restore() else { return }
            }
            publish(.waitingForAC, decision.message(minimumBatteryPercent: current.minimumBatteryPercent), at: safety.now)
            return
        }
        guard decision == .allowed else {
            cancel(decision.message(minimumBatteryPercent: current.minimumBatteryPercent), reason: decision.terminationReason ?? .unknown); return
        }
        if !active {
            // A failed activation may already have created a recovery journal.
            restorationNeeded = true
            publish(.starting, "Turning on sleep prevention.", at: safety.now)
            do {
                try backend.activate { [snapshot] in
                    let fresh = snapshot()
                    return current.isWithinTime(at: fresh.now) &&
                        fresh.powerDecision(minimumBatteryPercent: current.minimumBatteryPercent) == .allowed && fresh.consoleUser == current.user &&
                        fresh.watchdogFresh && fresh.watchdogGeneration == current.watchdog
                }
                active = true
            } catch {
                failClosed("Sleep prevention could not be turned on: \(error.localizedDescription)", reason: .backendActivationFailed)
                return
            }
        }
        do {
            guard try backend.verifyActive() else {
                failClosed("The sleep setting could not be confirmed. Restoring it.", reason: .backendVerificationFailed); return
            }
            publish(.active, "Sleep prevention is on.", at: safety.now)
        } catch {
            failClosed("The sleep setting could not be confirmed: \(error.localizedDescription)", reason: .backendVerificationFailed)
        }
    }

    public func disconnected(_ connection: UUID) {
        if session?.connection == connection { cancel("Keep Mac Awake disconnected. The session ended.", reason: .disconnected) }
    }

    public func failClosed(_ message: String, reason: ControlStatus.TerminationReason = .backendActivationFailed) {
        recordTermination(reason)
        session = nil
        active = false
        if restorationNeeded, !restore() { return }
        status = ControlStatus(phase: .failed, message: message, terminationReason: terminalReason)
    }

    /// External supervision must fence a potentially stopped writer before attempting recovery.
    public func suspendForRecovery(_ message: String, reason: ControlStatus.TerminationReason = .recoveryRequired) {
        recordTermination(reason)
        session = nil; active = false; restorationNeeded = true
        status = ControlStatus(phase: .restoring, message: message, terminationReason: terminalReason)
    }

    public func recoveryDidComplete() {
        session = nil; active = false; restorationNeeded = false
        status = ControlStatus(phase: .idle, message: "The sleep setting was restored. The session ended.", terminationReason: terminalReason)
    }

    private func cancel(_ message: String, reason: ControlStatus.TerminationReason) {
        recordTermination(reason)
        session = nil
        active = false
        if restorationNeeded, !restore() { return }
        status = ControlStatus(phase: .idle, message: message, terminationReason: terminalReason)
    }

    private func recordTermination(_ reason: ControlStatus.TerminationReason) {
        if let session {
            endedSession = session
            terminalReason = reason
        } else if terminalReason == nil {
            terminalReason = reason
        }
    }

    @discardableResult private func restore() -> Bool {
        do {
            try backend.restore()
            restorationNeeded = false
            return true
        } catch {
            recordTermination(.recoveryFailed)
            session = nil; active = false; restorationNeeded = true
            status = ControlStatus(phase: .failed, message: "Restoring the sleep setting failed. Retrying: \(error.localizedDescription)", terminationReason: terminalReason)
            return false
        }
    }

    private func publish(_ phase: ControlStatus.Phase, _ message: String, at now: Double) {
        status = ControlStatus(phase: phase, message: message, sessionID: session?.id,
                               remainingSeconds: session?.deadline.map { max(0, Int(ceil($0 - now))) },
                               minimumBatteryPercent: session?.minimumBatteryPercent, isUnlimited: sessionIsUnlimited)
    }

    private func rejected(_ message: String) -> ControlStatus {
        ControlStatus(phase: .failed, message: message)
    }

    private func statusFor(_ connection: UUID) -> ControlStatus {
        var result = status
        if session?.connection != connection { result.sessionID = nil }
        return result
    }
}
