import Foundation

/// A source of quota observations that is read as a whole, for example a folder of small files that a helper keeps up
/// to date.
///
/// Quota figures that arrive inside session logs do not need a feed, because their adapter emits them together with
/// the usage it reads. A feed is for everything else. The coordinator knows nothing about any provider, only about
/// this protocol, so a new provider's feed is added by creating one and handing it to the coordinator.
public protocol QuotaFeed: Sendable {
    var id: TelemetrySourceID { get }
    /// Folders whose changes mean that the feed has something new.
    var watchRoots: [URL] { get }
    /// Individual files whose changes mean that the feed has something new. Unlike a folder, these are watched
    /// without opening the folder to every event in it, which matters when the file lives in the home directory.
    var watchFiles: [URL] { get }
    /// True when the feed reads a source whose meaning is not documented. Such a feed is only read when the user has
    /// opted in, and its observations must carry the `unverified` authority.
    var requiresOptIn: Bool { get }
    func observations(now: Date) -> [QuotaObservation]
    /// Reads the feed and describes the source state as well as the observations. A feed that only produces
    /// observations can rely on the default implementation.
    func read(now: Date) -> QuotaFeedOutput
}

public extension QuotaFeed {
    var watchFiles: [URL] { [] }

    func read(now: Date) -> QuotaFeedOutput {
        // A feed with no watch root can still name a watched file. An entirely empty list has nothing whose existence
        // answers this question; saying "exists" merely because an empty list is vacuously true would misreport a
        // missing file.
        let paths = watchRoots.isEmpty ? watchFiles : watchRoots
        return QuotaFeedOutput(observations: observations(now: now),
                               sourceExists: !paths.isEmpty && paths.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }
}

/// Why a feed could not produce a usable reading. An issue can accompany observations: one malformed model-scoped
/// limit does not invalidate the shared windows that were read successfully.
public enum QuotaFeedIssue: String, Sendable, Equatable {
    /// The file exists but could not be opened safely: permissions, a symbolic link, a hard link, or a file type
    /// other than a regular file.
    case unreadable
    /// The source is larger than the adapter is willing to read.
    case fileTooLarge
    /// The file is not a complete JSON document, for example in the middle of an atomic replacement.
    case invalidJSON
    /// The document is valid JSON but has no `cachedUsageUtilization` object.
    case noUsageData
    /// The observation timestamp is missing, malformed, implausibly old, or in the future.
    case invalidTimestamp
    /// The source names no usable account identity.
    case invalidAccount
    /// Some windows could not be read, while others were. They are reported separately rather than discarded.
    case malformedWindow
    /// The account identity in the source changed since the previous read. The observations are from a different
    /// account and must not be reconciled with the previous ones.
    case accountChanged

    /// A short explanation for the interface. It deliberately contains no file content and no identifier.
    public var explanation: String {
        switch self {
        case .unreadable:
            String(localized: "The source file could not be read safely.")
        case .fileTooLarge:
            String(localized: "The source file is larger than expected and was not read.")
        case .invalidJSON:
            String(localized: "The source file is not a complete JSON document. It may be in the middle of a rewrite.")
        case .noUsageData:
            String(localized: "The source file has no subscription usage snapshot yet.")
        case .invalidTimestamp:
            String(localized: "The snapshot has no trustworthy observation time, so it was not used.")
        case .invalidAccount:
            String(localized: "The snapshot does not identify a valid account, so it was not used.")
        case .malformedWindow:
            String(localized: "Some quota windows in the snapshot were malformed and were skipped.")
        case .accountChanged:
            String(localized: "The account changed. The newest observation is shown; the two accounts' percentages were not averaged or summed.")
        }
    }
}

/// One read of a quota feed.
public struct QuotaFeedOutput: Sendable, Equatable {
    public var observations: [QuotaObservation]
    public var sourcePath: URL?
    public var sourceExists: Bool
    public var issue: QuotaFeedIssue?
    /// A short, one-way fingerprint of the account that the source names. It is used only to detect a change. The raw
    /// identifier is never retained.
    public var accountFingerprint: String?

    public init(observations: [QuotaObservation], sourcePath: URL? = nil, sourceExists: Bool = true,
                issue: QuotaFeedIssue? = nil, accountFingerprint: String? = nil) {
        self.observations = observations
        self.sourcePath = sourcePath
        self.sourceExists = sourceExists
        self.issue = issue
        self.accountFingerprint = accountFingerprint
    }
}

/// What the coordinator knows about how one feed is delivering.
public struct QuotaFeedStatus: Sendable, Equatable, Identifiable {
    public var id: TelemetrySourceID
    public var rootsExist: Bool
    public var observationCount: Int
    /// The number of distinct sessions or files that the observations came from, when they say.
    public var originCount: Int
    public var newestObservation: Date?
    public var lastRead: Date?
    /// The last read that produced at least one usable observation, even if another window in the same read was
    /// malformed or the account changed.
    public var lastSuccess: Date?
    /// Whether the feed's own source exists now, as opposed to whether a watch root exists.
    public var sourceExists: Bool
    public var sourcePath: String?
    /// The most recent condition that prevented or limited this read.
    public var issue: QuotaFeedIssue?

    public init(id: TelemetrySourceID, rootsExist: Bool, observationCount: Int, originCount: Int,
                newestObservation: Date?, lastRead: Date?, lastSuccess: Date? = nil, sourceExists: Bool = false,
                sourcePath: String? = nil, issue: QuotaFeedIssue? = nil) {
        self.id = id
        self.rootsExist = rootsExist
        self.observationCount = observationCount
        self.originCount = originCount
        self.newestObservation = newestObservation
        self.lastRead = lastRead
        self.lastSuccess = lastSuccess
        self.sourceExists = sourceExists
        self.sourcePath = sourcePath
        self.issue = issue
    }
}
