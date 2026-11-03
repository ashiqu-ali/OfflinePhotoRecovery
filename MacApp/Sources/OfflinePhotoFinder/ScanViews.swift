import PhotoFinderCore
import SwiftUI

struct ChooseBackupView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button { model.startOver() } label: { Label("Back", systemImage: "chevron.left") }
            Text(model.backups.count > 1 ? "Choose a backup" : "Search this backup").font(.title.bold())

            List(model.backups, selection: $model.chosenID) { backup in
                BackupRow(backup: backup).padding(.vertical, 4)
            }
            .frame(height: min(CGFloat(model.backups.count) * 56 + 16, 260))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            if let backup = model.chosen, backup.isEncrypted {
                VStack(alignment: .leading, spacing: 8) {
                    Text("This backup is encrypted. Enter the backup password (set with “Encrypt local backup”).")
                        .foregroundStyle(.secondary)
                    SecureField("Backup password", text: $model.password)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 340)
                        .onSubmit { if !model.password.isEmpty { model.startScan() } }
                }
            }

            HStack {
                Spacer()
                Button { model.startScan() } label: {
                    Label("Search for Photos & Videos", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(model.chosen == nil || (model.chosen?.isEncrypted == true && model.password.isEmpty))
            }
        }
        .padding(32)
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct BusyView: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text(title).font(.title2.bold())
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
        }
    }
}

struct ScanningView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Text("Searching the backup…").font(.title2.bold())
            ProgressView(value: Double(model.stats.checked), total: Double(max(model.stats.total, 1)))
                .frame(width: 440)
            Text("Checked \(model.stats.checked.formatted()) of \(model.stats.total.formatted()) files")
                .monospacedDigit().foregroundStyle(.secondary)
            Text("Found \(model.stats.found.formatted()) photos and videos so far")
                .font(.headline).monospacedDigit()
            Button("Cancel") { model.cancelScan() }
        }
    }
}
