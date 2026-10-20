import Foundation

enum CanonicalPath {
    /// Resolves symbolic links the way the kernel does, so that a path compares equal to the paths
    /// reported by FSEvents. Foundation's `resolvingSymlinksInPath` is unsuitable because it removes
    /// the `/private` prefix that FSEvents includes. For a path that does not exist yet, the nearest
    /// existing ancestor is resolved and the remaining components are appended.
    static func resolve(_ url: URL) -> URL {
        var existing = url.standardizedFileURL
        var trailing: [String] = []
        let fm = FileManager.default
        while !fm.fileExists(atPath: existing.path), existing.path != "/" {
            trailing.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(existing.path, &buffer) != nil else { return url }
        var resolved = URL(fileURLWithPath: String(cString: buffer))
        for component in trailing { resolved.appendPathComponent(component) }
        return resolved
    }
}
