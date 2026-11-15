import Foundation

// MARK: - FileSystemModuleStatus (Is the OrbitFS FSKit module switched on?)

/// macOS switches a FSKit module off every time its app is replaced, so after each
/// update the user has to turn OrbitFS back on in System Settings before it can mount.
public enum FileSystemModuleStatus {
    /// Login Items & Extensions pane, where XDrive's "FSKit Modules" switch lives.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!

    /// FSClient.installedExtensions does not list third-party modules, so ask mount(8)
    /// directly: a disabled module fails with "Module <id> is disabled!". A probe that
    /// happens to mount is unmounted straight away.
    public static func isDisabled() async -> Bool {
        let probeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("xdrive-fskit-probe-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: probeDir, withIntermediateDirectories: true)
        } catch {
            NSLog("XDrive: cannot create FSKit probe directory: \(error.localizedDescription)")
            return false
        }
        defer { try? FileManager.default.removeItem(at: probeDir) }

        let (status, output) = await run("/sbin/mount", ["-F", "-t", MountHelper.fileSystemType, MountHelper.resource, probeDir.path])
        if status == 0 {
            _ = await run("/sbin/umount", [probeDir.path])
            return false
        }
        return output.contains("is disabled")
    }

    private static func run(_ tool: String, _ arguments: [String]) async -> (Int32, String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { finished in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: (finished.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: (-1, error.localizedDescription))
            }
        }
    }
}
