import Foundation
import PhotoFinderCore

// Developer checks for PhotoFinderCore. Not part of the app bundle.
//
//   photofinder-selftest vectors
//   PF_PASSWORD=secret photofinder-selftest scan <backup folder> [--export <folder>]

var failures = 0

func check(_ name: String, _ ok: Bool) {
    print("\(ok ? "PASS" : "FAIL")  \(name)")
    if !ok { failures += 1 }
}

func hex(_ string: String) -> Data {
    var data = Data()
    var index = string.startIndex
    while index < string.endIndex {
        let next = string.index(index, offsetBy: 2)
        data.append(UInt8(string[index..<next], radix: 16)!)
        index = next
    }
    return data
}

func runVectors() {
    // RFC 3394 §4.1 and §4.6.
    let kek128 = hex("000102030405060708090A0B0C0D0E0F")
    let wrapped128 = hex("1FA68B0A8112B447AEF34BD8FB5A7B829D3E862371D2CFE5")
    check("RFC 3394 unwrap, 128-bit KEK",
          (try? Crypto.aesKeyUnwrap(kek: kek128, wrapped: wrapped128)) == hex("00112233445566778899AABBCCDDEEFF"))

    let kek256 = hex("000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F")
    let wrapped256 = hex("28C9F404C4B810F4CBCCB35CFB87F8263F5786E2D80ED326CBC7F0E71A99F43BFB988B9B7A02DD21")
    check("RFC 3394 unwrap, 256-bit key",
          (try? Crypto.aesKeyUnwrap(kek: kek256, wrapped: wrapped256))
            == hex("00112233445566778899AABBCCDDEEFF000102030405060708090A0B0C0D0E0F"))

    var tampered = wrapped256
    tampered[5] ^= 0x01
    var rejected = false
    do { _ = try Crypto.aesKeyUnwrap(kek: kek256, wrapped: tampered) } catch CryptoError.integrityCheckFailed { rejected = true } catch {}
    check("RFC 3394 rejects a wrong key", rejected)

    // RFC 6070 (PBKDF2-HMAC-SHA1) and the matching widely published SHA-256 vector.
    check("PBKDF2-SHA1", (try? Crypto.pbkdf2SHA1(Data("password".utf8), salt: Data("salt".utf8), rounds: 4096, length: 20))
          == hex("4b007901b765489abead49d926f721d065a429c1"))
    check("PBKDF2-SHA256", (try? Crypto.pbkdf2SHA256(Data("password".utf8), salt: Data("salt".utf8), rounds: 4096))
          == hex("c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a"))

    check("Sniff JPEG", MediaSniffer.sniff(hex("FFD8FFE000104A46494600010100000100010000"))?.kind == .photo)
    check("Sniff HEIC", MediaSniffer.sniff(Data([0, 0, 0, 0x18]) + Data("ftypheic".utf8) + Data(count: 8))?.fileExtension == "heic")
    check("Sniff MOV", MediaSniffer.sniff(Data([0, 0, 0, 0x14]) + Data("ftypqt  ".utf8) + Data(count: 8))?.kind == .video)
    check("Ignore M4A audio", MediaSniffer.sniff(Data([0, 0, 0, 0x20]) + Data("ftypM4A ".utf8) + Data(count: 8)) == nil)
    check("Source: WhatsApp group", SourceClassifier.source(domain: "AppDomainGroup-group.net.whatsapp.WhatsApp.shared", path: "x") == "WhatsApp")
    check("Source: Camera Roll", SourceClassifier.source(domain: "CameraRollDomain", path: "Media/DCIM/100APPLE/IMG_0001.HEIC") == "Camera Roll")
}

func runScan(_ arguments: [String]) throws {
    guard let path = arguments.first else { print("usage: scan <backup folder> [--export <folder>]"); exit(2) }
    let exportPath = arguments.firstIndex(of: "--export").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }

    guard let summary = try BackupLocator.findBackups(in: URL(fileURLWithPath: path)).first else {
        print("No backup found in \(path)"); exit(1)
    }
    print("Backup: \(summary.deviceName), iOS \(summary.iosVersion ?? "?"), encrypted: \(summary.isEncrypted)")
    let started = Date()
    let reader = try BackupReader(summary: summary, password: ProcessInfo.processInfo.environment["PF_PASSWORD"])
    print(String(format: "Unlocked in %.1fs", Date().timeIntervalSince(started)))

    var last = ScanStats()
    let items = try Scanner.scan(reader, progress: { last = $0 }, isCancelled: { false })
    print("Checked \(last.checked)/\(last.total) files, found \(last.found), unreadable \(last.unreadable)")
    for item in items {
        let status = item.libraryStatus.map { " | library: \($0.rawValue)" } ?? ""
        print("  [\(item.kind.rawValue)] \(item.source) | \(item.entry.relativePath) | \(item.entry.size) bytes\(status) | export as \(item.exportFileName)")
    }

    if let exportPath {
        let result = try Exporter.export(items, from: reader, into: URL(fileURLWithPath: exportPath),
                                         progress: { _, _ in }, isCancelled: { false })
        print("Exported \(result.exported), duplicates skipped \(result.duplicatesSkipped), failed \(result.failed)")
        print("EXPORT_FOLDER=\(result.folder.path)")
    }
}

switch CommandLine.arguments.dropFirst().first {
case "vectors":
    runVectors()
case "scan":
    do { try runScan(Array(CommandLine.arguments.dropFirst(2))) } catch { print("ERROR: \(error.localizedDescription)"); failures += 1 }
default:
    print("usage: photofinder-selftest vectors | scan <backup folder> [--export <folder>]")
    exit(2)
}
exit(failures == 0 ? 0 : 1)
