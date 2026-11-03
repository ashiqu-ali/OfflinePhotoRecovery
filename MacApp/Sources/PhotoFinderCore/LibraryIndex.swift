import Foundation
import SQLite3

public enum LibraryStatus: String, Sendable, Hashable {
    case inLibrary, recentlyDeleted, notInLibrary
}

/// What the Photos app currently holds, read from copies of Photos.sqlite and iCloud Photos' sync
/// database (CPL/storage/store.cloudphotodb). An item is only called "not in library" when there is
/// evidence for it; anything that can't be linked either way gets no label.
struct LibraryIndex {
    /// Photo name without extension ("IMG_0146") → status. Folder numbers are ignored on purpose:
    /// iOS can file a photo under a different DCIM folder than its thumbnails and edits.
    private var names: [String: LibraryStatus] = [:]
    /// iCloud cache fingerprints known to belong to photos in the library.
    private var cacheInLibrary: Set<String> = []
    /// iCloud cache fingerprints whose original iCloud Photos has recorded as deleted.
    private var cacheDeleted: Set<String> = []

    init?(photoDataFolder: URL) {
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("library-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        guard let photos = Self.openCopy(of: "Photos.sqlite", in: photoDataFolder, workDir: workDir) else { return nil }
        defer { sqlite3_close(photos) }

        // ZASSET since iOS 14; ZGENERICASSET before that.
        var assetTable = "ZASSET"
        for table in ["ZASSET", "ZGENERICASSET"] {
            Self.forEachRow(photos, "SELECT ZFILENAME, ZTRASHEDSTATE FROM \(table)") { row in
                assetTable = table
                guard let name = row.text(0) else { return }
                let status: LibraryStatus = row.int(1) != 0 ? .recentlyDeleted : .inLibrary
                let key = Self.stem(name)
                if names[key] != .inLibrary { names[key] = status }
            }
            if !names.isEmpty { break }
        }
        guard !names.isEmpty else { return nil }
        // Separate queries, so a column missing in some iOS version only disables its own check.
        var assetIDs: Set<String> = []
        for column in ["ZUUID", "ZCLOUDASSETGUID"] {
            Self.forEachRow(photos, "SELECT \(column) FROM \(assetTable) WHERE \(column) IS NOT NULL") { row in
                if let id = row.text(0) { assetIDs.insert(id) }
            }
        }
        // Photos renamed on import keep their original name here.
        Self.forEachRow(photos, "SELECT ZORIGINALFILENAME FROM ZADDITIONALASSETATTRIBUTES WHERE ZORIGINALFILENAME IS NOT NULL") { row in
            if let name = row.text(0), names[Self.stem(name)] == nil { names[Self.stem(name)] = .inLibrary }
        }

        var masterIDs: Set<String> = []
        Self.forEachRow(photos, "SELECT ZCLOUDMASTERGUID FROM ZCLOUDMASTER WHERE ZCLOUDMASTERGUID IS NOT NULL") { row in
            if let id = row.text(0) { masterIDs.insert(id) }
        }
        cacheInLibrary = masterIDs
        for (table, column) in [("ZINTERNALRESOURCE", "ZFINGERPRINT"), ("ZCLOUDRESOURCE", "ZFINGERPRINT"),
                                ("ZADDITIONALASSETATTRIBUTES", "ZMASTERFINGERPRINT"),
                                ("ZADDITIONALASSETATTRIBUTES", "ZADJUSTEDFINGERPRINT")] {
            Self.forEachRow(photos, "SELECT \(column) FROM \(table) WHERE \(column) IS NOT NULL") { row in
                if let fingerprint = row.text(0) { cacheInLibrary.insert(fingerprint) }
            }
        }

        let cplFolder = photoDataFolder.appendingPathComponent("CPL/storage")
        if let cpl = Self.openCopy(of: "store.cloudphotodb", in: cplFolder, workDir: workDir) {
            defer { sqlite3_close(cpl) }
            // Files waiting to upload, linked to the photo they belong to.
            Self.forEachRow(cpl, "SELECT fingerPrint, itemIdentifier FROM outgoingResources") { row in
                guard let fingerprint = row.text(0), let item = row.text(1) else { return }
                if assetIDs.contains(item) || masterIDs.contains(item) { cacheInLibrary.insert(fingerprint) }
            }
            // Originals iCloud Photos has been told to delete. Their identifier is the original's fingerprint.
            Self.forEachRow(cpl, "SELECT identifier FROM pushRepository WHERE class = 'CPLMasterChange' AND trashed = 1") { row in
                if let id = row.text(0) { cacheDeleted.insert(id) }
            }
            Self.forEachRow(cpl, "SELECT cloudIdentifier, localIdentifier FROM idMapping WHERE deleteTimestamp IS NOT NULL AND deleteTimestamp != 0") { row in
                cacheDeleted.formUnion([row.text(0), row.text(1)].compactMap { $0 })
            }
            cacheDeleted.subtract(cacheInLibrary)
        }
    }

    /// `path` is relative to the copy root, such as "PhotoData/Thumbnails/V2/DCIM/100APPLE/IMG_0001.JPG/5005.JPG".
    func status(forPath path: String) -> LibraryStatus? {
        if path.hasPrefix("PhotoData/CPL/storage/filecache/") {
            guard let fingerprint = Self.cacheFingerprint(fileName: (path as NSString).lastPathComponent) else { return nil }
            if cacheInLibrary.contains(fingerprint) { return .inLibrary }
            return cacheDeleted.contains(fingerprint) ? .notInLibrary : nil
        }
        guard let name = Self.photoName(forPath: path) else { return nil }
        return names[name] ?? .notInLibrary
    }

    /// The photo a Camera Roll file, thumbnail or edit belongs to, without extension ("IMG_0001").
    static func photoName(forPath path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        // DCIM/100APPLE/IMG_0001.HEIC
        if parts.first == "DCIM", parts.count == 3 { return stem(parts[2]) }
        // PhotoData/Thumbnails/V2/<folders>/IMG_0001.JPG/5005.JPG
        if parts.count >= 6, parts[0] == "PhotoData", parts[1] == "Thumbnails", parts[2] == "V2" {
            return stem(parts[parts.count - 2])
        }
        // PhotoData/Mutations/DCIM/100APPLE/IMG_0001/Adjustments/FullSizeRender.jpg
        if parts.count >= 5, parts[0] == "PhotoData", parts[1] == "Mutations", parts[2] == "DCIM" { return stem(parts[4]) }
        return nil
    }

    /// "cplAa2+Y69za7wJ9cDxrCcx0NefVyN8.jpeg" → "Aa2+Y69za7wJ9cDxrCcx0NefVyN8"
    static func cacheFingerprint(fileName: String) -> String? {
        guard fileName.hasPrefix("cpl") else { return nil }
        let fingerprint = stem(String(fileName.dropFirst(3)))
        return fingerprint.isEmpty ? nil : fingerprint
    }

    static func stem(_ name: String) -> String { (name as NSString).deletingPathExtension }

    // MARK: SQLite helpers

    /// Opens a private copy (with its -wal/-shm journal) so the copied library is never changed.
    private static func openCopy(of name: String, in folder: URL, workDir: URL) -> OpaquePointer? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.appendingPathComponent(name).path) else { return nil }
        try? fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            let file = folder.appendingPathComponent(name + suffix)
            if fm.fileExists(atPath: file.path) { try? fm.copyItem(at: file, to: workDir.appendingPathComponent(name + suffix)) }
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(workDir.appendingPathComponent(name).path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        return db
    }

    private struct Row {
        let stmt: OpaquePointer?
        func text(_ column: Int32) -> String? { sqlite3_column_text(stmt, column).map { String(cString: $0) } }
        func int(_ column: Int32) -> Int32 { sqlite3_column_int(stmt, column) }
    }

    /// Runs a query, quietly doing nothing if this iOS version's database lacks the table or column.
    private static func forEachRow(_ db: OpaquePointer?, _ sql: String, _ body: (Row) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            return
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW { body(Row(stmt: stmt)) }
    }
}
