import Foundation

public enum MediaKind: String, Sendable, Hashable {
    case photo, video
}

public struct SniffResult: Equatable, Sendable {
    public let kind: MediaKind
    public let fileExtension: String
}

/// Identifies photos and videos from their first bytes. Backup files often have no extension
/// (app caches use hashed names), so the content decides, not the name.
public enum MediaSniffer {
    public static let headerLength = 32

    private static let heifBrands: Set<String> = ["heic", "heix", "heim", "heis", "hevc", "hevx", "hevm", "hevs", "mif1", "msf1"]
    private static let avifBrands: Set<String> = ["avif", "avis"]
    private static let audioBrands: Set<String> = ["M4A ", "M4B ", "M4P ", "F4A ", "F4B "]
    private static let quickTimeAtoms: Set<String> = ["moov", "mdat", "wide", "pnot"]

    public static func sniff(_ header: Data) -> SniffResult? {
        let b = [UInt8](header.prefix(headerLength))
        guard b.count >= 12 else { return nil }

        if b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return SniffResult(kind: .photo, fileExtension: "jpg") }
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return SniffResult(kind: .photo, fileExtension: "png") }
        if ascii(b, 0, 6) == "GIF87a" || ascii(b, 0, 6) == "GIF89a" { return SniffResult(kind: .photo, fileExtension: "gif") }
        if ascii(b, 0, 4) == "RIFF", ascii(b, 8, 4) == "WEBP" { return SniffResult(kind: .photo, fileExtension: "webp") }
        if b.starts(with: [0x49, 0x49, 0x2A, 0x00]) || b.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) {
            return SniffResult(kind: .photo, fileExtension: "tiff")
        }

        let box = ascii(b, 4, 4)
        if box == "ftyp" {
            let brand = ascii(b, 8, 4)
            if heifBrands.contains(brand) { return SniffResult(kind: .photo, fileExtension: "heic") }
            if avifBrands.contains(brand) { return SniffResult(kind: .photo, fileExtension: "avif") }
            if audioBrands.contains(brand) || brand == "crx " { return nil }
            if brand == "qt  " { return SniffResult(kind: .video, fileExtension: "mov") }
            if brand.hasPrefix("3g") { return SniffResult(kind: .video, fileExtension: "3gp") }
            return SniffResult(kind: .video, fileExtension: "mp4")
        }
        if quickTimeAtoms.contains(box) { return SniffResult(kind: .video, fileExtension: "mov") }
        return nil
    }

    private static func ascii(_ bytes: [UInt8], _ offset: Int, _ count: Int) -> String {
        guard offset + count <= bytes.count else { return "" }
        return String(decoding: bytes[offset..<offset + count], as: Unicode.ASCII.self)
    }
}
