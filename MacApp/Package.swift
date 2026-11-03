// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OfflinePhotoFinder",
    platforms: [.macOS(.v14)],
    targets: [
        // Reads and decrypts iPhone backups. No UI, no networking, no third-party code.
        .target(name: "PhotoFinderCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        // The sandboxed Mac app.
        .executableTarget(name: "OfflinePhotoFinder", dependencies: ["PhotoFinderCore"]),
        // Developer checks: crypto test vectors and scanning a test backup from the command line.
        .executableTarget(name: "photofinder-selftest", dependencies: ["PhotoFinderCore"]),
    ]
)
