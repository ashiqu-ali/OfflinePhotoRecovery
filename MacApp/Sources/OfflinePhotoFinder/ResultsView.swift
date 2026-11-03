import PhotoFinderCore
import SwiftUI

struct ResultsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var previewItem: MediaItem?

    var body: some View {
        let shown = model.visibleItems
        let counts = model.sourceCounts
        let library = model.libraryCounts
        NavigationSplitView {
            List(selection: $model.sourceFilter) {
                if library.notInLibrary + library.recentlyDeleted > 0 {
                    Section("Compared with your Photos library") {
                        SourceRow(name: "Not in library any more", symbol: "exclamationmark.circle", count: library.notInLibrary)
                            .tag(AppModel.notInLibrary)
                            .help("Thumbnails and edits whose photo is gone from the Photos library: leftovers of deleted photos")
                        SourceRow(name: "In Recently Deleted", symbol: "trash", count: library.recentlyDeleted)
                            .tag(AppModel.inRecentlyDeleted)
                            .help("Still recoverable on the iPhone: Photos › Recently Deleted › Recover")
                    }
                }
                Section("Found in") {
                    SourceRow(name: "Everything", symbol: "square.grid.2x2", count: counts.reduce(0) { $0 + $1.count })
                        .tag(AppModel.allSources)
                    ForEach(counts, id: \.name) { source in
                        SourceRow(name: source.name, symbol: Self.symbol(for: source.name), count: source.count)
                            .tag(source.name)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250)
            .safeAreaInset(edge: .bottom) {
                Button { model.startOver() } label: { Label("Search Another Backup", systemImage: "arrow.uturn.left") }
                    .padding(12)
            }
        } detail: {
            VStack(spacing: 0) {
                toolbar(shown: shown)
                Divider()
                if shown.isEmpty {
                    ContentUnavailableView("Nothing here", systemImage: "photo.on.rectangle",
                                           description: Text("Try another source, “All”, or a smaller minimum size."))
                } else if let reader = model.reader {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 156, maximum: 200), spacing: 12)], spacing: 14) {
                            ForEach(shown) { item in
                                ThumbnailCell(item: item, reader: reader, selected: model.selection.contains(item.id))
                                    .onTapGesture { model.toggle(item) }
                                    .contextMenu {
                                        Button("Preview") { previewItem = item }
                                        Button(model.selection.contains(item.id) ? "Deselect" : "Select") { model.toggle(item) }
                                    }
                            }
                        }
                        .padding(14)
                    }
                }
            }
        }
        .sheet(item: $previewItem) { item in
            PreviewSheet(item: item).environmentObject(model)
        }
        .sheet(isPresented: Binding(get: { model.export != nil }, set: { if !$0 { model.export = nil } })) {
            ExportSheet().environmentObject(model)
        }
    }

    private func toolbar(shown: [MediaItem]) -> some View {
        HStack(spacing: 12) {
            Picker("Show", selection: $model.kindFilter) {
                ForEach(KindFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            Picker("Size", selection: $model.minimumSize) {
                ForEach(MinimumSize.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .frame(width: 150)
            .help("Hides tiny images such as app icons and stickers")
            Spacer()
            Text("\(shown.count) shown · \(model.selection.count) selected")
                .monospacedDigit().foregroundStyle(.secondary)
            Button("Select All") { model.selection.formUnion(shown.map(\.id)) }
            Button("Clear") { model.selection.removeAll() }.disabled(model.selection.isEmpty)
            Button {
                model.exportItems(model.selection.isEmpty ? shown : model.items.filter { model.selection.contains($0.id) })
            } label: {
                Label(model.selection.isEmpty ? "Export All Shown…" : "Export \(model.selection.count) Selected…",
                      systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .disabled(shown.isEmpty && model.selection.isEmpty)
        }
        .padding(10)
    }

    static func symbol(for source: String) -> String {
        switch source {
        case SourceClassifier.cameraRoll: return "camera"
        case SourceClassifier.thumbnails: return "photo.stack"
        case SourceClassifier.messages, "Messages": return "message"
        case "WhatsApp", "WhatsApp Business", "Telegram", "Signal", "Messenger", "WeChat", "Viber", "LINE": return "bubble.left.and.bubble.right"
        case "Edited Photo Versions": return "wand.and.stars"
        case "Shared Albums", "iCloud Photos Cache": return "icloud"
        default: return "app"
        }
    }
}

struct SourceRow: View {
    let name: String
    let symbol: String
    let count: Int

    var body: some View {
        Label {
            HStack {
                Text(name).lineLimit(1)
                Spacer()
                Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: symbol)
        }
    }
}

struct ThumbnailCell: View {
    let item: MediaItem
    let reader: BackupReader
    let selected: Bool
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                Color.secondary.opacity(0.1)
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else if failed {
                    Image(systemName: item.kind == .video ? "film" : "photo").font(.largeTitle).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 156, height: 156)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .bottomLeading) {
                if item.kind == .video {
                    Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(.white).shadow(radius: 2).padding(6)
                }
            }
            .overlay(alignment: .topLeading) {
                if let status = item.libraryStatus, status != .inLibrary {
                    Text(status == .notInLibrary ? "Not in library" : "Recently Deleted")
                        .font(.caption2.bold()).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(status == .notInLibrary ? Color.orange : Color.gray))
                        .padding(6)
                }
            }
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill").font(.title2)
                        .foregroundStyle(.white, Color.accentColor).padding(6)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.accentColor : .clear, lineWidth: 3))

            Text(item.fileName).font(.caption).lineLimit(1).truncationMode(.middle)
            Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 156)
        .contentShape(Rectangle())
        .help("\(item.source)\n\(item.entry.relativePath)")
        .task(id: item.id) {
            image = await ThumbnailLoader.shared.thumbnail(for: item, reader: reader, maxPixel: 320)
            failed = image == nil
        }
    }

    private var caption: String {
        [item.entry.modified?.formatted(date: .abbreviated, time: .omitted),
         ByteCountFormatter.string(fromByteCount: item.entry.size, countStyle: .file)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

struct PreviewSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let item: MediaItem
    @State private var image: NSImage?
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack {
                Color.black.opacity(0.85)
                if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                } else if loading {
                    ProgressView()
                } else {
                    Text("No preview available. Export the file to open it.").foregroundStyle(.white)
                }
            }
            .frame(minWidth: 640, minHeight: 440)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow { Text("Found in").foregroundStyle(.secondary); Text(item.source) }
                GridRow { Text("Original path").foregroundStyle(.secondary); Text(item.entry.relativePath).textSelection(.enabled) }
                GridRow {
                    Text("Size").foregroundStyle(.secondary)
                    Text(ByteCountFormatter.string(fromByteCount: item.entry.size, countStyle: .file))
                }
                if let date = item.entry.modified {
                    GridRow { Text("Modified").foregroundStyle(.secondary); Text(date.formatted(date: .long, time: .shortened)) }
                }
            }
            .font(.callout)

            HStack {
                Spacer()
                Button(model.selection.contains(item.id) ? "Deselect" : "Select for Export") { model.toggle(item) }
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .task {
            if let reader = model.reader {
                image = await ThumbnailLoader.shared.thumbnail(for: item, reader: reader, maxPixel: 1600)
            }
            loading = false
        }
    }
}

struct ExportSheet: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            if let progress = model.export {
                if let result = progress.result {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(.green)
                    Text("Exported \(result.exported) files").font(.title2.bold())
                    Text(details(result)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    HStack {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([result.folder]) }
                        Button("Done") { model.export = nil }.keyboardShortcut(.defaultAction)
                    }
                } else {
                    Text("Exporting…").font(.title2.bold())
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))).frame(width: 360)
                    Text("\(progress.done) of \(progress.total)").monospacedDigit().foregroundStyle(.secondary)
                    Button("Stop") { model.cancelExport() }
                }
            }
        }
        .padding(28)
        .frame(minWidth: 440)
    }

    private func details(_ result: ExportSummary) -> String {
        var parts = ["Saved to “\(result.folder.lastPathComponent)”, with an index.csv listing where each file came from."]
        if result.duplicatesSkipped > 0 { parts.append("\(result.duplicatesSkipped) exact duplicates were skipped.") }
        if result.failed > 0 { parts.append("\(result.failed) files couldn't be read (see index.csv).") }
        return parts.joined(separator: " ")
    }
}
