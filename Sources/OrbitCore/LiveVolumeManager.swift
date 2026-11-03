import AppKit
import Foundation
import CoreServices

// MARK: - LiveVolumeManager (Attaches real APFS volume at /Volumes/XDrive & syncs with DriveTree)

private func liveVolumeFSEventCallback(
    streamRef: ConstFSEventStreamRef,
    clientCallBackInfo: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info = clientCallBackInfo else { return }
    let manager = Unmanaged<LiveVolumeManager>.fromOpaque(info).takeUnretainedValue()
    let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
    Task { @MainActor in
        manager.handleFileSystemChanges(paths: paths)
    }
}

@MainActor
public final class LiveVolumeManager: ObservableObject {
    public static let shared = LiveVolumeManager()

    @Published public private(set) var isMounted: Bool = false
    @Published public private(set) var attachedDevice: String?
    @Published public private(set) var statusMessage: String = "Sẵn sàng gắn kết ổ đĩa"

    public static let volumeName = "XDrive"
    public static let mountPointURL = URL(fileURLWithPath: "/Volumes/\(volumeName)")

    public var onFileChanged: (([URL]) -> Void)?

    private var eventStream: FSEventStreamRef?
    private var isMirroring = false

    public init() {
        checkCurrentMount()
    }

    public func checkCurrentMount() {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: Self.mountPointURL.path, isDirectory: &isDir), isDir.boolValue {
            isMounted = true
        } else {
            isMounted = false
            attachedDevice = nil
        }
    }

    public static var bundleURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("XDrive", isDirectory: true)
        return appSupport.appendingPathComponent("XDriveVolume.sparsebundle")
    }

    /// Mounts a real macOS APFS Volume named "XDrive" directly at `/Volumes/XDrive`.
    /// Provisions a 2 TB APFS Sparsebundle dynamically backed by host SSD (virtual 2 TB capacity).
    @discardableResult
    public func mountLiveVolume(initialFilesProvider: (() -> [(name: String, data: Data)])? = nil) async -> Bool {
        if isMounted && FileManager.default.fileExists(atPath: Self.mountPointURL.path) {
            statusMessage = "Đã gắn kết tại /Volumes/\(Self.volumeName)"
            return true
        }

        statusMessage = "Đang chuẩn bị phân vùng 2 TB APFS tại /Volumes/\(Self.volumeName)..."

        do {
            let bundlePath = Self.bundleURL.path

            // 1. Create 2 TB APFS sparsebundle if not already present
            if !FileManager.default.fileExists(atPath: bundlePath) {
                let parentDir = Self.bundleURL.deletingLastPathComponent()
                try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

                let createProc = Process()
                createProc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                createProc.arguments = [
                    "create",
                    "-size", "2TB",
                    "-type", "SPARSEBUNDLE",
                    "-fs", "APFS",
                    "-volname", Self.volumeName,
                    bundlePath
                ]
                try createProc.run()
                createProc.waitUntilExit()

                guard createProc.terminationStatus == 0 else {
                    statusMessage = "Không thể khởi tạo ảnh đĩa 2 TB"
                    return false
                }
            }

            // 2. Attach the sparsebundle -> automounts at /Volumes/XDrive
            let attachProc = Process()
            attachProc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            attachProc.arguments = ["attach", bundlePath]
            let outPipe = Pipe()
            attachProc.standardOutput = outPipe
            try attachProc.run()
            attachProc.waitUntilExit()

            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            if let outStr = String(data: outData, encoding: .utf8) {
                let lines = outStr.components(separatedBy: .newlines)
                for line in lines {
                    let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                    if let first = parts.first, first.hasPrefix("/dev/disk") {
                        attachedDevice = first
                        break
                    }
                }
            }

            // Verify mount point
            guard FileManager.default.fileExists(atPath: Self.mountPointURL.path) else {
                statusMessage = "Chưa tìm thấy /Volumes/\(Self.volumeName) sau khi gắn"
                return false
            }

            isMounted = true
            statusMessage = "Đã gắn kết thành công tại /Volumes/\(Self.volumeName) (2 TB APFS)"

            // 3. Seed initial files if not already present
            if let provider = initialFilesProvider {
                let files = provider()
                for file in files {
                    let target = Self.mountPointURL.appendingPathComponent(file.name)
                    if !FileManager.default.fileExists(atPath: target.path) {
                        try? file.data.write(to: target)
                    }
                }
            }

            // 3b. Set custom squircle icon for /Volumes/XDrive on Finder Sidebar
            if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") ?? Bundle.main.resourceURL?.appendingPathComponent("AppIcon.icns"),
               let iconImg = NSImage(contentsOf: iconURL) {
                NSWorkspace.shared.setIcon(iconImg, forFile: Self.mountPointURL.path, options: [])
            }

            // 4. Activate FinderSync extension for /Volumes/XDrive
            activateFinderSyncExtension()

            // 5. Start real-time FileSystem Watcher (FSEvents)
            startWatching()

            return true
        } catch {
            statusMessage = "Lỗi gắn kết: \(error.localizedDescription)"
            return false
        }
    }

    public func unmountLiveVolume() async {
        stopWatching()
        guard isMounted else { return }
        statusMessage = "Đang tháo ổ đĩa /Volumes/\(Self.volumeName)..."

        let unmountProc = Process()
        unmountProc.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        unmountProc.arguments = ["unmount", Self.mountPointURL.path]
        try? unmountProc.run()
        unmountProc.waitUntilExit()

        if let dev = attachedDevice {
            let ejectProc = Process()
            ejectProc.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
            ejectProc.arguments = ["eject", dev]
            try? ejectProc.run()
            ejectProc.waitUntilExit()
            attachedDevice = nil
        } else {
            let ejectProc = Process()
            ejectProc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            ejectProc.arguments = ["detach", Self.mountPointURL.path, "-force"]
            try? ejectProc.run()
            ejectProc.waitUntilExit()
        }

        isMounted = false
        statusMessage = "Đã ngắt kết nối /Volumes/\(Self.volumeName)"
    }

    /// Automatically registers and activates FinderSync extension using `pluginkit`
    public func activateFinderSyncExtension() {
        let pkProc = Process()
        pkProc.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        pkProc.arguments = ["-e", "use", "-i", "com.letcontactabhi.orbit.finder"]
        try? pkProc.run()
        pkProc.waitUntilExit()
    }

    // MARK: - FSEvents Stream Management

    public func startWatching() {
        guard eventStream == nil else { return }
        guard FileManager.default.fileExists(atPath: Self.mountPointURL.path) else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let pathsToWatch = [Self.mountPointURL.path as CFString] as CFArray
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            liveVolumeFSEventCallback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            flags
        ) else { return }

        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        if FSEventStreamStart(stream) {
            self.eventStream = stream
        }
    }

    public func stopWatching() {
        if let stream = eventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.eventStream = nil
        }
    }

    public func handleFileSystemChanges(paths: [String]) {
        guard !isMirroring else { return }
        let ignoredPrefixes = [".DS_Store", "._", ".Spotlight-V100", ".fseventsd", ".Trashes", ".VolumeIcon"]

        let validURLs = paths.compactMap { path -> URL? in
            let url = URL(fileURLWithPath: path)
            let relativePath = url.path.replacingOccurrences(of: Self.mountPointURL.path, with: "")
            let components = relativePath.split(separator: "/").map(String.init)
            
            // Ignore if any path component starts with "." or belongs to system hidden metadata
            if components.contains(where: { comp in
                comp.hasPrefix(".") || ignoredPrefixes.contains(where: { comp.hasPrefix($0) })
            }) {
                return nil
            }
            return url
        }

        guard !validURLs.isEmpty else { return }
        onFileChanged?(validURLs)
    }

    /// Mirrors an internal node's data out to the real live mount on `/Volumes/XDrive`
    public func mirrorFileToLiveDisk(relativePath: String, data: Data) {
        isMirroring = true
        defer { isMirroring = false }

        let targetURL = Self.mountPointURL.appendingPathComponent(relativePath)
        let parentDir = targetURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        try? data.write(to: targetURL, options: .atomic)
    }

    /// Measures the physical on-disk size (bytes) occupied by XDriveVolume.sparsebundle on Mac SSD
    public func physicalBundleSizeBytes() -> UInt64 {
        let bundleURL = Self.bundleURL
        guard FileManager.default.fileExists(atPath: bundleURL.path) else { return 0 }

        guard let enumerator = FileManager.default.enumerator(
            at: bundleURL,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey],
            options: []
        ) else { return 0 }

        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            if let vals = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]) {
                let size = vals.totalFileAllocatedSize ?? vals.fileAllocatedSize ?? vals.fileSize ?? 0
                total += UInt64(size)
            }
        }
        return total
    }

    /// Runs `hdiutil compact` to reclaim actual physical SSD host space from XDriveVolume.sparsebundle
    @discardableResult
    public func compactSparseBundle() async -> Bool {
        let bundlePath = Self.bundleURL.path
        guard FileManager.default.fileExists(atPath: bundlePath) else { return false }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let compactProc = Process()
                compactProc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                compactProc.arguments = ["compact", bundlePath]
                try? compactProc.run()
                compactProc.waitUntilExit()
                continuation.resume(returning: compactProc.terminationStatus == 0)
            }
        }
    }
}

