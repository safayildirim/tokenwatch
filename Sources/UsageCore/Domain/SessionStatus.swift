import Foundation

/// This is the lifecycle state shown for a session.
public enum SessionState: String, Sendable, Codable, CaseIterable {
    case active
    case idle
    case completed
    case unknown

    /// The state in the user's language, for the interface.
    public var label: String {
        switch self {
        case .active: String(localized: "Active")
        case .idle: String(localized: "Idle")
        case .completed: String(localized: "Completed")
        case .unknown: String(localized: "Unknown")
        }
    }

    /// The state in English, for exports, whose values must not depend on the language of the app.
    public var exportLabel: String {
        switch self {
        case .active: "Active"
        case .idle: "Idle"
        case .completed: "Completed"
        case .unknown: "Unknown"
        }
    }
}

/// How a session state was determined.
public enum StatusBasis: String, Sendable, Codable {
    /// The state was seen directly, for example from the live process registry that Claude Code maintains.
    case observed
    /// Guessed from how long ago the session last wrote a record.
    case inferred
}

public struct SessionStatus: Sendable, Equatable, Codable {
    public var state: SessionState
    public var basis: StatusBasis

    public init(_ state: SessionState, _ basis: StatusBasis) {
        self.state = state
        self.basis = basis
    }

    public var label: String {
        let state = self.state.label
        return basis == .inferred && self.state != .unknown ? String(localized: "\(state) (inferred)") : state
    }

    /// The status in English, for exports.
    public var exportLabel: String { basis == .inferred && state != .unknown ? "\(state.exportLabel) (inferred)" : state.exportLabel }
}

/// A process that Claude Code has registered as running a session.
public struct LiveProcess: Sendable, Equatable {
    public enum Activity: String, Sendable { case busy, idle, other }
    public var sessionExternalID: String
    public var pid: Int32
    public var activity: Activity
    public var entrypoint: String?
    public var updatedAt: Int64?
}

/// Thresholds for inferring a state when no live process information exists.
public struct StatusPolicy: Sendable, Equatable {
    /// A session that wrote a record within this many seconds is considered active.
    public var activeWithin: TimeInterval = 120
    /// A session that wrote a record within this many seconds is considered idle rather than done.
    public var idleWithin: TimeInterval = 60 * 60
    public init() {}
}

public enum SessionStatusResolver {
    /// Derives the state of a session.
    ///
    /// Observed information always wins over inference. An unchanged log file is never treated as
    /// proof of completion unless the registry showed the owning process exiting after the last
    /// record was written.
    public static func resolve(now: Date, lastActivityMs: Int64?, observedEndedAtMs: Int64?,
                               live: LiveProcess?, policy: StatusPolicy = StatusPolicy()) -> SessionStatus {
        if let live {
            return SessionStatus(live.activity == .busy ? .active : .idle, .observed)
        }
        if let ended = observedEndedAtMs, ended >= (lastActivityMs ?? 0) - 2000 {
            return SessionStatus(.completed, .observed)
        }
        guard let last = lastActivityMs else { return SessionStatus(.unknown, .inferred) }
        let age = now.timeIntervalSince(Clock.date(ms: last))
        if age < 0 { return SessionStatus(.active, .inferred) }
        if age <= policy.activeWithin { return SessionStatus(.active, .inferred) }
        if age <= policy.idleWithin { return SessionStatus(.idle, .inferred) }
        return SessionStatus(.completed, .inferred)
    }
}
