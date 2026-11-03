import Foundation

/// The backup keybag stored in Manifest.plist. It holds one AES key per data-protection class,
/// each wrapped with a key derived from the backup password.
struct Keybag {
    private(set) var header: [String: Data] = [:]
    private(set) var classKeys: [UInt32: [String: Data]] = [:]
    private var unlockedKeys: [UInt32: Data] = [:]

    private static let classKeyTags: Set<String> = ["CLAS", "WRAP", "WPKY", "KTYP", "PBKY"]
    private static let wrapPasscode: UInt32 = 2

    /// Parses the tag-length-value blob: a header, then one "UUID"-led record per class key.
    init(data: Data) throws {
        let bytes = [UInt8](data)
        var offset = 0
        var current: [String: Data]?
        var sawHeaderUUID = false
        var sawHeaderWrap = false

        while offset + 8 <= bytes.count {
            let tag = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
            let length = Int(Data(bytes[offset + 4..<offset + 8]).bigEndianUInt32)
            let start = offset + 8
            guard start + length <= bytes.count else { throw BackupError.unreadable("The backup keybag is damaged.") }
            let value = Data(bytes[start..<start + length])
            offset = start + length

            if tag == "UUID" && !sawHeaderUUID {
                sawHeaderUUID = true
                header[tag] = value
            } else if tag == "WRAP" && !sawHeaderWrap {
                sawHeaderWrap = true
                header[tag] = value
            } else if tag == "UUID" {
                if let finished = current, let cls = finished["CLAS"] { classKeys[cls.bigEndianUInt32] = finished }
                current = ["UUID": value]
            } else if Self.classKeyTags.contains(tag), current != nil {
                current?[tag] = value
            } else {
                header[tag] = value
            }
        }
        if let finished = current, let cls = finished["CLAS"] { classKeys[cls.bigEndianUInt32] = finished }
        guard !classKeys.isEmpty else { throw BackupError.unreadable("The backup keybag has no keys.") }
    }

    /// Derives the password key the same way iOS does (PBKDF2-SHA256 then PBKDF2-SHA1) and unwraps every class key.
    mutating func unlock(password: String) throws {
        var key = Data(password.utf8)
        if let dpsl = header["DPSL"], let dpic = header["DPIC"] {
            key = try Crypto.pbkdf2SHA256(key, salt: dpsl, rounds: Int(dpic.bigEndianUInt32))
        }
        guard let salt = header["SALT"], let iterations = header["ITER"] else {
            throw BackupError.unreadable("The backup keybag is missing its salt.")
        }
        let passwordKey = try Crypto.pbkdf2SHA1(key, salt: salt, rounds: Int(iterations.bigEndianUInt32))

        var unlocked: [UInt32: Data] = [:]
        for (cls, record) in classKeys {
            guard let wrapped = record["WPKY"] else { continue }
            let wrap = record["WRAP"]?.bigEndianUInt32 ?? 0
            if wrap & Self.wrapPasscode != 0 {
                do {
                    unlocked[cls] = try Crypto.aesKeyUnwrap(kek: passwordKey, wrapped: wrapped)
                } catch CryptoError.integrityCheckFailed {
                    throw BackupError.wrongPassword
                }
            } else if wrap == 0 {
                unlocked[cls] = wrapped
            }
        }
        guard !unlocked.isEmpty else { throw BackupError.wrongPassword }
        unlockedKeys = unlocked
    }

    func unwrap(_ wrappedKey: Data, protectionClass: UInt32) throws -> Data {
        guard let classKey = unlockedKeys[protectionClass] else { throw BackupError.missingClassKey(protectionClass) }
        return try Crypto.aesKeyUnwrap(kek: classKey, wrapped: wrappedKey)
    }
}
