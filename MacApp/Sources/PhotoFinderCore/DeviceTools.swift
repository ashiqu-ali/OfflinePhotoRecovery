import Foundation

public struct ConnectedDevice: Identifiable, Hashable, Sendable {
    public let id: String  // UDID
    public var name = "iPhone"
    public var model: String?
    public var iosVersion: String?
    /// True when the iPhone has "Encrypt local backup" turned on, so the backup will need its password.
    public var backupWillEncrypt: Bool?
    public var usedBytes: Int64?
}

public enum PairingState: Equatable, Sendable {
    case paired
    case needsTrust(String)
    case failed(String)
}

public enum DeviceError: Error, LocalizedError {
    case toolsMissing
    case usbmuxUnavailable(String)
    case toolFailed(String)
    case backupFailed(String)

    public var errorDescription: String? {
        switch self {
        case .toolsMissing:
            return "The libimobiledevice tools aren't inside this app. Rebuild it with build.sh."
        case .usbmuxUnavailable(let output):
            return "Couldn't talk to macOS's USB device service. \(output)"
        case .toolFailed(let output):
            return output
        case .backupFailed(let output):
            return "The backup stopped before finishing.\n\(output)"
        }
    }
}

/// Runs the open-source libimobiledevice tools bundled inside the app. They reach the iPhone only
/// through macOS's local usbmuxd service over the USB cable; the app's sandbox blocks all networking.
public enum DeviceTools {
    public static let toolNames = ["idevice_id", "ideviceinfo", "idevicepair", "idevicebackup2", "afcclient"]

    public static func toolURL(_ name: String) -> URL? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(name)")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        for dir in ["/opt/homebrew/bin", "/usr/local/bin"] {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    public static var isAvailable: Bool { toolNames.allSatisfy { toolURL($0) != nil } }

    /// Where backups made by this app are kept (inside the app's own sandbox container).
    public static var backupStorageFolder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Offline Photo Finder/Backups", isDirectory: true)
    }

    static func run(_ tool: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        guard let url = toolURL(tool) else { throw DeviceError.toolsMissing }
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// UDIDs of iPhones connected by USB cable (network-attached devices are not listed).
    public static func connectedDeviceIDs() throws -> [String] {
        let result = try run("idevice_id", ["-l"])
        guard result.status == 0 else { throw DeviceError.usbmuxUnavailable(clean(result.output)) }
        return result.output.split(whereSeparator: \.isNewline)
            .compactMap { $0.split(separator: " ").first.map(String.init) }
            .filter { !$0.isEmpty }
    }

    /// Checks the existing pairing; if there is none, asks the iPhone to show "Trust This Computer?".
    public static func pair(udid: String) throws -> PairingState {
        if try run("idevicepair", ["-u", udid, "validate"]).status == 0 { return .paired }
        let attempt = try run("idevicepair", ["-u", udid, "pair"])
        if attempt.status == 0 { return .paired }
        let message = clean(attempt.output)
        let lower = message.lowercased()
        if lower.contains("trust") || lower.contains("passcode") || lower.contains("locked") {
            return .needsTrust(message)
        }
        return .failed(message)
    }

    public static func details(udid: String) -> ConnectedDevice {
        var device = ConnectedDevice(id: udid)
        if let values = try? keyValues(udid: udid, domain: nil) {
            device.name = values["DeviceName"] ?? device.name
            device.model = values["ProductType"]
            device.iosVersion = values["ProductVersion"]
        }
        if let backup = try? keyValues(udid: udid, domain: "com.apple.mobile.backup") {
            device.backupWillEncrypt = backup["WillEncrypt"] == "true"
        }
        device.usedBytes = usedStorage(udid: udid)
        return device
    }

    /// Storage in use, from the AFC file service. (Avoid lockdown's "com.apple.disk_usage" query: the
    /// iPhone measures every app to answer it, which can keep it busy for many minutes and stall backups.)
    static func usedStorage(udid: String) -> Int64? {
        guard let result = try? run("afcclient", ["-u", udid, "devinfo"]), result.status == 0,
              let start = result.output.firstIndex(of: "{"),
              let info = try? JSONSerialization.jsonObject(with: Data(result.output[start...].utf8)) as? [String: Any],
              let total = (info["FSTotalBytes"] as? NSNumber)?.int64Value,
              let free = (info["FSFreeBytes"] as? NSNumber)?.int64Value else { return nil }
        return total - free
    }

    /// ideviceinfo prints top-level values as "Key: value" lines.
    static func keyValues(udid: String, domain: String?) throws -> [String: String] {
        var arguments = ["-u", udid]
        if let domain { arguments += ["-q", domain] }
        let result = try run("ideviceinfo", arguments)
        guard result.status == 0 else { throw DeviceError.toolFailed(clean(result.output)) }
        var values: [String: String] = [:]
        for line in result.output.split(whereSeparator: \.isNewline) where !line.hasPrefix(" ") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            values[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return values
    }

    static func clean(_ output: String) -> String {
        output.split(whereSeparator: \.isNewline)
            .map { $0.replacingOccurrences(of: "ERROR: ", with: "").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

/// Copies the Photos app's own folders straight off the iPhone with AFC (`afcclient get -r`). Much
/// faster than a full backup, and it works when iCloud Photos keeps the photo library out of backups.
public final class PhotoFolderCopyJob: @unchecked Sendable {
    public enum Event: Sendable {
        /// Folder being copied, its position, and the folder count.
        case folder(String, Int, Int)
        /// Transfer status of the current file, such as "45% (31.8 MB/s)".
        case transfer(String)
        case log(String)
    }

    /// Folders under the iPhone's Media directory that can hold photos or leftovers of them.
    /// DCIM (the current Camera Roll) is optional because it is large and nothing in it is lost.
    public static let photoFolders = ["PhotoData", "PhotoStreamsData", "CloudAssets", "LoFiCloudAssets", "Photos", "Downloads"]

    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    public init() {}

    /// Blocks until done. The copy lands in `folder/<UDID>-photos`, which is returned.
    public func run(device: ConnectedDevice, includeCameraRoll: Bool, into folder: URL,
                    onEvent: (Event) -> Void) throws -> URL {
        guard let tool = DeviceTools.toolURL("afcclient") else { throw DeviceError.toolsMissing }
        let destination = folder.appendingPathComponent("\(device.id)-photos", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let folders = (includeCameraRoll ? ["DCIM"] : []) + Self.photoFolders

        for (index, name) in folders.enumerated() {
            if isCancelled { throw BackupError.cancelled }
            onEvent(.folder(name, index, folders.count))
            let process = Process()
            process.executableURL = tool
            // "--" stops afcclient treating "-rf" as its own option; -r recurses, -f overwrites older copies.
            process.arguments = ["-u", device.id, "--", "get", "-rf", "/\(name)", destination.appendingPathComponent(name).path]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            lock.withLock { self.process = process }
            try process.run()

            var pending = ""
            let reader = pipe.fileHandleForReading
            while case let data = reader.availableData, !data.isEmpty {
                pending += String(decoding: data, as: UTF8.self)
                // Large files report "  45% (31.8 MB/s)" repeatedly on one line.
                if let range = pending.range(of: #"\d{1,3}% \([^)]*\)"#, options: [.regularExpression, .backwards]) {
                    onEvent(.transfer(String(pending[range])))
                }
                while let end = pending.firstIndex(where: \.isNewline) {
                    let line = pending[..<end].trimmingCharacters(in: .whitespaces)
                    pending.removeSubrange(...end)
                    // Folders that don't exist on this iPhone are reported and skipped.
                    if line.localizedCaseInsensitiveContains("error") { onEvent(.log("/\(name): \(line)")) }
                }
                if pending.count > 4096 { pending = String(pending.suffix(256)) }
            }
            process.waitUntilExit()
        }
        if isCancelled { throw BackupError.cancelled }

        let marker: [String: Any] = [
            "DeviceName": device.name, "ProductType": device.model ?? "", "ProductVersion": device.iosVersion ?? "",
            "UDID": device.id, "Date": Date(), "IncludesCameraRoll": includeCameraRoll,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: marker, format: .xml, options: 0)
        try data.write(to: destination.appendingPathComponent(BackupLocator.photoCopyMarker))
        return destination
    }

    public func cancel() {
        let running = lock.withLock { () -> Process? in
            cancelled = true
            return process
        }
        if let running, running.isRunning { running.interrupt() }
    }

    private var isCancelled: Bool { lock.withLock { cancelled } }
}

/// One run of `idevicebackup2 backup`. Incremental when a previous backup of the same iPhone exists.
public final class DeviceBackupJob: @unchecked Sendable {
    public enum Event: Sendable {
        /// Overall progress (0…1) and, when known, the amount copied, such as "1.2 GB/14.8 GB".
        case progress(Double, String?)
        case log(String)
    }

    private let process = Process()
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    /// Blocks until the backup finishes. The backup lands in `folder/<UDID>`, which is returned.
    public func run(udid: String, into folder: URL, onEvent: (Event) -> Void) throws -> URL {
        guard let tool = DeviceTools.toolURL("idevicebackup2") else { throw DeviceError.toolsMissing }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        process.executableURL = tool
        process.arguments = ["-u", udid, "backup", folder.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()

        var pending = ""
        var recent: [String] = []
        let reader = pipe.fileHandleForReading
        while case let data = reader.availableData, !data.isEmpty {
            pending += String(decoding: data, as: UTF8.self)
            // Progress bars redraw with "\r", so split on any line break.
            while let end = pending.firstIndex(where: \.isNewline) {
                let line = pending[..<end].trimmingCharacters(in: .whitespaces)
                pending.removeSubrange(...end)
                guard !line.isEmpty else { continue }
                // "[=====     ]  12% (1.2 GB/9.8 GB)" while files arrive; "... 12% Finished" between steps.
                if line.hasPrefix("[") && line.contains("%") {
                    if let percent = Self.percent(in: line) { onEvent(.progress(percent, Self.amount(in: line))) }
                } else {
                    recent = Array((recent + [line]).suffix(6))
                    onEvent(.log(line))
                }
            }
        }
        process.waitUntilExit()

        if isCancelled { throw BackupError.cancelled }
        guard process.terminationStatus == 0 else {
            throw DeviceError.backupFailed(recent.joined(separator: "\n"))
        }
        return folder.appendingPathComponent(udid, isDirectory: true)
    }

    public func cancel() {
        lock.withLock { cancelled = true }
        if process.isRunning { process.interrupt() }
    }

    private var isCancelled: Bool { lock.withLock { cancelled } }

    static func percent(in line: String) -> Double? {
        guard let range = line.range(of: #"\d{1,3}(\.\d+)?%"#, options: .regularExpression),
              let value = Double(line[range].dropLast()) else { return nil }
        return min(max(value / 100, 0), 1)
    }

    static func amount(in line: String) -> String? {
        guard let range = line.range(of: #"\(([^()]*/[^()]*)\)"#, options: .regularExpression) else { return nil }
        return String(line[range].dropFirst().dropLast())
    }
}
