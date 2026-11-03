import AVFoundation
import AppKit
import ImageIO
import PhotoFinderCore

/// Decrypts files on demand and makes small previews. Photos are decoded in memory; videos are
/// decrypted to a private temporary file just long enough to grab one frame, then deleted.
final class ThumbnailLoader: @unchecked Sendable {
    static let shared = ThumbnailLoader()

    private let cache = NSCache<NSString, NSImage>()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .userInitiated
        return queue
    }()

    func clear() { cache.removeAllObjects() }

    func thumbnail(for item: MediaItem, reader: BackupReader, maxPixel: Int) async -> NSImage? {
        let key = "\(item.id)-\(maxPixel)"
        if let cached = cache.object(forKey: key as NSString) { return cached }
        return await withCheckedContinuation { continuation in
            queue.addOperation {
                let image = item.kind == .photo
                    ? Self.photoThumbnail(item, reader: reader, maxPixel: maxPixel)
                    : Self.videoThumbnail(item, reader: reader, maxPixel: maxPixel)
                if let image { self.cache.setObject(image, forKey: key as NSString) }
                continuation.resume(returning: image)
            }
        }
    }

    private static func photoThumbnail(_ item: MediaItem, reader: BackupReader, maxPixel: Int) -> NSImage? {
        guard item.entry.size < 200_000_000,
              let data = try? reader.readAll(item.entry),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }

    private final class FrameBox: @unchecked Sendable { var image: CGImage? }

    private static func videoThumbnail(_ item: MediaItem, reader: BackupReader, maxPixel: Int) -> NSImage? {
        guard item.entry.size < 400_000_000 else { return nil }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-\(UUID().uuidString).\(item.detectedExtension)")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard (try? reader.copyDecrypted(item.entry, to: temp)) != nil else { return nil }

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: temp))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        let box = FrameBox()
        let done = DispatchSemaphore(value: 0)
        generator.generateCGImageAsynchronously(for: .zero) { image, _, _ in
            box.image = image
            done.signal()
        }
        done.wait()
        return box.image.map { NSImage(cgImage: $0, size: .zero) }
    }
}
