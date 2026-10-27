import Foundation
import Darwin
import notify
import Security
import SystemConfiguration
import KeepMacAwakeControlCore
import KeepMacAwakeCore
import KeepMacAwakeControlProtocol
import KeepMacAwakeServiceSupport

func consoleUserID() -> UInt32? {
    var uid: uid_t = 0
    var gid: gid_t = 0
    guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) as String?, uid != 0,
          name != "loginwindow", name != "_mbsetupuser" else { return nil }
    return uid
}

func readInstallationTrust() throws -> InstallationTrust {
    let directory = try SecureDirectory(ControlConstants.installationDirectory, privateMode: false)
    let trust = try directory.read("trust.json", as: InstallationTrust.self)
    for (requirement, identifier) in [(trust.appRequirement, ControlConstants.appIdentifier),
                                      (trust.helperRequirement, ControlConstants.serviceName),
                                      (trust.coordinatorRequirement, ControlConstants.coordinatorIdentifier),
                                      (trust.cliRequirement, ControlConstants.cliIdentifier)] {
        var compiled: SecRequirement?
        guard TrustRequirements.isExact(requirement, identifier: identifier),
              SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess else {
            throw ServiceError.failed("The installation signing requirement is invalid.")
        }
    }
    return trust
}

func validateInstallation() throws {
    _ = try SecureDirectory(ControlConstants.stateDirectory, privateMode: true)
    let trust = try readInstallationTrust()
    let paths = [(ControlConstants.installationDirectory + "/KeepMacAwakeHelper", trust.helperRequirement),
                 (ControlConstants.applicationPath, trust.appRequirement),
                 (ControlConstants.coordinatorPath, trust.coordinatorRequirement),
                 (ControlConstants.cliPath, trust.cliRequirement)]
    for (path, requirement) in paths {
        var code: SecStaticCode?
        var compiled: SecRequirement?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code,
              SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess,
              let compiled,
              SecStaticCodeCheckValidity(code, [], compiled) == errSecSuccess else {
            throw ServiceError.failed("A file signature does not match this installation: \(path)")
        }
    }
}

final class LockedBackend: SessionBackend {
    /// About 100 ms in total for the controller's own lock attempts.
    private static let lockAttempts = 5
    let directory: SecureDirectory
    let transaction: SleepTransaction
    var beforeActivation: (() throws -> Void)?
    init(directory: SecureDirectory) {
        self.directory = directory
        transaction = SleepTransaction(directory: URL(fileURLWithPath: directory.path))
    }
    func activate(authorized: () -> Bool) throws {
        try directory.withTransactionLock(attempts: Self.lockAttempts) {
            try beforeActivation?()
            guard authorized() else { throw ServiceError.unauthorized }
            try transaction.activate(authorized: authorized)
        }
    }
    func restore() throws {
        try directory.withTransactionLock(attempts: Self.lockAttempts) {
            try transaction.restore()
            guard !transaction.hasPendingRecovery else { throw ServiceError.failed("Recovery was not confirmed.") }
        }
    }
    func verifyActive() throws -> Bool {
        try directory.withTransactionLock(attempts: Self.lockAttempts) { try transaction.verifyActive() }
    }
    func hasOrphanedRecovery() throws -> Bool {
        try RecoveryInspection.hasOrphanedJournal(
            withLock: { try directory.withTransactionLock($0) },
            readHeartbeat: { try self.directory.readHeartbeat(.controller) },
            hasJournal: { self.transaction.hasPendingRecovery }
        )
    }
}

final class ServiceRuntime: NSObject, NSXPCListenerDelegate {
    enum Mode { case controller, watchdog }
    let queue = DispatchQueue(label: "com.keepmacawake.service")
    private let mode: Mode
    private let directory: SecureDirectory
    private let backend: LockedBackend
    private let trust: InstallationTrust
    private var generation = UUID().uuidString
    private var ready = false
    private var recovery: FencedRecovery?
    private var recoveryMessage = "Restoring the initial state."
    private var lastRecoveryAt = continuousSeconds()
    private let startedAt = continuousSeconds()
    private var timer: DispatchSourceTimer?
    private var signals: [DispatchSourceSignal] = []
    private var listener: NSXPCListener?
    private var watchdogAssessment = WatchdogAssessment()
    private var cadence = SupervisionCadence()
    private var controllerProgress = IdleControllerProgress()
    private var lastWakePublishAt = -Double.infinity
    private var interval = ControlConstants.supervisionSeconds
    /// Without wake notifications an idle watchdog could not answer a Start, so
    /// both services then keep checking every second, as before idle supervision.
    private var wakesAvailable = false
    /// Only the controller keeps the first-session record.
    private var firstSession = FirstSessionTracker(stored: nil)
    private lazy var policy = SessionPolicy(backend: backend, snapshot: { [unowned self] in self.safetySnapshot() })

    init(mode: Mode) throws {
        self.mode = mode
        self.directory = try SecureDirectory(ControlConstants.stateDirectory, privateMode: true)
        self.backend = LockedBackend(directory: directory)
        self.trust = try readInstallationTrust()
        super.init()
        if mode == .controller {
            // A missing or unreadable record counts as none; it never stops the service.
            firstSession = FirstSessionTracker(stored: try? directory.read(FirstSessionRecord.fileName,
                                                                           as: FirstSessionRecord.self))
        }
        backend.beforeActivation = { [unowned self] in
            // Publish intent BEFORE journal creation, under the same transaction lock.
            try self.publishHeartbeat()
        }
    }

    func run() throws -> Never {
        try publishHeartbeat()
        if mode == .controller {
            let listener = NSXPCListener(machServiceName: ControlConstants.serviceName)
            // Only the per-user coordinator talks to the helper; the app and the
            // command-line tool go through it.
            listener.setConnectionCodeSigningRequirement(trust.coordinatorRequirement)
            listener.delegate = self
            self.listener = listener
            listener.resume()
        } else {
            beginRecovery(fencing: .controller, message: "The supervising service restarted. Ending the previous session.")
        }
        registerWakes()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.supervise() }
        self.timer = timer
        timer.resume()
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { [weak self] in
                guard let self else { exit(0) }
                self.ready = false
                try? self.publishHeartbeat()
                if self.mode == .controller { self.policy.failClosed("The system service is stopping.", reason: .serviceStopping) }
                else {
                    self.beginRecovery(fencing: .controller, message: "The supervising service is stopping.")
                    try? self.recovery?.attempt()
                }
                exit(0)
            }
            signals.append(source); source.resume()
        }
        dispatchMain()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard mode == .controller, let console = consoleUserID(), connection.effectiveUserIdentifier == console else { return false }
        let identifier = UUID()
        let endpoint = ConnectionEndpoint(runtime: self, connection: connection, identifier: identifier)
        connection.exportedInterface = NSXPCInterface(with: KeepMacAwakeServiceProtocol.self)
        connection.exportedObject = endpoint
        let disconnected: () -> Void = { [weak self] in
            guard let self else { return }
            self.queue.async {
                self.supervise()
                self.policy.disconnected(identifier)
                self.publishOrExit()
                self.updateCadence()
            }
        }
        connection.invalidationHandler = disconnected
        connection.interruptionHandler = disconnected
        connection.resume()
        return true
    }

    func request(_ data: Data, connection: NSXPCConnection, identifier: UUID, reply: @escaping (Data) -> Void) {
        queue.async {
            // The policy ticks inside handle(), before it reads the request.
            self.supervise(tickingPolicy: false)
            let status: ControlStatus
            if data.count > 4096 {
                status = ControlStatus(phase: .failed, message: "The request is too large.")
            } else if let console = consoleUserID(), connection.effectiveUserIdentifier == console,
                      let request = try? JSONDecoder().decode(ControlRequest.self, from: data) {
                if self.ready && self.recovery == nil {
                    status = self.policy.handle(request, connection: identifier, user: console, confirmWatchdog: {
                        // The watchdog reads the policy's state after this request's tick, for
                        // example an expired session already ended, not the timer's older one.
                        self.publishOrExit()
                        return self.awaitWatchdogAfterWake()
                    })
                } else {
                    let reason: ControlStatus.TerminationReason?
                    switch request.kind {
                    case .renew, .stop:
                        reason = self.policy.retainedTerminationReason(sessionID: request.sessionID,
                                                                        connection: identifier, user: console)
                    case .status:
                        reason = self.policy.status.terminationReason
                    case .start:
                        reason = nil
                    }
                    status = ControlStatus(phase: .restoring, message: self.recoveryMessage,
                                           terminationReason: reason)
                }
            } else {
                status = ControlStatus(phase: .failed, message: "The request is not from the console user or is invalid.")
            }
            self.publishOrExit()
            // A session started by this request is supervised every second from now on.
            self.updateCadence()
            self.updateFirstSession()
            var answer = status
            answer.firstSessionAt = self.firstSession.record?.firstSessionAt
            answer.latestSeenAt = self.firstSession.record?.latestSeenAt
            // Encoding this closed Codable model cannot fail for normal finite values.
            reply((try? JSONEncoder().encode(answer)) ?? Data())
        }
    }

    private func registerWakes() {
        var keepaliveToken: Int32 = 0, startToken: Int32 = 0
        if mode == .watchdog {
            // A keepalive from a controller that needs supervision only extends the
            // fast rate; a Start wake always publishes at once as proof of the answer.
            let keepalive = notify_register_dispatch(ControlConstants.watchdogWakeName, &keepaliveToken, queue) { [weak self] _ in
                self?.woken(publishNow: false)
            }
            let start = notify_register_dispatch(ControlConstants.watchdogStartName, &startToken, queue) { [weak self] _ in
                self?.woken(publishNow: true)
            }
            wakesAvailable = keepalive == NOTIFY_STATUS_OK && start == NOTIFY_STATUS_OK
        } else {
            wakesAvailable = true
        }
    }

    /// Anyone can post these notifications, so a wake never takes the transaction
    /// lock: it switches to the fast rate (the timer runs the next full check at once)
    /// and answers a Start with a heartbeat, at most four times a second.
    private func woken(publishNow: Bool) {
        let now = continuousSeconds()
        cadence.hold(at: now)
        if interval > ControlConstants.supervisionSeconds {
            interval = ControlConstants.supervisionSeconds
            timer?.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(100))
        }
        if publishNow, !(now - lastWakePublishAt < 0.25) {
            lastWakePublishAt = now
            publishOrExit()
        }
    }

    /// An idle watchdog checks once a minute. Start wakes it and waits for a
    /// heartbeat published after the wake, which proves it now supervises every
    /// second. Without that answer the Start is refused.
    private func awaitWatchdogAfterWake() -> Bool {
        let wokenAt = continuousSeconds()
        guard wokenAt.isFinite, notify_post(ControlConstants.watchdogStartName) == NOTIFY_STATUS_OK else { return false }
        repeat {
            if let beat = peerHeartbeat(), beat.updatedAt >= wokenAt, beat.isFresh(at: continuousSeconds()) { return true }
            usleep(20_000)
        } while continuousSeconds() - wokenAt < ControlConstants.watchdogWakeTimeoutSeconds
        return false
    }

    /// Supervise every second while anything needs it and once a minute otherwise.
    private func updateCadence() {
        let needsSupervision: Bool
        if mode == .controller {
            needsSupervision = !ready || recovery != nil || policy.needsSupervision
            // Keep the watchdog at the full rate for as long as this controller needs it.
            if needsSupervision { notify_post(ControlConstants.watchdogWakeName) }
        } else {
            needsSupervision = !ready || recovery != nil || peerHeartbeat()?.isQuiescentController() != true
        }
        let next = wakesAvailable ? cadence.interval(needsSupervision: needsSupervision, at: continuousSeconds())
                                  : ControlConstants.supervisionSeconds
        guard next != interval else { return }
        interval = next
        let leeway: DispatchTimeInterval = next > ControlConstants.supervisionSeconds ? .seconds(5) : .milliseconds(100)
        timer?.schedule(deadline: .now() + next, repeating: next, leeway: leeway)
    }

    private func peerHeartbeat() -> PeerHeartbeat? {
        try? directory.readHeartbeat(mode == .controller ? .watchdog : .controller)
    }

    private func safetySnapshot() -> SafetySnapshot {
        let power = currentPower()
        let console = consoleUserID()
        let observation = PeerObservation(read: peerHeartbeat, clock: continuousSeconds)
        return SafetySnapshot(now: observation.observedAt, acPower: power.ac, consoleUser: console,
                              watchdogGeneration: observation.heartbeat?.generation,
                              watchdogFresh: ready && recovery == nil && observation.heartbeat?.isFresh(at: observation.observedAt) == true,
                              batteryPercent: power.percent, thermalSafe: power.thermalSafe)
    }

    private func currentPower() -> (ac: Bool?, percent: Int?, thermalSafe: Bool) {
        let snapshot = SystemProbe().read().snapshot
        let ac: Bool? = snapshot.source == .unknown ? nil : snapshot.source == .ac
        let thermalSafe: Bool
        switch ProcessInfo.processInfo.thermalState {
        case .nominal, .fair: thermalSafe = true
        case .serious, .critical: thermalSafe = false
        @unknown default: thermalSafe = false
        }
        return (ac, snapshot.batteryPercent, thermalSafe)
    }

    private func publishHeartbeat() throws {
        let heartbeat: PeerHeartbeat
        if mode == .controller {
            heartbeat = policy.controllerHeartbeat(generation: generation, updatedAt: continuousSeconds(), ready: ready)
        } else {
            heartbeat = PeerHeartbeat(generation: generation, updatedAt: continuousSeconds(), ready: ready && recovery == nil)
        }
        try directory.write(heartbeat, name: mode == .controller ? "controller-heartbeat.json" : "watchdog-heartbeat.json")
    }

    private func publishOrExit() {
        do { try publishHeartbeat() }
        catch {
            // No reliable progress heartbeat means no permission to retain a writer.
            fputs("Keep Mac Awake: cannot publish the supervision state.\n", stderr)
            exit(1)
        }
    }

    private func beginRecovery(fencing peer: FixedPeer, message: String,
                               reason: ControlStatus.TerminationReason = .recoveryRequired) {
        guard recovery == nil else { return }
        ready = false
        generation = UUID().uuidString
        recoveryMessage = message
        if mode == .controller { policy.suspendForRecovery(message, reason: reason) }
        recovery = FencedRecovery(fence: { try PeerFencer.kill(peer) }, restore: { [backend] in try backend.restore() })
    }

    private func supervise(tickingPolicy: Bool = true) {
        superviseOnce(tickingPolicy: tickingPolicy)
        updateCadence()
        updateFirstSession()
    }

    /// Records the first accepted session and the latest time seen. A failed
    /// write is retried at the next call and never affects a session.
    private func updateFirstSession() {
        guard mode == .controller else { return }
        let now = Int(Date().timeIntervalSince1970)
        guard let record = firstSession.observe(sessionLive: policy.sessionUser != nil, now: now) else { return }
        if (try? directory.write(record, name: FirstSessionRecord.fileName)) != nil {
            firstSession.didWrite(record)
        }
    }

    private func superviseOnce(tickingPolicy: Bool = true) {
        if let recovery {
            publishOrExit() // ready=false before kill, lock, or potentially blocking native I/O
            do {
                try recovery.attempt()
                if !recovery.pending {
                    self.recovery = nil
                    if mode == .controller { policy.recoveryDidComplete() }
                    ready = true; lastRecoveryAt = continuousSeconds()
                }
            } catch { recoveryMessage = "Recovery in progress: \(error.localizedDescription)" }
            publishOrExit()
            return
        }
        let observation = PeerObservation(read: peerHeartbeat, clock: continuousSeconds)
        let now = observation.observedAt, peer = observation.heartbeat
        if mode == .controller {
            if !ready {
                do {
                    try backend.restore()
                    policy.recoveryDidComplete()
                    ready = true
                } catch {
                    recoveryMessage = "Recovery in progress: \(error.localizedDescription)"
                    // A watchdog that publishes but is not ready is restoring too. Fencing
                    // it would restart its recovery, which fences this controller again.
                    if now - startedAt >= ControlConstants.peerTimeoutSeconds && peer?.isProgressing(at: now) != true {
                        beginRecovery(fencing: .watchdog, message: "The supervising service is not responding during recovery.", reason: .watchdogUnavailable)
                    }
                }
            } else if (policy.sessionUser != nil || policy.requiresRestoration) && peer?.isFresh(at: now) != true {
                // A SIGSTOP'ed watchdog may own flock. Kill before requesting that lock.
                beginRecovery(fencing: .watchdog, message: "The supervising service stopped making progress. Ending the session.", reason: .watchdogUnavailable)
            } else if tickingPolicy {
                policy.tick()
            }
        } else {
            if controllerProgress.isStalled(peer, uptime: ProcessInfo.processInfo.systemUptime) {
                // A hung idle controller would refuse every Start; restart it. Measure
                // again from scratch, so an old heartbeat cannot cause a restart loop.
                controllerProgress = IdleControllerProgress()
                if now - lastRecoveryAt >= ControlConstants.peerTimeoutSeconds {
                    beginRecovery(fencing: .controller, message: "The system service stopped responding. Restarting it.")
                    superviseOnce()
                    return
                }
            }
            // An idle controller needs no power reading: it is never fenced for its age alone.
            let power = peer?.isQuiescentController() == true ? (ac: nil, percent: nil, thermalSafe: false) : currentPower()
            let shouldFence = watchdogAssessment.shouldFence(peer, at: now, ac: power.ac, console: consoleUserID(),
                                                            batteryPercent: power.percent, thermalSafe: power.thermalSafe)
            if shouldFence {
                // Let a freshly fenced launchd controller restart, without a kill loop.
                if now - lastRecoveryAt >= ControlConstants.peerTimeoutSeconds || peer?.sessionUser != nil {
                    beginRecovery(fencing: .controller, message: "The controller, power conditions or session authorization are no longer safe.")
                }
            } else if peer?.blocking != true {
                do {
                    if try backend.hasOrphanedRecovery() {
                        beginRecovery(fencing: .controller, message: "Found a recovery journal without an active session.")
                    }
                } catch ServiceError.busy {
                    // Nonblocking lock: do not refresh progress while another process is stuck.
                    return
                } catch {
                    beginRecovery(fencing: .controller, message: "Cannot check the recovery journal.")
                }
            }
        }
        publishOrExit()
        // Newly scheduled recovery runs immediately after advertising ready=false.
        if recovery != nil { superviseOnce() }
    }
}

private final class ConnectionEndpoint: NSObject, KeepMacAwakeServiceProtocol {
    private weak var runtime: ServiceRuntime?
    private weak var connection: NSXPCConnection?
    private let identifier: UUID
    init(runtime: ServiceRuntime, connection: NSXPCConnection, identifier: UUID) {
        self.runtime = runtime; self.connection = connection; self.identifier = identifier
    }
    func request(_ data: Data, withReply reply: @escaping (Data) -> Void) {
        guard let runtime, let connection else { reply(Data()); return }
        runtime.request(data, connection: connection, identifier: identifier, reply: reply)
    }
}
