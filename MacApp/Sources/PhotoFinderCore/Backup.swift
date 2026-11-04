import Foundation
import CryptoKit
import SQLite3

public enum BackupError: Error, LocalizedError {
    case passwordRequired
    case wrongPassword
    case missingClassKey(UInt32)
    case accessDenied(String)
    case incompleteBackup
    case unreadable(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .passwordRequired:
            return "This backup is encrypted. Enter its password."
        case .incompleteBackup:
            return "This backup hasn't finished yet. Let the backup complete (it opens on its own when done), then search it. If it was interrupted, back up again."
        case .wrongPassword:
            return "That password doesn't unlock this backup. Use the backup password (the one set with “Encrypt local backup”), not your iPhone passcode or Apple ID password."
        case .missingClassKey(let cls):
            return "The backup is missing the key for protection class \(cls)."
        case .accessDenied(let name):
            return "macOS didn't allow this app to read “\(name)”. In Finder, copy the backup folder to your Desktop, then open the copy."
        case .unreadable(let message):
            return message
        case .cancelled:
            return "Cancelled."
        }
    }
}

/// One device backup folder (the folder that holds Manifest.plist).
public struct BackupSummary: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let deviceName: String
    public let productType: String?
    public let iosVersion: String?
    public let lastBackup: Date?
    public let isEncrypted: Bool
    /// A direct copy of the iPhone's photo folders (made over USB with AFC), not an iOS backup.
    public var isPhotoFolderCopy = false
    /// False while a backup is still being written (Status.plist not yet "finished"). Reading its
    /// Manifest.db then gives a half-written file, so the app waits instead of showing a cryptic error.
    public var isComplete = true
}

public enum BackupLocator {
    /// Written at the top of a photo-folder copy so it can be recognised later.
    public static let photoCopyMarker = "OfflinePhotoFinder-copy.plist"

    /// Accepts a device backup folder, a folder of device backups (like Finder's `Backup`), or its parent.
    public static func findBackups(in folder: URL) throws -> [BackupSummary] {
        let fm = FileManager.default
        do {
            _ = try fm.contentsOfDirectory(atPath: folder.path)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError {
            throw BackupError.accessDenied(folder.lastPathComponent)
        }

        var candidates = [folder]
        for dir in [folder, folder.appendingPathComponent("Backup", isDirectory: true)] {
            if let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                candidates += children
            }
        }
        var seen = Set<String>()
        var found: [BackupSummary] = []
        for candidate in candidates where seen.insert(candidate.standardizedFileURL.path).inserted {
            if let summary = summary(for: candidate) { found.append(summary) }
        }
        return found.sorted { ($0.lastBackup ?? .distantPast) > ($1.lastBackup ?? .distantPast) }
    }

    public static func summary(for url: URL) -> BackupSummary? {
        if let marker = readPlist(url.appendingPathComponent(photoCopyMarker)) {
            return BackupSummary(url: url,
                                 deviceName: marker["DeviceName"] as? String ?? "iPhone",
                                 productType: marker["ProductType"] as? String,
                                 iosVersion: marker["ProductVersion"] as? String,
                                 lastBackup: marker["Date"] as? Date,
                                 isEncrypted: false,
                                 isPhotoFolderCopy: true)
        }
        guard let manifest = readPlist(url.appendingPathComponent("Manifest.plist")),
              FileManager.default.fileExists(atPath: url.appendingPathComponent("Manifest.db").path) else { return nil }
        let info = readPlist(url.appendingPathComponent("Info.plist")) ?? [:]
        let lockdown = manifest["Lockdown"] as? [String: Any] ?? [:]
        // A backup still being written reports SnapshotState other than "finished" in Status.plist.
        let status = readPlist(url.appendingPathComponent("Status.plist")) ?? [:]
        let complete = (status["SnapshotState"] as? String).map { $0 == "finished" } ?? true
        return BackupSummary(
            url: url,
            deviceName: info["Device Name"] as? String ?? info["Display Name"] as? String
                ?? lockdown["DeviceName"] as? String ?? url.lastPathComponent,
            productType: info["Product Type"] as? String ?? lockdown["ProductType"] as? String,
            iosVersion: info["Product Version"] as? String ?? lockdown["ProductVersion"] as? String,
            lastBackup: info["Last Backup Date"] as? Date ?? manifest["Date"] as? Date,
            isEncrypted: manifest["IsEncrypted"] as? Bool ?? false,
            isComplete: complete)
    }

    static func readPlist(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}

/// One file listed in Manifest.db, with the metadata from its MBFile record.
public struct BackupEntry: Hashable, Sendable {
    public let fileID: String
    public let domain: String
    public let relativePath: String
    public let size: Int64
    public let protectionClass: UInt32
    let encryptionKey: Data?
    public let modified: Date?
    public let created: Date?
}

/// Decodes the NSKeyedArchiver "MBFile" record stored in Manifest.db's `file` column.
final class MBFileRecord: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }

    let size: Int64
    let protectionClass: UInt32
    let encryptionKey: Data?
    let lastModified: Int64
    let birth: Int64

    init?(coder: NSCoder) {
        size = coder.decodeInt64(forKey: "Size")
        protectionClass = UInt32(truncatingIfNeeded: coder.decodeInt64(forKey: "ProtectionClass"))
        encryptionKey = coder.decodeObject(of: [NSData.self, NSMutableData.self], forKey: "EncryptionKey") as? Data
        lastModified = coder.decodeInt64(forKey: "LastModified")
        birth = coder.decodeInt64(forKey: "Birth")
    }

    func encode(with coder: NSCoder) {}

    static func decode(_ blob: Data) -> MBFileRecord? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: blob) else { return nil }
        unarchiver.setClass(MBFileRecord.self, forClassName: "MBFile")
        defer { unarchiver.finishDecoding() }
        return unarchiver.decodeObject(of: MBFileRecord.self, forKey: NSKeyedArchiveRootObjectKey)
    }
}

struct ManifestRow {
    let fileID: String
    let domain: String
    let relativePath: String
    let blob: Data
}

/// Read-only access to a backup. Nothing inside the backup folder is ever written or modified.
public final class BackupReader: @unchecked Sendable {
    public let summary: BackupSummary
    private let keybag: Keybag?
    private let manifestKey: (protectionClass: UInt32, wrapped: Data)?

    /// For encrypted backups this derives the password key, which takes a few seconds by design.
    public init(summary: BackupSummary, password: String?) throws {
        self.summary = summary
        if summary.isPhotoFolderCopy {
            keybag = nil
            manifestKey = nil
            return
        }
        guard summary.isComplete else { throw BackupError.incompleteBackup }
        guard let manifest = BackupLocator.readPlist(summary.url.appendingPathComponent("Manifest.plist")) else {
            throw BackupError.unreadable("Couldn't read Manifest.plist in “\(summary.url.lastPathComponent)”.")
        }
        guard summary.isEncrypted else {
            keybag = nil
            manifestKey = nil
            return
        }
        guard let password, !password.isEmpty else { throw BackupError.passwordRequired }
        guard let bagData = manifest["BackupKeyBag"] as? Data,
              let keyData = manifest["ManifestKey"] as? Data, keyData.count > 4 else {
            throw BackupError.unreadable("This encrypted backup is missing its keys. It may be incomplete.")
        }
        var bag = try Keybag(data: bagData)
        try bag.unlock(password: password)
        keybag = bag
        manifestKey = (keyData.littleEndianUInt32, Data(keyData.dropFirst(4)))
    }

    /// Decrypts (or copies) Manifest.db into a private temporary folder, runs `body`, then deletes the copy.
    func withManifest<T>(_ body: (ManifestDatabase) throws -> T) throws -> T {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("manifest-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        let source = summary.url.appendingPathComponent("Manifest.db")
        let copy = workDir.appendingPathComponent("Manifest.db")
        if let keybag, let manifestKey {
            let key = try keybag.unwrap(manifestKey.wrapped, protectionClass: manifestKey.protectionClass)
            let plain = Crypto.stripPKCS7(try Crypto.aesCBCDecrypt(key: key, data: Data(contentsOf: source)))
            guard plain.starts(with: Data("SQLite format 3".utf8)) else {
                throw BackupError.unreadable("Manifest.db didn't decrypt to a valid database.")
            }
            try plain.write(to: copy)
        } else {
            try fm.copyItem(at: source, to: copy)
        }
        let database = try ManifestDatabase(path: copy.path)
        return try body(database)
    }

    func entry(from row: ManifestRow) -> BackupEntry? {
        guard let record = MBFileRecord.decode(row.blob) else { return nil }
        return BackupEntry(
            fileID: row.fileID,
            domain: row.domain,
            relativePath: row.relativePath,
            size: record.size,
            protectionClass: record.protectionClass,
            encryptionKey: record.encryptionKey,
            modified: record.lastModified > 0 ? Date(timeIntervalSince1970: TimeInterval(record.lastModified)) : nil,
            created: record.birth > 0 ? Date(timeIntervalSince1970: TimeInterval(record.birth)) : nil)
    }

    /// Backups store files as `<first two characters of fileID>/<fileID>`; photo-folder copies use
    /// the real path, which is what `fileID` holds for them.
    public func storedFileURL(_ entry: BackupEntry) -> URL {
        if summary.isPhotoFolderCopy { return summary.url.appendingPathComponent(entry.fileID) }
        return summary.url
            .appendingPathComponent(String(entry.fileID.prefix(2)), isDirectory: true)
            .appendingPathComponent(entry.fileID)
    }

    private func fileKey(_ entry: BackupEntry) throws -> Data? {
        guard let keybag else { return nil }
        // The first four bytes repeat the protection class; the 40-byte wrapped key follows.
        guard let stored = entry.encryptionKey, stored.count > 4 else {
            throw BackupError.unreadable("No encryption key recorded for \(entry.relativePath).")
        }
        return try keybag.unwrap(Data(stored.dropFirst(4)), protectionClass: entry.protectionClass)
    }

    public func readPrefix(_ entry: BackupEntry, length: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: storedFileURL(entry))
        defer { try? handle.close() }
        guard let key = try fileKey(entry) else { return try handle.read(upToCount: length) ?? Data() }
        let raw = try handle.read(upToCount: (length + 15) / 16 * 16) ?? Data()
        return Data(try Crypto.aesCBCDecrypt(key: key, data: raw).prefix(length))
    }

    public func readAll(_ entry: BackupEntry) throws -> Data {
        let raw = try Data(contentsOf: storedFileURL(entry), options: .mappedIfSafe)
        guard let key = try fileKey(entry) else { return raw }
        let plain = try Crypto.aesCBCDecrypt(key: key, data: raw)
        if entry.size > 0, Int64(plain.count) >= entry.size { return Data(plain.prefix(Int(entry.size))) }
        return Crypto.stripPKCS7(plain)
    }

    /// Streams the decrypted file to `destination` and returns its SHA-256 (hex).
    @discardableResult
    public func copyDecrypted(_ entry: BackupEntry, to destination: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: storedFileURL(entry))
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw BackupError.unreadable("Couldn't create “\(destination.lastPathComponent)”.")
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        let key = try fileKey(entry)
        let decryptor = try key.map { try CBCDecryptor(key: $0) }
        // Encrypted files are padded to 16 bytes; the recorded size tells us where the real data ends.
        var remaining: Int64 = (decryptor != nil && entry.size > 0) ? entry.size : .max
        var hasher = SHA256()
        while remaining > 0, let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            var plain = try decryptor?.update(chunk) ?? chunk
            if Int64(plain.count) > remaining { plain = Data(plain.prefix(Int(remaining))) }
            remaining -= Int64(plain.count)
            hasher.update(data: plain)
            try output.write(contentsOf: plain)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Minimal read-only wrapper around the SQLite C API that ships with macOS.
final class ManifestDatabase {
    private var db: OpaquePointer?

    init(path: String) throws {
        // iOS writes Manifest.db in WAL journal mode. Opening that read-only the plain way needs the
        // -wal/-shm sidecars (which a backup doesn't ship) and a writable directory; immutable=1 tells
        // SQLite the file won't change, so it reads the committed data straight from the main file.
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let uri = "file:\(encoded)?immutable=1"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            throw BackupError.unreadable("Manifest.db couldn't be opened (\(message)).")
        }
    }

    deinit { sqlite3_close(db) }

    func fileCount() throws -> Int {
        let stmt = try prepare("SELECT COUNT(*) FROM Files WHERE flags = 1")
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    /// Visits every regular file (flags = 1; directories are 2 and symlinks 4).
    func forEachFile(_ body: (ManifestRow) throws -> Void) throws {
        let stmt = try prepare("SELECT fileID, domain, relativePath, file FROM Files WHERE flags = 1")
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            var blob = Data()
            if let bytes = sqlite3_column_blob(stmt, 3) {
                blob = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 3)))
            }
            try body(ManifestRow(fileID: text(stmt, 0), domain: text(stmt, 1), relativePath: text(stmt, 2), blob: blob))
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw BackupError.unreadable("Couldn't read this backup's file list. The backup may be incomplete or damaged — back up again.")
        }
        return stmt
    }

    private func text(_ stmt: OpaquePointer?, _ column: Int32) -> String {
        sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? ""
    }
}
