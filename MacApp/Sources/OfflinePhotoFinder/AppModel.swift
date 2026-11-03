import AppKit
import PhotoFinderCore
import SwiftUI

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.withLock { value } }
    func cancel() { lock.withLock { value = true } }
}

enum KindFilter: String, CaseIterable, Identifiable {
    case all = "All", photos = "Photos", videos = "Videos"
    var id: String { rawValue }
    func matches(_ kind: MediaKind) -> Bool {
        switch self {
        case .all: return true
        case .photos: return kind == .photo
        case .videos: return kind == .video
        }
    }
}

enum MinimumSize: Int64, CaseIterable, Identifiable {
    case any = 0, kb10 = 10_240, kb50 = 51_200, kb200 = 204_800
    var id: Int64 { rawValue }
    var label: String {
        self == .any ? "Any size" : "At least " + ByteCountFormatter.string(fromByteCount: rawValue, countStyle: .file)
    }
}

enum DeviceStage: Equatable {
    case searching
    case working(String)
    case needsTrust(String)
    case ready(ConnectedDevice)
    case backingUp(ConnectedDevice, Double, String?)
    /// Folder being copied, overall fraction, and the current file's transfer status.
    case copyingPhotos(ConnectedDevice, String, Double, String?)
    case failed(String)
}

struct ExportProgress {
    var done = 0
    var total = 0
    var result: ExportSummary?
}

extension Error {
    var isCancellation: Bool {
        if let error = self as? BackupError, case .cancelled = error { return true }
        return false
    }
}

@MainActor
final class AppModel: ObservableObject {
    enum Screen { case home, device, chooseBackup, unlocking, scanning, results }
    static let allSources = "__all__"
    static let notInLibrary = "__not_in_library__"
    static let inRecentlyDeleted = "__recently_deleted__"

    @Published var screen: Screen = .home
    @Published var errorMessage: String?
    @Published var savedBackups: [BackupSummary] = []

    @Published var backups: [BackupSummary] = []
    @Published var chosenID: BackupSummary.ID?
    @Published var password = ""

    @Published var deviceStage: DeviceStage = .searching
    @Published var backupLog: [String] = []
    @Published var backupStartedAt = Date()
    @Published var includeCameraRoll = false
    /// Bytes written so far by the running copy or backup, measured on disk every few seconds.
    @Published var copiedBytes: Int64 = 0
    @Published var storageFolder: URL = DeviceTools.backupStorageFolder

    @Published var stats = ScanStats()
    @Published var items: [MediaItem] = []
    @Published var sourceFilter: String? = AppModel.allSources
    @Published var kindFilter: KindFilter = .all
    @Published var minimumSize: MinimumSize = .kb10
    @Published var selection: Set<MediaItem.ID> = []
    @Published var export: ExportProgress?

    private(set) var reader: BackupReader?
    private var scanFlag = CancelFlag()
    private var exportFlag = CancelFlag()
    private var backupJob: DeviceBackupJob?
    private var copyJob: PhotoFolderCopyJob?
    private var searchTask: Task<Void, Never>?
    private var pendingUDID: String?
    private var handledLaunchArguments = false
    private var sizeWatch: Task<Void, Never>?
    private static let storageBookmarkKey = "storageFolderBookmark"

    init() {
        restoreStorageFolder()
    }

    var chosen: BackupSummary? { backups.first { $0.id == chosenID } }

    // MARK: Home

    func refreshSavedBackups() {
        var found: [BackupSummary] = []
        for folder in Set([DeviceTools.backupStorageFolder, storageFolder]) {
            found += (try? BackupLocator.findBackups(in: folder)) ?? []
        }
        savedBackups = found.sorted { ($0.lastBackup ?? .distantPast) > ($1.lastBackup ?? .distantPast) }
    }

    // MARK: Where backups are saved

    var isUsingDefaultStorage: Bool { storageFolder == DeviceTools.backupStorageFolder }

    var freeSpace: Int64? {
        if isUsingDefaultStorage {
            try? FileManager.default.createDirectory(at: storageFolder, withIntermediateDirectories: true)
        }
        return (try? storageFolder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    /// Reopens the folder chosen in an earlier session. macOS only allows this through the bookmark
    /// saved when the folder was chosen.
    private func restoreStorageFolder() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageBookmarkKey) else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil,
                                 bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else { return }
        storageFolder = url
        if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: Self.storageBookmarkKey)
        }
    }

    func chooseStorageFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.message = "Choose where backups and photo copies are saved, for example an external drive."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: Self.storageBookmarkKey)
        } else {
            errorMessage = "This location will be used until the app quits, but macOS won't let the app remember it for next time."
        }
        if !isUsingDefaultStorage { storageFolder.stopAccessingSecurityScopedResource() }
        _ = url.startAccessingSecurityScopedResource()
        storageFolder = url
        refreshSavedBackups()
    }

    func useDefaultStorage() {
        if !isUsingDefaultStorage { storageFolder.stopAccessingSecurityScopedResource() }
        UserDefaults.standard.removeObject(forKey: Self.storageBookmarkKey)
        storageFolder = DeviceTools.backupStorageFolder
        refreshSavedBackups()
    }

    /// Measures what a copy or backup has written so far. `fromNow` ignores what was already there
    /// (a full backup of the same iPhone is updated in place).
    private func watchSize(of folder: URL, fromNow: Bool) {
        sizeWatch?.cancel()
        copiedBytes = 0
        sizeWatch = Task {
            let baseline = fromNow ? await Task.detached { Self.folderSize(folder) }.value : 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                let size = await Task.detached { Self.folderSize(folder) }.value
                if !Task.isCancelled { copiedBytes = max(0, size - baseline) }
            }
        }
    }

    nonisolated static func folderSize(_ folder: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    func openBackupFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Open"
        panel.message = "Choose an iPhone backup folder (for example, a copy of Finder's Backup folder)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        showBackups(in: url)
    }

    func showBackups(in folder: URL) {
        do {
            let found = try BackupLocator.findBackups(in: folder)
            guard !found.isEmpty else {
                errorMessage = "There's no iPhone backup in “\(folder.lastPathComponent)”. Choose the folder that contains Manifest.plist, or the folder that holds one folder per device."
                return
            }
            choose(found)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func choose(_ list: [BackupSummary]) {
        backups = list
        chosenID = list.first?.id
        password = ""
        screen = .chooseBackup
    }

    func deleteSavedBackup(_ backup: BackupSummary) {
        do {
            try FileManager.default.removeItem(at: backup.url)
        } catch {
            errorMessage = error.localizedDescription
        }
        refreshSavedBackups()
    }

    func startOver() {
        scanFlag.cancel()
        reader = nil
        items = []
        selection = []
        ThumbnailLoader.shared.clear()
        refreshSavedBackups()
        screen = .home
    }

    /// `--open-backup <folder>` opens a backup at launch and, if it needs no password, searches it
    /// straight away (handy for trying the app on a sample backup).
    func handleLaunchArguments() {
        guard !handledLaunchArguments else { return }
        handledLaunchArguments = true
        refreshSavedBackups()
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--open-backup"), arguments.indices.contains(index + 1) {
            showBackups(in: URL(fileURLWithPath: arguments[index + 1]))
            if backups.count == 1, chosen?.isEncrypted == false { startScan() }
        }
        #if DEBUG
        if arguments.contains("--connect-iphone") { startDeviceFlow() }
        WindowSnapshot.scheduleIfRequested()
        #endif
    }

    // MARK: iPhone over USB

    func startDeviceFlow() {
        guard DeviceTools.isAvailable else {
            errorMessage = DeviceError.toolsMissing.localizedDescription
            return
        }
        screen = .device
        backupLog = []
        searchForDevice()
    }

    func leaveDeviceFlow() {
        searchTask?.cancel()
        backupJob?.cancel()
        copyJob?.cancel()
        screen = .home
        refreshSavedBackups()
    }

    /// Polls for a cable-connected iPhone every two seconds.
    func searchForDevice() {
        deviceStage = .searching
        searchTask?.cancel()
        searchTask = Task {
            while !Task.isCancelled {
                let result = await Task.detached { Result { try DeviceTools.connectedDeviceIDs() } }.value
                guard screen == .device, deviceStage == .searching else { return }
                switch result {
                case .failure(let error):
                    deviceStage = .failed(error.localizedDescription)
                    return
                case .success(let ids):
                    if let udid = ids.first {
                        connect(udid)
                        return
                    }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func retryPairing() {
        if let pendingUDID { connect(pendingUDID) }
    }

    private func connect(_ udid: String) {
        pendingUDID = udid
        deviceStage = .working("Connecting to the iPhone…")
        Task {
            let pairing = await Task.detached { Result { try DeviceTools.pair(udid: udid) } }.value
            guard screen == .device else { return }
            switch pairing {
            case .failure(let error):
                deviceStage = .failed(error.localizedDescription)
            case .success(.needsTrust(let message)):
                deviceStage = .needsTrust(message)
            case .success(.failed(let message)):
                deviceStage = .failed(message)
            case .success(.paired):
                deviceStage = .working("Reading the iPhone's details…")
                let device = await Task.detached { DeviceTools.details(udid: udid) }.value
                if screen == .device { deviceStage = .ready(device) }
            }
        }
    }

    func startBackup(_ device: ConnectedDevice) {
        let job = DeviceBackupJob()
        backupJob = job
        backupLog = []
        backupStartedAt = Date()
        deviceStage = .backingUp(device, 0, nil)
        let folder = storageFolder
        watchSize(of: folder.appendingPathComponent(device.id, isDirectory: true), fromNow: true)
        Task {
            let result = await Task.detached {
                Result {
                    try job.run(udid: device.id, into: folder) { event in
                        Task { @MainActor in self.handle(event, from: device) }
                    }
                }
            }.value
            sizeWatch?.cancel()
            backupJob = nil
            refreshSavedBackups()
            switch result {
            case .success(let url):
                guard let summary = BackupLocator.summary(for: url) else {
                    deviceStage = .failed("The backup finished but its files couldn't be read.")
                    return
                }
                choose([summary])
                if !summary.isEncrypted { startScan() }
            case .failure(let error) where error.isCancellation:
                deviceStage = .ready(device)
            case .failure(let error):
                deviceStage = .failed(error.localizedDescription)
            }
        }
    }

    func cancelBackup() {
        backupJob?.cancel()
        copyJob?.cancel()
    }

    /// The fast path: copy the Photos app's folders over USB, then search them straight away.
    func startPhotoCopy(_ device: ConnectedDevice) {
        let job = PhotoFolderCopyJob()
        copyJob = job
        backupLog = []
        backupStartedAt = Date()
        deviceStage = .copyingPhotos(device, "", 0, nil)
        let folder = storageFolder
        let includeCameraRoll = includeCameraRoll
        watchSize(of: folder.appendingPathComponent("\(device.id)-photos", isDirectory: true), fromNow: false)
        Task {
            let result = await Task.detached {
                Result {
                    try job.run(device: device, includeCameraRoll: includeCameraRoll, into: folder) { event in
                        Task { @MainActor in self.handle(event, from: device) }
                    }
                }
            }.value
            sizeWatch?.cancel()
            copyJob = nil
            refreshSavedBackups()
            switch result {
            case .success(let url):
                guard let summary = BackupLocator.summary(for: url) else {
                    deviceStage = .failed("The copy finished but couldn't be read.")
                    return
                }
                choose([summary])
                startScan()
            case .failure(let error) where error.isCancellation:
                deviceStage = .ready(device)
            case .failure(let error):
                deviceStage = .failed(error.localizedDescription)
            }
        }
    }

    private func handle(_ event: PhotoFolderCopyJob.Event, from device: ConnectedDevice) {
        guard case .copyingPhotos(_, let folder, let fraction, let transfer) = deviceStage else { return }
        switch event {
        case .folder(let name, let index, let count):
            deviceStage = .copyingPhotos(device, name, Double(index) / Double(count), nil)
        case .transfer(let status):
            deviceStage = .copyingPhotos(device, folder, fraction, status)
        case .log(let line):
            backupLog = Array((backupLog + [line]).suffix(200))
            deviceStage = .copyingPhotos(device, folder, fraction, transfer)
        }
    }

    private func handle(_ event: DeviceBackupJob.Event, from device: ConnectedDevice) {
        switch event {
        case .progress(let value, let amount):
            if case .backingUp(_, _, let previous) = deviceStage {
                deviceStage = .backingUp(device, value, amount ?? previous)
            }
        case .log(let line):
            backupLog = Array((backupLog + [line]).suffix(200))
        }
    }

    // MARK: Scanning

    func startScan() {
        guard let backup = chosen else { return }
        let password = backup.isEncrypted ? self.password : nil
        let flag = CancelFlag()
        scanFlag = flag
        stats = ScanStats()
        screen = backup.isEncrypted ? .unlocking : .scanning
        Task {
            let result = await Task.detached { () -> Result<(BackupReader, [MediaItem]), Error> in
                Result {
                    let reader = try BackupReader(summary: backup, password: password)
                    Task { @MainActor in if self.screen == .unlocking { self.screen = .scanning } }
                    let items = try Scanner.scan(reader,
                                                 progress: { stats in Task { @MainActor in self.update(stats) } },
                                                 isCancelled: { flag.isCancelled })
                    return (reader, items)
                }
            }.value
            switch result {
            case .success(let (reader, items)):
                self.reader = reader
                self.items = items
                selection = []
                // Lead with the leftovers of deleted photos when the copy lets us identify them.
                sourceFilter = items.contains { $0.libraryStatus == .notInLibrary } ? Self.notInLibrary : Self.allSources
                self.password = ""
                screen = .results
            case .failure(let error):
                screen = .chooseBackup
                if !error.isCancellation { errorMessage = error.localizedDescription }
            }
        }
    }

    func cancelScan() { scanFlag.cancel() }

    private func update(_ newStats: ScanStats) {
        if newStats.checked >= stats.checked { stats = newStats }
    }

    // MARK: Results

    var visibleItems: [MediaItem] {
        items.filter { item in
            let sourceMatches: Bool
            switch sourceFilter {
            case nil, Self.allSources?: sourceMatches = true
            case Self.notInLibrary?: sourceMatches = item.libraryStatus == .notInLibrary
            case Self.inRecentlyDeleted?: sourceMatches = item.libraryStatus == .recentlyDeleted
            case let source?: sourceMatches = item.source == source
            }
            return sourceMatches && kindFilter.matches(item.kind) && item.entry.size >= minimumSize.rawValue
        }
    }

    /// How many shown items the Photos library no longer has, and how many are in Recently Deleted.
    var libraryCounts: (notInLibrary: Int, recentlyDeleted: Int) {
        var counts = (notInLibrary: 0, recentlyDeleted: 0)
        for item in items where kindFilter.matches(item.kind) && item.entry.size >= minimumSize.rawValue {
            if item.libraryStatus == .notInLibrary { counts.notInLibrary += 1 }
            if item.libraryStatus == .recentlyDeleted { counts.recentlyDeleted += 1 }
        }
        return counts
    }

    var sourceCounts: [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for item in items where kindFilter.matches(item.kind) && item.entry.size >= minimumSize.rawValue {
            counts[item.source, default: 0] += 1
        }
        return counts.map { (name: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }

    func toggle(_ item: MediaItem) {
        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
    }

    // MARK: Export

    func exportItems(_ list: [MediaItem]) {
        guard let reader, !list.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose where to save \(list.count) recovered files. A new folder will be created inside it."
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let flag = CancelFlag()
        exportFlag = flag
        export = ExportProgress(done: 0, total: list.count)
        Task {
            let result = await Task.detached {
                Result {
                    try Exporter.export(list, from: reader, into: destination,
                                        progress: { done, _ in Task { @MainActor in self.export?.done = done } },
                                        isCancelled: { flag.isCancelled })
                }
            }.value
            switch result {
            case .success(let summary):
                export?.result = summary
            case .failure(let error):
                export = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancelExport() { exportFlag.cancel() }
}
