import Foundation

/// A log file that belongs to a telemetry source, together with the identity hints that can be derived
/// from its location alone.
public struct SourceFileRef: Sendable, Hashable {
    public var sourceID: TelemetrySourceID
    public var path: String
    /// A stable key for the project the file belongs to, when the location says so.
    public var projectKey: String
    /// The session the file belongs to, as implied by its path or name.
    public var sessionHint: String
    /// Set when the file is the log of a sub-agent rather than of a main conversation.
    public var agentHint: String?
    /// Free-form facts that the adapter derived from the location, for example `archived`.
    public var hints: [String: String]

    public init(sourceID: TelemetrySourceID, path: String, projectKey: String = "", sessionHint: String = "",
                agentHint: String? = nil, hints: [String: String] = [:]) {
        self.sourceID = sourceID
        self.path = path
        self.projectKey = projectKey
        self.sessionHint = sessionHint
        self.agentHint = agentHint
        self.hints = hints
    }

    /// True when the file is stored compressed and must be decoded before its lines can be read.
    public var isCompressed: Bool { path.hasSuffix(".zst") }
}

/// Parses the complete lines of one file into normalized observations.
///
/// A parser instance is created per file synchronization and may keep state across chunks.
/// Implementations must be tolerant: a malformed line is reported through `batch.malformedLineCount`
/// and must never prevent the following lines from being processed.
public protocol LineParser: AnyObject {
    /// Parses one line. `offset` is the line's byte offset in the (decompressed) file, for provenance.
    func parse(line: UnsafeBufferPointer<UInt8>, offset: Int64, into batch: inout NormalizedBatch)
    /// Moves any state accumulated while parsing the chunk into `batch`.
    func flush(into batch: inout NormalizedBatch)
}

/// Knows how to find, identify and parse the data of one kind of telemetry source.
///
/// Each adapter is independent. The collector gives every adapter its own error boundary, so a
/// failing or unsupported source never stops the others from being collected. The provider and
/// products an adapter reports on are declared in the `ProviderRegistry`, and the adapter refers to
/// them only through the typed identifiers.
public protocol SourceAdapter: Sendable {
    var sourceID: TelemetrySourceID { get }
    var displayName: String { get }
    /// Directories that should be watched recursively for changes.
    var watchRoots: [URL] { get }
    /// Lists every log file currently present. This is the cheap enumeration used by the initial
    /// scan and by the periodic reconciliation pass.
    func discoverFiles() throws -> [SourceFileRef]
    /// Identifies a path reported by the file system watcher, or returns nil if it is not a log
    /// file of this source.
    func fileRef(forPath path: String) -> SourceFileRef?
    func makeParser(for file: SourceFileRef) -> any LineParser
    /// A short statement about what this source can and cannot report, for the diagnostics view.
    var coverageNote: String { get }
    /// True when a file that has grown can be parsed starting at the end of the previous pass.
    ///
    /// A source whose lines can only be understood together with earlier ones (a header at the top that names the
    /// session, or running totals that identify repeated records) must return false. The whole file is then read
    /// again after every change, which is safe because the observations are idempotent.
    var resumesFromCheckpoint: Bool { get }
}

public extension SourceAdapter {
    var resumesFromCheckpoint: Bool { true }
}
