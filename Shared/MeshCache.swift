import CryptoKit
import Foundation
import os.log

private let cacheLogger = Logger(subsystem: "com.kevincappuccio.KiCadQuickLook", category: "cache")

/// Caches tessellated model geometry so a STEP file is run through the
/// Open CASCADE kernel once.
///
/// Reading a STEP file is the whole cost of a STEP preview (about a second
/// per megabyte, 93% of it inside the kernel), and the result is the same
/// whichever process asks for it. The Quick Look extensions' sandboxes
/// allow writes only inside their own containers (the app group container
/// is readable but not writable from them), while each extension can read
/// the other's container, so every process writes its own cache directory
/// and looks entries up in the peers' as well: a thumbnail generated while
/// browsing a folder makes the later preview instant.
///
/// Entries are keyed by the content hash of the source file plus the
/// tessellation parameters, so copies of the same library part share an
/// entry and keys survive moves. The blob format is produced and consumed
/// by the model page (see ModelPreviewHTMLBuilder).
final class MeshCache {
    static let shared = MeshCache()

    /// Part of every key; bump when the blob format or the tessellation
    /// parameters change so stale entries are ignored.
    static let formatVersion = "1"
    /// Eviction starts above this total size and stops below 80% of it.
    static let maximumTotalSize = 1 << 30
    /// Files larger than this are never hashed or cached; nothing that big
    /// can be tessellated anyway (see `KiCadFileLoader.maximumModelSize`).
    static let maximumSourceSize = 64 * 1024 * 1024

    private static let bundlePrefix = "com.kevincappuccio.KiCadQuickLook"
    private static let subdirectory = "meshes"

    /// Where this process writes entries; nil disables storing.
    let directory: URL?
    /// Directories searched on lookup: the writable one first, then the
    /// sibling extensions' caches and the app group container.
    let searchDirectories: [URL]

    init() {
        let fileManager = FileManager.default
        var writable: URL?
        if let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            // Inside a sandbox this is the container's Caches directory;
            // unsandboxed (the render harness) it is ~/Library/Caches, so
            // namespace it.
            let isContainer = caches.path.contains("/Library/Containers/")
            let base = isContainer ? caches : caches.appendingPathComponent(Self.bundlePrefix, isDirectory: true)
            let directory = base.appendingPathComponent(Self.subdirectory, isDirectory: true)
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                writable = directory
            } catch {
                cacheLogger.error("mesh cache directory unavailable: \(String(describing: error), privacy: .public)")
            }
        }
        directory = writable

        var peers: [URL] = []
        if let home = getpwuid(getuid())?.pointee.pw_dir.map({ String(cString: $0) }) {
            for name in ["ThumbnailExtension", "PreviewExtension"] {
                peers.append(URL(fileURLWithPath: "\(home)/Library/Containers/\(Self.bundlePrefix).\(name)/Data/Library/Caches/\(Self.subdirectory)", isDirectory: true))
            }
            peers.append(URL(fileURLWithPath: "\(home)/Library/Containers/\(Self.bundlePrefix)/Data/Library/Caches/\(Self.subdirectory)", isDirectory: true))
        }
        if let group = fileManager.containerURL(forSecurityApplicationGroupIdentifier: "LK2RWK9EUK.\(Self.bundlePrefix)") {
            peers.append(group.appendingPathComponent("Library/Caches/\(Self.subdirectory)", isDirectory: true))
        }
        searchDirectories = ([writable].compactMap { $0 } + peers.filter { $0 != writable })
        cacheLogger.info("mesh cache writes to \(writable?.path ?? "nowhere", privacy: .public)")
    }

    /// The cache key for a model file's content.
    static func key(for data: Data, format: ModelFormat, parameters: String) -> String {
        var hasher = SHA256()
        hasher.update(data: data)
        hasher.update(data: Data("\n\(format.rawValue)|\(parameters)|\(formatVersion)".utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func fileName(for key: String) -> String {
        "\(key).kiqlmesh"
    }

    func lookup(key: String) -> Data? {
        let fileManager = FileManager.default
        for directory in searchDirectories {
            let url = directory.appendingPathComponent(Self.fileName(for: key))
            guard let data = fileManager.contents(atPath: url.path), data.count > 16 else { continue }
            // Touch so eviction treats it as recently used (ignored where
            // the directory is read-only).
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            cacheLogger.info("mesh cache hit \(key.prefix(12), privacy: .public) (\(data.count, privacy: .public) bytes) in \(directory.path, privacy: .public)")
            return data
        }
        cacheLogger.info("mesh cache miss \(key.prefix(12), privacy: .public)")
        return nil
    }

    func store(key: String, data: Data) {
        guard let directory = directory else { return }
        let url = directory.appendingPathComponent(Self.fileName(for: key))
        do {
            try data.write(to: url, options: .atomic)
            cacheLogger.info("mesh cache stored \(key.prefix(12), privacy: .public) (\(data.count, privacy: .public) bytes)")
        } catch {
            cacheLogger.error("mesh cache store failed: \(String(describing: error), privacy: .public)")
            return
        }
        evictIfNeeded(in: directory)
    }

    /// Size-capped least-recently-used eviction (by modification date).
    private func evictIfNeeded(in directory: URL) {
        let fileManager = FileManager.default
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }
        var entries: [(url: URL, size: Int, date: Date)] = urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize
            else { return nil }
            return (url, size, values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > Self.maximumTotalSize else { return }
        entries.sort { $0.date < $1.date }
        let target = Self.maximumTotalSize * 8 / 10
        for entry in entries where total > target {
            try? fileManager.removeItem(at: entry.url)
            total -= entry.size
        }
        cacheLogger.info("mesh cache evicted down to \(total, privacy: .public) bytes")
    }
}
