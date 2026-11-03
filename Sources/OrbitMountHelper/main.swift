import Foundation
import OrbitCore

// MARK: - OrbitMountHelper (Privileged LaunchDaemon XPC Service)

final class Helper: NSObject, NSXPCListenerDelegate, MountHelperProtocol {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: MountHelperProtocol.self)
        newConnection.exportedObject = self
        newConnection.resume()
        return true
    }

    func version(reply: @escaping @Sendable (Int) -> Void) {
        reply(MountHelper.version)
    }

    func mount(uid: UInt32, gid: UInt32, reply: @escaping @Sendable (String?) -> Void) {
        if MountHelper.isMounted {
            reply(nil)
            return
        }

        let mountPath = MountHelper.mountPoint
        do {
            try FileManager.default.createDirectory(atPath: mountPath, withIntermediateDirectories: true)
            chown(mountPath, uid, gid)
        } catch {
            reply("Không thể tạo thư mục mount \(mountPath): \(error.localizedDescription)")
            return
        }

        let options = "u=\(uid),g=\(gid)"
        var lastError = "Không thể gắn kết ổ đĩa OrbitFS."

        for resource in MountHelper.resources(startingWith: MountHelper.resource) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/sbin/mount")
            proc.arguments = ["-t", MountHelper.fileSystemType, "-o", options, resource, mountPath]
            let errPipe = Pipe()
            proc.standardError = errPipe

            do {
                try proc.run()
                proc.waitUntilExit()
                if proc.terminationStatus == 0 {
                    reply(nil)
                    return
                }
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let errText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "exit \(proc.terminationStatus)"
                lastError = errText
                if !MountHelper.shouldTryNextAddress(after: errText) {
                    break
                }
            } catch {
                lastError = error.localizedDescription
            }
        }

        reply(lastError)
    }

    func unmount(reply: @escaping @Sendable (String?) -> Void) {
        guard MountHelper.isMounted else {
            reply(nil)
            return
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        proc.arguments = ["unmountForce", MountHelper.mountPoint]
        let errPipe = Pipe()
        proc.standardError = errPipe

        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus == 0 {
                try? FileManager.default.removeItem(atPath: MountHelper.mountPoint)
                reply(nil)
            } else {
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                reply(String(data: errData, encoding: .utf8))
            }
        } catch {
            reply(error.localizedDescription)
        }
    }
}

let delegate = Helper()
let listener = NSXPCListener(machServiceName: MountHelper.machService)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()

