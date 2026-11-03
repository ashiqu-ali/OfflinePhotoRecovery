import PhotoFinderCore
import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var pendingDelete: BackupSummary?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Find photos and videos inside an iPhone backup")
                        .font(.largeTitle.bold())
                    Text("Searches the Camera Roll, low-res thumbnails, Messages, WhatsApp, Telegram and other apps. Everything stays on this Mac.")
                        .foregroundStyle(.secondary)
                }

                HStack(alignment: .top, spacing: 16) {
                    ActionCard(symbol: "cable.connector",
                               title: "Back up iPhone over USB",
                               detail: "Connect the iPhone with a cable. The app makes a fresh backup and searches it. Wi-Fi can stay off and the iPhone can stay in Airplane Mode.",
                               button: "Connect iPhone") { model.startDeviceFlow() }
                    ActionCard(symbol: "folder",
                               title: "Open an existing backup",
                               detail: "Use a backup made earlier by Finder or iTunes, for example one copied from an old Mac or an external drive.",
                               button: "Choose Folder…") { model.openBackupFolder() }
                }

                StorageLocationRow()

                if !model.savedBackups.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Backups made by this app").font(.title3.bold())
                        ForEach(model.savedBackups) { backup in
                            HStack(spacing: 10) {
                                BackupRow(backup: backup)
                                Spacer()
                                Button("Search") { model.choose([backup]) }
                                    .buttonStyle(.borderedProminent)
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([backup.url]) }
                                Button(role: .destructive) { pendingDelete = backup } label: { Image(systemName: "trash") }
                                    .help("Delete this backup from the Mac")
                            }
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
                        }
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 880, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .confirmationDialog("Delete this backup?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { backup in
            Button("Delete Backup", role: .destructive) { model.deleteSavedBackup(backup) }
        } message: { backup in
            Text("This removes the backup of “\(backup.deviceName)” from this Mac. Photos you already exported stay where you saved them.")
        }
    }
}

struct ActionCard: View {
    let symbol: String
    let title: String
    let detail: String
    let button: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(.tint)
            Text(title).font(.title3.bold())
            Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(button, action: action).buttonStyle(.borderedProminent).controlSize(.large)
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.08)))
    }
}

struct BackupRow: View {
    let backup: BackupSummary

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "iphone").font(.title2).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(backup.deviceName).font(.headline)
                    if backup.isEncrypted {
                        Image(systemName: "lock.fill").foregroundStyle(.secondary).help("Encrypted backup")
                    }
                }
                Text(backup.subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

extension BackupSummary {
    var subtitle: String {
        [isPhotoFolderCopy ? "Photos folders copy" : "Full backup",
         iosVersion.map { "iOS \($0)" },
         lastBackup.map { "made \($0.formatted(date: .abbreviated, time: .shortened))" },
         isEncrypted ? "encrypted" : nil]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

struct DeviceView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            content
                .padding(32)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 22) {
            Button { model.leaveDeviceFlow() } label: { Label("Back", systemImage: "chevron.left") }

            switch model.deviceStage {
            case .searching:
                StatusPanel(symbol: "cable.connector", title: "Connect your iPhone with a USB cable",
                            detail: "Unlock it and leave it on the Home Screen. Looking for it now…", busy: true)
            case .working(let message):
                StatusPanel(symbol: "iphone", title: message, detail: "Keep the iPhone unlocked.", busy: true)
            case .needsTrust(let message):
                StatusPanel(symbol: "hand.tap", title: "Tap “Trust” on your iPhone",
                            detail: "Then enter the iPhone passcode. This pairing stays between your iPhone and this Mac.\n\n\(message)")
                Button("I Tapped Trust – Continue") { model.retryPairing() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            case .ready(let device):
                DeviceReadyPanel(device: device)
            case .backingUp(let device, let progress, let amount):
                BackupProgressPanel(device: device, progress: progress, amount: amount)
            case .copyingPhotos(let device, let folder, let fraction, let transfer):
                CopyProgressPanel(device: device, folder: folder, fraction: fraction, transfer: transfer)
            case .failed(let message):
                StatusPanel(symbol: "exclamationmark.triangle", title: "That didn't work", detail: message)
                Button("Try Again") { model.searchForDevice() }.controlSize(.large)
            }
        }
    }
}

struct StatusPanel: View {
    let symbol: String
    let title: String
    let detail: String
    var busy = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(.tint).frame(width: 44)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text(title).font(.title2.bold())
                    if busy { ProgressView().controlSize(.small) }
                }
                if !detail.isEmpty {
                    Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct DeviceReadyPanel: View {
    @EnvironmentObject private var model: AppModel
    let device: ConnectedDevice

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StatusPanel(symbol: "iphone", title: device.name,
                        detail: [device.model, device.iosVersion.map { "iOS \($0)" }].compactMap { $0 }.joined(separator: " · "))

            OptionCard(title: "Fast: copy the Photos app's folders",
                       badge: "Start here",
                       detail: "Copies thumbnails, edited versions, the iCloud photo cache and shared albums straight from the iPhone over the cable (about 30 MB/s), then marks every picture whose photo is no longer in your library. No waiting for the iPhone to prepare.") {
                Toggle("Also copy the current Camera Roll (slower; those photos aren't lost)", isOn: $model.includeCameraRoll)
                Button { model.startPhotoCopy(device) } label: {
                    Label("Copy Photos Folders", systemImage: "bolt.fill")
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
            }

            OptionCard(title: "Complete: full iPhone backup",
                       badge: nil,
                       detail: "Needed for pictures inside WhatsApp, Messages, Telegram and other apps. The iPhone spends a few minutes preparing before files start to arrive. With iCloud Photos on, the Camera Roll isn't part of backups.") {
                VStack(alignment: .leading, spacing: 6) {
                    if let used = device.usedBytes, let free = model.freeSpace {
                        Label("\(bytes(used)) used on the iPhone · \(bytes(free)) free where backups are saved",
                              systemImage: "internaldrive")
                        if used > free {
                            Label("Possibly not enough space. Choose an external drive below with “Change…”.",
                                  systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                    switch device.backupWillEncrypt {
                    case true?:
                        Label("This iPhone encrypts its backups; you'll need that backup password.", systemImage: "lock.fill")
                    case false?:
                        Label("Not encrypted. It stays in this app's private folder; delete it when you're done.", systemImage: "lock.open")
                    case nil:
                        EmptyView()
                    }
                }
                .font(.callout).foregroundStyle(.secondary)
                Button { model.startBackup(device) } label: {
                    Label("Back Up Everything", systemImage: "arrow.down.doc")
                }
                .controlSize(.large)
            }

            StorageLocationRow()
        }
    }

    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
}

struct OptionCard<Content: View>: View {
    let title: String
    let badge: String?
    let detail: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title).font(.title3.bold())
                if let badge {
                    Text(badge).font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                }
            }
            Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
    }
}

struct CopyProgressPanel: View {
    @EnvironmentObject private var model: AppModel
    let device: ConnectedDevice
    let folder: String
    let fraction: Double
    let transfer: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StatusPanel(symbol: "bolt.fill", title: "Copying photo folders from \(device.name)…",
                        detail: "Keep the cable connected. The search starts automatically when copying finishes.")
            // The total size isn't known in advance, so show steady activity plus what has arrived.
            ProgressView().progressViewStyle(.linear)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = Duration.seconds(context.date.timeIntervalSince(model.backupStartedAt))
                    .formatted(.time(pattern: .minuteSecond))
                let step = folder.isEmpty ? nil : "Folder \(Int((fraction * Double(folderCount)).rounded()) + 1) of \(folderCount): /\(folder)"
                Text([step,
                      "\(ByteCountFormatter.string(fromByteCount: model.copiedBytes, countStyle: .file)) copied",
                      speed, elapsed].compactMap { $0 }.joined(separator: " · "))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            StorageLocationRow(allowsChange: false)
            if !model.backupLog.isEmpty {
                Text(model.backupLog.suffix(3).joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            Button("Cancel", role: .cancel) { model.cancelBackup() }
        }
    }

    private var folderCount: Int { PhotoFolderCopyJob.photoFolders.count + (model.includeCameraRoll ? 1 : 0) }

    /// "45% (31.8 MB/s)" is one file's progress; only the speed means something for the whole copy.
    private var speed: String? {
        guard let transfer, let range = transfer.range(of: #"[\d.]+ [KMG]?B/s"#, options: .regularExpression) else { return nil }
        return String(transfer[range])
    }
}

struct StorageLocationRow: View {
    @EnvironmentObject private var model: AppModel
    var allowsChange = true

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: model.isUsingDefaultStorage ? "internaldrive" : "externaldrive")
                .font(.title3).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Backups and photo copies are saved to").font(.caption).foregroundStyle(.secondary)
                Text(model.isUsingDefaultStorage ? "This app's private folder on this Mac" : model.storageFolder.path)
                    .lineLimit(1).truncationMode(.middle)
                if let free = model.freeSpace {
                    Text("\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free there · nothing is written to the iPhone")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.storageFolder]) }
            if allowsChange {
                Button("Change…") { model.chooseStorageFolder() }
                if !model.isUsingDefaultStorage { Button("Use Default") { model.useDefaultStorage() } }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }
}

struct BackupProgressPanel: View {
    @EnvironmentObject private var model: AppModel
    let device: ConnectedDevice
    let progress: Double
    let amount: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StatusPanel(symbol: "arrow.down.doc", title: "Backing up \(device.name)…",
                        detail: "Keep the cable connected and the iPhone unlocked. If the iPhone asks for its passcode, enter it there.")
            ProgressView(value: progress)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = Duration.seconds(context.date.timeIntervalSince(model.backupStartedAt))
                    .formatted(.time(pattern: .minuteSecond))
                let received = ByteCountFormatter.string(fromByteCount: model.copiedBytes, countStyle: .file)
                Text(progress == 0 && amount == nil && model.copiedBytes == 0
                     ? "Waiting for the iPhone to prepare the backup · \(elapsed). This can take several minutes on a full phone."
                     : "\(Int(progress * 100))% · \(amount ?? "\(received) received") · \(elapsed)")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            StorageLocationRow(allowsChange: false)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.backupLog.enumerated()), id: \.offset) { index, line in
                            Text(line).font(.system(.caption, design: .monospaced)).id(index)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .frame(height: 160)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
                .onChange(of: model.backupLog.count) { _, count in proxy.scrollTo(count - 1, anchor: .bottom) }
            }
            Button("Cancel Backup", role: .cancel) { model.cancelBackup() }
        }
    }
}
