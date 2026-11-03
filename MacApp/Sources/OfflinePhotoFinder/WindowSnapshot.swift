#if DEBUG
import AppKit

/// Debug builds only: `--snapshot <png path> <seconds>` saves a picture of the app's own window
/// after a delay and quits. Used to check the screens without screen-recording permission.
enum WindowSnapshot {
    static func scheduleIfRequested() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--snapshot"), arguments.indices.contains(index + 2),
              let delay = Double(arguments[index + 2]) else { return }
        let destination = URL(fileURLWithPath: arguments[index + 1])
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let view = NSApp.windows.first(where: \.isVisible)?.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(2) }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: destination)
            exit(0)
        }
    }
}
#endif
