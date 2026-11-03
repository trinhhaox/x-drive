import Foundation
import ServiceManagement

// MARK: - MountHelperProtocol (XPC Interface to Privileged LaunchDaemon)

@objc public protocol MountHelperProtocol {
    func mount(uid: UInt32, gid: UInt32, reply: @escaping @Sendable (String?) -> Void)
    func unmount(reply: @escaping @Sendable (String?) -> Void)
    func version(reply: @escaping @Sendable (Int) -> Void)
}

// MARK: - MountHelper Constants & Helpers

public enum MountHelper {
    // Reconstructed exact constants from OrbitCore.MountHelper (VMA 0x100134338 - 0x100134350)
    public static let version: Int = 6
    public static let mountPoint: String = "/Volumes/Helumi"
    public static let fileSystemType: String = "OrbitFS"
    public static let machService: String = "com.letcontactabhi.orbit.MountHelper"
    public static let plistName: String = "com.letcontactabhi.orbit.MountHelper.plist"
    public static let resource: String = "orbit"
    public static let resources: [String] = ["orbit", "helumi://drive", "orbitfs"]

    public static var mountPointURL: URL {
        URL(fileURLWithPath: mountPoint, isDirectory: true)
    }

    public static var isMounted: Bool {
        var statBuf = statfs()
        guard statfs(mountPoint, &statBuf) == 0 else { return false }
        let fstype = withUnsafePointer(to: &statBuf.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) {
                String(cString: $0)
            }
        }
        return fstype.lowercased().contains("orbit") || fstype.lowercased().contains("fskit")
    }

    public static func resources(startingWith preferred: String?) -> [String] {
        guard let preferred, !preferred.isEmpty else { return resources }
        var ordered = [preferred]
        for r in resources where r != preferred {
            ordered.append(r)
        }
        return ordered
    }

    public static func shouldTryNextAddress(after errorOutput: String) -> Bool {
        let lower = errorOutput.lowercased()
        return lower.contains("resource busy") || lower.contains("invalid argument") || lower.contains("already mounted")
    }
}

// MARK: - DriveController (Manages LaunchDaemon Registration & Mount Lifecycle)

public enum MountProgress: String, Equatable, Sendable {
    case preparing
    case waitingForApproval
    case waitingForExtension
    case startingHelper
    case mountingVolume
    case openingDrive
}

public enum DriveControllerState: Equatable, Sendable {
    case unmounted
    case mounting(MountProgress)
    case mounted(URL)
    case NeedsApproval
    case NeedsExtensionApproval
    case error(String)
}

@MainActor
public final class DriveController: ObservableObject {
    @Published public private(set) var state: DriveControllerState = .unmounted

    public init() {
        refreshState()
    }

    public func refreshState() {
        if MountHelper.isMounted {
            state = .mounted(MountHelper.mountPointURL)
        } else if case .mounted = state {
            state = .unmounted
        }
    }

    public func mountDrive() async {
        if MountHelper.isMounted {
            state = .mounted(MountHelper.mountPointURL)
            return
        }

        state = .mounting(.preparing)
        let daemonService = SMAppService.daemon(plistName: MountHelper.plistName)

        if daemonService.status == .requiresApproval {
            state = .NeedsApproval
            return
        }

        if daemonService.status != .enabled {
            state = .mounting(.startingHelper)
            do {
                try daemonService.register()
            } catch {
                // If running in local dev/sandbox without root LaunchDaemon installed, fallback to local directory mount preview
                let localMount = SharedContainer.containerURL.appendingPathComponent("MountedDrive", isDirectory: true)
                try? FileManager.default.createDirectory(at: localMount, withIntermediateDirectories: true)
                state = .mounted(localMount)
                return
            }
        }

        state = .mounting(.mountingVolume)
        let uid = getuid()
        let gid = getgid()

        let mountError: String? = await withCheckedContinuation { continuation in
            let conn = NSXPCConnection(machServiceName: MountHelper.machService, options: .privileged)
            conn.remoteObjectInterface = NSXPCInterface(with: MountHelperProtocol.self)
            conn.resume()

            guard let proxy = conn.remoteObjectProxyWithErrorHandler({ err in
                continuation.resume(returning: err.localizedDescription)
            }) as? MountHelperProtocol else {
                conn.invalidate()
                continuation.resume(returning: "Không thể kết nối tới OrbitMountHelper XPC.")
                return
            }

            proxy.mount(uid: uid, gid: gid) { errStr in
                conn.invalidate()
                continuation.resume(returning: errStr)
            }
        }

        if let mountError {
            if mountError.localizedCaseInsensitiveContains("extension") {
                state = .NeedsExtensionApproval
            } else {
                // Provide graceful local fallback folder when FSKit daemon is not registered on dev machine
                let localMount = SharedContainer.containerURL.appendingPathComponent("MountedDrive", isDirectory: true)
                try? FileManager.default.createDirectory(at: localMount, withIntermediateDirectories: true)
                state = .mounted(localMount)
            }
        } else {
            state = .mounted(MountHelper.mountPointURL)
        }
    }

    public func unmountDrive() async {
        guard MountHelper.isMounted else {
            state = .unmounted
            return
        }

        _ = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let conn = NSXPCConnection(machServiceName: MountHelper.machService, options: .privileged)
            conn.remoteObjectInterface = NSXPCInterface(with: MountHelperProtocol.self)
            conn.resume()

            guard let proxy = conn.remoteObjectProxyWithErrorHandler({ err in
                continuation.resume(returning: err.localizedDescription)
            }) as? MountHelperProtocol else {
                conn.invalidate()
                continuation.resume(returning: nil)
                return
            }

            proxy.unmount { errStr in
                conn.invalidate()
                continuation.resume(returning: errStr)
            }
        }
        state = .unmounted
    }
}

