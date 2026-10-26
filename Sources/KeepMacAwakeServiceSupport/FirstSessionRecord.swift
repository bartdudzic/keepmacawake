import Foundation

/// When the helper first accepted a session on this Mac, and the latest
/// wall-clock time it has seen since. The helper keeps and reports it; it never
/// changes what a session does. The app uses it to decide what a Start may do.
public struct FirstSessionRecord: Codable, Equatable, Sendable {
    public static let fileName = "first-session.json"
    /// After this long the record stops changing, so an idle helper writes nothing more.
    public static let activeSeconds = 7 * 24 * 3600
    /// An idle check raises the latest time at most once an hour.
    public static let idleStepSeconds = 3600

    /// Unix seconds.
    public let firstSessionAt: Int
    public let latestSeenAt: Int

    public enum Event: Sendable { case sessionAccepted, sessionEnded, idleCheck }

    public init(firstSessionAt: Int, latestSeenAt: Int) {
        self.firstSessionAt = firstSessionAt; self.latestSeenAt = latestSeenAt
    }

    public var isValid: Bool { firstSessionAt > 0 && latestSeenAt >= firstSessionAt }
    /// A settled record is never written again.
    public var isSettled: Bool { latestSeenAt - firstSessionAt >= Self.activeSeconds }

    /// The record after an event, or nil when nothing changes. An earlier time
    /// never lowers a stored value, so moving the clock back changes nothing.
    public static func next(after record: FirstSessionRecord?, event: Event, now: Int) -> FirstSessionRecord? {
        guard now > 0 else { return nil }
        guard let record, record.isValid else {
            return event == .sessionAccepted ? FirstSessionRecord(firstSessionAt: now, latestSeenAt: now) : nil
        }
        guard !record.isSettled, now > record.latestSeenAt else { return nil }
        if event == .idleCheck && now - record.latestSeenAt < idleStepSeconds { return nil }
        return FirstSessionRecord(firstSessionAt: record.firstSessionAt, latestSeenAt: now)
    }
}

/// The helper's copy of the record: what it reports, and whether the copy on
/// disk still needs writing. A failed write is retried at the next event.
public struct FirstSessionTracker: Sendable {
    public private(set) var record: FirstSessionRecord?
    public private(set) var needsWrite = false
    private var sessionWasLive = false

    public init(stored: FirstSessionRecord?) {
        record = stored.flatMap { $0.isValid ? $0 : nil }
    }

    /// Called after every request and supervision check with whether a session
    /// is live now. Returns the record to write, if any.
    public mutating func observe(sessionLive: Bool, now: Int) -> FirstSessionRecord? {
        let event: FirstSessionRecord.Event?
        switch (sessionWasLive, sessionLive) {
        case (false, true): event = .sessionAccepted
        case (true, false): event = .sessionEnded
        case (false, false): event = .idleCheck
        case (true, true): event = nil
        }
        sessionWasLive = sessionLive
        if let event, let next = FirstSessionRecord.next(after: record, event: event, now: now) {
            record = next
            needsWrite = true
        }
        return needsWrite ? record : nil
    }

    public mutating func didWrite(_ written: FirstSessionRecord) {
        if written == record { needsWrite = false }
    }
}
