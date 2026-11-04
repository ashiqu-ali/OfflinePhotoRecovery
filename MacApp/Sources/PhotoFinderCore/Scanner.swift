import Foundation

public struct MediaItem: Identifiable, Hashable, Sendable {
    public var id: String { entry.fileID }
    public let entry: BackupEntry
    public let kind: MediaKind
    public let detectedExtension: String
    public let source: String
    /// Set for photo-folder copies, by checking the copied Photos library database.
    public var libraryStatus: LibraryStatus?

    public var fileName: String { (entry.relativePath as NSString).lastPathComponent }

    /// Keeps the original name, adding the detected extension when the name has none (common for app caches).
    public var exportFileName: String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        let mediaExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tif", "tiff", "dng", "avif",
                                            "mov", "mp4", "m4v", "3gp"]
        // Thumbnails are all called 5005.JPG; name them after their photo instead.
        let mediaPath = entry.relativePath.hasPrefix("Media/") ? String(entry.relativePath.dropFirst(6)) : entry.relativePath
        if mediaPath.hasPrefix("PhotoData/Thumbnails/V2/"), let photo = LibraryIndex.photoName(forPath: mediaPath) {
            return "\(photo)-thumbnail.\(ext.isEmpty ? detectedExtension : ext)"
        }
        // Edits are all called FullSizeRender; PhotoData/Mutations/DCIM/100APPLE/IMG_0001/Adjustments/FullSizeRender.jpg
        let parts = mediaPath.split(separator: "/")
        if parts.count >= 5, parts[0] == "PhotoData", parts[1] == "Mutations", parts[2] == "DCIM" {
            return "\(parts[4])-edited.\(ext.isEmpty ? detectedExtension : ext)"
        }
        return mediaExtensions.contains(ext) ? fileName : "\(fileName).\(detectedExtension)"
    }
}

public struct ScanStats: Sendable {
    public var checked = 0
    public var total = 0
    public var found = 0
    public var unreadable = 0
    public init() {}
}

public enum Scanner {
    /// Extensions that are never photos or videos; skipping them avoids opening most of the backup.
    private static let skippedExtensions: Set<String> = [
        "plist", "db", "sqlite", "sqlite3", "sqlitedb", "sqlite-wal", "sqlite-shm", "db-wal", "db-shm", "wal", "shm",
        "json", "txt", "log", "strings", "js", "css", "html", "htm", "xml", "nib", "car", "ttf", "otf", "sql", "lock",
        "m4a", "mp3", "aac", "caf", "wav", "amr", "opus", "pdf", "vcf", "ics", "realm", "ithmb",
        "albummetadata", "memorymetadata", "aae",
    ]
    public static let minimumBytes: Int64 = 1024

    /// The Photos app's databases, by their path inside a backup. Pulled out so a backup can be
    /// compared against the library the same way a photo-folder copy is (Recently Deleted, leftovers).
    private static let libraryDatabasePaths: Set<String> = {
        var paths = Set<String>()
        for base in ["Media/PhotoData/Photos.sqlite", "Media/PhotoData/CPL/storage/store.cloudphotodb"] {
            for suffix in ["", "-wal", "-shm"] { paths.insert(base + suffix) }
        }
        return paths
    }()

    /// Checks every file and returns the photos and videos, newest first. File headers are read on
    /// all CPU cores at once, which is what makes large backups quick to search.
    public static func scan(_ reader: BackupReader,
                            progress: (ScanStats) -> Void,
                            isCancelled: () -> Bool) throws -> [MediaItem] {
        var stats = ScanStats()
        var candidates: [BackupEntry] = []
        var library: LibraryIndex?
        var cleanup: (() -> Void)?
        defer { cleanup?() }

        if reader.summary.isPhotoFolderCopy {
            candidates = try folderCandidates(in: reader.summary.url, stats: &stats, progress: progress, isCancelled: isCancelled)
            library = LibraryIndex(photoDataFolder: reader.summary.url.appendingPathComponent("PhotoData"))
        } else {
            var databaseEntries: [BackupEntry] = []
            try reader.withManifest { manifest in
                stats.total = try manifest.fileCount()
                progress(stats)
                try manifest.forEachFile { row in
                    if isCancelled() { throw BackupError.cancelled }
                    // The Photos databases are skipped as media but kept to compare against the library.
                    if libraryDatabasePaths.contains(row.relativePath), let entry = reader.entry(from: row) {
                        databaseEntries.append(entry)
                        stats.checked += 1
                        return
                    }
                    guard !skippedExtensions.contains((row.relativePath as NSString).pathExtension.lowercased()),
                          let entry = reader.entry(from: row), entry.size >= minimumBytes else {
                        stats.checked += 1
                        if stats.checked % 2000 == 0 { progress(stats) }
                        return
                    }
                    candidates.append(entry)
                }
            }
            (library, cleanup) = backupLibrary(reader: reader, databaseEntries: databaseEntries)
        }
        progress(stats)

        let items = try sniff(candidates, reader: reader, library: library, stats: stats,
                              progress: progress, isCancelled: isCancelled)
        return items.sorted { ($0.entry.modified ?? .distantPast) > ($1.entry.modified ?? .distantPast) }
    }

    /// Extracts a backup's Photos databases into a temporary PhotoData folder and builds a library
    /// index from them, so a backup gets the same labels as a direct copy. Returns a cleanup closure.
    private static func backupLibrary(reader: BackupReader, databaseEntries: [BackupEntry]) -> (LibraryIndex?, () -> Void) {
        guard databaseEntries.contains(where: { $0.relativePath == "Media/PhotoData/Photos.sqlite" }) else { return (nil, {}) }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("backup-library-\(UUID().uuidString)", isDirectory: true)
        let photoData = root.appendingPathComponent("PhotoData", isDirectory: true)
        let cleanup: () -> Void = { try? fm.removeItem(at: root) }
        do {
            for entry in databaseEntries {
                // "Media/PhotoData/<rest>" is recreated at "<photoData>/<rest>".
                let rest = String(entry.relativePath.dropFirst("Media/PhotoData/".count))
                let destination = photoData.appendingPathComponent(rest)
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try reader.copyDecrypted(entry, to: destination)
            }
            return (LibraryIndex(photoDataFolder: photoData), cleanup)
        } catch {
            cleanup()
            return (nil, {})
        }
    }

    /// The path used to look an item up in the Photos library, the same for copies and backups.
    static func libraryPath(of entry: BackupEntry) -> String {
        entry.relativePath.hasPrefix("Media/") ? String(entry.relativePath.dropFirst("Media/".count)) : entry.relativePath
    }

    /// Lists the files of a photo-folder copy, mapping its paths onto the same domains a backup uses.
    private static func folderCandidates(in root: URL, stats: inout ScanStats,
                                         progress: (ScanStats) -> Void,
                                         isCancelled: () -> Bool) throws -> [BackupEntry] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return [] }
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var entries: [BackupEntry] = []
        for case let url as URL in enumerator {
            if isCancelled() { throw BackupError.cancelled }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  url.path.hasPrefix(prefix) else { continue }
            stats.total += 1
            let relative = String(url.path.dropFirst(prefix.count))
            let size = Int64(values.fileSize ?? 0)
            guard relative != BackupLocator.photoCopyMarker,
                  !skippedExtensions.contains(url.pathExtension.lowercased()), size >= minimumBytes else {
                stats.checked += 1
                continue
            }
            let domain = relative.hasPrefix("DCIM/") || relative.hasPrefix("PhotoData/") ? "CameraRollDomain" : "MediaDomain"
            entries.append(BackupEntry(fileID: relative, domain: domain, relativePath: "Media/" + relative, size: size,
                                       protectionClass: 0, encryptionKey: nil,
                                       modified: values.contentModificationDate, created: values.creationDate))
            if stats.total % 2000 == 0 { progress(stats) }
        }
        return entries
    }

    private static func sniff(_ candidates: [BackupEntry], reader: BackupReader, library: LibraryIndex?,
                              stats initial: ScanStats, progress: (ScanStats) -> Void,
                              isCancelled: () -> Bool) throws -> [MediaItem] {
        let lock = NSLock()
        var stats = initial
        var items: [MediaItem] = []
        var cancelled = false
        let chunkSize = 64
        let chunkCount = (candidates.count + chunkSize - 1) / chunkSize

        DispatchQueue.concurrentPerform(iterations: chunkCount) { chunk in
            let range = (chunk * chunkSize)..<min(candidates.count, (chunk + 1) * chunkSize)
            var found: [MediaItem] = []
            var unreadable = 0
            for entry in candidates[range] {
                if isCancelled() {
                    lock.withLock { cancelled = true }
                    return
                }
                do {
                    guard let match = MediaSniffer.sniff(try reader.readPrefix(entry, length: MediaSniffer.headerLength)) else { continue }
                    found.append(MediaItem(entry: entry, kind: match.kind, detectedExtension: match.fileExtension,
                                           source: SourceClassifier.source(domain: entry.domain, path: entry.relativePath),
                                           libraryStatus: library?.status(forPath: libraryPath(of: entry))))
                } catch {
                    // Listed but missing or damaged on disk (for example, an interrupted backup).
                    unreadable += 1
                }
            }
            lock.withLock {
                items += found
                stats.checked += range.count
                stats.found += found.count
                stats.unreadable += unreadable
                if chunk % 8 == 0 || stats.checked == stats.total { progress(stats) }
            }
        }
        if cancelled { throw BackupError.cancelled }
        progress(stats)
        return items
    }
}
