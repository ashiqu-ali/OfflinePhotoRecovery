import SwiftUI

@main
struct OfflinePhotoFinderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Offline Photo Finder") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 660)
        }
        .windowResizability(.contentMinSize)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            OfflineBanner()
            Divider()
            Group {
                switch model.screen {
                case .home: HomeView()
                case .device: DeviceView()
                case .chooseBackup: ChooseBackupView()
                case .unlocking:
                    BusyView(title: "Unlocking the backup…",
                             detail: "Checking the password. Apple makes this deliberately slow so backup passwords are hard to guess.")
                case .scanning: ScanningView()
                case .results: ResultsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .alert("Something went wrong",
               isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .task { model.handleLaunchArguments() }
    }
}
