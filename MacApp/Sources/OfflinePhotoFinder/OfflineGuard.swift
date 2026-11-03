import Darwin
import Security
import SwiftUI

/// Proves at launch that macOS is blocking this app from the network.
struct OfflineGuard {
    let sandboxed: Bool
    let hasNetworkEntitlement: Bool
    let tcpBlocked: Bool

    var internetBlocked: Bool { sandboxed && !hasNetworkEntitlement && tcpBlocked }

    static let current = OfflineGuard(
        sandboxed: entitlement("com.apple.security.app-sandbox"),
        hasNetworkEntitlement: entitlement("com.apple.security.network.client") || entitlement("com.apple.security.network.server"),
        tcpBlocked: loopbackConnectionIsBlocked())

    private static func entitlement(_ name: String) -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, name as CFString, nil) else { return false }
        return (value as? Bool) ?? false
    }

    /// Tries a TCP connection to this Mac's own loopback address, so nothing can leave the computer.
    /// Inside the sandbox macOS refuses with "operation not permitted" before any connection is made.
    private static func loopbackConnectionIsBlocked() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return errno == EPERM || errno == EACCES }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(9).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result != 0 && (errno == EPERM || errno == EACCES)
    }
}

struct OfflineBanner: View {
    private let status = OfflineGuard.current

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: status.internetBlocked ? "lock.shield.fill" : "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(status.internetBlocked ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.internetBlocked ? "Offline: macOS blocks this app from the internet"
                                            : "Not protected: this copy can reach the network")
                    .font(.headline)
                Text(status.internetBlocked
                     ? "Verified at launch. The only connection allowed is the USB cable link to your iPhone through macOS's own device service."
                     : "Build the app with build.sh so macOS enforces the block.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
