import Foundation

public struct ExportSummary: Sendable {
    public let folder: URL
    public let exported: Int
    public let duplicatesSkipped: Int
    public let failed: Int
}

/// Writes decrypted copies into a new folder, one subfolder per source, plus an index.csv describing each file.
public enum Exporter {
    public static func export(_ items: [MediaItem],
                              from reader: BackupReader,
                              into parent: URL,
                              skipDuplicates: Bool = true,
                              progress: (Int, Int) -> Void,
                              isCancelled: () -> Bool) throws -> ExportSummary {
        let fm = FileManager.default
        let stamp = reader.summary.lastBackup.map { Self.dayFormatter.string(from: $0) } ?? "undated"
        let root = uniqueURL(parent.appendingPathComponent(sanitize("\(reader.summary.deviceName) – recovered from backup \(stamp)"),
                                                           isDirectory: true))
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        var firstCopyByHash: [String: String] = [:]
        var csv = "exported_file,source,kind,original_domain,original_path,size_bytes,modified,sha256,note\n"
        var exported = 0, duplicates = 0, failed = 0
        let iso = ISO8601DateFormatter()

        // Export Camera Roll originals first so that, when a photo also exists in a chat app,
        // the copy kept is the original and the chat copy is the one marked as a duplicate.
        let ordered = items.enumerated().sorted { lhs, rhs in
            let l = priority(lhs.element.source), r = priority(rhs.element.source)
            return l != r ? l < r : lhs.offset < rhs.offset
        }.map(\.element)

        for (index, item) in ordered.enumerated() {
            if isCancelled() { break }
            progress(index, items.count)
            let folder = root.appendingPathComponent(sanitize(item.source), isDirectory: true)
            let destination = uniqueURL(folder.appendingPathComponent(sanitize(item.exportFileName)))
            let relative = "\(folder.lastPathComponent)/\(destination.lastPathComponent)"
            let modified = item.entry.modified.map(iso.string(from:)) ?? ""
            func row(_ file: String, _ sha: String, _ note: String) -> String {
                [file, item.source, item.kind.rawValue, item.entry.domain, item.entry.relativePath,
                 String(item.entry.size), modified, sha, note].map(csvField).joined(separator: ",") + "\n"
            }
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                let sha = try reader.copyDecrypted(item.entry, to: destination)
                if skipDuplicates, let original = firstCopyByHash[sha] {
                    try? fm.removeItem(at: destination)
                    duplicates += 1
                    csv += row("", sha, "duplicate of \(original)")
                    continue
                }
                firstCopyByHash[sha] = relative
                var attributes: [FileAttributeKey: Any] = [:]
                if let date = item.entry.modified { attributes[.modificationDate] = date }
                if let date = item.entry.created ?? item.entry.modified { attributes[.creationDate] = date }
                try? fm.setAttributes(attributes, ofItemAtPath: destination.path)
                exported += 1
                csv += row(relative, sha, "")
            } catch {
                try? fm.removeItem(at: destination)
                failed += 1
                csv += row("", "", "failed: \(error.localizedDescription)")
            }
        }
        progress(items.count, items.count)
        try csv.write(to: root.appendingPathComponent("index.csv"), atomically: true, encoding: .utf8)
        removeEmptyFolders(in: root)
        return ExportSummary(folder: root, exported: exported, duplicatesSkipped: duplicates, failed: failed)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func priority(_ source: String) -> Int {
        switch source {
        case SourceClassifier.cameraRoll: return 0
        case SourceClassifier.thumbnails: return 2
        default: return 1
        }
    }

    static func sanitize(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned.hasPrefix(".") ? "file\(cleaned)" : cleaned
    }

    /// Appends " (2)", " (3)"… before the extension until the name is free.
    static func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent()
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func removeEmptyFolders(in root: URL) {
        let fm = FileManager.default
        for folder in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            if let contents = try? fm.contentsOfDirectory(atPath: folder.path), contents.isEmpty {
                try? fm.removeItem(at: folder)
            }
        }
    }
}
