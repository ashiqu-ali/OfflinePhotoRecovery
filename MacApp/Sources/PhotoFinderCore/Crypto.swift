import Foundation
import CommonCrypto

public enum CryptoError: Error, LocalizedError {
    case status(Int32)
    case badInput(String)
    case integrityCheckFailed

    public var errorDescription: String? {
        switch self {
        case .status(let code): return "Decryption failed (CommonCrypto error \(code))."
        case .badInput(let message): return message
        case .integrityCheckFailed: return "A wrapped key failed its integrity check."
        }
    }
}

/// Thin wrappers over Apple's CommonCrypto, which ships with macOS. No third-party crypto code.
public enum Crypto {
    static let success = Int32(kCCSuccess)

    public static func pbkdf2SHA256(_ password: Data, salt: Data, rounds: Int, length: Int = 32) throws -> Data {
        try pbkdf2(password, salt: salt, rounds: rounds, length: length, prf: CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256))
    }

    public static func pbkdf2SHA1(_ password: Data, salt: Data, rounds: Int, length: Int = 32) throws -> Data {
        try pbkdf2(password, salt: salt, rounds: rounds, length: length, prf: CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1))
    }

    private static func pbkdf2(_ password: Data, salt: Data, rounds: Int, length: Int, prf: CCPseudoRandomAlgorithm) throws -> Data {
        var derived = Data(count: length)
        let status: Int32 = derived.withUnsafeMutableBytes { out in
            password.withUnsafeBytes { pass in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pass.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        prf, UInt32(rounds),
                        out.baseAddress?.assumingMemoryBound(to: UInt8.self), length)
                }
            }
        }
        guard status == success else { throw CryptoError.status(status) }
        return derived
    }

    /// RFC 3394 AES key unwrap. Throws `integrityCheckFailed` when the key-encryption key is wrong.
    public static func aesKeyUnwrap(kek: Data, wrapped: Data) throws -> Data {
        let c = [UInt8](wrapped)
        guard c.count >= 24, c.count % 8 == 0 else { throw CryptoError.badInput("Wrapped key has an invalid length.") }
        let n = c.count / 8 - 1
        let aes = try AESBlockCipher(key: kek, operation: CCOperation(kCCDecrypt))
        var a = Array(c[0..<8])
        var r = (1...n).map { Array(c[($0 * 8)..<($0 * 8 + 8)]) }
        var block = [UInt8](repeating: 0, count: 16)
        for j in stride(from: 5, through: 0, by: -1) {
            for i in stride(from: n, through: 1, by: -1) {
                var t = UInt64(n * j + i)
                for k in stride(from: 7, through: 0, by: -1) {
                    block[k] = a[k] ^ UInt8(t & 0xFF)
                    t >>= 8
                }
                for k in 0..<8 { block[8 + k] = r[i - 1][k] }
                try aes.process(&block)
                a = Array(block[0..<8])
                r[i - 1] = Array(block[8..<16])
            }
        }
        guard a == [UInt8](repeating: 0xA6, count: 8) else { throw CryptoError.integrityCheckFailed }
        return Data(r.joined())
    }

    /// AES-256-CBC with a zero IV, the scheme iOS backups use. Trailing bytes that don't fill a block are ignored.
    public static func aesCBCDecrypt(key: Data, data: Data) throws -> Data {
        let usable = data.count - data.count % 16
        guard usable > 0 else { return Data() }
        return try CBCDecryptor(key: key).update(data.prefix(usable))
    }

    public static func stripPKCS7(_ data: Data) -> Data {
        guard let last = data.last, (1...16).contains(last), data.count >= Int(last) else { return data }
        guard data.suffix(Int(last)).allSatisfy({ $0 == last }) else { return data }
        return data.dropLast(Int(last))
    }
}

/// Streaming AES-CBC decryption (zero IV, no padding removal) so large videos never need to fit in memory.
public final class CBCDecryptor {
    private let cryptor: CCCryptorRef

    public init(key: Data) throws {
        guard [16, 24, 32].contains(key.count) else { throw CryptoError.badInput("AES key has an invalid length.") }
        var ref: CCCryptorRef?
        let iv = [UInt8](repeating: 0, count: 16)
        let status = key.withUnsafeBytes { k in
            CCCryptorCreate(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(0),
                            k.baseAddress, key.count, iv, &ref)
        }
        guard status == Crypto.success, let ref else { throw CryptoError.status(status) }
        cryptor = ref
    }

    deinit { CCCryptorRelease(cryptor) }

    public func update(_ input: Data) throws -> Data {
        guard !input.isEmpty else { return Data() }
        var output = Data(count: input.count + 16)
        var moved = 0
        let status = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { inp in
                CCCryptorUpdate(cryptor, inp.baseAddress, input.count, out.baseAddress, out.count, &moved)
            }
        }
        guard status == Crypto.success else { throw CryptoError.status(status) }
        output.count = moved
        return output
    }
}

/// Single-block AES (ECB) used by the key unwrap loop; created once per unwrap instead of once per block.
private final class AESBlockCipher {
    private let cryptor: CCCryptorRef

    init(key: Data, operation: CCOperation) throws {
        guard [16, 24, 32].contains(key.count) else { throw CryptoError.badInput("AES key has an invalid length.") }
        var ref: CCCryptorRef?
        let status = key.withUnsafeBytes { k in
            CCCryptorCreate(operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                            k.baseAddress, key.count, nil, &ref)
        }
        guard status == Crypto.success, let ref else { throw CryptoError.status(status) }
        cryptor = ref
    }

    deinit { CCCryptorRelease(cryptor) }

    func process(_ block: inout [UInt8]) throws {
        var out = [UInt8](repeating: 0, count: 16)
        var moved = 0
        let status = CCCryptorUpdate(cryptor, block, 16, &out, 16, &moved)
        guard status == Crypto.success, moved == 16 else { throw CryptoError.status(status) }
        block = out
    }
}

extension Data {
    /// Reads up to four bytes as a big-endian integer (the format used inside keybags).
    var bigEndianUInt32: UInt32 { prefix(4).reduce(0) { ($0 << 8) | UInt32($1) } }
    var littleEndianUInt32: UInt32 { prefix(4).reversed().reduce(0) { ($0 << 8) | UInt32($1) } }
}
