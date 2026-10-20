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
    /// True when the feed reads a source whose meaning is not documented. Such a feed is only read when the user has
    /// opted in, and its observations must carry the `unverified` authority.
    var requiresOptIn: Bool { get }
    func observations(now: Date) -> [QuotaObservation]
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
}
